/*
 *  Copyright (C) 2026 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "LinuxRendererGLESVisionOS.h"

#include "cores/VideoPlayer/VideoRenderers/RenderFactory.h"
#include "cores/VideoPlayer/VideoRenderers/RenderFlags.h"

CBaseRenderer* CLinuxRendererGLESVisionOS::Create(CVideoBuffer* buffer)
{
  return new CLinuxRendererGLESVisionOS();
}

bool CLinuxRendererGLESVisionOS::Register()
{
  VIDEOPLAYER::CRendererFactory::RegisterRenderer("default", Create);
  return true;
}

bool CLinuxRendererGLESVisionOS::Configure(const VideoPicture& picture,
                                           float fps,
                                           unsigned int orientation)
{
  if (!CLinuxRendererGLES::Configure(picture, fps, orientation))
    return false;

  // Translate the stream's stereo layout into the render flags that drive
  // CBaseRenderer::ManageRenderArea's per-eye half-source-rect selection.
  // Clear-then-set so a reconfigure from a stereoscopic to a flat stream
  // cannot leave stale bits; then rerun the render-area calculation the
  // base Configure already performed, now with the stereo bits in place.
  m_iFlags &= ~(CONF_FLAGS_STEREO_MODE_SBS | CONF_FLAGS_STEREO_MODE_TAB |
                CONF_FLAGS_STEREO_CADANCE_RIGHT_LEFT);
  m_iFlags |= GetFlagsStereoMode(picture.stereoMode);
  ManageRenderArea();

  return true;
}
