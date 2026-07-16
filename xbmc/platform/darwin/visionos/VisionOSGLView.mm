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

#import "platform/darwin/visionos/XBMCController.h"

#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

// GLES headers from ANGLE
#include <GLES3/gl3.h>

// ANGLE EGL extension for Metal layer surfaces
#ifndef EGL_ANGLE_platform_angle_metal
#define EGL_ANGLE_platform_angle_metal 1
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

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
    NSLog(@"VISIONOS-GAZE probe installed (no hoverStyle)");
    metalLayer.opaque = YES;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // VISIONOS_STAGE2: framebufferOnly=NO enables readbacks needed for some effects

    if (![self initEGL])
    {
      VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: failed to initialise ANGLE EGL");
      return nil;
    }
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

  // Choose config
  const EGLint configAttribs[] = {
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

  // Create window surface from the CAMetalLayer
  CAMetalLayer* metalLayer = static_cast<CAMetalLayer*>(self.layer);
  m_eglSurface = eglCreateWindowSurface(m_eglDisplay, m_eglConfig,
                                        (__bridge EGLNativeWindowType)metalLayer, nullptr);
  if (m_eglSurface == EGL_NO_SURFACE)
  {
    VISIONOS_SHELL_LOG(LOGERROR, "VisionOSGLView: eglCreateWindowSurface failed (err={})",
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

    glBindFramebuffer(GL_FRAMEBUFFER, 0); // ANGLE default framebuffer
    glViewport(0, 0, m_framebufferWidth, m_framebufferHeight);
    glScissor(0, 0, m_framebufferWidth, m_framebufferHeight);
  }
}

- (bool)presentFramebuffer
{
  if (m_eglDisplay == EGL_NO_DISPLAY || m_eglSurface == EGL_NO_SURFACE)
    return false;

  return eglSwapBuffers(m_eglDisplay, m_eglSurface) == EGL_TRUE;
}

- (CGFloat)getScreenScale
{
  // UIScreen is unavailable on visionOS; use a fixed logical scale of 2×.
  return 2.0f;
}


- (void)gazeArmFired:(NSTimer*)t
{
  self.gazeArmTimer = nil;
  self.gazeEnterDown = YES;
  NSLog(@"VISIONOS-GAZE arm: enter down");
  [g_xbmcController sendKeyDown:XBMCK_RETURN];
  self.gazeHoldTimer = [NSTimer scheduledTimerWithTimeInterval:0.26 target:self selector:@selector(gazeHoldFired:) userInfo:nil repeats:NO];
}

- (void)gazeHoldFired:(NSTimer*)t
{
  NSLog(@"VISIONOS-GAZE hold repeat");
  [g_xbmcController sendKeyDown:XBMCK_RETURN];
}

- (void)gazeDragChanged:(CGPoint)p
{
  if (self.gazeIsDrag || self.gazeEnterDown)
    return;
  CGFloat dx = p.x - self.gazeStart.x;
  CGFloat dy = p.y - self.gazeStart.y;
  if (fabs(dx) < 40.0 && fabs(dy) < 40.0)
    return;
  [self.gazeArmTimer invalidate];
  self.gazeArmTimer = nil;
  self.gazeIsDrag = YES;
  NSLog(@"VISIONOS-GAZE drag started");
}

- (void)gazeDragEnded:(CGPoint)p
{
  CGFloat dx = p.x - self.gazeStart.x;
  CGFloat dy = p.y - self.gazeStart.y;
  CGFloat ax = fabs(dx), ay = fabs(dy);
  CGFloat hi = fmax(ax, ay), lo = fmin(ax, ay);
  if (hi <= 0.0 || lo / hi >= 0.5)
  {
    NSLog(@"VISIONOS-GAZE drag indeterminate dx=%.1f dy=%.1f", dx, dy);
    return;
  }
  XBMCKey k = (ax > ay) ? (dx > 0 ? XBMCK_RIGHT : XBMCK_LEFT)
                        : (dy > 0 ? XBMCK_DOWN : XBMCK_UP);
  if (k == XBMCK_RIGHT && self.gazeStart.x < 60.0)
    k = XBMCK_ESCAPE;
  NSLog(@"VISIONOS-GAZE drag dx=%.1f dy=%.1f startx=%.1f key=%d", dx, dy, self.gazeStart.x, (int)k);
  [g_xbmcController sendKey:k];
}

- (void)gazePressed:(UILongPressGestureRecognizer*)g
{
  CGPoint p = [g locationInView:self];
  if (g.state == UIGestureRecognizerStateBegan)
  {
    NSLog(@"VISIONOS-GAZE down x=%.1f y=%.1f", p.x, p.y);
    self.gazeStart = p;
    self.gazeIsDrag = NO;
    self.gazeEnterDown = NO;
    self.gazeArmTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(gazeArmFired:) userInfo:nil repeats:NO];
  }
  else if (g.state == UIGestureRecognizerStateChanged)
  {
    [self gazeDragChanged:p];
  }
  else if (g.state == UIGestureRecognizerStateEnded ||
           g.state == UIGestureRecognizerStateCancelled)
  {
    [self.gazeHoldTimer invalidate];
    self.gazeHoldTimer = nil;
    NSLog(@"VISIONOS-GAZE up x=%.1f y=%.1f", p.x, p.y);
    [self.gazeArmTimer invalidate];
    self.gazeArmTimer = nil;
    if (self.gazeEnterDown)
    {
      self.gazeEnterDown = NO;
      [g_xbmcController sendKeyUp:XBMCK_RETURN];
    }
    else if (!self.gazeIsDrag)
    {
      NSLog(@"VISIONOS-GAZE quick pinch");
      [g_xbmcController sendKeyWithUnicode:XBMCK_RETURN];
    }
    else
    {
      [self gazeDragEnded:p];
    }
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];

  // Recreate the EGL surface when the view resizes.
  // Do NOT call eglMakeCurrent here — the context is owned by the XBMC_Run
  // render thread.  Only recreate the surface object; setFramebuffer will
  // rebind it on the render thread on the next frame.
  if (m_eglDisplay != EGL_NO_DISPLAY && m_eglSurface != EGL_NO_SURFACE)
  {
    // Detach whatever is current (may be nothing, may be the render thread's
    // binding — the render thread will rebind via setFramebuffer next frame).
    eglMakeCurrent(m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(m_eglDisplay, m_eglSurface);
    m_eglSurface = EGL_NO_SURFACE;

    CAMetalLayer* metalLayer = static_cast<CAMetalLayer*>(self.layer);
    m_eglSurface = eglCreateWindowSurface(m_eglDisplay, m_eglConfig,
                                          (__bridge EGLNativeWindowType)metalLayer,
                                          nullptr);
    if (m_eglSurface != EGL_NO_SURFACE)
    {
      // Update cached dimensions without touching context ownership.
      eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_WIDTH, &m_framebufferWidth);
      eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_HEIGHT, &m_framebufferHeight);
    }
  }
}

@end
