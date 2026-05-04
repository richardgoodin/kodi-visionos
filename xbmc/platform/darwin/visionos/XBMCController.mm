/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/XBMCController.h"

#include "CompileInfo.h"
#include "FileItem.h"
#include "ServiceBroker.h"
#include "application/AppEnvironment.h"
#include "application/AppParams.h"
#include "application/Application.h"
#include "application/ApplicationComponents.h"
#include "application/ApplicationPowerHandling.h"
#include "cores/AudioEngine/Interfaces/AE.h"
#include "guilib/GUIComponent.h"
#include "guilib/GUIWindowManager.h"
#include "interfaces/AnnouncementManager.h"
#include "messaging/ApplicationMessenger.h"
#include "network/Network.h"
#include "network/NetworkServices.h"
#include "platform/xbmc.h"
#include "powermanagement/PowerManager.h"
#include "settings/AdvancedSettings.h"
#include "settings/SettingsComponent.h"
#include "utils/log.h"
#import "windowing/visionos/WinEventsVisionOS.h"
#import "windowing/visionos/WinSystemVisionOS.h"

#import "platform/darwin/ios-common/AnnounceReceiver.h"
#import "platform/darwin/ios-common/DarwinEmbedNowPlayingInfoManager.h"
#import "platform/darwin/visionos/VisionOSDisplayManager.h"
#import "platform/darwin/visionos/VisionOSGLView.h"
#import "platform/darwin/visionos/XBMCApplication.h"
#include "platform/darwin/visionos/powermanagement/VisionOSPowerSyscall.h"

XBMCController* g_xbmcController;

#pragma mark - XBMCController implementation
@implementation XBMCController

@synthesize appAlive = m_appAlive;
@synthesize MPNPInfoManager;
@synthesize displayManager;
@synthesize glView;

#pragma mark - UIView Keyboard

- (void)activateKeyboard:(UIView*)view
{
  [self.view addSubview:view];
  glView.userInteractionEnabled = NO;
}

- (void)deactivateKeyboard:(UIView*)view
{
  [view removeFromSuperview];
  glView.userInteractionEnabled = YES;
  [self becomeFirstResponder];
}

- (void)nativeKeyboardActive:(bool)active
{
  // Not used on visionOS in Stage 1
}

#pragma mark - View

- (void)viewDidLoad
{
  [super viewDidLoad];

  glView = [[VisionOSGLView alloc] initWithFrame:self.view.bounds];

  displayManager.screenScale = [glView getScreenScale];

  self.view.backgroundColor = UIColor.blackColor;
  [self.view addSubview:glView];
}

