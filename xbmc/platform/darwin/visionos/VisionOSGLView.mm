/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/VisionOSGLView.h"

#include "messaging/ApplicationMessenger.h"
#include "utils/log.h"

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

@implementation VisionOSGLView

@synthesize eglContext = m_eglContext;
@synthesize eglDisplay = m_eglDisplay;

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
    metalLayer.opaque = YES;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // VISIONOS_STAGE2: framebufferOnly=NO enables readbacks needed for some effects

    if (![self initEGL])
    {
      CLog::Log(LOGERROR, "VisionOSGLView: failed to initialise ANGLE EGL");
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
    CLog::Log(LOGERROR, "VisionOSGLView: no Metal device");
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
    CLog::Log(LOGERROR, "VisionOSGLView: eglGetPlatformDisplay failed");
    return NO;
  }

  EGLint major, minor;
  if (!eglInitialize(m_eglDisplay, &major, &minor))
  {
    CLog::Log(LOGERROR, "VisionOSGLView: eglInitialize failed");
    return NO;
  }
  CLog::Log(LOGINFO, "VisionOSGLView: EGL {}.{} on Metal", major, minor);

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
      CLog::Log(LOGERROR, "VisionOSGLView: eglChooseConfig failed");
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
    CLog::Log(LOGERROR, "VisionOSGLView: eglCreateContext failed");
    return NO;
  }

  // Create window surface from the CAMetalLayer
  CAMetalLayer* metalLayer = static_cast<CAMetalLayer*>(self.layer);
  m_eglSurface = eglCreateWindowSurface(m_eglDisplay, m_eglConfig,
                                        (__bridge EGLNativeWindowType)metalLayer, nullptr);
  if (m_eglSurface == EGL_NO_SURFACE)
  {
    CLog::Log(LOGERROR, "VisionOSGLView: eglCreateWindowSurface failed (err={})",
              eglGetError());
    return NO;
  }

  if (!eglMakeCurrent(m_eglDisplay, m_eglSurface, m_eglSurface, m_eglContext))
  {
    CLog::Log(LOGERROR, "VisionOSGLView: eglMakeCurrent failed");
    return NO;
  }

  // Cache framebuffer dimensions
  eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_WIDTH, &m_framebufferWidth);
  eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_HEIGHT, &m_framebufferHeight);
  CLog::Log(LOGINFO, "VisionOSGLView: surface {}x{}", m_framebufferWidth, m_framebufferHeight);

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

- (void)setFramebuffer
{
  if (m_eglContext != EGL_NO_CONTEXT)
  {
    if (eglGetCurrentContext() != m_eglContext)
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

- (void)layoutSubviews
{
  [super layoutSubviews];

  // Recreate the EGL surface when the view resizes
  if (m_eglDisplay != EGL_NO_DISPLAY && m_eglSurface != EGL_NO_SURFACE)
  {
    eglMakeCurrent(m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(m_eglDisplay, m_eglSurface);
    m_eglSurface = EGL_NO_SURFACE;

    CAMetalLayer* metalLayer = static_cast<CAMetalLayer*>(self.layer);
    m_eglSurface = eglCreateWindowSurface(m_eglDisplay, m_eglConfig,
                                          (__bridge EGLNativeWindowType)metalLayer,
                                          nullptr);
    if (m_eglSurface != EGL_NO_SURFACE)
    {
      eglMakeCurrent(m_eglDisplay, m_eglSurface, m_eglSurface, m_eglContext);
      eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_WIDTH, &m_framebufferWidth);
      eglQuerySurface(m_eglDisplay, m_eglSurface, EGL_HEIGHT, &m_framebufferHeight);
    }
  }
}

@end
