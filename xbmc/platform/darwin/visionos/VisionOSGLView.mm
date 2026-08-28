/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/VisionOSGLView.h"

#include "messaging/ApplicationMessenger.h"
#include "platform/darwin/visionos/VisionOSLog.h"

#import "platform/darwin/visionos/VisionOSDesktop.h"
#import "platform/darwin/visionos/XBMCController.h"

#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

// GLES headers from ANGLE
#include <GLES3/gl3.h>

#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

// Shared sequence number for the frame-timing logs below (single render
// thread).  Commented out with them — re-enable together.
// static int s_stereoLogSeq = 0;

// ANGLE EGL extension for Metal layer surfaces
#ifndef EGL_ANGLE_platform_angle_metal
#define EGL_ANGLE_platform_angle_metal 1
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

namespace
{
// Gaze/pinch tuning. See README_visionos.md for the reasoning.

// A pinch must be held this long, without movement, before it counts as a
// press. Enter is not sent until it expires, so a drag can still cancel it.
constexpr NSTimeInterval GAZE_ARM_DELAY = 0.50; // Apple long-press: 0.5 s stationary commits to hold; movement before then cancels

// Delay after arming before a second KEYDOWN is sent. Must EXCEED Kodi
// KEYBOARD::KEY_HOLD_TRESHOLD (250ms), or CKeyboardStat::TranslateKey never
// sets MODIFIER_LONG and the longpress action in the keymap cannot fire.
constexpr NSTimeInterval GAZE_HOLD_REPEAT_DELAY = 0.26;

// Minimum travel, in fixed-desktop points, before a pinch counts as a drag.
constexpr CGFloat GAZE_DRAG_THRESHOLD = 12.0; // Apple-style movement allowance; direction resolved on release, so this only detects motion

// Minor/major axis ratio above which a drag is too diagonal to resolve.
// 0.5 is +/- 27 degrees from an axis.
constexpr CGFloat GAZE_DIAGONAL_LIMIT = 0.5;

// Distance from the left edge, in fixed-desktop points, within which a drag
// resolving Right is treated as Back instead.
constexpr CGFloat GAZE_EDGE_MARGIN = 60.0;
} // namespace

@interface VisionOSGLView ()
@property(nonatomic, strong) NSTimer* gazeHoldTimer;
@property(nonatomic, strong) NSTimer* gazeArmTimer;
@property(nonatomic, assign) CGPoint gazeStart;
@property(nonatomic, assign) BOOL gazeIsDrag;
@property(nonatomic, assign) BOOL gazeEnterDown;
@end

@implementation VisionOSGLView

@synthesize eglContext = m_eglContext;
@synthesize eglDisplay = m_eglDisplay;
@synthesize eglSurface = m_eglSurface;
@synthesize rightEyeDrawn = m_rightEyeDrawn;

// The buffer just completed — valid between glFinish and the index flip in
// presentFramebuffer, which is exactly when the publish path reads it.
// Left eye: also the mono-path surface.
- (IOSurfaceRef)renderSurface
{
  return m_renderSurfaces[0][m_renderIndex];
}

// Right-eye counterpart, same slot.
- (IOSurfaceRef)renderSurfaceRight
{
  return m_renderSurfaces[1][m_renderIndex];
}

