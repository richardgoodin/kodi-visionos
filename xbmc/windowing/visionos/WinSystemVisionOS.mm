/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "WinSystemVisionOS.h"

#include "ServiceBroker.h"
// visionOS is an embedded Apple platform; the iOS audio sink (AVAudioSession +
// AudioUnit) is the closest match.  AESinkDARWINTVOS would also compile since
// AVAudioSession is present on visionOS, but tvOS-specific route / category
// constants that aren't available on xrOS will produce warnings.
#import "cores/AudioEngine/Sinks/AESinkDARWINIOS.h"
#include "cores/RetroPlayer/process/ios/RPProcessInfoIOS.h"
#include "cores/RetroPlayer/rendering/VideoRenderers/RPRendererOpenGLES.h"
#include "cores/VideoPlayer/DVDCodecs/DVDFactoryCodec.h"
#include "cores/VideoPlayer/DVDCodecs/Video/VTB.h"
// ProcessInfoIOS / RPProcessInfoIOS are pure C++ stubs; no iOS-specific APIs.
// They register VTB + GLES capabilities that are identical on visionOS.
#include "cores/VideoPlayer/Process/ios/ProcessInfoIOS.h"
// RendererVTBGLES is excluded from the visionOS build (CVOpenGLESTextureCache
// and the native GLES sync APIs are unavailable on visionOS).
#include "cores/VideoPlayer/VideoRenderers/LinuxRendererGLES.h"

// ANGLE GLES headers — glGetString and friends come from ANGLE, not the
// unavailable system OpenGL ES framework on visionOS.
#include <GLES3/gl3.h>
#include "cores/VideoPlayer/VideoRenderers/RenderFactory.h"
#include "filesystem/SpecialProtocol.h"
#include "guilib/DispResource.h"
#include "guilib/Texture.h"
#include "messaging/ApplicationMessenger.h"
#include "settings/DisplaySettings.h"
#include "settings/Settings.h"
#include "settings/SettingsComponent.h"
#include "utils/StringUtils.h"
#include "utils/log.h"
#include "windowing/GraphicContext.h"
#include "windowing/OSScreenSaver.h"
#include "windowing/WindowSystemFactory.h"
#import "windowing/visionos/OSScreenSaverVisionOS.h"
#import "windowing/visionos/VideoSyncVisionOS.h"
#import "windowing/visionos/WinEventsVisionOS.h"

#import "platform/darwin/DarwinUtils.h"
#import "platform/darwin/visionos/VisionOSDisplayManager.h"
#import "platform/darwin/visionos/VisionOSGLView.h"
#import "platform/darwin/visionos/XBMCController.h"

#include <memory>
#include <mutex>
#include <vector>

#import <Foundation/Foundation.h>
#import <QuartzCore/CADisplayLink.h>

using namespace std::chrono_literals;

#define CONST_HDMI "HDMI"

constexpr auto LOST_DEVICE_TIMEOUT_MS{3000ms};

// CADisplayLink callback shim
@interface VisionOSDisplayLinkCallback : NSObject
{
@private
  CVideoSyncVisionOS* videoSyncImpl;
}
@property(nonatomic, setter=SetVideoSyncImpl:) CVideoSyncVisionOS* videoSyncImpl;
- (void)runDisplayLink;
@end

using namespace KODI;
using namespace MESSAGING;

struct CADisplayLinkWrapper
{
  CADisplayLink* impl;
  VisionOSDisplayLinkCallback* callbackClass;
};

void CWinSystemVisionOS::Register()
{
  KODI::WINDOWING::CWindowSystemFactory::RegisterWindowSystem(CreateWinSystem);
}

std::unique_ptr<CWinSystemBase> CWinSystemVisionOS::CreateWinSystem()
{
  return std::make_unique<CWinSystemVisionOS>();
}

void CWinSystemVisionOS::MessagePush(XBMC_Event* newEvent)
{
  dynamic_cast<CWinEventsVisionOS&>(*m_winEvents).MessagePush(newEvent);
}

size_t CWinSystemVisionOS::GetQueueSize()
{
  return dynamic_cast<CWinEventsVisionOS&>(*m_winEvents).GetQueueSize();
}

