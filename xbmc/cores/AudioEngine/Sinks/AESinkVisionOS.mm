/*
 *  Copyright (C) 2026 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "AESinkVisionOS.h"

#include "cores/AudioEngine/AESinkFactory.h"
#include "cores/AudioEngine/Utils/AEUtil.h"
#include "utils/log.h"

#include <chrono>
#include <thread>
#include <vector>

#import <AVFoundation/AVAudioSession.h>
#import <AVFoundation/AVSampleBufferAudioRenderer.h>
#import <AVFoundation/AVSampleBufferRenderSynchronizer.h>
#import <CoreMedia/CoreMedia.h>

using namespace std::chrono_literals;

namespace
{
// How much audio we let sit in the renderer ahead of the play head.  AE's
// A/V sync tolerates this as long as GetDelay reports it accurately; smaller
// values give tighter sync, larger ones more underrun protection.
constexpr double kMaxQueuedSeconds = 0.35;
// Audio primed before the clock is started, so the first frames aren't late.
constexpr double kPrimeSeconds = 0.10;

// Map an AE channel onto a CoreAudio channel label.  For 5.1 the rear pair is
// LeftSurround/RightSurround; in 7.1 those labels belong to the side pair and
// the rear pair becomes RearSurroundLeft/Right, so the mapping of BL/BR depends
// on whether SL/SR are present.  Returns 0 for channels we don't carry.
AudioChannelLabel ChannelLabel(enum AEChannel ch, bool hasSides)
{
  switch (ch)
  {
    case AE_CH_FL:
      return kAudioChannelLabel_Left;
    case AE_CH_FR:
      return kAudioChannelLabel_Right;
    case AE_CH_FC:
      return kAudioChannelLabel_Center;
    case AE_CH_LFE:
      return kAudioChannelLabel_LFEScreen;
    case AE_CH_BL:
      return hasSides ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround;
    case AE_CH_BR:
      return hasSides ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround;
    case AE_CH_SL:
      return kAudioChannelLabel_LeftSurround;
    case AE_CH_SR:
      return kAudioChannelLabel_RightSurround;
    case AE_CH_FLOC:
      return kAudioChannelLabel_LeftCenter;
    case AE_CH_FROC:
      return kAudioChannelLabel_RightCenter;
    case AE_CH_BC:
      return kAudioChannelLabel_CenterSurround;
    default:
      return 0;
  }
}
} // namespace

struct CAESinkVisionOS::Impl
{
  AVSampleBufferAudioRenderer* renderer = nil;
  AVSampleBufferRenderSynchronizer* sync = nil;
  CMAudioFormatDescriptionRef fmtDesc = nullptr;
};

AEDeviceInfoList CAESinkVisionOS::m_devices;

CAESinkVisionOS::CAESinkVisionOS() : m_impl(std::make_unique<Impl>())
{
}

CAESinkVisionOS::~CAESinkVisionOS()
{
  Deinitialize();
}

void CAESinkVisionOS::Register()
{
  AE::AESinkRegEntry reg;
  reg.sinkName = "VISIONOS";
  reg.createFunc = CAESinkVisionOS::Create;
  reg.enumerateFunc = CAESinkVisionOS::EnumerateDevicesEx;
  AE::CAESinkFactory::RegisterSink(reg);
}

std::unique_ptr<IAESink> CAESinkVisionOS::Create(std::string& device, AEAudioFormat& desiredFormat)
{
  auto sink = std::make_unique<CAESinkVisionOS>();
  if (sink->Initialize(desiredFormat, device))
    return sink;
  return {};
}

void CAESinkVisionOS::EnumerateDevicesEx(AEDeviceInfoList& list, bool force)
{
  m_devices.clear();

  CAEDeviceInfo device;
  device.m_deviceName = "default";
  device.m_displayName = "Spatial Audio";
  device.m_displayNameExtra = "AVSampleBufferAudioRenderer";
  device.m_deviceType = AE_DEVTYPE_PCM;
  device.m_wantsIECPassthrough = false;
  device.m_onlyPCM = true;

  // Advertise the full 7.1 set; the OS spatializer takes whatever layout the
  // sample buffers are tagged with, independent of the 2-channel hardware
  // route.  AE picks the layout from the user's "Number of channels" setting.
  device.m_channels = AE_CH_LAYOUT_7_1;
  device.m_sampleRates.push_back(48000);
  device.m_dataFormats.push_back(AE_FMT_FLOAT);

  CLog::Log(LOGDEBUG, "CAESinkVisionOS::EnumerateDevicesEx: {}", device.m_deviceName);
  m_devices.push_back(device);
  list = m_devices;
}

bool CAESinkVisionOS::Initialize(AEAudioFormat& format, std::string& device)
{
  std::lock_guard<std::mutex> lock(m_mutex);

  if (format.m_dataFormat == AE_FMT_RAW)
  {
    CLog::Log(LOGERROR, "CAESinkVisionOS::Initialize: passthrough not supported");
    return false;
  }

  // Keep only channels we can label for CoreAudio; AE remaps to this layout.
  bool hasSides = false;
  for (unsigned int i = 0; i < format.m_channelLayout.Count(); ++i)
    if (format.m_channelLayout[i] == AE_CH_SL || format.m_channelLayout[i] == AE_CH_SR)
      hasSides = true;

  CAEChannelInfo channels;
  std::vector<AudioChannelLabel> labels;
  for (unsigned int i = 0; i < format.m_channelLayout.Count(); ++i)
  {
    AudioChannelLabel label = ChannelLabel(format.m_channelLayout[i], hasSides);
    if (label == 0 || labels.size() >= 8)
      continue;
    channels += format.m_channelLayout[i];
    labels.push_back(label);
  }
  if (labels.empty())
  {
    channels += AE_CH_FL;
    channels += AE_CH_FR;
    labels = {kAudioChannelLabel_Left, kAudioChannelLabel_Right};
  }

  format.m_channelLayout = channels;
  format.m_dataFormat = AE_FMT_FLOAT;
  format.m_sampleRate = 48000;
  format.m_frames = 1024;
  format.m_frameSize = channels.Count() * sizeof(float);
  m_sampleRate = format.m_sampleRate;
  m_frameSize = format.m_frameSize;
  m_format = format;

  // Audio session: multichannel content declaration is a hint to the OS that
  // spatial content is being played; the sample rate keeps the renderer from
  // resampling.
  AVAudioSession* session = AVAudioSession.sharedInstance;
  NSError* err = nil;
  [session setPreferredSampleRate:m_sampleRate error:&err];
  err = nil;
  [session setSupportsMultichannelContent:(channels.Count() > 2) error:&err];
  m_outputLatency = session.outputLatency;

  // Format description: interleaved packed float with an explicit channel
  // layout built from per-channel labels (no ordering assumptions).
  AudioStreamBasicDescription asbd = {};
  asbd.mSampleRate = m_sampleRate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  asbd.mChannelsPerFrame = static_cast<UInt32>(channels.Count());
  asbd.mFramesPerPacket = 1;
  asbd.mBitsPerChannel = 32;
  asbd.mBytesPerFrame = asbd.mChannelsPerFrame * 4;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame;

  const size_t layoutSize =
      offsetof(AudioChannelLayout, mChannelDescriptions) +
      labels.size() * sizeof(AudioChannelDescription);
  std::vector<uint8_t> layoutBuf(layoutSize, 0);
  auto* layout = reinterpret_cast<AudioChannelLayout*>(layoutBuf.data());
  layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
  layout->mNumberChannelDescriptions = static_cast<UInt32>(labels.size());
  for (size_t i = 0; i < labels.size(); ++i)
    layout->mChannelDescriptions[i].mChannelLabel = labels[i];

  OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, layoutSize, layout,
                                                   0, nullptr, nullptr, &m_impl->fmtDesc);
  if (status != noErr)
  {
    CLog::Log(LOGERROR, "CAESinkVisionOS::Initialize: CMAudioFormatDescriptionCreate failed {}",
              static_cast<int>(status));
    return false;
  }

  m_impl->renderer = [[AVSampleBufferAudioRenderer alloc] init];
  m_impl->sync = [[AVSampleBufferRenderSynchronizer alloc] init];
  if (!m_impl->renderer || !m_impl->sync)
  {
    CLog::Log(LOGERROR, "CAESinkVisionOS::Initialize: renderer/synchronizer creation failed");
    return false;
  }

  // Let the OS spatialize everything we hand it, multichannel included.
  m_impl->renderer.allowedAudioSpatializationFormats =
      AVAudioSpatializationFormatMonoStereoAndMultichannel;
  // We manage priming ourselves; don't let the synchronizer defer the rate
  // change until it decides it has "sufficient" data.
  m_impl->sync.delaysRateChangeUntilHasSufficientMediaData = NO;
  [m_impl->sync addRenderer:m_impl->renderer];

  m_ptsSamples = 0;
  m_started = false;

  CLog::Log(LOGINFO,
            "CAESinkVisionOS::Initialize: {} ch @ {} Hz float, route outputLatency {:.4f}",
            channels.Count(), m_sampleRate, m_outputLatency);
  return true;
}

void CAESinkVisionOS::Deinitialize()
{
  std::lock_guard<std::mutex> lock(m_mutex);
  if (!m_impl->renderer)
    return;

  m_impl->sync.rate = 0.0f;
  [m_impl->renderer flush];
  [m_impl->sync removeRenderer:m_impl->renderer atTime:kCMTimeInvalid completionHandler:nil];
  m_impl->renderer = nil;
  m_impl->sync = nil;
  if (m_impl->fmtDesc)
  {
    CFRelease(m_impl->fmtDesc);
    m_impl->fmtDesc = nullptr;
  }
  m_started = false;
  m_ptsSamples = 0;
}

double CAESinkVisionOS::QueuedSeconds() const
{
  const double written = static_cast<double>(m_ptsSamples) / m_sampleRate;
  if (!m_started)
    return written;
  const double played = CMTimeGetSeconds([m_impl->sync currentTime]);
  return written - played;
}

void CAESinkVisionOS::StartClock()
{
  [m_impl->sync setRate:1.0f time:CMTimeMake(0, static_cast<int32_t>(m_sampleRate))];
  m_started = true;
}

void CAESinkVisionOS::StopAndFlush()
{
  m_impl->sync.rate = 0.0f;
  [m_impl->renderer flush];
  m_started = false;
  m_ptsSamples = 0;
}

unsigned int CAESinkVisionOS::AddPackets(uint8_t** data, unsigned int frames, unsigned int offset)
{
  std::unique_lock<std::mutex> lock(m_mutex);
  if (!m_impl->renderer || frames == 0)
    return frames;

  // Ran dry (pause, seek, stall): the clock has moved past our write position
  // and any further buffers would be stamped in the past and dropped.  Reset
  // and re-prime from here.
  if (m_started && QueuedSeconds() < 0.0)
  {
    CLog::Log(LOGDEBUG, "CAESinkVisionOS::AddPackets: renderer underran, restarting clock");
    StopAndFlush();
  }

  // Throttle: this call MUST block, and GetDelay is only accurate if the
  // queue is bounded.
  while (m_started && QueuedSeconds() > kMaxQueuedSeconds)
  {
    lock.unlock();
    std::this_thread::sleep_for(5ms);
    lock.lock();
    if (!m_impl->renderer)
      return frames;
  }

  const size_t bytes = static_cast<size_t>(frames) * m_frameSize;
  const uint8_t* src = data[0] + static_cast<size_t>(offset) * m_frameSize;

  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes,
                                                       kCFAllocatorDefault, nullptr, 0, bytes,
                                                       kCMBlockBufferAssureMemoryNowFlag, &block);
  if (status != noErr)
  {
    CLog::Log(LOGERROR, "CAESinkVisionOS::AddPackets: CMBlockBufferCreate failed {}",
              static_cast<int>(status));
    return frames;
  }
  CMBlockBufferReplaceDataBytes(src, block, 0, bytes);

  const CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, static_cast<int32_t>(m_sampleRate)),
      .presentationTimeStamp = CMTimeMake(m_ptsSamples, static_cast<int32_t>(m_sampleRate)),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  const size_t sampleSize = m_frameSize;
  CMSampleBufferRef sample = nullptr;
  status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, m_impl->fmtDesc, frames, 1,
                                     &timing, 1, &sampleSize, &sample);
  CFRelease(block);
  if (status != noErr)
  {
    CLog::Log(LOGERROR, "CAESinkVisionOS::AddPackets: CMSampleBufferCreateReady failed {}",
              static_cast<int>(status));
    return frames;
  }

  [m_impl->renderer enqueueSampleBuffer:sample];
  CFRelease(sample);
  m_ptsSamples += frames;

  if (!m_started && QueuedSeconds() >= kPrimeSeconds)
    StartClock();

  if (m_impl->renderer.status == AVQueuedSampleBufferRenderingStatusFailed)
    CLog::Log(LOGERROR, "CAESinkVisionOS::AddPackets: renderer failed: {}",
              [[m_impl->renderer.error localizedDescription] UTF8String]);

  return frames;
}

void CAESinkVisionOS::GetDelay(AEDelayStatus& status)
{
  std::lock_guard<std::mutex> lock(m_mutex);
  double delay = 0.0;
  if (m_impl->renderer)
  {
    delay = QueuedSeconds();
    if (delay < 0.0)
      delay = 0.0;
    delay += m_outputLatency;
  }
  status.SetDelay(delay);
}

double CAESinkVisionOS::GetCacheTotal()
{
  return kMaxQueuedSeconds;
}

void CAESinkVisionOS::Drain()
{
  {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_impl->renderer)
      return;
    if (!m_started && m_ptsSamples > 0)
      StartClock(); // play out whatever was primed
  }
  // Wait for the play head to reach the write position.
  const auto deadline = std::chrono::steady_clock::now() + 2s;
  while (std::chrono::steady_clock::now() < deadline)
  {
    {
      std::lock_guard<std::mutex> lock(m_mutex);
      if (!m_impl->renderer || !m_started || QueuedSeconds() <= 0.0)
        break;
    }
    std::this_thread::sleep_for(10ms);
  }
  std::lock_guard<std::mutex> lock(m_mutex);
  if (m_impl->renderer)
    StopAndFlush();
}
