/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/VisionOSDesktop.h"
#import "platform/darwin/visionos/VisionOSDisplayManager.h"

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
  // visionOS targets 90 Hz.  CADisplayLink will give us the actual rate at
  // runtime; this default is used during initialisation.
  // VISIONOS_STAGE2: wire up CADisplayLink and report the measured rate.
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