// visionOS uses CAMetalLayer as the backing layer for ANGLE
+ (Class)layerClass
{
  return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame]))
  {
    CGFloat scale = [self getScreenScale];
    self.contentScaleFactor = scale;

    CAMetalLayer* metalLayer = static_cast<CAMetalLayer*>(self.layer);
    metalLayer.contentsScale = scale;
    self.userInteractionEnabled = YES;

    UILongPressGestureRecognizer* press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(gazePressed:)];
    press.minimumPressDuration = 0.0;
    [self addGestureRecognizer:press];
    VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze recognizer installed");
    // RealityKit-Mono: the layer is NOT a render target (EGL never touches
    // it) and must contribute NOTHING visually — an opaque never-presented
    // CAMetalLayer composites as solid black at the glass depth and
    // z-fights the display plane (the "popping against black").  Fully
    // transparent: the RealityKit plane is the only rectangle rendered.
    metalLayer.opaque = NO;
    metalLayer.backgroundColor = UIColor.clearColor.CGColor;
    self.backgroundColor = UIColor.clearColor;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;

    if (![self initEGL])
    {
      VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: failed to initialise ANGLE EGL");
      return nil;
    }

    // RealityKit-Mono: the actual display targets.  Kodi renders into these
    // IOSurfaces (via FBOs set up lazily on the render thread); the
    // RealityKit plane samples the published one.  Physical size matches the
    // fixed desktop: 1920x1080 pt at 2x = 3840x2160 px.  Two-slot
    // BufferQueue: buffer 0 is implicitly acquired at startup (drawn first
    // without a wait), so its release sem starts at 0 credits; buffer 1
    // starts free with 1 credit.
    NSDictionary* surfProps = @{
      (id)kIOSurfaceWidth : @(3840),
      (id)kIOSurfaceHeight : @(2160),
      // EDR: 64RGBAHalf (8 bytes/element) instead of BGRA8.
      (id)kIOSurfaceBytesPerElement : @(8),
      (id)kIOSurfacePixelFormat : @((uint32_t)'RGhA'),
    };
    for (int eye = 0; eye < 2; ++eye)
    {
      for (int i = 0; i < 2; ++i)
      {
        m_renderSurfaces[eye][i] = IOSurfaceCreate((__bridge CFDictionaryRef)surfProps);
        if (!m_renderSurfaces[eye][i])
          VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: IOSurfaceCreate failed (eye {} buffer {})",
                             eye, i);
      }
    }
    // Per-SLOT release fences (both eyes of a frame share a slot and flip
    // together), delivery-gated: sems start empty and the dequeue only
    // waits for surfaces that were actually delivered (m_outstanding) —
    // see the header comment.
    for (int i = 0; i < 2; ++i)
    {
      m_releaseSems[i] = dispatch_semaphore_create(0);
      m_outstanding[i] = 0;
    }
    m_renderIndex = 0;
    m_currentEye = 0;
    m_rightEyeDrawn = NO;

    // Presentation-rate sync (replaces eglSwapBuffers' implicit vsync
    // blocking): tick at the display's real refresh rate, signal the render
    // thread.
    m_vsyncSem = dispatch_semaphore_create(0);
    // Dedicated thread: on the main run loop 5-15% of ticks were dropped
    // under load (RealityKit blits / SwiftUI share the main thread),
    // stretching presentFramebuffer's vsync wait to 16.7 ms at random —
    // visible as intermittent stutter in 24p playback.  The link is
    // created on the thread it runs on.  (No preferredFrameRateRange
    // request: the probe showed the M5 panel already runs 120 Hz — an
    // exact 5x multiple of 24 fps — and ignored a 96 Hz hint.)
    m_vsyncThread = [[NSThread alloc] initWithTarget:self
                                            selector:@selector(vsyncThreadMain)
                                              object:nil];
    m_vsyncThread.name = @"Kodi-vsync";
    m_vsyncThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [m_vsyncThread start];
  }
  return self;
}

