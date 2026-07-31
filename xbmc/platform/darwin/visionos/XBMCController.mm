/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/visionos/XBMCController.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include "CompileInfo.h"
#include "FileItem.h"
#include "ServiceBroker.h"
#include "application/AppEnvironment.h"
#include "application/AppInboundProtocol.h"
#include "application/AppParams.h"
#include "application/Application.h"
#include "application/ApplicationComponents.h"
#include "application/ApplicationPowerHandling.h"
#include "cores/AudioEngine/Interfaces/AE.h"
#include "guilib/GUIComponent.h"
#include "guilib/GUIWindowManager.h"
#include "input/keyboard/XBMC_vkeys.h"
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
#import "platform/darwin/visionos/VisionOSDesktop.h"
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

#pragma mark - Window appearance

// visionOS: hide the glass container so the root window renders without the
// system panel background and its rounded corners.
- (UIContainerBackgroundStyle)preferredContainerBackgroundStyle
{
  return UIContainerBackgroundStyleHidden;
}

#pragma mark - Bluetooth keyboard helpers

// Fire a synchronous KEYDOWN + KEYUP pair into Kodi's input pipeline.
- (void)sendKeypressEvent:(XBMC_Event)event
{
  std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();
  if (appPort)
  {
    event.type = XBMC_KEYDOWN;
    appPort->OnEvent(event);
    event.type = XBMC_KEYUP;
    appPort->OnEvent(event);
  }
}

// Convenience: send a single named key with no modifier / unicode.
- (void)sendKey:(XBMCKey)key
{
  XBMC_Event evt = {};
  evt.key.keysym.sym = key;
  [self sendKeypressEvent:evt];
}

// Send a KEYDOWN only — caller must pair it with sendKeyUp:.
- (void)sendKeyDown:(XBMCKey)key
{
  std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();
  if (appPort)
  {
    XBMC_Event evt = {};
    evt.type = XBMC_KEYDOWN;
    evt.key.keysym.sym = key;
    appPort->OnEvent(evt);
  }
}

// Send a KEYUP only.
- (void)sendKeyUp:(XBMCKey)key
{
  std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();
  if (appPort)
  {
    XBMC_Event evt = {};
    evt.type = XBMC_KEYUP;
    evt.key.keysym.sym = key;
    appPort->OnEvent(evt);
  }
}

// Send a key with both sym and unicode set — letter keys need unicode.
- (void)sendKeyWithUnicode:(XBMCKey)key
{
  XBMC_Event evt = {};
  evt.key.keysym.sym = key;
  evt.key.keysym.unicode = (uint16_t)key;
  [self sendKeypressEvent:evt];
}

#pragma mark - UIKeyInput protocol (Bluetooth keyboard text input)

// Return NO so UIKit never shows the software keyboard.
// The zero-size inputView returned below also suppresses it.
- (BOOL)hasText
{
  return NO;
}

// Called for every printable character typed on the BT keyboard.
- (void)insertText:(NSString*)text
{
  if (!text.length)
    return;

  XBMC_Event evt = {};
  unichar ch = [text characterAtIndex:0];
  unichar uni = ch;

  // Upper-case letters → send as lower-case with LSHIFT modifier.
  if (ch >= 'A' && ch <= 'Z')
  {
    evt.key.keysym.mod = XBMCKMOD_LSHIFT;
    ch += 0x20;
  }

  // Newline / carriage-return → Return key.
  if (ch == '\n' || ch == '\r')
  {
    ch = XBMCK_RETURN;
    uni = XBMCK_RETURN;
  }

  evt.key.keysym.sym = (XBMCKey)ch;
  evt.key.keysym.unicode = uni;
  [self sendKeypressEvent:evt];
}

// Called when the BT keyboard Backspace key is pressed.
- (void)deleteBackward
{
  [self sendKey:XBMCK_BACKSPACE];
}

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

#pragma mark - UIResponder press events (arrow keys, Esc, Return, etc.)

