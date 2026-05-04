/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "VideoSyncVisionOS.h"

#include "ServiceBroker.h"
#include "cores/VideoPlayer/VideoReferenceClock.h"
#include "utils/MathUtils.h"
#include "utils/TimeUtils.h"
#include "utils/XTimeUtils.h"
#include "utils/log.h"
#include "windowing/GraphicContext.h"
#include "windowing/WinSystem.h"
#include "windowing/visionos/WinSystemVisionOS.h"

#include <chrono>

using namespace std::chrono_literals;

bool CVideoSyncVisionOS::Setup()
{
  CLog::Log(LOGDEBUG, "CVideoSyncVisionOS::Setup");
  CWinSystemVisionOS* winSystem =
      dynamic_cast<CWinSystemVisionOS*>(CServiceBroker::GetWinSystem());
  if (!winSystem)
    return false;

  m_stopRequested = false;
  m_vblankCount = 0;
  return winSystem->InitDisplayLink(this);
}

void CVideoSyncVisionOS::Run(CEvent& stopEvent)
{
  uint32_t prevVblankCount = m_vblankCount;
  while (!stopEvent.Wait(0ms))
  {
    uint32_t curVblankCount = m_vblankCount;
    if (curVblankCount != prevVblankCount)
    {
      uint32_t diff = curVblankCount - prevVblankCount;
      prevVblankCount = curVblankCount;
      // Notify reference clock about the number of vblanks
      m_refClock->UpdateClock(diff, CurrentHostCounter());
    }
    // Sleep a short interval between polls to avoid busy-spinning
    KODI::TIME::Sleep(2ms);
  }
}

void CVideoSyncVisionOS::Cleanup()
{
  CLog::Log(LOGDEBUG, "CVideoSyncVisionOS::Cleanup");
  CWinSystemVisionOS* winSystem =
      dynamic_cast<CWinSystemVisionOS*>(CServiceBroker::GetWinSystem());
  if (winSystem)
    winSystem->DeinitDisplayLink();
}

float CVideoSyncVisionOS::GetFps()
{
  // visionOS default: 90 Hz
  return static_cast<float>(
      CServiceBroker::GetWinSystem()->GetGfxContext().GetFPS());
}

void CVideoSyncVisionOS::VisionOSVblankHandler()
{
  m_vblankCount++;
}
