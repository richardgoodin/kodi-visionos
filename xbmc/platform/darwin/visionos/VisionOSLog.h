/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

// Shell-layer logging shim for visionOS.
//
// Use VISIONOS_SHELL_LOG(...) instead of CLog::Log(...) in any code that runs
// on the UIKit main thread before Kodi's engine thread has registered its
// logging component with CServiceBroker.  CLog::Log is NOT safe to call in
// that window: CLog::FormatAndLogInternal dereferences the logging service
// pointer which is null, faulting at +0x28 (KERN_INVALID_ADDRESS, SIGSEGV).
//
// Syntax is identical to CLog::Log so conversion is a mechanical rename:
//
//   CLog::Log(LOGERROR, "something: {}", value);
//   →
//   VISIONOS_SHELL_LOG(LOGERROR, "something: {}", value);
//
// Logs appear in Console.app under:
//   subsystem = com.goodin.kodi
//   category  = shell
//
// Strings are emitted with %{public}s so they are not redacted as <private>
// during bring-up (before a privacy-preserving profile is active).
//
// Kodi log-level mapping:
//   LOGDEBUG   → OS_LOG_TYPE_DEBUG
//   LOGINFO    → OS_LOG_TYPE_INFO
//   LOGWARNING → OS_LOG_TYPE_DEFAULT
//   LOGERROR   → OS_LOG_TYPE_ERROR
//   LOGFATAL   → OS_LOG_TYPE_FAULT

#include "utils/log.h" // LOGDEBUG / LOGINFO / LOGWARNING / LOGERROR / LOGFATAL constants

#include <fmt/format.h>
#include <os/log.h>

namespace
{
inline os_log_t VisionOSShellLogger()
{
  // os_log_create is cheap and thread-safe; the static local is initialised
  // once under the Meyers-singleton guarantee.
  static os_log_t s_log = os_log_create("com.goodin.kodi", "shell");
  return s_log;
}
} // anonymous namespace

// clang-format off
/// Log to the os_log shell channel.  Safe to call at any point during UIKit
/// startup, before CServiceBroker::GetLogging() is available.
#define VISIONOS_SHELL_LOG(level, ...)                                                   \
  do {                                                                                    \
    auto _shellMsg = fmt::format(__VA_ARGS__);                                           \
    switch (level)                                                                        \
    {                                                                                     \
      case LOGDEBUG:                                                                      \
        os_log_with_type(VisionOSShellLogger(), OS_LOG_TYPE_DEBUG,                       \
                         "%{public}s", _shellMsg.c_str());                               \
        break;                                                                            \
      case LOGINFO:                                                                       \
        os_log_with_type(VisionOSShellLogger(), OS_LOG_TYPE_INFO,                        \
                         "%{public}s", _shellMsg.c_str());                               \
        break;                                                                            \
      case LOGWARNING:                                                                    \
        os_log_with_type(VisionOSShellLogger(), OS_LOG_TYPE_DEFAULT,                     \
                         "%{public}s", _shellMsg.c_str());                               \
        break;                                                                            \
      case LOGERROR:                                                                      \
        os_log_with_type(VisionOSShellLogger(), OS_LOG_TYPE_ERROR,                       \
                         "%{public}s", _shellMsg.c_str());                               \
        break;                                                                            \
      case LOGFATAL:                                                                      \
        os_log_with_type(VisionOSShellLogger(), OS_LOG_TYPE_FAULT,                       \
                         "%{public}s", _shellMsg.c_str());                               \
        break;                                                                            \
      default:                                                                            \
        os_log_with_type(VisionOSShellLogger(), OS_LOG_TYPE_DEFAULT,                     \
                         "%{public}s", _shellMsg.c_str());                               \
        break;                                                                            \
    }                                                                                     \
  } while (0)
// clang-format on
