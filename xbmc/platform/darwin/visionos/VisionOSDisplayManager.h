/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

// visionOS display manager.  visionOS presents a single logical display at a
// fixed resolution; there is no AVDisplayManager equivalent.  This class
// mirrors TVOSDisplayManager's interface so the windowing layer can call it
// without ifdefs.

#pragma once

#import <UIKit/UIKit.h>

@interface VisionOSDisplayManager : NSObject

@property(nonatomic) CGFloat screenScale;

/// Returns the current render-buffer size in pixels.
- (CGSize)getScreenSize;

/// Returns the current display refresh rate (Hz).
- (double)getDisplayRate;

/// No-op on visionOS (no mode switching); kept for API parity with tvOS.
- (void)displayRateSwitch:(double)refreshRate withDynamicRange:(int)dynamicRange;

@end