- (BOOL)initEGL
{
  // Obtain the system default Metal device
  id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
  if (!metalDevice)
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: no Metal device");
    return NO;
  }

  // Create an ANGLE EGLDisplay backed by the Metal device
  EGLAttrib displayAttribs[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
      EGL_NONE};

  m_eglDisplay = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                       (__bridge void*)metalDevice,
                                       displayAttribs);
  if (m_eglDisplay == EGL_NO_DISPLAY)
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: eglGetPlatformDisplay failed");
    return NO;
  }

  EGLint major, minor;
  if (!eglInitialize(m_eglDisplay, &major, &minor))
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: eglInitialize failed");
    return NO;
  }
  VISIONOS_SHELL_LOG(LOGINFO, "VisionOSGLView: EGL {}.{} on Metal", major, minor);

  // Choose config.  EGL_SURFACE_TYPE must include PBUFFER: the context's
  // current draw surface is an offscreen pbuffer (the CAMetalLayer is not
  // used by EGL at all — a window surface on a never-presented layer makes
  // ANGLE block on the layer's exhausted drawable pool, stalling every
  // frame boundary to timeout cadence: the ~10 s/frame symptom).
  const EGLint configAttribs[] = {
      EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
      EGL_RED_SIZE, 8,
      EGL_GREEN_SIZE, 8,
      EGL_BLUE_SIZE, 8,
      EGL_ALPHA_SIZE, 8,
      EGL_DEPTH_SIZE, 16,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_NONE};

  EGLint numConfigs = 0;
  if (!eglChooseConfig(m_eglDisplay, configAttribs, &m_eglConfig, 1, &numConfigs) || numConfigs < 1)
  {
    // Fallback to GLES 2
    const EGLint fallbackAttribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 16,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE};
    if (!eglChooseConfig(m_eglDisplay, fallbackAttribs, &m_eglConfig, 1, &numConfigs) ||
        numConfigs < 1)
    {
      VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: eglChooseConfig failed");
      return NO;
    }
  }

  // Create context
  const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  m_eglContext = eglCreateContext(m_eglDisplay, m_eglConfig, EGL_NO_CONTEXT, ctxAttribs);
  if (m_eglContext == EGL_NO_CONTEXT)
  {
    const EGLint ctxAttribs2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    m_eglContext =
        eglCreateContext(m_eglDisplay, m_eglConfig, EGL_NO_CONTEXT, ctxAttribs2);
  }
  if (m_eglContext == EGL_NO_CONTEXT)
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: eglCreateContext failed");
    return NO;
  }

  // Offscreen current-surface: a plain pbuffer at the render resolution.
  // NOT the render target (Kodi draws into the IOSurface FBO) — it exists
  // so the context has a valid current draw surface and so
  // CWinSystemVisionOS::GetScreenResolution's eglQuerySurface reports
  // 3840x2160.  The CAMetalLayer is deliberately absent from EGL entirely.
  const EGLint pbufferAttribs[] = {EGL_WIDTH, 3840, EGL_HEIGHT, 2160, EGL_NONE};
  m_eglSurface = eglCreatePbufferSurface(m_eglDisplay, m_eglConfig, pbufferAttribs);
  if (m_eglSurface == EGL_NO_SURFACE)
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: eglCreatePbufferSurface failed (err={})",
                       eglGetError());
    return NO;
  }

  // Cache framebuffer dimensions (surface query does not require the context to be current)
  eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_WIDTH, &m_framebufferWidth);
  eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_HEIGHT, &m_framebufferHeight);
  VISIONOS_SHELL_LOG(LOGINFO, "VisionOSGLView: surface {}x{}", m_framebufferWidth,
                     m_framebufferHeight);

  // Do NOT call eglMakeCurrent here.  The context must be first bound on the
  // XBMC_Run background thread (not the UIKit main thread), otherwise the render
  // thread's eglMakeCurrent call returns EGL_BAD_ACCESS (0x3002).
  // setFramebuffer is the authoritative place that binds the context.

  return YES;
}