void CWinSystemVisionOS::AnnounceOnLostDevice()
{
  std::unique_lock lock(m_resourceSection);
  CLog::Log(LOGDEBUG, "CWinSystemVisionOS::AnnounceOnLostDevice");
  for (auto dispResource : m_resources)
    dispResource->OnLostDisplay();
}

void CWinSystemVisionOS::AnnounceOnResetDevice()
{
  std::unique_lock lock(m_resourceSection);
  CLog::Log(LOGDEBUG, "CWinSystemVisionOS::AnnounceOnResetDevice");
  for (auto dispResource : m_resources)
    dispResource->OnResetDisplay();
}

void CWinSystemVisionOS::StartLostDeviceTimer()
{
  if (m_lostDeviceTimer.IsRunning())
    m_lostDeviceTimer.Restart();
  else
    m_lostDeviceTimer.Start(LOST_DEVICE_TIMEOUT_MS, false);
}

void CWinSystemVisionOS::StopLostDeviceTimer()
{
  m_lostDeviceTimer.Stop();
}

CWinSystemVisionOS::CWinSystemVisionOS() : CWinSystemBase(), m_lostDeviceTimer(this)
{
  m_bIsBackgrounded = false;
  m_pDisplayLink = new CADisplayLinkWrapper;
  m_pDisplayLink->callbackClass = [[VisionOSDisplayLinkCallback alloc] init];

  m_winEvents = std::make_unique<CWinEventsVisionOS>();

  CAESinkDARWINIOS::Register();
}

CWinSystemVisionOS::~CWinSystemVisionOS()
{
  m_pDisplayLink->callbackClass = nil;
  delete m_pDisplayLink;
}

bool CWinSystemVisionOS::InitWindowSystem()
{
  return CWinSystemBase::InitWindowSystem();
}

bool CWinSystemVisionOS::DestroyWindowSystem()
{
  return true;
}

std::unique_ptr<KODI::WINDOWING::IOSScreenSaver> CWinSystemVisionOS::GetOSScreenSaverImpl()
{
  return std::make_unique<COSScreenSaverVisionOS>();
}

bool CWinSystemVisionOS::CreateNewWindow(const std::string& name,
                                         bool fullScreen,
                                         RESOLUTION_INFO& res)
{
  if (!SetFullScreen(fullScreen, res, false))
    return false;

  [g_xbmcController setFramebuffer];

  m_bWindowCreated = true;

  m_eglext = " ";

  // Use EGL to query extension strings; the system OpenGL ES glGetString is
  // unavailable on visionOS (we go through ANGLE).
  // The EGL display lives in VisionOSGLView; retrieve it from the controller.
  EGLDisplay eglDisplay = g_xbmcController.glView.eglDisplay;
  const char* tmpExtensions = eglQueryString(eglDisplay, EGL_EXTENSIONS);
  if (tmpExtensions != nullptr)
  {
    m_eglext += tmpExtensions;
    m_eglext += " ";
  }

  CLog::Log(LOGDEBUG, "GL_EXTENSIONS: {}", m_eglext);

  // Register platform-dependent rendering objects
  CDVDFactoryCodec::ClearHWAccels();
  VTB::CDecoder::Register();
  VIDEOPLAYER::CRendererFactory::ClearRenderer();
  CLinuxRendererGLES::Register();
  // CRendererVTB not available on visionOS (CVOpenGLESTextureCache unavailable).
  VIDEOPLAYER::CProcessInfoIOS::Register();
  RETRO::CRPProcessInfoIOS::Register();
  RETRO::CRPProcessInfoIOS::RegisterRendererFactory(new RETRO::CRendererFactoryOpenGLES);

  return true;
}