// Map a UIPress to an XBMCKey for non-printable / navigation keys.
// Returns XBMCK_UNKNOWN when the key should be handled by insertText: instead.
static XBMCKey XBMCKeyFromUIPress(UIPress* press)
{
  UIKey* key = press.key;
  if (!key)
    return XBMCK_UNKNOWN;

  NSString* chars = key.charactersIgnoringModifiers;
  if (!chars.length)
    return XBMCK_UNKNOWN;

  // Navigation / special keys exposed as named UIKeyInput constants.
  if ([chars isEqualToString:UIKeyInputUpArrow])
    return XBMCK_UP;
  if ([chars isEqualToString:UIKeyInputDownArrow])
    return XBMCK_DOWN;
  if ([chars isEqualToString:UIKeyInputLeftArrow])
    return XBMCK_LEFT;
  if ([chars isEqualToString:UIKeyInputRightArrow])
    return XBMCK_RIGHT;
  if ([chars isEqualToString:UIKeyInputEscape])
    return XBMCK_ESCAPE;
  if ([chars isEqualToString:UIKeyInputPageUp])
    return XBMCK_PAGEUP;
  if ([chars isEqualToString:UIKeyInputPageDown])
    return XBMCK_PAGEDOWN;
  if ([chars isEqualToString:UIKeyInputHome])
    return XBMCK_HOME;
  if ([chars isEqualToString:UIKeyInputEnd])
    return XBMCK_END;

  // Carriage return / newline → Return.
  unichar ch = [chars characterAtIndex:0];
  if (ch == '\r' || ch == '\n')
    return XBMCK_RETURN;
  if (ch == '\t')
    return XBMCK_TAB;

  return XBMCK_UNKNOWN;
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event
{
  bool handled = false;
  for (UIPress* press in presses)
  {
    XBMCKey xkey = XBMCKeyFromUIPress(press);
    if (xkey != XBMCK_UNKNOWN)
    {
      XBMC_Event evt = {};
      evt.type = XBMC_KEYDOWN;
      evt.key.keysym.sym = xkey;
      std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();
      if (appPort)
        appPort->OnEvent(evt);
      handled = true;
    }
  }
  if (!handled)
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event
{
  bool handled = false;
  for (UIPress* press in presses)
  {
    XBMCKey xkey = XBMCKeyFromUIPress(press);
    if (xkey != XBMCK_UNKNOWN)
    {
      XBMC_Event evt = {};
      evt.type = XBMC_KEYUP;
      evt.key.keysym.sym = xkey;
      std::shared_ptr<CAppInboundProtocol> appPort = CServiceBroker::GetAppPort();
      if (appPort)
        appPort->OnEvent(evt);
      handled = true;
    }
  }
  if (!handled)
    [super pressesEnded:presses withEvent:event];
}

#pragma mark - View

- (void)viewDidLoad
{
  [super viewDidLoad];

  glView = [[VisionOSGLView alloc] initWithFrame:CGRectMake(0, 0, VISIONOS_DESKTOP_WIDTH, VISIONOS_DESKTOP_HEIGHT)];

  displayManager.screenScale = [glView getScreenScale];

  // RealityKit-Mono: nothing native may render in the window — the display
  // plane is the only visible rectangle.  (Was blackColor, which composited
  // as a black rectangle at glass depth and z-fought the plane.)
  self.view.backgroundColor = UIColor.clearColor;
  [self.view addSubview:glView];
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  CGSize fixed = glView.bounds.size;
  CGSize avail = self.view.bounds.size;
  if (fixed.width <= 0 || fixed.height <= 0)
    return;
  CGFloat s = MIN(avail.width / fixed.width, avail.height / fixed.height);
  glView.transform = CGAffineTransformMakeScale(s, s);
  glView.center = CGPointMake(avail.width / 2.0, avail.height / 2.0);
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

  // RealityKit-Mono presentation: embed the RealityKit hosting view (the
  // display plane that shows Kodi's IOSurface) as a child over the glView
  // shortly after the window is up.  Runtime class lookup - no generated
  // -Swift.h coupling.
  static dispatch_once_t stereoOnce;
  dispatch_once(&stereoOnce, ^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      Class presenterClass = NSClassFromString(@"VisionOSStereoPresenter");
      if (!presenterClass)
      {
        CLog::Log(LOGERROR, "VISIONOS-STEREO: VisionOSStereoPresenter not found - Swift lib not linked?");
        return;
      }
      id presenter = [[presenterClass alloc] init];
      self.stereoPresenter = presenter;
      UIViewController* vc = [presenter valueForKey:@"viewController"];
      if (!vc)
      {
        CLog::Log(LOGERROR, "VISIONOS-STEREO: presenter returned no view controller");
        return;
      }
      [self addChildViewController:vc];
      // Cover the ENTIRE fixed desktop: subview of the glView so it inherits
      // the drag-scaling transform and stays aligned through resizes.
      vc.view.frame = self.glView.bounds;
      // Input ENABLED: with the native stack fully transparent, UIKit views
      // are not gaze-targetable — the RealityKit plane is the targetable
      // content, and its gestures feed the gaze grammar via injectGazePhase.
      vc.view.userInteractionEnabled = YES;
      [presenter setValue:self.glView forKey:@"gazeTarget"];
      [self.glView addSubview:vc.view];
      [vc didMoveToParentViewController:self];
    });
  });
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
    // Release the EGL context from the main thread so the XBMC_Run background
    // thread can acquire it via eglMakeCurrent in InitRenderSystem.
    // If initEGL bound the context on the main thread and we don't release it
    // here, eglMakeCurrent on the render thread returns EGL_BAD_ACCESS (0x3002).
    [glView releaseContext];

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
    catch (const std::exception& e)
    {
      m_appAlive = FALSE;
      CLog::Log(LOGERROR, "{}std::exception caught on main loop: {} (status={}). Exiting",
                __PRETTY_FUNCTION__, e.what(), status);
    }
    catch (...)
    {
      m_appAlive = FALSE;
      CLog::Log(LOGERROR, "{}Unknown exception caught on main loop status={}. Exiting",
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

#pragma mark - Stereo presentation

// Render thread.  The presenter's update method only schedules main-actor
// work, so the call itself is cheap and thread-safe.
- (void)publishStereoSurface
{
  id presenter = self.stereoPresenter;
  if (!presenter)
    return;
  IOSurfaceRef surface = self.glView.renderSurface;
  if (!surface)
    return;
  ((void (*)(id, SEL, IOSurfaceRef))objc_msgSend)(presenter, @selector(updateWithIOSurface:),
                                                  surface);
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
