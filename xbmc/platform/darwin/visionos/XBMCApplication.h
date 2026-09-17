/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import <UIKit/UIKit.h>

@interface XBMCApplicationDelegate : UIResponder <UIApplicationDelegate>
@property(nullable, nonatomic, strong) UIWindow* window;
@end

// UIScene lifecycle (mandatory for apps built with the 27 SDK, TN3187).
// Owns the window and the foreground/background transitions, which UIKit
// no longer delivers to the application delegate once a scene manifest
// is present in Info.plist.
@interface XBMCSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nullable, nonatomic, strong) UIWindow* window;
@end