bool CWinSystemVisionOS::InitRenderSystem()
{
  // UIKit's layoutSubviews can fire between CreateNewWindow() and this call,
  // unbinding the EGL context (eglMakeCurrent to NULL) while recreating the
  // surface.  Explicitly rebind here before the base class calls glGetString.
  VisionOSGLView* glView = g_xbmcController.glView;
  EGLDisplay disp = glView.eglDisplay;
  EGLSurface surf = glView.eglSurface;
  EGLContext ctx  = glView.eglContext;

  CLog::Log(LOGDEBUG, "CWinSystemVisionOS::InitRenderSystem: disp={} surf={} ctx={}",
            (void*)disp, (void*)surf, (void*)ctx);

  if (ctx != EGL_NO_CONTEXT && surf != EGL_NO_SURFACE)
  {
    if (!eglMakeCurrent(disp, surf, surf, ctx))
      CLog::Log(LOGERROR, "CWinSystemVisionOS::InitRenderSystem: eglMakeCurrent failed err=0x{:x}",
                static_cast<unsigned>(eglGetError()));
    else
      CLog::Log(LOGDEBUG, "CWinSystemVisionOS::InitRenderSystem: eglMakeCurrent OK");
  }
  else
  {
    CLog::Log(LOGERROR, "CWinSystemVisionOS::InitRenderSystem: EGL context or surface is invalid (ctx={} surf={})",
              (void*)ctx, (void*)surf);
  }

  return CRenderSystemGLES::InitRenderSystem();
}

bool CWinSystemVisionOS::DestroyWindow()
{
  return true;
}

bool CWinSystemVisionOS::ResizeWindow(int newWidth, int newHeight, int newLeft, int newTop)
{
  if (m_nWidth != newWidth || m_nHeight != newHeight)
  {
    m_nWidth = newWidth;
    m_nHeight = newHeight;
  }
  CRenderSystemGLES::ResetRenderSystem(newWidth, newHeight);
  return true;
}

bool CWinSystemVisionOS::SetFullScreen(bool fullScreen, RESOLUTION_INFO& res, bool blankOtherDisplays)
{
  m_nWidth = res.iWidth;
  m_nHeight = res.iHeight;
  m_bFullScreen = fullScreen;

  CLog::Log(LOGDEBUG, "About to switch to {} x {} @ {}", m_nWidth, m_nHeight, res.fRefreshRate);
  // No mode switching on visionOS; just reset the render system dimensions
  [g_xbmcController.displayManager displayRateSwitch:res.fRefreshRate withDynamicRange:0];
  CRenderSystemGLES::ResetRenderSystem(res.iWidth, res.iHeight);
  return true;
}

bool CWinSystemVisionOS::GetScreenResolution(int* w, int* h, double* fps)
{
  *w = [g_xbmcController.displayManager getScreenSize].width;
  *h = [g_xbmcController.displayManager getScreenSize].height;
  *fps = [g_xbmcController.displayManager getDisplayRate];
  CLog::Log(LOGDEBUG, "visionOS screen: {}x{} @ {}", *w, *h, *fps);
  return true;
}

void CWinSystemVisionOS::UpdateResolutions()
{
  int w, h;
  double fps;
  CWinSystemBase::UpdateResolutions();

  if (GetScreenResolution(&w, &h, &fps))
    UpdateDesktopResolution(CDisplaySettings::GetInstance().GetResolutionInfo(RES_DESKTOP),
                            CONST_HDMI, w, h, fps, 0);

  CDisplaySettings::GetInstance().ClearCustomResolutions();

  // visionOS: add a limited set of refresh rates matching the display capability
  const std::vector<float> supportedRefreshRates = {24.0f, 25.0f, 30.0f, 60.0f, 90.0f};
  for (float refreshRate : supportedRefreshRates)
  {
    RESOLUTION_INFO res;
    UpdateDesktopResolution(res, CONST_HDMI, w, h, refreshRate, 0);
    CLog::Log(LOGINFO, "visionOS: adding resolution {}x{} @ {}", w, h, refreshRate);
    CServiceBroker::GetWinSystem()->GetGfxContext().ResetOverscan(res);
    CDisplaySettings::GetInstance().AddResolutionInfo(res);
  }
}

bool CWinSystemVisionOS::IsExtSupported(const char* extension) const
{
  if (strncmp(extension, "EGL_", 4) != 0)
    return CRenderSystemGLES::IsExtSupported(extension);

  std::string name = ' ' + std::string(extension) + ' ';
  return m_eglext.find(name) != std::string::npos;
}

