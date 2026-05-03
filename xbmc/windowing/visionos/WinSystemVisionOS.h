/*
 *  Copyright (C) 2024 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "rendering/gles/RenderSystemGLES.h"
#include "threads/CriticalSection.h"
#include "threads/Timer.h"
#include "windowing/OSScreenSaver.h"
#include "windowing/WinSystem.h"

#include <EGL/egl.h>

#include <memory>
#include <string>
#include <vector>

class IDispResource;
class CVideoSyncVisionOS;
struct CADisplayLinkWrapper;

class CWinSystemVisionOS : public CWinSystemBase,
                           public CRenderSystemGLES,
                           public ITimerCallback
{
public:
  CWinSystemVisionOS();
  ~CWinSystemVisionOS() override;

  static void Register();
  static std::unique_ptr<CWinSystemBase> CreateWinSystem();

  // ITimerCallback
  void OnTimeout() override {}

  void MessagePush(XBMC_Event* newEvent);
  size_t GetQueueSize();
  void AnnounceOnLostDevice();
  void AnnounceOnResetDevice();
  void StartLostDeviceTimer();
  void StopLostDeviceTimer();

  // CWinSystemBase
  CRenderSystemBase* GetRenderSystem() override { return this; }
  bool InitWindowSystem() override;
  bool DestroyWindowSystem() override;
  bool CreateNewWindow(const std::string& name, bool fullScreen, RESOLUTION_INFO& res) override;
  bool DestroyWindow() override;
  bool ResizeWindow(int newWidth, int newHeight, int newLeft, int newTop) override;
  bool SetFullScreen(bool fullScreen, RESOLUTION_INFO& res, bool blankOtherDisplays) override;
  int GetBufferAge() override { return 3; }
  void UpdateResolutions() override;
  bool CanDoWindowed() override { return false; }

  void ShowOSMouse(bool show) override {}
  bool HasCursor() override;

  void NotifyAppActiveChange(bool bActivated) override;

  bool Minimize() override;
  bool Restore() override;
  bool Hide() override;
  bool Show(bool raise = true) override;

  bool IsExtSupported(const char* extension) const override;

  bool BeginRender() override;
  bool EndRender() override;

  void Register(IDispResource* resource) override;
  void Unregister(IDispResource* resource) override;

  std::vector<std::string> GetConnectedOutputs() override;

  bool InitDisplayLink(CVideoSyncVisionOS* syncImpl);
  void DeinitDisplayLink();
  void OnAppFocusChange(bool focus);
  bool IsBackgrounded() const { return m_bIsBackgrounded; }
  EGLContext GetEGLContextObj();

  // winevents
  bool MessagePump() override;

protected:
  std::unique_ptr<KODI::WINDOWING::IOSScreenSaver> GetOSScreenSaverImpl() override;
  void PresentRenderImpl(bool rendered) override;
  void SetVSyncImpl(bool enable) override {}

  void* m_glView; // VisionOSGLView opaque ptr
  bool m_bWasFullScreenBeforeMinimize;
  std::string m_eglext;
  CCriticalSection m_resourceSection;
  std::vector<IDispResource*> m_resources;
  bool m_bIsBackgrounded;
  CTimer m_lostDeviceTimer;

private:
  bool GetScreenResolution(int* w, int* h, double* fps);
  CADisplayLinkWrapper* m_pDisplayLink;
};
