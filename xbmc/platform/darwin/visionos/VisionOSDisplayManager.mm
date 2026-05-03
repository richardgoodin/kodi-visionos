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
    screenScale = UIScreen.mainScreen ? UIScreen.mainScreen.scale : 2.0f;
    CLog::Log(LOGDEBUG, "VisionOSDisplayManager: screenScale={:.1f}", (float)screenScale);
  }
  return self;
}

- (CGSize)getScreenSize
{
  // visionOS windowed apps get their frame from the window scene, not UIScreen.
  // Until we have a real scene reference, ask UIScreen which on visionOS returns
  // the virtual canvas size (e.g. 1920x1080 equivalent).
  CGRect bounds = UIScreen.mainScreen ? UIScreen.mainScreen.bounds : CGRectMake(0, 0, 1920, 1080);
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