- (void)dealloc
{
  if (m_eglDisplay != EGL_NO_DISPLAY)
  {
    eglMakeCurrent(m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (m_eglSurface != EGL_NO_SURFACE)
      eglDestroySurface(m_eglDisplay, m_eglSurface);
    if (m_eglContext != EGL_NO_CONTEXT)
      eglDestroyContext(m_eglDisplay, m_eglContext);
    eglTerminate(m_eglDisplay);
  }
}

- (void)releaseContext
{
  // Detach the EGL context from the current thread so a background render
  // thread can acquire it via eglMakeCurrent.  Must be called on the main
  // thread before startAnimation spins up the XBMC_Run NSThread.
  if (m_eglDisplay != EGL_NO_DISPLAY)
    eglMakeCurrent(m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

- (void)setFramebuffer
{
  if (m_eglContext != EGL_NO_CONTEXT)
  {
    // Rebind if the context is not current OR if the draw surface has changed
    // (e.g. layoutSubviews recreated m_eglSurface while we were rendering to
    // the old one).  Without the surface check, the render thread keeps drawing
    // to the destroyed surface while presentFramebuffer swaps a blank new one,
    // producing a partial / missing-items frame.
    if (eglGetCurrentContext() != m_eglContext ||
        eglGetCurrentSurface(EGL_DRAW) != m_eglSurface)
      eglMakeCurrent(m_eglDisplay, m_eglSurface, m_eglSurface, m_eglContext);

    // RealityKit: first call on the render thread builds the
    // IOSurface-backed FBOs (needs a current context, which the main thread
    // deliberately never holds).
    if (!m_renderFBOs[0][0] && m_renderSurfaces[0][0])
      [self setupRenderTarget];

    if (m_renderFBOs[m_currentEye][m_renderIndex])
    {
      glBindFramebuffer(GL_FRAMEBUFFER, m_renderFBOs[m_currentEye][m_renderIndex]);
      // Frame timing (1/3), with s_stereoLogSeq at the top of the file:
      // NSLog(@"VISIONOS-STEREO: #%d draw-start %.6f", ++s_stereoLogSeq, CACurrentMediaTime());
    }
    else
      glBindFramebuffer(GL_FRAMEBUFFER, 0); // ANGLE default framebuffer
    glViewport(0, 0, m_framebufferWidth, m_framebufferHeight);
    glScissor(0, 0, m_framebufferWidth, m_framebufferHeight);
  }
}

// Build the FBOs whose color attachments are the shared IOSurfaces (two
// eyes x two slots), using the same ANGLE client-buffer mechanism the VTB
// renderer uses for decode surfaces — in reverse (render INTO the
// IOSurface instead of sampling it).  Must run on the render thread with
// the EGL context current.  All-or-nothing: any failure zeroes every FBO.
- (void)setupRenderTarget
{
  const EGLint cfgAttribs[] = {EGL_SURFACE_TYPE,         EGL_PBUFFER_BIT,
                               EGL_RENDERABLE_TYPE,      EGL_OPENGL_ES2_BIT,
                               EGL_RED_SIZE,             8,
                               EGL_GREEN_SIZE,           8,
                               EGL_BLUE_SIZE,            8,
                               EGL_ALPHA_SIZE,           8,
                               EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
                               EGL_NONE};
  EGLConfig cfg = nullptr;
  EGLint numConfigs = 0;
  if (!eglChooseConfig(m_eglDisplay, cfgAttribs, &cfg, 1, &numConfigs) || numConfigs < 1)
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: stereo pbuffer eglChooseConfig failed (0x{:x})",
                       static_cast<unsigned>(eglGetError()));
    return;
  }

  // One depth renderbuffer shared by both FBOs: only one is ever the draw
  // target at a time, and the consumer never reads depth.
  glGenRenderbuffers(1, &m_renderDepthRB);
  glBindRenderbuffer(GL_RENDERBUFFER, m_renderDepthRB);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, 3840, 2160);

  for (int eye = 0; eye < 2; ++eye)
  {
    for (int i = 0; i < 2; ++i)
    {
      const EGLint attribs[] = {EGL_WIDTH,
                                3840,
                                EGL_HEIGHT,
                                2160,
                                EGL_IOSURFACE_PLANE_ANGLE,
                                0,
                                EGL_TEXTURE_TARGET,
                                EGL_TEXTURE_2D,
                                EGL_TEXTURE_FORMAT,
                                EGL_TEXTURE_RGBA,
                                // EDR: ANGLE's IOSurface table maps
                                // (GL_RGBA, GL_HALF_FLOAT) -> R16G16B16A16_FLOAT
                                // (IOSurfaceSurfaceMtl.mm line 55).
                                EGL_TEXTURE_INTERNAL_FORMAT_ANGLE,
                                GL_RGBA,
                                EGL_TEXTURE_TYPE_ANGLE,
                                GL_HALF_FLOAT,
                                EGL_NONE};
      m_renderPbuffers[eye][i] = eglCreatePbufferFromClientBuffer(
          m_eglDisplay, EGL_IOSURFACE_ANGLE,
          reinterpret_cast<EGLClientBuffer>(m_renderSurfaces[eye][i]), cfg, attribs);
      if (m_renderPbuffers[eye][i] == EGL_NO_SURFACE)
      {
        VISIONOS_SHELL_LOG(
            LOGERROR,
            "VisionOSGLView: render-target eglCreatePbufferFromClientBuffer failed (eye {} buffer {}, 0x{:x})",
            eye, i, static_cast<unsigned>(eglGetError()));
        [self teardownRenderTargets];
        return;
      }

      glGenTextures(1, &m_renderTextures[eye][i]);
      glBindTexture(GL_TEXTURE_2D, m_renderTextures[eye][i]);
      if (!eglBindTexImage(m_eglDisplay, m_renderPbuffers[eye][i], EGL_BACK_BUFFER))
      {
        VISIONOS_SHELL_LOG(
            LOGERROR,
            "VisionOSGLView: render-target eglBindTexImage failed (eye {} buffer {}, 0x{:x})", eye,
            i, static_cast<unsigned>(eglGetError()));
        [self teardownRenderTargets];
        return;
      }
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glBindTexture(GL_TEXTURE_2D, 0);

      glGenFramebuffers(1, &m_renderFBOs[eye][i]);
      glBindFramebuffer(GL_FRAMEBUFFER, m_renderFBOs[eye][i]);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                             m_renderTextures[eye][i], 0);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
                                m_renderDepthRB);

      const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
      if (status != GL_FRAMEBUFFER_COMPLETE)
      {
        VISIONOS_SHELL_LOG(LOGERROR,
                           "VisionOSGLView: render-target FBO eye {} slot {} incomplete (0x{:x})",
                           eye, i, static_cast<unsigned>(status));
        [self teardownRenderTargets];
        return;
      }
    }
  }
}

