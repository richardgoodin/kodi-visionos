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
// CURRENT STATE — "RealityKit Mono": Kodi renders into a 3840x2160 IOSurface
// (VisionOSGLView redirects its FBO there; the CAMetalLayer is no longer
// presented).  Each presented frame is published here, blitted into a
// LowLevelTexture, and sampled by BOTH eye inputs of the camera-index
// ShaderGraphMaterial on the display plane.  If UI + input + video all work
// through this path, it gets committed as "RealityKit Mono"; stereo is then
// a second surface + the left/right parameters diverging.
//
// Proven earlier on this ladder: RealityKit hosting in the UIKit window,
// camera-index per-eye material selection (red-left/blue-right on device),
// textures through the switch, frozen plane constants (1360 pt/m; glass at
// z = -270/1360).
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

  /// Render thread.  Only records the surface and schedules main-actor work.
  @objc public func update(withIOSurface surface: IOSurfaceRef) {
    bridge.submit(surface)
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
  private var pendingSurface: IOSurfaceRef?

  // MainActor-only state (created in attach/drain).
  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var lowLevel: LowLevelTexture?
  private var decodePipeline: MTLComputePipelineState?
  // One cached wrap per render IOSurface (two fixed allocations — the
  // producer's two-slot BufferQueue), keyed by IOSurfaceID.
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

  /// Render thread: coalesce to the newest surface and poke the main actor.
  /// A replaced (never-to-be-read) surface is released immediately.
  func submit(_ surface: IOSurfaceRef) {
    var dropped: IOSurfaceRef?
    lock.lock()
    if let old = pendingSurface, IOSurfaceGetID(old) != IOSurfaceGetID(surface) {
      dropped = old
    }
    pendingSurface = surface
    lock.unlock()
    if let dropped {
      sendRelease(IOSurfaceGetID(dropped))
    }
    Task { @MainActor in
      self.drain()
    }
  }

  private func takePending() -> IOSurfaceRef? {
    lock.lock()
    defer { lock.unlock() }
    let s = pendingSurface
    pendingSurface = nil
    return s
  }

  /// Called once by the view after the ShaderGraphMaterial loads: create the
  /// LowLevelTexture sink, bind it to BOTH eyes (mono), put the material on
  /// the plane.
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
      let llt = try LowLevelTexture(descriptor: desc)
      let resource = try TextureResource(from: llt)
      try mat.setParameter(name: "leftTexture", value: .textureResource(resource))
      try mat.setParameter(name: "rightTexture", value: .textureResource(resource))
      plane.model?.materials = [mat]
      lowLevel = llt
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

  /// MainActor: blit the newest published frame into the LowLevelTexture.
  /// Every taken surface is released — by the command buffer's completion
  /// handler when the blit commits, or immediately on any path that
  /// returns without committing.
  @MainActor
  func drain() {
    guard let surface = takePending() else { return }
    let surfaceID = IOSurfaceGetID(surface)

    guard attached,
          let device,
          let queue,
          let llt = lowLevel
    else {
      sendRelease(surfaceID)
      return
    }

    var src = srcTextures[surfaceID]
    if src == nil {
      let d = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba16Float, // EDR: matches the 'RGhA' IOSurfaces
          width: kSurfaceWidth, height: kSurfaceHeight, mipmapped: false)
      d.usage = [.shaderRead]
      src = device.makeTexture(descriptor: d, iosurface: surface, plane: 0)
      if src == nil {
        NSLog("VISIONOS-STEREO: IOSurface -> MTLTexture wrap FAILED")
        sendRelease(surfaceID)
        return
      }
      srcTextures[surfaceID] = src
    }
    guard let src,
          let cmd = queue.makeCommandBuffer()
    else {
      sendRelease(surfaceID)
      return
    }

    // Release fence: fires on GPU completion of the read — the moment the
    // producer may write this surface again.
    cmd.addCompletedHandler { [weak self] _ in
      self?.sendRelease(surfaceID)
    }

    let dst = llt.replace(using: cmd)

    if let pipeline = decodePipeline,
       let compute = cmd.makeComputeCommandEncoder()
    {
      // Decode extended-sRGB -> linear while copying into the LowLevelTexture.
      compute.setComputePipelineState(pipeline)
      compute.setTexture(src, index: 0)
      compute.setTexture(dst, index: 1)
      let w = pipeline.threadExecutionWidth
      let h = pipeline.maxTotalThreadsPerThreadgroup / w
      compute.dispatchThreads(
          MTLSize(width: kSurfaceWidth, height: kSurfaceHeight, depth: 1),
          threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
      compute.endEncoding()
      if dst.mipmapLevelCount > 1,
         let blit = cmd.makeBlitCommandEncoder()
      {
        blit.generateMipmaps(for: dst)
        blit.endEncoding()
      }
      cmd.commit()
      return
    }

    // Fallback: straight blit (no decode).
    guard let blit = cmd.makeBlitCommandEncoder() else {
      // Never committed — the completion handler will not fire.
      sendRelease(surfaceID)
      return
    }
    blit.copy(from: src,
              sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: kSurfaceWidth, height: kSurfaceHeight, depth: 1),
              to: dst,
              destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    if dst.mipmapLevelCount > 1 {
      blit.generateMipmaps(for: dst)
    }
    blit.endEncoding()
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
