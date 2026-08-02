/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

// visionOS replacement for TVOSEAGLView, RealityKit presentation:
// ANGLE EGL renders into IOSurface-backed FBOs — per eye under
// HARDWAREBASED stereo, left-only in mono — (the CAMetalLayer is fully
// transparent and unused by EGL); the RealityKit display plane samples the
// published surfaces through a camera-index material.  This view provides
// the fixed-desktop coordinate space for input and hosts the RealityKit
// view as a transform-scaled subview.  Frame pacing is the CADisplayLink
// vsync in presentFramebuffer.

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

  // RealityKit render targets, [eye][slot]: eye 0 = LEFT (and the mono
  // path — identical to the original single-eye layout), eye 1 = RIGHT
  // (HARDWAREBASED stereo; drawn only when stereo is active).  Per eye,
  // two-slot BufferQueue (Android-style): Kodi renders into
  // IOSurface-backed FBOs instead of the CAMetalLayer window surface
  // (which is no longer presented).  Two buffers + a per-buffer release
  // fence rebuild the eglSwapBuffers contract the IOSurface publish path
  // lost: the producer never writes a surface the RealityKit blit hasn't
  // finished reading (the single-buffer reader/writer race showed as
  // whole layers missing from displayed frames — the list-over-video
  // flashing).
  IOSurfaceRef m_renderSurfaces[2][2];
  EGLSurface m_renderPbuffers[2][2];
  GLuint m_renderTextures[2][2];
  GLuint m_renderFBOs[2][2];
  GLuint m_renderDepthRB; // shared by all FBOs: one draw target at a time, consumer never reads depth
  int m_renderIndex; // slot being drawn this frame (both eyes share the slot index)
  int m_currentEye; // eye being drawn this pass: 0 left, 1 right (always 0 outside stereo)
  // Release fences, per SLOT (both eyes of a frame share a slot and flip
  // together).  Delivery-gated counting: the producer increments
  // m_outstanding[slot] once per surface actually handed to the presenter
  // at publish; the dequeue of that slot waits on the sem that many times.
  // Each release (the Swift side's blit GPU-completion handler — the
  // BufferQueue releaseBuffer) signals once.  Before the RealityKit side
  // attaches, nothing is delivered, the counts stay 0, and the dequeue
  // never waits — the startup implicit-acquire falls out with no special
  // arming or initial credits.
  dispatch_semaphore_t m_releaseSems[2];
  int m_outstanding[2];
  // Set by selectEye:1 — this frame rendered a right-eye pass, so present
  // publishes the left/right pair.  Cleared at the end of
  // presentFramebuffer.
  BOOL m_rightEyeDrawn;

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
// Right-eye counterpart (same slot), published only when rightEyeDrawn.
@property(readonly) IOSurfaceRef renderSurfaceRight;
// Whether the frame being presented rendered a right-eye pass.
@property(readonly) BOOL rightEyeDrawn;

- (instancetype)initWithFrame:(CGRect)frame;

// Detach the EGL context from the current thread so a background thread can take ownership
- (void)releaseContext;

// Called before each Kodi render frame
- (void)setFramebuffer;

// Called after each Kodi render frame to present
- (bool)presentFramebuffer;

// HARDWAREBASED stereo: select which eye's render target setFramebuffer
// binds (0 = left, 1 = right).  Called on the render thread from
// CWinSystemVisionOS::SetStereoMode on each SetStereoView(LEFT/RIGHT)
// pass; rebinds the FBO immediately if targets exist.  Outside stereo the
// eye stays 0 and this is never called.
- (void)selectEye:(int)eye;

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
