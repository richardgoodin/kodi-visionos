/*
 *  Copyright (C) 2005-2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "cores/VideoPlayer/VideoRenderers/LinuxRendererGLES.h"

#include <CoreVideo/CoreVideo.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

class CRendererVTBVisionOS : public CLinuxRendererGLES
{
public:
  CRendererVTBVisionOS() = default;
  ~CRendererVTBVisionOS() override;

  static CBaseRenderer* Create(CVideoBuffer* buffer);
  static bool Register();

  void ReleaseBuffer(int idx) override;
  bool NeedBuffer(int idx) override;

protected:
  bool LoadShadersHook() override;
  void AfterRenderHook(int idx) override;
  EShaderFormat GetShaderFormat() override;

  bool UploadTexture(int index) override;
  void DeleteTexture(int index) override;
  bool CreateTexture(int index) override;

  struct CRenderBuffer
  {
    EGLSurface m_eglSurfaceY = EGL_NO_SURFACE;
    EGLSurface m_eglSurfaceUV = EGL_NO_SURFACE;
    CVBufferRef m_videoBuffer = nullptr;
    GLsync m_fence = nullptr;
  };
  CRenderBuffer m_vtbBuffers[NUM_BUFFERS];

  EGLDisplay m_eglDisplay = EGL_NO_DISPLAY;
};
