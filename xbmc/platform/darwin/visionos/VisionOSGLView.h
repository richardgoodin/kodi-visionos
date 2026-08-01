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

  // RealityKit-Mono render target, two-slot BufferQueue (Android-style):
  // Kodi renders into IOSurface-backed FBOs instead of the CAMetalLayer
  // window surface (which is no longer presented).  Two buffers + a
  // per-buffer release fence rebuild the eglSwapBuffers contract the
  // IOSurface publish path lost: the producer never writes a surface the
  // RealityKit blit hasn't finished reading (the single-buffer
  // reader/writer race showed as whole layers missing from displayed
  // frames — the list-over-video flashing).
  IOSurfaceRef m_renderSurfaces[2];
  EGLSurface m_renderPbuffers[2];
  GLuint m_renderTextures[2];
  GLuint m_renderFBOs[2];
  GLuint m_renderDepthRB; // shared: the consumer never reads depth
  int m_renderIndex; // buffer being drawn this frame
  // Release fence, signaled by the Swift side's blit GPU-completion
  // handler (the BufferQueue releaseBuffer).  Armed only after the first
  // release ever arrives — before the RealityKit side attaches, no
  // releases flow and waiting would deadlock startup.
  dispatch_semaphore_t m_releaseSems[2];
  BOOL m_releaseFenceLive;

  // Presentation-rate sync: a CADisplayLink on the main run loop signals
  // this semaphore each refresh; presentFramebuffer blocks on it.
  dispatch_semaphore_t m_vsyncSem;
  CADisplayLink* m_vsyncLink;
}

@property(readonly) EGLContext eglContext;
@property(readonly) EGLDisplay eglDisplay;
@property(readonly) EGLSurface eglSurface;
// The surface to publish: the buffer just completed (current index — read
// during presentFramebuffer's publish, before the index flips).
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

// Release fence (BufferQueue releaseBuffer): called from the Swift side's
// blit completion handler (any thread) when RealityKit is done reading the
// surface with this IOSurfaceID.  Frees that buffer for the producer.
- (void)releaseSurfaceWithID:(uint32_t)surfaceID;

- (CGFloat)getScreenScale;

@end
