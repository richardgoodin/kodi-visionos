/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

// visionOS main UIViewController.  Mirrors TVOSController but uses
// VisionOSGLView (ANGLE/Metal) instead of TVOSEAGLView (EAGL).

#pragma once

#include <memory>
#include <string>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ANGLE EGL types used in the interface below.
#include <EGL/egl.h>

@class VisionOSDisplayManager;
@class VisionOSGLView;
@class DarwinEmbedNowPlayingInfoManager;

class CFileItem;

@interface XBMCController : UIViewController
{
  BOOL m_isPlayingBeforeInactive;
  UIBackgroundTaskIdentifier m_enterBackgroundTaskId;
  bool m_nativeKeyboardActive;
  BOOL m_pause;
  BOOL m_animating;
  NSConditionLock* m_animationThreadLock;
  NSThread* m_animationThread;
  std::unique_ptr<CFileItem> m_playingFileItemBeforeBackground;
  std::string m_lastUsedPlayer;
}

@property(nonatomic) BOOL appAlive;
@property(nonatomic, strong) DarwinEmbedNowPlayingInfoManager* MPNPInfoManager;
@property(nonatomic, strong) VisionOSDisplayManager* displayManager;
@property(nonatomic, strong) VisionOSGLView* glView;

- (void)pauseAnimation;
- (void)resumeAnimation;
- (void)startAnimation;
- (void)stopAnimation;

- (void)enterBackground;
- (void)enterForeground;
- (void)setFramebuffer;
- (bool)presentFramebuffer;
- (void)activateKeyboard:(UIView*)view;
- (void)deactivateKeyboard:(UIView*)view;
- (void)nativeKeyboardActive:(bool)active;

- (void)beginEnterBackgroundTask;
- (void)endEnterBackgroundTask;

- (void)disableScreenSaver;
- (void)enableScreenSaver;
- (bool)resetSystemIdleTimer;

- (CGRect)fullscreenSubviewFrame;

- (EGLContext)getEGLContextObj;

@end

extern XBMCController* g_xbmcController;
