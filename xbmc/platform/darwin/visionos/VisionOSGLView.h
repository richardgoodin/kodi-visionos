/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

// visionOS replacement for TVOSEAGLView, RealityKit-Mono architecture:
// ANGLE EGL renders into an IOSurface-backed FBO (the CAMetalLayer is fully
// transparent and unused by EGL); the RealityKit display plane samples the
// IOSurface.  This view provides the fixed-desktop coordinate space for
// input and hosts the RealityKit view as a transform-scaled subview.  Frame
// pacing is the CADisplayLink vsync in presentFramebuffer.

#pragma once

#import <UIKit/UIKit.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <IOSurface/IOSurfaceRef.h>

@interface VisionOSGLView : UIView
{
  EGLDisplay m_eglDisplay;
  EGLContext m_eglContext;
  EGLSurface m_eglSurface;
  EGLConfig m_eglConfig;

  GLint m_framebufferWidth;
  GLint m_framebufferHeight;

  // RealityKit-Mono render target: Kodi renders into this IOSurface-backed
  // FBO instead of the CAMetalLayer window surface (which is no longer
  // presented).  Single-buffered: double buffering was tried and did not
  // change the peripheral artifacts (they are foveation/aliasing, not a
  // reader/writer race).
  IOSurfaceRef m_renderSurface;
  EGLSurface m_renderPbuffer;
  GLuint m_renderTexture;
  GLuint m_renderFBO;
  GLuint m_renderDepthRB;

  // Presentation-rate sync: a CADisplayLink on the main run loop signals
  // this semaphore each refresh; presentFramebuffer blocks on it.
  dispatch_semaphore_t m_vsyncSem;
  CADisplayLink* m_vsyncLink;
}

@property(readonly) EGLContext eglContext;
@property(readonly) EGLDisplay eglDisplay;
@property(readonly) EGLSurface eglSurface;
@property(readonly) IOSurfaceRef renderSurface;

- (instancetype)initWithFrame:(CGRect)frame;

// Detach the EGL context from the current thread so a background thread can take ownership
- (void)releaseContext;

// Called before each Kodi render frame
- (void)setFramebuffer;

// Called after each Kodi render frame to present
- (bool)presentFramebuffer;

// Injected gaze phases from the RealityKit input path (0=began, 1=changed,
// 2=ended), point in fixed-desktop (1920x1080) coordinates.  Feeds the same
// gaze grammar as the on-view recognizer, which cannot fire anymore: the
// native stack is fully transparent and transparent UIKit views are not
// gaze-targetable on visionOS — the RealityKit plane is the input surface.
- (void)injectGazePhase:(NSInteger)phase x:(double)x y:(double)y;

- (CGFloat)getScreenScale;

@end