// Failure path for setupRenderTarget: return to the no-FBO state (all
// zero) so setFramebuffer falls back to the default framebuffer.
- (void)teardownRenderTargets
{
  for (int eye = 0; eye < 2; ++eye)
  {
    for (int i = 0; i < 2; ++i)
    {
      if (m_renderFBOs[eye][i])
        glDeleteFramebuffers(1, &m_renderFBOs[eye][i]);
      m_renderFBOs[eye][i] = 0;
      if (m_renderTextures[eye][i])
        glDeleteTextures(1, &m_renderTextures[eye][i]);
      m_renderTextures[eye][i] = 0;
      if (m_renderPbuffers[eye][i] != EGL_NO_SURFACE)
        eglDestroySurface(m_eglDisplay, m_renderPbuffers[eye][i]);
      m_renderPbuffers[eye][i] = EGL_NO_SURFACE;
    }
  }
  if (m_renderDepthRB)
    glDeleteRenderbuffers(1, &m_renderDepthRB);
  m_renderDepthRB = 0;
}

// HARDWAREBASED stereo eye selection — render thread only (called from
// CWinSystemVisionOS::SetStereoMode during the per-eye passes).  Rebinds
// the FBO immediately: SetStereoView runs between BeginRender's
// setFramebuffer and the pass's draw calls, so the bind must not wait for
// the next setFramebuffer.
- (void)selectEye:(int)eye
{
  m_currentEye = (eye == 1) ? 1 : 0;
  if (m_currentEye == 1)
    m_rightEyeDrawn = YES;
  if (m_renderFBOs[m_currentEye][m_renderIndex] && eglGetCurrentContext() == m_eglContext)
    glBindFramebuffer(GL_FRAMEBUFFER, m_renderFBOs[m_currentEye][m_renderIndex]);
}

// Dedicated run-loop thread for the vsync display link — the link is the
// run loop's only source and is never invalidated (the view lives for the
// app's lifetime).
- (void)vsyncThreadMain
{
  @autoreleasepool
  {
    m_vsyncLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(vsyncTick:)];
    [m_vsyncLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [[NSRunLoop currentRunLoop] run];
  }
}

// Measured panel refresh rate (0.0 before the first tick).
- (double)displayRate
{
  CADisplayLink* link = m_vsyncLink;
  if (link && link.duration > 0)
    return round(1.0 / link.duration);
  return 0.0;
}

- (void)vsyncTick:(CADisplayLink*)link
{
  // Measured-rate probe, disabled in place (re-enable for display-rate
  // debugging — prints once a second):
  // static double lastLog = 0;
  // static int ticks = 0;
  // ++ticks;
  // const double now = CACurrentMediaTime();
  // if (lastLog == 0)
  //   lastLog = now;
  // else if (now - lastLog >= 1.0)
  // {
  //   NSLog(@"VISIONOS-VSYNC: %.1f Hz (link duration %.2f ms)", ticks / (now - lastLog),
  //         (link.targetTimestamp - link.timestamp) * 1000.0);
  //   ticks = 0;
  //   lastLog = now;
  // }
  dispatch_semaphore_signal(m_vsyncSem);
}

