/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "windowing/VideoSync.h"

class CVideoSyncVisionOS : public CVideoSync
{
public:
  explicit CVideoSyncVisionOS(CVideoReferenceClock* clock) : CVideoSync(clock) {}

  bool Setup() override;
  void Run(CEvent& stopEvent) override;
  void Cleanup() override;
  float GetFps() override;

  void VisionOSVblankHandler();

private:
  volatile bool m_stopRequested = false;
  volatile uint32_t m_vblankCount = 0;
};
