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
#include "cores/VideoPlayer/VideoRenderers/HwDecRender/RendererVTBVisionOS.h"
// GLES SW renderer subclass adding the stereo CONF_FLAGS translation the
// stock GLES renderer lacks (registered as "default" in place of
// CLinuxRendererGLES below).
#include "cores/VideoPlayer/VideoRenderers/HwDecRender/LinuxRendererGLESVisionOS.h"

// ANGLE GLES headers — glGetString and friends come from ANGLE, not the
// unavailable system OpenGL ES framework on visionOS.
#include <GLES3/gl3.h>
#include "cores/VideoPlayer/VideoRenderers/RenderFactory.h"
#include "filesystem/SpecialProtocol.h"
#include "guilib/DispResource.h"
#include "guilib/IDirtyRegionSolver.h"
#include "guilib/Texture.h"
#include "messaging/ApplicationMessenger.h"
#include "settings/AdvancedSettings.h"
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
  NSThread* thread;
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

  // Dirty-region optimization is disabled on this platform by design: the
  // full composite is republished wholesale into an IOSurface every frame,
  // video behind GUI windows is drawn outside the dirty-region system, and
  // partial redraw assumes framebuffer retention that the BufferQueue
  // presentation model doesn't provide.  Force the fill-viewport-always
  // solver: every iteration renders the whole frame and presents — the
  // vsync block in presentFramebuffer paces the loop.  Must be set before
  // CGUIWindowManager::Initialize() runs SelectAlgorithm().
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_guiAlgorithmDirtyRegions =
      DIRTYREGION_SOLVER_FILL_VIEWPORT_ALWAYS;

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
  CLinuxRendererGLESVisionOS::Register();
  CRendererVTBVisionOS::Register();
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
  // Use the actual EGL framebuffer pixel dimensions reported by eglQuerySurface
  // rather than a hardcoded logical resolution.  This ensures m_width/m_height
  // in CRenderSystemGLES match the real drawable surface so that
  // SetScissors' Y-flip (m_height - y2) lands in the correct GL pixel row.
  VisionOSGLView* glView = g_xbmcController.glView;
  if (glView && glView.eglSurface != EGL_NO_SURFACE)
  {
    EGLint fbW = 0, fbH = 0;
    eglQuerySurface(glView.eglDisplay, glView.eglSurface, EGL_WIDTH,  &fbW);
    eglQuerySurface(glView.eglDisplay, glView.eglSurface, EGL_HEIGHT, &fbH);
    if (fbW > 0 && fbH > 0)
    {
      *w = fbW;
      *h = fbH;
      *fps = [g_xbmcController.displayManager getDisplayRate];
      CLog::Log(LOGDEBUG, "visionOS screen: {}x{} @ {} (from EGL surface)", *w, *h, *fps);
      return true;
    }
  }
  // Fallback to display manager if EGL surface is not yet available.
  *w = [g_xbmcController.displayManager getScreenSize].width;
  *h = [g_xbmcController.displayManager getScreenSize].height;
  *fps = [g_xbmcController.displayManager getDisplayRate];
  CLog::Log(LOGDEBUG, "visionOS screen: {}x{} @ {} (from display manager)", *w, *h, *fps);
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

  // visionOS: add a limited set of refresh rates matching the display
  // capability (M2: 90/96/100; M5: up to 120).  displayRateSwitch is a
  // no-op — the compositor owns the mode — so these are informational.
  const std::vector<float> supportedRefreshRates = {24.0f,  25.0f, 30.0f,  60.0f,
                                                    90.0f,  96.0f, 100.0f, 120.0f};
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

bool CWinSystemVisionOS::SupportsStereo(RenderStereoMode mode) const
{
  // RealityKit presentation renders each eye into its own full-resolution
  // IOSurface selected by the camera-index material — advertise HARDWAREBASED
  // on top of the base modes (OFF / SPLIT_VERTICAL / SPLIT_HORIZONTAL / MONO).
  if (mode == RenderStereoMode::HARDWAREBASED)
    return true;
  return CRenderSystemGLES::SupportsStereo(mode);
}

void CWinSystemVisionOS::SetStereoMode(RenderStereoMode mode, RenderStereoView view)
{
  CRenderSystemGLES::SetStereoMode(mode, view);
  // HARDWAREBASED: Application::Render runs the full render once per eye,
  // calling SetStereoView(LEFT) then SetStereoView(RIGHT), which lands here
  // per pass — bind that eye's render target.  Everything else (including
  // the SetStereoView(OFF) at frame end and all non-stereo rendering)
  // draws on the left/mono target.  selectEye only touches GL when the
  // calling thread holds the EGL context, so stray calls from non-render
  // threads (e.g. resolution changes) are harmless.
  const int eye =
      (mode == RenderStereoMode::HARDWAREBASED && view == RenderStereoView::RIGHT) ? 1 : 0;
  [g_xbmcController.glView selectEye:eye];
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

  // Dedicated thread + run loop for the vblank link: on the MAIN run loop
  // the callback is starved under load (measured 5-15% dropped ticks),
  // jittering the video reference clock this link drives.  The link is
  // created on the thread it runs on; DeinitDisplayLink's invalidate
  // empties the run loop and the thread exits.
  CADisplayLinkWrapper* wrapper = m_pDisplayLink;
  VisionOSDisplayLinkCallback* cb = m_pDisplayLink->callbackClass;
  NSThread* thread = [[NSThread alloc] initWithBlock:^{
    @autoreleasepool
    {
      wrapper->impl = [CADisplayLink displayLinkWithTarget:cb
                                                  selector:@selector(runDisplayLink)];
      [wrapper->impl addToRunLoop:[NSRunLoop currentRunLoop]
                          forMode:NSRunLoopCommonModes];
      [[NSRunLoop currentRunLoop] run];
    }
  }];
  thread.name = @"Kodi-videosync";
  thread.qualityOfService = NSQualityOfServiceUserInteractive;
  m_pDisplayLink->thread = thread;
  [thread start];
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
  m_pDisplayLink->thread = nil;
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
