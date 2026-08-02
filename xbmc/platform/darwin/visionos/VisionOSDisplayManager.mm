/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/VisionOSDesktop.h"
#import "platform/darwin/visionos/VisionOSDisplayManager.h"
#import "platform/darwin/visionos/VisionOSGLView.h"
#import "platform/darwin/visionos/XBMCController.h"

#include "platform/darwin/visionos/VisionOSLog.h"

@implementation VisionOSDisplayManager

@synthesize screenScale;

- (instancetype)init
{
  self = [super init];
  if (self)
  {
    // UIScreen is unavailable on visionOS; use a fixed logical scale of 2×.
    screenScale = VISIONOS_DESKTOP_SCALE;
    VISIONOS_SHELL_LOG(LOGDEBUG, "VisionOSDisplayManager: screenScale={:.1f}", (float)screenScale);
  }
  return self;
}

- (CGSize)getScreenSize
{
  // The desktop is FIXED by design: Kodi renders one 1920x1080 canvas and the
  // compositor scales it to the window.  This is the ONLY size Kodi ever sees
  // -- do NOT query real window geometry here.  See VisionOSDesktop.h.
  CGRect bounds = CGRectMake(0, 0, VISIONOS_DESKTOP_WIDTH, VISIONOS_DESKTOP_HEIGHT);
  CGSize pixelSize;
  pixelSize.width = bounds.size.width * screenScale;
  pixelSize.height = bounds.size.height * screenScale;
  return pixelSize;
}

- (double)getDisplayRate
{
  // Real measured rate from the vsync display link (M5 panel: 120 Hz).
  // Kodi's A/V sync and frame placement run against this number — the old
  // hardcoded 90 put 24p scheduling off by a third on a 120 Hz panel.
  const double measured = [g_xbmcController.glView displayRate];
  if (measured > 0.0)
    return measured;
  // Early init, before the first vsync tick.
  return 90.0;
}

- (void)displayRateSwitch:(double)refreshRate withDynamicRange:(int)dynamicRange
{
  // No-op on visionOS – the system compositor controls the display mode.
  VISIONOS_SHELL_LOG(LOGDEBUG,
                     "VisionOSDisplayManager::displayRateSwitch: requested {:.3f} Hz (no-op)",
                     refreshRate);
}

@end