- (bool)presentFramebuffer
{
  if (m_eglDisplay == EGL_NO_DISPLAY || m_eglSurface == EGL_NO_SURFACE)
    return false;

  if (m_renderFBOs[0][m_renderIndex])
  {
    // Frame timing (2/3) — CPU draw complete, before the vsync wait:
    // NSLog(@"VISIONOS-STEREO: #%d draw-done %.6f", ++s_stereoLogSeq, CACurrentMediaTime());

    // Sync to the PRESENTATION RATE: drain any stale vsync signals, then
    // block until the next display-link tick — the same contract
    // eglSwapBuffers used to provide.  No timeout: if the display link is
    // not ticking at 90 Hz we are dead anyway, and a hard block makes that
    // visible instead of masking it.
    if (m_vsyncSem)
    {
      while (dispatch_semaphore_wait(m_vsyncSem, DISPATCH_TIME_NOW) == 0)
        ;
      dispatch_semaphore_wait(m_vsyncSem, DISPATCH_TIME_FOREVER);
    }

    glFinish();
    // Frame timing (3/3) — after vsync wait + glFinish:
    // NSLog(@"VISIONOS-STEREO: #%d draw-end %.6f", ++s_stereoLogSeq, CACurrentMediaTime());

    // Publish the completed frame (renderSurface/renderSurfaceRight
    // getters return the current slot; the pair goes out together when the
    // right eye was drawn), then dequeue the other slot for the next
    // frame.  Count one pending release per surface the presenter actually
    // took.
    const BOOL delivered = [g_xbmcController publishStereoSurface];
    if (delivered)
      m_outstanding[m_renderIndex] += m_rightEyeDrawn ? 2 : 1;

    const int next = m_renderIndex ^ 1;
    // BufferQueue dequeue: collect the consumer's releases for every
    // surface of the target slot still outstanding.  With two slots and a
    // ~2 ms blit these are almost always already signaled; they block only
    // when the main actor is a full frame behind — backpressure instead of
    // corruption.  Bounded so a broken release path degrades (with a log)
    // instead of hanging.
    while (m_outstanding[next] > 0)
    {
      if (dispatch_semaphore_wait(m_releaseSems[next],
                                  dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) != 0)
      {
        VISIONOS_SHELL_LOG(LOGWARNING,
                           "VisionOSGLView: release fence timeout on slot {} ({} outstanding) — proceeding",
                           next, m_outstanding[next]);
        m_outstanding[next] = 0;
        break;
      }
      --m_outstanding[next];
    }
    m_renderIndex = next;
    m_rightEyeDrawn = NO;
    return true;
  }

  return eglSwapBuffers(m_eglDisplay, m_eglSurface) == EGL_TRUE;
}

// BufferQueue releaseBuffer: the Swift blit's GPU-completion handler ends
// up here (any thread).  Both eyes of a slot signal the same per-slot sem
// — the dequeue knows how many signals to collect (m_outstanding).
- (void)releaseSurfaceWithID:(uint32_t)surfaceID
{
  for (int eye = 0; eye < 2; ++eye)
  {
    for (int i = 0; i < 2; ++i)
    {
      if (m_renderSurfaces[eye][i] && IOSurfaceGetID(m_renderSurfaces[eye][i]) == surfaceID)
      {
        dispatch_semaphore_signal(m_releaseSems[i]);
        return;
      }
    }
  }
  VISIONOS_SHELL_LOG(LOGWARNING, "VisionOSGLView: release for unknown IOSurfaceID {}", surfaceID);
}

- (CGFloat)getScreenScale
{
  // UIScreen is unavailable on visionOS; use a fixed logical scale of 2×.
  return VISIONOS_DESKTOP_SCALE;
}


- (void)gazeArmFired:(NSTimer*)t
{
  self.gazeArmTimer = nil;
  self.gazeEnterDown = YES;
  VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze hold begun (stationary 0.5s), Enter down");
  [g_xbmcController sendKeyDown:XBMCK_RETURN];
  self.gazeHoldTimer = [NSTimer scheduledTimerWithTimeInterval:GAZE_HOLD_REPEAT_DELAY target:self selector:@selector(gazeHoldFired:) userInfo:nil repeats:NO];
}

