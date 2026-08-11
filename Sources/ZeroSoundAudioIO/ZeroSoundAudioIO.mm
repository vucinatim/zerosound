#include "ZeroSoundAudioIO.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/HostTime.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint32_t kChannelCount = 2;
constexpr uint32_t kRingCapacityFrames = 1U << 18;
constexpr uint32_t kRingMask = kRingCapacityFrames - 1;

AudioObjectPropertyAddress PropertyAddress(
  AudioObjectPropertySelector selector,
  AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
  AudioObjectPropertyElement element = kAudioObjectPropertyElementMain
) {
  return {selector, scope, element};
}

std::string StatusMessage(const char *operation, OSStatus status) {
  char code[5] = {};
  const uint32_t raw = CFSwapInt32HostToBig(static_cast<uint32_t>(status));
  std::memcpy(code, &raw, 4);
  const bool printable = std::all_of(code, code + 4, [](char character) {
    return character >= 32 && character <= 126;
  });

  if (printable) {
    return std::string(operation) + " failed ('" + std::string(code, 4) + "')";
  }
  return std::string(operation) + " failed (OSStatus " + std::to_string(status) + ")";
}

void CopyError(const std::string &message, char *destination, size_t capacity) {
  if (destination == nullptr || capacity == 0) {
    return;
  }
  const size_t count = std::min(message.size(), capacity - 1);
  std::memcpy(destination, message.data(), count);
  destination[count] = '\0';
}

}  // namespace

struct ZSAudioCapture {
  AudioObjectID tapID = kAudioObjectUnknown;
  AudioObjectID aggregateDeviceID = kAudioObjectUnknown;
  AudioDeviceIOProcID ioProcID = nullptr;
  AudioStreamBasicDescription format = {};

  std::vector<float> samples = std::vector<float>(kRingCapacityFrames * kChannelCount, 0.0F);
  std::vector<uint64_t> hostTimes = std::vector<uint64_t>(kRingCapacityFrames, 0);
  std::atomic<uint64_t> writeFrame{0};
  std::atomic<uint64_t> readFrame{0};
  std::atomic<uint64_t> droppedFrames{0};
  std::atomic<bool> running{false};

  void resetRing() {
    writeFrame.store(0, std::memory_order_relaxed);
    readFrame.store(0, std::memory_order_relaxed);
    droppedFrames.store(0, std::memory_order_relaxed);
  }

  void write(const AudioBufferList *input, const AudioTimeStamp *inputTime) noexcept {
    if (input == nullptr || input->mNumberBuffers == 0 || format.mSampleRate <= 0) {
      return;
    }

    const bool nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    uint32_t frameCount = UINT32_MAX;
    for (uint32_t bufferIndex = 0; bufferIndex < input->mNumberBuffers; ++bufferIndex) {
      const AudioBuffer &buffer = input->mBuffers[bufferIndex];
      if (buffer.mData == nullptr || buffer.mNumberChannels == 0) {
        return;
      }
      const uint32_t bytesPerFrame = nonInterleaved
        ? sizeof(float)
        : sizeof(float) * buffer.mNumberChannels;
      frameCount = std::min(frameCount, buffer.mDataByteSize / bytesPerFrame);
    }

    if (frameCount == 0 || frameCount == UINT32_MAX) {
      return;
    }

    const uint64_t write = writeFrame.load(std::memory_order_relaxed);
    const uint64_t read = readFrame.load(std::memory_order_acquire);
    if (write + frameCount - read > kRingCapacityFrames) {
      droppedFrames.fetch_add(frameCount, std::memory_order_relaxed);
      return;
    }

    const uint64_t firstHostTime =
      inputTime != nullptr && (inputTime->mFlags & kAudioTimeStampHostTimeValid) != 0
      ? inputTime->mHostTime
      : AudioGetCurrentHostTime();
    const double ticksPerFrame = AudioGetHostClockFrequency() / format.mSampleRate;

    for (uint32_t frame = 0; frame < frameCount; ++frame) {
      float left = 0.0F;
      float right = 0.0F;

      if (nonInterleaved && input->mNumberBuffers >= 2) {
        left = static_cast<const float *>(input->mBuffers[0].mData)[frame];
        right = static_cast<const float *>(input->mBuffers[1].mData)[frame];
      } else {
        const AudioBuffer &buffer = input->mBuffers[0];
        const float *source = static_cast<const float *>(buffer.mData);
        left = source[frame * buffer.mNumberChannels];
        right = buffer.mNumberChannels > 1
          ? source[frame * buffer.mNumberChannels + 1]
          : left;
      }

      const uint32_t destinationFrame = static_cast<uint32_t>(write + frame) & kRingMask;
      samples[destinationFrame * kChannelCount] = left;
      samples[destinationFrame * kChannelCount + 1] = right;
      hostTimes[destinationFrame] = firstHostTime + static_cast<uint64_t>(std::llround(frame * ticksPerFrame));
    }

    writeFrame.store(write + frameCount, std::memory_order_release);
  }
};

