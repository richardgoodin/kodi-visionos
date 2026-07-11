/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

// visionOS replacement for TVOSEAGLView.
// Uses ANGLE EGL over Metal (CAMetalLayer) instead of native EAGL.
// Kodi's renderer continues to call GLES; only the surface/context setup differs.

#pragma once

#import <UIKit/UIKit.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

// VISIONOS_STAGE2: A CAMetalLayer-backed MTKView could replace this UIView
// for proper frame-pacing integration with the compositor.

@interface VisionOSGLView : UIView
{
  EGLDisplay m_eglDisplay;
  EGLContext m_eglContext;
  EGLSurface m_eglSurface;
  EGLConfig m_eglConfig;

  GLint m_framebufferWidth;
  GLint m_framebufferHeight;
}

@property(readonly) EGLContext eglContext;
@property(readonly) EGLDisplay eglDisplay;
@property(readonly) EGLSurface eglSurface;

- (instancetype)initWithFrame:(CGRect)frame;

// Detach the EGL context from the current thread so a background thread can take ownership
- (void)releaseContext;

// Called before each Kodi render frame
- (void)setFramebuffer;

// Called after each Kodi render frame to present
- (bool)presentFramebuffer;

- (CGFloat)getScreenScale;

@end