- (void)viewWillAppear:(BOOL)animated
{
  [self resumeAnimation];
  [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
  [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
}

- (void)viewWillDisappear:(BOOL)animated
{
  [self pauseAnimation];
  [super viewWillDisappear:animated];
}

- (UIView*)inputView
{
  return [[UIView alloc] initWithFrame:CGRectZero];
}

#pragma mark - FirstResponder

- (BOOL)canBecomeFirstResponder
{
  return YES;
}

#pragma mark - FrameBuffer

- (void)setFramebuffer
{
  if (!m_pause)
    [glView setFramebuffer];
}

- (bool)presentFramebuffer
{
  if (!m_pause)
    return [glView presentFramebuffer];
  else
    return FALSE;
}

- (CGRect)fullscreenSubviewFrame
{
  // UIScreen is unavailable on visionOS; return the window bounds if available,
  // otherwise fall back to a fixed 1920×1080 logical canvas.
  if (self.view.window)
    return self.view.window.bounds;
  return CGRectMake(0, 0, 1920, 1080);
}

- (void)didReceiveMemoryWarning
{
  [super didReceiveMemoryWarning];
}

#pragma mark - BackgroundTask

- (void)beginEnterBackgroundTask
{
  CLog::Log(LOGDEBUG, "{}", __PRETTY_FUNCTION__);
  if (m_enterBackgroundTaskId == UIBackgroundTaskInvalid)
    m_enterBackgroundTaskId =
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
}

- (void)endEnterBackgroundTask
{
  CLog::Log(LOGDEBUG, "{}", __PRETTY_FUNCTION__);
  if (m_enterBackgroundTaskId != UIBackgroundTaskInvalid)
  {
    [[UIApplication sharedApplication] endBackgroundTask:m_enterBackgroundTaskId];
    m_enterBackgroundTaskId = UIBackgroundTaskInvalid;
  }
}

#pragma mark - AppFocus

- (void)enterBackground
{
  CLog::Log(LOGDEBUG, "{}", __PRETTY_FUNCTION__);
  [self beginEnterBackgroundTask];

  if (CServiceBroker::GetGUI()->GetWindowManager().GetActiveWindow() == WINDOW_SLIDESHOW ||
      CServiceBroker::GetGUI()->GetWindowManager().GetActiveWindow() == WINDOW_FULLSCREEN_VIDEO ||
      CServiceBroker::GetGUI()->GetWindowManager().GetActiveWindow() == WINDOW_FULLSCREEN_GAME ||
      CServiceBroker::GetGUI()->GetWindowManager().GetActiveWindow() == WINDOW_VISUALISATION)
    CServiceBroker::GetGUI()->GetWindowManager().PreviousWindow();

  dynamic_cast<CVisionOSPowerSyscall*>(CServiceBroker::GetPowerManager().GetPowerSyscall())
      ->SetOnPause();
  CServiceBroker::GetPowerManager().ProcessEvents();

  CWinSystemVisionOS* winSystem =
      dynamic_cast<CWinSystemVisionOS*>(CServiceBroker::GetWinSystem());
  winSystem->OnAppFocusChange(false);

  CServiceBroker::GetNetwork().GetServices().Stop(true);

  [self endEnterBackgroundTask];
}

- (void)enterForeground
{
  CLog::Log(LOGDEBUG, "{}", __PRETTY_FUNCTION__);

  while (m_enterBackgroundTaskId != UIBackgroundTaskInvalid)
  {
    CLog::Log(LOGDEBUG, "{}: enterBackground task still running, wait", __PRETTY_FUNCTION__);
    usleep(50 * 1000);
  }

  CServiceBroker::GetNetwork().GetServices().Start();

  CWinSystemVisionOS* winSystem =
      dynamic_cast<CWinSystemVisionOS*>(CServiceBroker::GetWinSystem());
  winSystem->OnAppFocusChange(true);

  dynamic_cast<CVisionOSPowerSyscall*>(CServiceBroker::GetPowerManager().GetPowerSyscall())
      ->SetOnResume();
  CServiceBroker::GetPowerManager().ProcessEvents();
}

#pragma mark - ScreenSaver / IdleTimer

- (void)disableScreenSaver
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
  });
}

- (void)enableScreenSaver
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
  });
}

