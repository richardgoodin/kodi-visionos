/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "OSScreenSaverVisionOS.h"

#import "platform/darwin/visionos/XBMCController.h"

void COSScreenSaverVisionOS::Inhibit()
{
  [g_xbmcController disableScreenSaver];
}

void COSScreenSaverVisionOS::Uninhibit()
{
  [g_xbmcController enableScreenSaver];
}
