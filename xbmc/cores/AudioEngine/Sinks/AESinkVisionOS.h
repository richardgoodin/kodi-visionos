/*
 *  Copyright (C) 2026 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "cores/AudioEngine/Interfaces/AESink.h"
#include "cores/AudioEngine/Utils/AEDeviceInfo.h"

#include <memory>
#include <mutex>
#include <string>

// visionOS audio sink built on AVSampleBufferAudioRenderer.
//
// The hardware route on Vision Pro (audio pods or AirPods) exposes only two
// output channels, so a RemoteIO AudioUnit can never take surround.  The OS
// spatializer that renders 5.1/7.1 binaurally with head tracking sits above
// the hardware and is fed through AVSampleBufferAudioRenderer: hand it LPCM
// sample buffers tagged with a multichannel AudioChannelLayout and it does the
// rest (the same path AVPlayer uses).  Playback position comes from the
// AVSampleBufferRenderSynchronizer's timebase.

class CAESinkVisionOS : public IAESink
{
public:
  const char* GetName() override { return "VISIONOS"; }

  CAESinkVisionOS();
  ~CAESinkVisionOS() override;

  static void Register();
  static void EnumerateDevicesEx(AEDeviceInfoList& list, bool force);
  static std::unique_ptr<IAESink> Create(std::string& device, AEAudioFormat& desiredFormat);

  bool Initialize(AEAudioFormat& format, std::string& device) override;
  void Deinitialize() override;

  void GetDelay(AEDelayStatus& status) override;
  double GetCacheTotal() override;
  unsigned int AddPackets(uint8_t** data, unsigned int frames, unsigned int offset) override;
  void Drain() override;
  bool HasVolume() override { return false; }

private:
  // Seconds of audio already handed to the renderer but not yet played.
  double QueuedSeconds() const;
  // (Re)start the synchronizer clock at the sink's current write position.
  void StartClock();
  // Stop the clock and discard everything queued in the renderer.
  void StopAndFlush();

  struct Impl; // Objective-C objects live here (kept out of the header)
  std::unique_ptr<Impl> m_impl;

  static AEDeviceInfoList m_devices;
  AEAudioFormat m_format;
  mutable std::mutex m_mutex;

  unsigned int m_sampleRate = 48000;
  unsigned int m_frameSize = 0; // bytes per frame as delivered by AE
  int64_t m_ptsSamples = 0; // frames enqueued since the last clock start
  bool m_started = false; // synchronizer running
  double m_outputLatency = 0.0; // AVAudioSession outputLatency, seconds
};