- (bool)resetSystemIdleTimer
{
  __block bool inActive = false;
  dispatch_async(dispatch_get_main_queue(), ^{
    inActive = [UIApplication sharedApplication].applicationState == UIApplicationStateInactive;
    if (inActive)
    {
      auto wakeupString =
          [[NSArray arrayWithObjects:[NSString stringWithUTF8String:CCompileInfo::GetAppName()],
                                     @"://wakeup", nil] componentsJoinedByString:@""];
      NSURL* url = [NSURL URLWithString:wakeupString];
      [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
  });
  return inActive;
}

#pragma mark - Runtime

- (void)pauseAnimation
{
  m_pause = YES;
  auto& components = CServiceBroker::GetAppComponents();
  const auto appPower = components.GetComponent<CApplicationPowerHandling>();
  appPower->SetRenderGUI(false);
}

- (void)resumeAnimation
{
  m_pause = NO;
  auto& components = CServiceBroker::GetAppComponents();
  const auto appPower = components.GetComponent<CApplicationPowerHandling>();
  appPower->SetRenderGUI(true);
}

- (void)startAnimation
{
  if (!m_animating && glView.eglContext != EGL_NO_CONTEXT)
  {
    m_animationThreadLock = [[NSConditionLock alloc] initWithCondition:FALSE];
    m_animationThread = [[NSThread alloc] initWithTarget:self
                                                selector:@selector(runAnimation:)
                                                  object:m_animationThreadLock];
    [m_animationThread start];
    m_animating = YES;
  }
}

- (void)stopAnimation
{
  if (!m_animating && glView.eglContext != EGL_NO_CONTEXT)
  {
    m_appAlive = NO;
    m_animating = NO;
    if (!g_application.m_bStop)
      CServiceBroker::GetAppMessenger()->PostMsg(TMSG_QUIT);

    CAnnounceReceiver::GetInstance()->DeInitialize();

    if (!m_animationThread.finished)
      [m_animationThreadLock lockWhenCondition:TRUE];
  }
}

- (void)runAnimation:(id)arg
{
  @autoreleasepool
  {
    [NSThread currentThread].name = @"XBMC_Run";

    NSConditionLock* myLock = arg;
    [myLock lock];

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_NOCLDWAIT;
    sa.sa_handler = SIG_IGN;
    sigaction(SIGCHLD, &sa, NULL);

    setlocale(LC_NUMERIC, "C");

    int status = 0;
    try
    {
      m_appAlive = YES;
      status = KODI_Run(true);
      auto& components = CServiceBroker::GetAppComponents();
      const auto appPower = components.GetComponent<CApplicationPowerHandling>();
      appPower->SetRenderGUI(false);
    }
    catch (...)
    {
      m_appAlive = FALSE;
      CLog::Log(LOGERROR, "{}Exception caught on main loop status={}. Exiting",
                __PRETTY_FUNCTION__, status);
    }

    [myLock unlockWithCondition:TRUE];

    [self enableScreenSaver];
    [self performSelectorOnMainThread:@selector(CallExit) withObject:nil waitUntilDone:NO];
  }
}

#pragma mark - KODI_Run

int KODI_Run(bool renderGUI)
{
  int status = -1;

  CAppEnvironment::SetUp(std::make_shared<CAppParams>());

  if (!g_application.Create())
  {
    CLog::Log(LOGERROR, "ERROR: Unable to create application. Exiting");
    return status;
  }

#ifdef _DEBUG
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevel = LOG_LEVEL_DEBUG;
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevelHint = LOG_LEVEL_DEBUG;
#else
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevel = LOG_LEVEL_NORMAL;
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevelHint = LOG_LEVEL_NORMAL;
#endif
  CServiceBroker::GetLogging().SetLogLevel(
      CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevel);

  CAnnounceReceiver::GetInstance()->Initialize();

  if (renderGUI && !g_application.CreateGUI())
  {
    CLog::Log(LOGERROR, "ERROR: Unable to create GUI. Exiting");
    if (g_application.Stop(EXITCODE_QUIT))
      g_application.Cleanup();
    return status;
  }
  if (!g_application.Initialize())
  {
    CLog::Log(LOGERROR, "ERROR: Unable to Initialize. Exiting");
    if (g_application.Stop(EXITCODE_QUIT))
      g_application.Cleanup();
    return status;
  }

  try
  {
    status = g_application.Run();
  }
  catch (...)
  {
    CLog::Log(LOGERROR, "ERROR: Exception caught on main loop. Exiting");
    status = -1;
  }

  CAppEnvironment::TearDown();

  return status;
}

- (void)CallExit
{
  exit(0);
}

#pragma mark - EGLContext accessor

- (EGLContext)getEGLContextObj
{
  return glView.eglContext;
}

#pragma mark - init/deinit

- (void)dealloc
{
  [self endEnterBackgroundTask];
  [self stopAnimation];
}

- (instancetype)init
{
  self = [super init];
  if (!self)
    return nil;

  m_pause = NO;
  m_appAlive = NO;
  m_animating = NO;
  m_isPlayingBeforeInactive = NO;
  m_enterBackgroundTaskId = UIBackgroundTaskInvalid;

  [self enableScreenSaver];

  g_xbmcController = self;
  MPNPInfoManager = [DarwinEmbedNowPlayingInfoManager new];
  displayManager = [VisionOSDisplayManager new];

  return self;
}

@end
#undef BOOL
