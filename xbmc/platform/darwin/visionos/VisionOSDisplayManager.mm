/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/VisionOSDisplayManager.h"

#include "utils/log.h"

@implementation VisionOSDisplayManager

@synthesize screenScale;

- (instancetype)init
{
  self = [super init];
  if (self)
  {
    // UIScreen is unavailable on visionOS; use a fixed logical scale of 2×.
    screenScale = 2.0f;
    CLog::Log(LOGDEBUG, "VisionOSDisplayManager: screenScale={:.1f}", (float)screenScale);
  }
  return self;
}

- (CGSize)getScreenSize
{
  // UIScreen is unavailable on visionOS.  Return a fixed virtual canvas size
  // that matches the Vision Pro's 1:1 pixel-layout for 2D windows.
  // VISIONOS_STAGE2: query UIWindowScene.effectiveGeometry for the actual frame.
  CGRect bounds = CGRectMake(0, 0, 1920, 1080);
  CGSize pixelSize;
  pixelSize.width = bounds.size.width * screenScale;
  pixelSize.height = bounds.size.height * screenScale;
  return pixelSize;
}

- (double)getDisplayRate
{
  // visionOS targets 90 Hz.  CADisplayLink will give us the actual rate at
  // runtime; this default is used during initialisation.
  // VISIONOS_STAGE2: query UIWindowScene.effectiveGeometry for actual rate
  return 90.0;
}

- (void)displayRateSwitch:(double)refreshRate withDynamicRange:(int)dynamicRange
{
  // No-op on visionOS – the system compositor controls the display mode.
  CLog::Log(LOGDEBUG, "VisionOSDisplayManager::displayRateSwitch: requested {:.3f} Hz (no-op)",
            refreshRate);
}

@end
