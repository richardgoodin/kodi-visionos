/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "VisionOSPowerSyscall.h"

#include "utils/log.h"

IPowerSyscall* CVisionOSPowerSyscall::CreateInstance()
{
  return new CVisionOSPowerSyscall;
}

void CVisionOSPowerSyscall::Register()
{
  IPowerSyscall::RegisterPowerSyscall(CVisionOSPowerSyscall::CreateInstance);
}

bool CVisionOSPowerSyscall::Powerdown()
{
  return false;
}

bool CVisionOSPowerSyscall::Suspend()
{
  return false;
}

bool CVisionOSPowerSyscall::Hibernate()
{
  return false;
}

bool CVisionOSPowerSyscall::Reboot()
{
  return false;
}

bool CVisionOSPowerSyscall::CanPowerdown()
{
  return false;
}

bool CVisionOSPowerSyscall::CanSuspend()
{
  return false;
}

bool CVisionOSPowerSyscall::CanHibernate()
{
  return false;
}

bool CVisionOSPowerSyscall::CanReboot()
{
  return false;
}

int CVisionOSPowerSyscall::BatteryLevel()
{
  return 0;
}

bool CVisionOSPowerSyscall::PumpPowerEvents(IPowerEventsCallback* callback)
{
  switch (m_state)
  {
    case SUSPENDED:
      callback->OnSleep();
      CLog::Log(LOGDEBUG, "{}: OnSleep called", __FUNCTION__);
      break;
    case RESUMED:
      callback->OnWake();
      CLog::Log(LOGDEBUG, "{}: OnWake called", __FUNCTION__);
      break;
    default:
      return false;
  }
  m_state = REPORTED;
  return true;
}

void CVisionOSPowerSyscall::SetOnPause()
{
  m_state = SUSPENDED;
}

void CVisionOSPowerSyscall::SetOnResume()
{
  m_state = RESUMED;
}