namespace {

OSStatus CaptureIOProc(
  AudioObjectID,
  const AudioTimeStamp *,
  const AudioBufferList *inputData,
  const AudioTimeStamp *inputTime,
  AudioBufferList *,
  const AudioTimeStamp *,
  void *clientData
) noexcept {
  auto *capture = static_cast<ZSAudioCapture *>(clientData);
  if (capture != nullptr && capture->running.load(std::memory_order_relaxed)) {
    capture->write(inputData, inputTime);
  }
  return noErr;
}

AudioObjectID CurrentProcessAudioObject() {
  pid_t processID = getpid();
  AudioObjectID processObject = kAudioObjectUnknown;
  uint32_t size = sizeof(processObject);
  auto address = PropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject);
  AudioObjectGetPropertyData(
    kAudioObjectSystemObject,
    &address,
    sizeof(processID),
    &processID,
    &size,
    &processObject
  );
  return processObject;
}

bool ReadTapFormat(AudioObjectID tapID, AudioStreamBasicDescription &format, std::string &error) {
  auto address = PropertyAddress(kAudioTapPropertyFormat);
  uint32_t size = sizeof(format);
  const OSStatus status = AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &format);
  if (status != noErr) {
    error = StatusMessage("Reading tap format", status);
    return false;
  }

  const bool isFloatPCM = format.mFormatID == kAudioFormatLinearPCM
    && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    && format.mBitsPerChannel == 32;
  if (!isFloatPCM || format.mChannelsPerFrame < 1) {
    error = "The system audio tap returned an unsupported audio format";
    return false;
  }
  return true;
}

bool ReadTapUID(AudioObjectID tapID, CFStringRef &uid, std::string &error) {
  auto address = PropertyAddress(kAudioTapPropertyUID);
  uint32_t size = sizeof(uid);
  const OSStatus status = AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &uid);
  if (status != noErr || uid == nullptr) {
    error = StatusMessage("Reading tap identifier", status);
    return false;
  }
  return true;
}

bool WaitForInputStream(AudioObjectID deviceID, std::string &error) {
  auto address = PropertyAddress(
    kAudioDevicePropertyStreams,
    kAudioDevicePropertyScopeInput
  );
  for (int attempt = 0; attempt < 100; ++attempt) {
    uint32_t size = 0;
    const OSStatus status = AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nullptr,
      &size
    );
    if (status == noErr && size >= sizeof(AudioObjectID)) {
      return true;
    }
    usleep(10'000);
  }
  error = "The system audio tap did not become ready in time";
  return false;
}

}  // namespace

ZSAudioCapture *ZSAudioCaptureCreate(void) {
  return new ZSAudioCapture();
}

void ZSAudioCaptureDestroy(ZSAudioCapture *capture) {
  if (capture == nullptr) {
    return;
  }
  ZSAudioCaptureStop(capture);
  delete capture;
}