- (void)gazeHoldFired:(NSTimer*)t
{
  VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze hold threshold, repeat Enter down");
  [g_xbmcController sendKeyDown:XBMCK_RETURN];
}

- (void)gazeDragChanged:(CGPoint)p
{
  if (self.gazeIsDrag || self.gazeEnterDown)
    return;
  CGFloat dx = p.x - self.gazeStart.x;
  CGFloat dy = p.y - self.gazeStart.y;
  if (fabs(dx) < GAZE_DRAG_THRESHOLD && fabs(dy) < GAZE_DRAG_THRESHOLD)
    return;
  [self.gazeArmTimer invalidate];
  self.gazeArmTimer = nil;
  self.gazeIsDrag = YES;
  VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze drag started");
}

- (void)gazeDragEnded:(CGPoint)p
{
  CGFloat dx = p.x - self.gazeStart.x;
  CGFloat dy = p.y - self.gazeStart.y;
  CGFloat ax = fabs(dx), ay = fabs(dy);
  CGFloat hi = fmax(ax, ay), lo = fmin(ax, ay);
  if (hi <= 0.0 || lo / hi >= GAZE_DIAGONAL_LIMIT)
  {
    VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze drag indeterminate dx={:.1f} dy={:.1f}", dx, dy);
    return;
  }
  XBMCKey k = (ax > ay) ? (dx > 0 ? XBMCK_RIGHT : XBMCK_LEFT)
                        : (dy > 0 ? XBMCK_DOWN : XBMCK_UP);
  if (k == XBMCK_RIGHT && self.gazeStart.x < GAZE_EDGE_MARGIN)
    k = XBMCK_ESCAPE;
  VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze drag dx={:.1f} dy={:.1f} startx={:.1f} key={}", dx, dy, self.gazeStart.x, (int)k);
  [g_xbmcController sendKey:k];
}

- (void)injectGazePhase:(NSInteger)phase x:(double)x y:(double)y
{
  CGPoint p = CGPointMake(x, y);
  if (phase == 0)
  {
    VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze down x={:.1f} y={:.1f}", p.x, p.y);
    self.gazeStart = p;
    self.gazeIsDrag = NO;
    self.gazeEnterDown = NO;
    self.gazeArmTimer = [NSTimer scheduledTimerWithTimeInterval:GAZE_ARM_DELAY target:self selector:@selector(gazeArmFired:) userInfo:nil repeats:NO];
  }
  else if (phase == 1)
  {
    [self gazeDragChanged:p];
  }
  else
  {
    [self.gazeHoldTimer invalidate];
    self.gazeHoldTimer = nil;
    VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze up x={:.1f} y={:.1f}", p.x, p.y);
    [self.gazeArmTimer invalidate];
    self.gazeArmTimer = nil;
    if (self.gazeEnterDown)
    {
      self.gazeEnterDown = NO;
      [g_xbmcController sendKeyUp:XBMCK_RETURN];
    }
    else if (!self.gazeIsDrag)
    {
      VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSGLView: gaze quick pinch, Enter");
      [g_xbmcController sendKeyWithUnicode:XBMCK_RETURN];
    }
    else
    {
      [self gazeDragEnded:p];
    }
  }
}

- (void)gazePressed:(UILongPressGestureRecognizer*)g
{
  CGPoint p = [g locationInView:self];
  if (g.state == UIGestureRecognizerStateBegan)
    [self injectGazePhase:0 x:p.x y:p.y];
  else if (g.state == UIGestureRecognizerStateChanged)
    [self injectGazePhase:1 x:p.x y:p.y];
  else if (g.state == UIGestureRecognizerStateEnded ||
           g.state == UIGestureRecognizerStateCancelled)
    [self injectGazePhase:2 x:p.x y:p.y];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  // EGL no longer touches the CAMetalLayer (offscreen pbuffer + IOSurface
  // FBO), and the fixed-desktop model keeps this view's bounds constant —
  // nothing to recreate on layout.
}

@end
