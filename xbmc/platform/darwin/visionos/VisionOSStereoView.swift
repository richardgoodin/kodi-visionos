/*
 *  Copyright (C) 2026 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

// =============================================================================
// Windowed stereo presentation for the visionOS Kodi port (RealityKit
// camera-index route — shared-space window preserved; no immersive space).
//
// Kodi renders into 3840x2160 IOSurfaces (VisionOSGLView redirects its FBOs
// there; the CAMetalLayer is never presented).  MONO: each presented frame's
// left surface is blitted into the left LowLevelTexture sink, which feeds
// BOTH eye inputs of the camera-index ShaderGraphMaterial on the display
// plane.  HARDWAREBASED STEREO: Kodi renders each eye into its own surface,
// the pair is published together, each sink gets its eye's frame, and the
// material's rightTexture input is rebound to the right sink (setStereo) —
// per-eye content in the shared-space window.
//
// Proven on device: RealityKit hosting in the UIKit window, camera-index
// per-eye material selection, live IOSurface feed with BufferQueue release
// fences, frozen plane constants (1360 pt/m; glass at z = -270/1360), EDR
// output through the extended-sRGB float chain, FSBS 3D playback.
// =============================================================================

import Foundation
import SwiftUI
import RealityKit
import UIKit
import Metal
import IOSurface

private let kSurfaceWidth = 3840
private let kSurfaceHeight = 2160

/// ObjC-facing presenter.  XBMCController creates one, embeds its
/// `viewController` over the glView, and calls updateWithIOSurface: from the
/// render thread after every finished frame.
@objc(VisionOSStereoPresenter)
public class VisionOSStereoPresenter: NSObject {

  private let bridge = StereoBridge()
  private var hosting: UIViewController?

  @objc public var viewController: UIViewController {
    if let hosting { return hosting }
    let vc = UIHostingController(rootView: StereoScaffoldView(bridge: bridge))
    // Transparent so the borderless shared-space window look is preserved.
    vc.view.backgroundColor = .clear
    hosting = vc
    return vc
  }

  /// Render thread, mono frame.  Only records the surface and schedules
  /// main-actor work.
  @objc public func update(withIOSurface surface: IOSurfaceRef) {
    bridge.submit(left: surface, right: nil)
  }

  /// Render thread, HARDWAREBASED stereo frame: both eyes of one frame,
  /// published together.
  @objc public func update(withLeftIOSurface left: IOSurfaceRef, right: IOSurfaceRef) {
    bridge.submit(left: left, right: right)
  }

  /// The object receiving injected gaze phases (the VisionOSGLView), set by
  /// XBMCController via KVC — no header coupling in either direction.
  @objc public var gazeTarget: NSObject? {
    didSet { bridge.gazeTarget = gazeTarget }
  }
}

/// Shared state between the render-thread publisher and the MainActor
/// RealityKit side.
final class StereoBridge {

  private let lock = NSLock()
  // Coalesced pending frame: left surface always, right surface only for
  // HARDWAREBASED stereo frames.
  private var pendingLeft: IOSurfaceRef?
  private var pendingRight: IOSurfaceRef?

  // MainActor-only state (created in attach/drain).
  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  // One LowLevelTexture sink per eye.  Mono binds the LEFT sink to both
  // material eye inputs (single blit per frame); stereo rebinds the
  // rightTexture parameter to the right sink (setStereo).
  private var lowLevelLeft: LowLevelTexture?
  private var lowLevelRight: LowLevelTexture?
  private var leftResource: TextureResource?
  private var rightResource: TextureResource?
  private var material: ShaderGraphMaterial?
  private var plane: ModelEntity?
  private var stereoBound = false
  private var decodePipeline: MTLComputePipelineState?
  // One cached wrap per render IOSurface (up to four fixed allocations —
  // the producer's two eyes x two BufferQueue slots), keyed by IOSurfaceID.
  private var srcTextures: [UInt32: MTLTexture] = [:]
  private var attached = false

  /// Gaze forwarding: the glView instance and the dynamic call into its
  /// injectGazePhase:x:y: — a C call through the IMP, so Swift needs no
  /// ObjC header for it.
  var gazeTarget: NSObject?
  private static let gazeSel = NSSelectorFromString("injectGazePhase:x:y:")
  private typealias GazeInjectFn = @convention(c) (NSObject, Selector, Int, Double, Double) -> Void

  /// BufferQueue releaseBuffer: same dynamic-IMP route as gaze, into the
  /// glView's releaseSurfaceWithID:.  Callable from any thread (render
  /// thread on coalesce, MainActor on early-outs, Metal completion thread
  /// after a real read).  INVARIANT: every surface handed to submit() gets
  /// exactly one release — instantly if it is never read, or on GPU
  /// completion of the blit that read it.  Before the glView target is set
  /// this no-ops, which is correct: the producer's fence only arms on the
  /// first release it receives.
  private static let releaseSel = NSSelectorFromString("releaseSurfaceWithID:")
  private typealias ReleaseFn = @convention(c) (NSObject, Selector, UInt32) -> Void

  private func sendRelease(_ surfaceID: UInt32) {
    guard let target = gazeTarget, target.responds(to: Self.releaseSel),
          let imp = target.method(for: Self.releaseSel)
    else { return }
    let fn = unsafeBitCast(imp, to: ReleaseFn.self)
    fn(target, Self.releaseSel, surfaceID)
  }

  /// Presentation decode: the float IOSurface holds EXTENDED-sRGB-ENCODED
  /// values (Kodi's GUI writes its normal sRGB output; the HDR video path
  /// will encode linear EDR with the same curve, >1.0 allowed).  This kernel
  /// is the single decode back to linear — exact piecewise EOTF, so SDR
  /// content matches the old .bgra8Unorm_srgb view bit-for-bit.
  private static let decodeKernelSource = """
  #include <metal_stdlib>
  using namespace metal;

  static inline float srgbToLinear(float c)
  {
    return (c <= 0.04045f) ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
  }

  kernel void srgbDecode(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
  {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height())
      return;
    float4 c = src.read(gid);
    dst.write(float4(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b), c.a), gid);
  }
  """

  @MainActor
  func sendGaze(phase: Int, x: Double, y: Double) {
    guard let target = gazeTarget, target.responds(to: Self.gazeSel),
          let imp = target.method(for: Self.gazeSel)
    else { return }
    let fn = unsafeBitCast(imp, to: GazeInjectFn.self)
    fn(target, Self.gazeSel, phase, x, y)
  }

  /// Render thread: coalesce to the newest frame and poke the main actor.
  /// Replaced (never-to-be-read) surfaces are released immediately.
  func submit(left: IOSurfaceRef, right: IOSurfaceRef?) {
    var dropped: [IOSurfaceRef] = []
    lock.lock()
    if let old = pendingLeft, IOSurfaceGetID(old) != IOSurfaceGetID(left) {
      dropped.append(old)
    }
    if let oldRight = pendingRight,
       right == nil || IOSurfaceGetID(oldRight) != IOSurfaceGetID(right!) {
      dropped.append(oldRight)
    }
    pendingLeft = left
    pendingRight = right
    lock.unlock()
    for d in dropped {
      sendRelease(IOSurfaceGetID(d))
    }
    Task { @MainActor in
      self.drain()
    }
  }

  private func takePending() -> (left: IOSurfaceRef, right: IOSurfaceRef?)? {
    lock.lock()
    defer { lock.unlock() }
    guard let left = pendingLeft else { return nil }
    let right = pendingRight
    pendingLeft = nil
    pendingRight = nil
    return (left, right)
  }

  /// Called once by the view after the ShaderGraphMaterial loads: create
  /// the per-eye LowLevelTexture sinks, bind the left one to BOTH eyes
  /// (mono start), put the material on the plane.
  @MainActor
  func attach(material: ShaderGraphMaterial, plane: ModelEntity) {
    do {
      var mat = material
      var desc = LowLevelTexture.Descriptor()
      // EDR TEST: half-float end to end.  NOTE no _srgb variant exists for
      // float formats — Kodi's sRGB-encoded output is sampled as linear, so
      // the UI looks washed out for the duration of this experiment.  The
      // only question is whether the >1.0 probe patch beats UI white.
      desc.pixelFormat = .rgba16Float
      desc.width = kSurfaceWidth
      desc.height = kSurfaceHeight
      // Full mip chain + render-target usage so mips can be generated after
      // each blit: a mip-less 4K texture sampled linearly aliases/shimmers
      // under peripheral (foveated) minification; the window server's own
      // compositing of CAMetalLayer content is properly filtered, which is
      // why the pre-RealityKit path did not shimmer.
      desc.mipmapLevelCount = 12
      desc.textureUsage = [.shaderRead, .shaderWrite, .renderTarget]
      let lltL = try LowLevelTexture(descriptor: desc)
      let lltR = try LowLevelTexture(descriptor: desc)
      let resL = try TextureResource(from: lltL)
      let resR = try TextureResource(from: lltR)
      // Mono start: the LEFT sink feeds both eyes.  setStereo() rebinds
      // rightTexture to the right sink when stereo frames arrive.
      try mat.setParameter(name: "leftTexture", value: .textureResource(resL))
      try mat.setParameter(name: "rightTexture", value: .textureResource(resL))
      plane.model?.materials = [mat]
      lowLevelLeft = lltL
      lowLevelRight = lltR
      leftResource = resL
      rightResource = resR
      self.material = mat
      self.plane = plane
      stereoBound = false
      device = MTLCreateSystemDefaultDevice()
      queue = device?.makeCommandQueue()
      // Compile the sRGB-decode compute pipeline.  Failure is non-fatal:
      // drain() falls back to a plain blit (washed-out but alive).
      do {
        if let device {
          let lib = try device.makeLibrary(source: Self.decodeKernelSource, options: nil)
          if let fn = lib.makeFunction(name: "srgbDecode") {
            decodePipeline = try device.makeComputePipelineState(function: fn)
          } else {
            NSLog("VISIONOS-STEREO: srgbDecode function missing from library")
          }
        }
      } catch {
        NSLog("VISIONOS-STEREO: decode pipeline FAILED, falling back to blit: \(error)")
      }
      attached = true
    } catch {
      NSLog("VISIONOS-STEREO: attach FAILED: \(error)")
    }
  }

  /// Rebind the material's right-eye input when the stream flips between
  /// mono (left sink on both eyes) and stereo (own sink per eye).  Rare —
  /// only on playback stereo-mode transitions.
  @MainActor
  private func setStereo(_ stereo: Bool) {
    guard stereo != stereoBound, var mat = material, let plane,
          let resL = leftResource, let resR = rightResource
    else { return }
    do {
      try mat.setParameter(name: "rightTexture",
                           value: .textureResource(stereo ? resR : resL))
      plane.model?.materials = [mat]
      material = mat
      stereoBound = stereo
    } catch {
      NSLog("VISIONOS-STEREO: right-eye rebind FAILED: \(error)")
    }
  }

  /// Cached IOSurface -> MTLTexture wrap (fixed producer allocations).
  @MainActor
  private func wrap(_ surface: IOSurfaceRef, id: UInt32, device: MTLDevice) -> MTLTexture? {
    if let cached = srcTextures[id] { return cached }
    let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, // EDR: matches the 'RGhA' IOSurfaces
        width: kSurfaceWidth, height: kSurfaceHeight, mipmapped: false)
    d.usage = [.shaderRead]
    guard let tex = device.makeTexture(descriptor: d, iosurface: surface, plane: 0) else {
      NSLog("VISIONOS-STEREO: IOSurface -> MTLTexture wrap FAILED")
      return nil
    }
    srcTextures[id] = tex
    return tex
  }

  /// Encode one eye: decode extended-sRGB -> linear into the sink (or a
  /// plain blit if the pipeline failed to build), then regenerate mips.
  @MainActor
  private func encode(cmd: MTLCommandBuffer, src: MTLTexture, into llt: LowLevelTexture) {
    let dst = llt.replace(using: cmd)
    if let pipeline = decodePipeline,
       let compute = cmd.makeComputeCommandEncoder()
    {
      compute.setComputePipelineState(pipeline)
      compute.setTexture(src, index: 0)
      compute.setTexture(dst, index: 1)
      let w = pipeline.threadExecutionWidth
      let h = pipeline.maxTotalThreadsPerThreadgroup / w
      compute.dispatchThreads(
          MTLSize(width: kSurfaceWidth, height: kSurfaceHeight, depth: 1),
          threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
      compute.endEncoding()
    } else if let blit = cmd.makeBlitCommandEncoder() {
      blit.copy(from: src,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: kSurfaceWidth, height: kSurfaceHeight, depth: 1),
                to: dst,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
      blit.endEncoding()
    }
    if dst.mipmapLevelCount > 1,
       let blit = cmd.makeBlitCommandEncoder()
    {
      blit.generateMipmaps(for: dst)
      blit.endEncoding()
    }
  }

  /// MainActor: blit the newest published frame (one or both eyes) into
  /// the LowLevelTexture sinks.  Every taken surface is released — by the
  /// command buffer's completion handler when the encode commits, or
  /// immediately on any path that returns without committing.
  @MainActor
  func drain() {
    guard let frame = takePending() else { return }
    let leftID = IOSurfaceGetID(frame.left)
    let rightID = frame.right.map { IOSurfaceGetID($0) }

    func releaseAll() {
      sendRelease(leftID)
      if let rightID { sendRelease(rightID) }
    }

    guard attached,
          let device,
          let queue,
          let lltL = lowLevelLeft,
          let lltR = lowLevelRight
    else {
      releaseAll()
      return
    }

    // Keep the right-eye binding in step with the stream.
    setStereo(frame.right != nil)

    guard let srcL = wrap(frame.left, id: leftID, device: device) else {
      releaseAll()
      return
    }
    var srcR: MTLTexture?
    if let right = frame.right {
      srcR = wrap(right, id: rightID!, device: device)
      if srcR == nil {
        releaseAll()
        return
      }
    }

    guard let cmd = queue.makeCommandBuffer() else {
      releaseAll()
      return
    }

    // Release fence: fires on GPU completion of the read — the moment the
    // producer may write these surfaces again.
    cmd.addCompletedHandler { [weak self] _ in
      self?.sendRelease(leftID)
      if let rightID { self?.sendRelease(rightID) }
    }

    encode(cmd: cmd, src: srcL, into: lltL)
    if let srcR {
      encode(cmd: cmd, src: srcR, into: lltR)
    }
    cmd.commit()
  }
}

/// The display plane: camera-index material over the live Kodi surface.
private struct StereoScaffoldView: View {

  let bridge: StereoBridge

  /// Whether a gaze drag is in flight (distinguishes phase 0 from 1).
  @State private var gazeActive = false

  /// Hand-authored camera-index material (node IDs verified against
  /// ShaderGraphCoder's emitter).  Each eye samples its own texture input
  /// through a shared UV node; mono input is a green constant (diagnostic);
  /// sampler defaults magenta/yellow flag "switch OK, texture unbound".
  static let stereoUSDA = """
  #usda 1.0
  (
      defaultPrim = "Root"
      metersPerUnit = 1
      upAxis = "Y"
  )

  def Xform "Root"
  {
      reorder nameChildren = ["StereoTest"]
      def Material "StereoTest"
      {
          asset inputs:leftTexture = ""
          asset inputs:rightTexture = ""
          token outputs:mtlx:surface.connect = </Root/StereoTest/Surface.outputs:out>
          token outputs:realitykit:vertex

          def Shader "Surface"
          {
              uniform token info:id = "ND_realitykit_unlit_surfaceshader"
              color3f inputs:color.connect = </Root/StereoTest/EyeSwitch.outputs:out>
              float inputs:opacity = 1
              bool inputs:applyPostProcessToneMap = 0
              bool inputs:hasPremultipliedAlpha = 0
              token outputs:out
          }

          def Shader "EyeSwitch"
          {
              uniform token info:id = "ND_realitykit_geometry_switch_cameraindex_color3"
              color3f inputs:mono = (0, 1, 0)
              color3f inputs:left.connect = </Root/StereoTest/LeftSample.outputs:out>
              color3f inputs:right.connect = </Root/StereoTest/RightSample.outputs:out>
              color3f outputs:out
          }

          def Shader "UV0"
          {
              uniform token info:id = "ND_texcoord_vector2"
              int inputs:index = 0
              vector2f outputs:out
          }

          def Shader "LeftSample"
          {
              uniform token info:id = "ND_RealityKitTexture2D_color3"
              asset inputs:file.connect = </Root/StereoTest.inputs:leftTexture>
              vector2f inputs:texcoord.connect = </Root/StereoTest/UV0.outputs:out>
              string inputs:mag_filter = "linear"
              string inputs:min_filter = "linear"
              string inputs:mip_filter = "linear"
              int inputs:max_anisotropy = 8
              color3f inputs:default = (1, 0, 1)
              color3f outputs:out
          }

          def Shader "RightSample"
          {
              uniform token info:id = "ND_RealityKitTexture2D_color3"
              asset inputs:file.connect = </Root/StereoTest.inputs:rightTexture>
              vector2f inputs:texcoord.connect = </Root/StereoTest/UV0.outputs:out>
              string inputs:mag_filter = "linear"
              string inputs:min_filter = "linear"
              string inputs:mip_filter = "linear"
              int inputs:max_anisotropy = 8
              color3f inputs:default = (1, 1, 0)
              color3f outputs:out
          }
      }
  }
  """

  /// FROZEN from device measurement (fit() instrumentation, Jul 31): the
  /// RealityView entity space maps points to meters at 1360 pt/m, so the
  /// pinned 1920x1080 pt hosting view is exactly (1920/1360) x (1080/1360) m
  /// (measured extents (1.4117647, 0.7941176) — these ratios exactly).  The
  /// view's volume is 540 pt (0.397 m) deep and the frame is CENTERED on
  /// z=0, so the WINDOW GLASS is at the BACK: z = -270/1360 = -0.1985294 —
  /// device-verified: a plane at z=0 sits one half-depth PROUD of the UI, at
  /// -0.1985 it is coplanar.  Runtime geometry reads are unstable (the frame
  /// re-anchors transiently, e.g. during drags), hence constants.
  static let planeScale = SIMD3<Float>(1920.0 / 1360.0, 1080.0 / 1360.0, 1.0)
  // Exact measured glass depth.  The native stack behind the plane is now
  // fully transparent (clear root view, non-opaque CAMetalLayer), so there
  // is no coplanar surface to z-fight and no nudge is needed.
  static let planePosition = SIMD3<Float>(0.0, 0.0, -270.0 / 1360.0)

  var body: some View {
    RealityView { content in
      // Plane synchronously, from constants — no geometry reads.
      let mesh = MeshResource.generatePlane(width: 1.0, height: 1.0)
      var placeholder = UnlitMaterial()
      placeholder.color = .init(tint: .init(white: 0.1, alpha: 1.0))
      let plane = ModelEntity(mesh: mesh, materials: [placeholder])
      plane.name = "display"
      plane.scale = Self.planeScale
      plane.position = Self.planePosition
      // Gaze/pinch input target: with the native stack fully transparent the
      // system will not target UIKit views (transparent areas are not
      // gaze-targetable on visionOS) — the plane's rendered pixels are the
      // targetable content; the collision shape gives the gesture ray
      // something to hit.
      plane.components.set(InputTargetComponent())
      plane.components.set(
          CollisionComponent(shapes: [.generateBox(width: 1.0, height: 1.0, depth: 0.01)]))
      content.add(plane)

      Task { @MainActor in
        do {
          let stereoMat = try await ShaderGraphMaterial(
              named: "/Root/StereoTest",
              from: Self.stereoUSDA.data(using: .utf8)!)
          bridge.attach(material: stereoMat, plane: plane)
        } catch {
          NSLog("VISIONOS-STEREO: camera-index material FAILED: \(error)")
          var fallback = UnlitMaterial()
          fallback.color = .init(tint: .orange)
          plane.model?.materials = [fallback]
        }
      }
    }
    .gesture(
      DragGesture(minimumDistance: 0)
        .targetedToAnyEntity()
        .onChanged { value in
          let p = Self.gazePoint(value)
          bridge.sendGaze(phase: gazeActive ? 1 : 0, x: p.x, y: p.y)
          gazeActive = true
        }
        .onEnded { value in
          let p = Self.gazePoint(value)
          bridge.sendGaze(phase: 2, x: p.x, y: p.y)
          gazeActive = false
        }
    )
  }

  /// Hit location in the PLANE'S local space mapped to Kodi's 1920x1080
  /// fixed-desktop points: the unit plane spans [-0.5, 0.5] in x/y with +y
  /// up; Kodi's y runs down.
  private static func gazePoint(_ value: EntityTargetValue<DragGesture.Value>) -> (x: Double, y: Double)
  {
    let local = value.convert(value.location3D, from: .local, to: value.entity)
    let x = (Double(local.x) + 0.5) * 1920.0
    let y = (0.5 - Double(local.y)) * 1080.0
    return (x, y)
  }
}
