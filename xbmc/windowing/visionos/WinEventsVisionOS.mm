/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "WinEventsVisionOS.h"

#include "ServiceBroker.h"
#include "application/AppInboundProtocol.h"
#include "guilib/GUIWindowManager.h"
#include "input/InputManager.h"
#include "input/keyboard/XBMC_vkeys.h"
#include "threads/CriticalSection.h"
#include "utils/log.h"

#include <list>
#include <mutex>

CWinEventsVisionOS::CWinEventsVisionOS() : CThread("CWinEventsVisionOS")
{
  CLog::Log(LOGDEBUG, "CWinEventsVisionOS::CWinEventsVisionOS");
  Create();
}

CWinEventsVisionOS::~CWinEventsVisionOS()
{
  m_bStop = true;
  StopThread(true);
}

void CWinEventsVisionOS::MessagePush(XBMC_Event* newEvent)
{
  std::unique_lock lock(m_eventsCond);
  m_events.push_back(*newEvent);
}

size_t CWinEventsVisionOS::GetQueueSize()
{
  std::unique_lock lock(m_eventsCond);
  return m_events.size();
}

bool CWinEventsVisionOS::MessagePump()
{
  bool ret = false;
  std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();

  for (size_t pumpEventCount = GetQueueSize(); pumpEventCount > 0; --pumpEventCount)
  {
    XBMC_Event pumpEvent;
    {
      std::unique_lock lock(m_eventsCond);
      if (m_events.empty())
        return ret;
      pumpEvent = m_events.front();
      m_events.pop_front();
    }

    if (appPort)
      ret = appPort->OnEvent(pumpEvent);
  }
  return ret;
}
