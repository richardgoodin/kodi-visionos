/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/XBMCApplication.h"

#import "platform/darwin/NSLogDebugHelpers.h"
#import "platform/darwin/visionos/XBMCController.h"

#import <AVFoundation/AVFoundation.h>

@implementation XBMCApplicationDelegate

- (XBMCController*)xbmcController
{
  return static_cast<XBMCController*>(self.window.rootViewController);
}

#pragma mark - Shutdown

- (void)applicationWillResignActive:(UIApplication*)application
{
  // Interrupted by system UI (control centre, etc.)
}

- (void)applicationDidEnterBackground:(UIApplication*)application
{
  if (application.applicationState == UIApplicationStateBackground)
  {
    [self.xbmcController pauseAnimation];
    [self.xbmcController enterBackground];
  }
}

- (void)applicationWillTerminate:(UIApplication*)application
{
  [self.xbmcController stopAnimation];
}

#pragma mark - Startup

- (void)applicationDidBecomeActive:(UIApplication*)application
{
}

- (void)applicationWillEnterForeground:(UIApplication*)application
{
  [self.xbmcController resumeAnimation];
  [self.xbmcController enterForeground];
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
  // UI setup
  // visionOS: UIScreen is unavailable; window geometry is managed by the system.
  self.window = [[UIWindow alloc] init];
  self.window.rootViewController = [XBMCController new];
  [self.window makeKeyAndVisible];
  [self.xbmcController startAnimation];

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
