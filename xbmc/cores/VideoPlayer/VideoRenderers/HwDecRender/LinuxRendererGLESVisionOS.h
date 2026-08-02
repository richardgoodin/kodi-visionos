/*
 *  Copyright (C) 2026 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "cores/VideoPlayer/VideoRenderers/LinuxRendererGLES.h"

// GLES software renderer with visionOS stereo support.  Stock
// CLinuxRendererGLES never translates picture.stereoMode into the
// CONF_FLAGS_STEREO_* bits of m_iFlags (LinuxRendererGL does), so
// CBaseRenderer::ManageRenderArea can never select the per-eye half source
// rect that HARDWAREBASED playback of SBS/TAB content needs — each eye
// would get the full double-wide frame.  This subclass adds the missing
// translation without touching the shared renderer.  CRendererVTBVisionOS
// derives from it, so the hardware-decode path inherits the same fix.
class CLinuxRendererGLESVisionOS : public CLinuxRendererGLES
{
public:
  CLinuxRendererGLESVisionOS() = default;

  static CBaseRenderer* Create(CVideoBuffer* buffer);
  static bool Register();

  bool Configure(const VideoPicture& picture, float fps, unsigned int orientation) override;
};