bool CWinSystemVisionOS::BeginRender()
{
  [g_xbmcController setFramebuffer];
  return CRenderSystemGLES::BeginRender();
}

bool CWinSystemVisionOS::EndRender()
{
  return CRenderSystemGLES::EndRender();
}

void CWinSystemVisionOS::Register(IDispResource* resource)
{
  std::unique_lock lock(m_resourceSection);
  m_resources.push_back(resource);
}

void CWinSystemVisionOS::Unregister(IDispResource* resource)
{
  std::unique_lock lock(m_resourceSection);
  auto i = std::find(m_resources.begin(), m_resources.end(), resource);
  if (i != m_resources.end())
    m_resources.erase(i);
}

void CWinSystemVisionOS::OnAppFocusChange(bool focus)
{
  std::unique_lock lock(m_resourceSection);
  m_bIsBackgrounded = !focus;
  CLog::Log(LOGDEBUG, "CWinSystemVisionOS::OnAppFocusChange: {}", focus ? 1 : 0);
  for (auto dispResource : m_resources)
    dispResource->OnAppFocusChange(focus);
}

// CADisplayLink integration
@implementation VisionOSDisplayLinkCallback
@synthesize videoSyncImpl;
- (void)runDisplayLink
{
  @autoreleasepool
  {
    if (videoSyncImpl != nullptr)
      videoSyncImpl->VisionOSVblankHandler();
  }
}
@end

bool CWinSystemVisionOS::InitDisplayLink(CVideoSyncVisionOS* syncImpl)
{
  m_pDisplayLink->callbackClass.videoSyncImpl = syncImpl;

  // Create a CADisplayLink attached to the main run loop.
  // UIWindowScene.displayLinkWithTarget:selector: is not available on visionOS 1.0;
  // CADisplayLink with the main run loop is the supported alternative.
  m_pDisplayLink->impl = [CADisplayLink
      displayLinkWithTarget:m_pDisplayLink->callbackClass
                   selector:@selector(runDisplayLink)];
  [m_pDisplayLink->impl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
  return true;
}

void CWinSystemVisionOS::DeinitDisplayLink()
{
  if (m_pDisplayLink->impl)
  {
    [m_pDisplayLink->impl invalidate];
    m_pDisplayLink->impl = nil;
    [m_pDisplayLink->callbackClass SetVideoSyncImpl:nil];
  }
}

void CWinSystemVisionOS::PresentRenderImpl(bool rendered)
{
  if (rendered)
    [g_xbmcController presentFramebuffer];
}

bool CWinSystemVisionOS::HasCursor()
{
  // VISIONOS_STAGE2: pointer/cursor is visible when paired with Magic Trackpad
  return false;
}

void CWinSystemVisionOS::NotifyAppActiveChange(bool bActivated)
{
  if (bActivated && m_bWasFullScreenBeforeMinimize &&
      !CServiceBroker::GetWinSystem()->GetGfxContext().IsFullScreenRoot())
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_TOGGLEFULLSCREEN);
}

bool CWinSystemVisionOS::Minimize()
{
  m_bWasFullScreenBeforeMinimize =
      CServiceBroker::GetWinSystem()->GetGfxContext().IsFullScreenRoot();
  if (m_bWasFullScreenBeforeMinimize)
    CServiceBroker::GetAppMessenger()->PostMsg(TMSG_TOGGLEFULLSCREEN);
  return true;
}

bool CWinSystemVisionOS::Restore()
{
  return false;
}

bool CWinSystemVisionOS::Hide()
{
  return true;
}

bool CWinSystemVisionOS::Show(bool raise)
{
  return true;
}

EGLContext CWinSystemVisionOS::GetEGLContextObj()
{
  return [g_xbmcController getEGLContextObj];
}

std::vector<std::string> CWinSystemVisionOS::GetConnectedOutputs()
{
  return {"Default", CONST_HDMI};
}

bool CWinSystemVisionOS::MessagePump()
{
  return m_winEvents->MessagePump();
}