bool ZSAudioCaptureStart(
  ZSAudioCapture *capture,
  char *errorMessage,
  size_t errorMessageCapacity
) {
  if (capture == nullptr) {
    CopyError("Invalid capture instance", errorMessage, errorMessageCapacity);
    return false;
  }
  if (capture->running.load(std::memory_order_relaxed)) {
    return true;
  }

  std::string error;
  @autoreleasepool {
    NSMutableArray<NSNumber *> *excludedProcesses = [NSMutableArray array];
    const AudioObjectID processObject = CurrentProcessAudioObject();
    if (processObject != kAudioObjectUnknown) {
      [excludedProcesses addObject:@(processObject)];
    }

    CATapDescription *description =
      [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excludedProcesses];
    description.name = @"ZeroSound System Audio";
    description.privateTap = YES;
    description.muteBehavior = CATapMutedWhenTapped;

    OSStatus status = AudioHardwareCreateProcessTap(description, &capture->tapID);
    if (status != noErr) {
      error = StatusMessage("Creating system audio tap", status);
    }

    if (error.empty() && !ReadTapFormat(capture->tapID, capture->format, error)) {
      // The helper populates the error.
    }

    CFStringRef tapUID = nullptr;
    if (error.empty() && !ReadTapUID(capture->tapID, tapUID, error)) {
      // The helper populates the error.
    }

    if (error.empty()) {
      NSDictionary *aggregateDescription = @{
        @kAudioAggregateDeviceNameKey: @"ZeroSound Capture",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
      };
      status = AudioHardwareCreateAggregateDevice(
        (__bridge CFDictionaryRef)aggregateDescription,
        &capture->aggregateDeviceID
      );
      if (status != noErr) {
        error = StatusMessage("Creating capture device", status);
      }
    }

    if (error.empty()) {
      CFArrayRef tapList = CFArrayCreate(
        kCFAllocatorDefault,
        reinterpret_cast<const void **>(&tapUID),
        1,
        &kCFTypeArrayCallBacks
      );
      auto address = PropertyAddress(kAudioAggregateDevicePropertyTapList);
      const uint32_t size = sizeof(tapList);
      status = AudioObjectSetPropertyData(
        capture->aggregateDeviceID,
        &address,
        0,
        nullptr,
        size,
        &tapList
      );
      CFRelease(tapList);
      if (status != noErr) {
        error = StatusMessage("Attaching system audio tap", status);
      }
    }

    if (tapUID != nullptr) {
      CFRelease(tapUID);
    }

    if (error.empty() && !WaitForInputStream(capture->aggregateDeviceID, error)) {
      // The helper populates the error.
    }

    if (error.empty()) {
      status = AudioDeviceCreateIOProcID(
        capture->aggregateDeviceID,
        CaptureIOProc,
        capture,
        &capture->ioProcID
      );
      if (status != noErr) {
        error = StatusMessage("Creating capture callback", status);
      }
    }

    if (error.empty()) {
      capture->resetRing();
      capture->running.store(true, std::memory_order_release);
      status = AudioDeviceStart(capture->aggregateDeviceID, capture->ioProcID);
      if (status != noErr) {
        capture->running.store(false, std::memory_order_release);
        error = status == kAudioHardwareIllegalOperationError
          ? "Allow system-audio recording in the macOS prompt, then click Stream again"
          : StatusMessage("Starting system audio capture", status);
      }
    }
  }

  if (!error.empty()) {
    CopyError(error, errorMessage, errorMessageCapacity);
    ZSAudioCaptureStop(capture);
    return false;
  }
  return true;
}

void ZSAudioCaptureStop(ZSAudioCapture *capture) {
  if (capture == nullptr) {
    return;
  }

  capture->running.store(false, std::memory_order_release);
  if (capture->aggregateDeviceID != kAudioObjectUnknown && capture->ioProcID != nullptr) {
    AudioDeviceStop(capture->aggregateDeviceID, capture->ioProcID);
    AudioDeviceDestroyIOProcID(capture->aggregateDeviceID, capture->ioProcID);
    capture->ioProcID = nullptr;
  }
  if (capture->aggregateDeviceID != kAudioObjectUnknown) {
    AudioHardwareDestroyAggregateDevice(capture->aggregateDeviceID);
    capture->aggregateDeviceID = kAudioObjectUnknown;
  }
  if (capture->tapID != kAudioObjectUnknown) {
    AudioHardwareDestroyProcessTap(capture->tapID);
    capture->tapID = kAudioObjectUnknown;
  }
}

double ZSAudioCaptureGetSampleRate(const ZSAudioCapture *capture) {
  return capture == nullptr ? 0 : capture->format.mSampleRate;
}

uint64_t ZSAudioCaptureGetDroppedFrameCount(const ZSAudioCapture *capture) {
  return capture == nullptr ? 0 : capture->droppedFrames.load(std::memory_order_relaxed);
}

ZSCapturedChunk ZSAudioCaptureRead(
  ZSAudioCapture *capture,
  float *destination,
  uint32_t maximumFrames
) {
  ZSCapturedChunk result = {};
  if (capture == nullptr || destination == nullptr || maximumFrames == 0) {
    return result;
  }

  const uint64_t read = capture->readFrame.load(std::memory_order_relaxed);
  const uint64_t write = capture->writeFrame.load(std::memory_order_acquire);
  const uint64_t availableFrames = write - read;
  if (availableFrames < maximumFrames) {
    return result;
  }
  const uint32_t available = maximumFrames;

  result.frameCount = available;
  result.firstHostTime = capture->hostTimes[static_cast<uint32_t>(read) & kRingMask];
  for (uint32_t frame = 0; frame < available; ++frame) {
    const uint32_t sourceFrame = static_cast<uint32_t>(read + frame) & kRingMask;
    destination[frame * kChannelCount] = capture->samples[sourceFrame * kChannelCount];
    destination[frame * kChannelCount + 1] = capture->samples[sourceFrame * kChannelCount + 1];
  }
  capture->readFrame.store(read + available, std::memory_order_release);
  return result;
}
