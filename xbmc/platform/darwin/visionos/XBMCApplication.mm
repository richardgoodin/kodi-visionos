/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/XBMCApplication.h"

#import "platform/darwin/NSLogDebugHelpers.h"
#import "platform/darwin/visionos/VisionOSDesktop.h"
#import "platform/darwin/visionos/XBMCController.h"

#import <AVFoundation/AVFoundation.h>

@implementation XBMCApplicationDelegate

- (XBMCController*)xbmcController
{
  return static_cast<XBMCController*>(self.window.rootViewController);
}

#pragma mark - Shutdown

- (void)applicationWillTerminate:(UIApplication*)application
{
  [self.xbmcController stopAnimation];
}

#pragma mark - Startup

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
  // Window creation lives in XBMCSceneDelegate (scene:willConnectToSession:).

  // Audio session
  auto audioSession = AVAudioSession.sharedInstance;
  NSError* err = nil;
  if (![audioSession setCategory:AVAudioSessionCategoryPlayback error:&err])
    NSLog(@"audioSession setCategory failed: %@", err);
  err = nil;
  if (![audioSession setMode:AVAudioSessionModeMoviePlayback error:&err])
    NSLog(@"audioSession setMode failed: %@", err);
  err = nil;
  if (![audioSession setActive:YES error:&err])
    NSLog(@"audioSession setActive failed: %@", err);

  return YES;
}

@end

@implementation XBMCSceneDelegate
{
  BOOL m_inBackground;
}

- (XBMCController*)xbmcController
{
  return static_cast<XBMCController*>(self.window.rootViewController);
}

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions
{
  if (![scene isKindOfClass:[UIWindowScene class]])
    return;
  UIWindowScene* ws = (UIWindowScene*)scene;

  // UI setup
  // visionOS: UIScreen is unavailable; window geometry is managed by the system.
  self.window = [[UIWindow alloc] initWithWindowScene:ws];
  self.window.rootViewController = [XBMCController new];
  [self.window makeKeyAndVisible];

  // Keep the application delegate's window pointing at the same window so
  // applicationWillTerminate: can still reach the controller.
  XBMCApplicationDelegate* appDelegate =
      (XBMCApplicationDelegate*)UIApplication.sharedApplication.delegate;
  appDelegate.window = self.window;

  UIWindowSceneGeometryPreferencesVision* geo =
      [[UIWindowSceneGeometryPreferencesVision alloc] init];
  geo.size = CGSizeMake(VISIONOS_DESKTOP_WIDTH, VISIONOS_DESKTOP_HEIGHT);
  geo.resizingRestrictions = UIWindowSceneResizingRestrictionsUniform;
  [ws requestGeometryUpdateWithPreferences:geo errorHandler:nil];

  m_inBackground = NO;
  [self.xbmcController startAnimation];
}

- (void)sceneWillResignActive:(UIScene*)scene
{
  // Interrupted by system UI (control centre, etc.)
}

- (void)sceneDidEnterBackground:(UIScene*)scene
{
  m_inBackground = YES;
  [self.xbmcController pauseAnimation];
  [self.xbmcController enterBackground];
}

- (void)sceneWillEnterForeground:(UIScene*)scene
{
  // Also delivered once at first launch, right after willConnectToSession;
  // only resume after a real background.
  if (!m_inBackground)
    return;
  m_inBackground = NO;
  [self.xbmcController resumeAnimation];
  [self.xbmcController enterForeground];
}

- (void)sceneDidBecomeActive:(UIScene*)scene
{
}

@end

static void SigPipeHandler(int s)
{
  NSLog(@"We Got a Pipe Signal: %d____________", s);
}

int main(int argc, char* argv[])
{
  @autoreleasepool
  {
    signal(SIGPIPE, SigPipeHandler);

    int retVal = 0;
    @try
    {
      retVal =
          UIApplicationMain(argc, argv, nil, NSStringFromClass([XBMCApplicationDelegate class]));
    }
    @catch (id theException)
    {
      ELOG(@"%@", theException);
    }
    @finally
    {
      ILOG(@"This always happens.");
    }
    return retVal;
  }
}
