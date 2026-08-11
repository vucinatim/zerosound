#ifndef ZeroSoundAudioIO_h
#define ZeroSoundAudioIO_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZSAudioCapture ZSAudioCapture;

typedef struct {
  uint32_t frameCount;
  uint64_t firstHostTime;
} ZSCapturedChunk;

ZSAudioCapture *ZSAudioCaptureCreate(void);
void ZSAudioCaptureDestroy(ZSAudioCapture *capture);

bool ZSAudioCaptureStart(
  ZSAudioCapture *capture,
  char *errorMessage,
  size_t errorMessageCapacity
);

void ZSAudioCaptureStop(ZSAudioCapture *capture);

double ZSAudioCaptureGetSampleRate(const ZSAudioCapture *capture);
uint64_t ZSAudioCaptureGetDroppedFrameCount(const ZSAudioCapture *capture);

ZSCapturedChunk ZSAudioCaptureRead(
  ZSAudioCapture *capture,
  float *interleavedStereoDestination,
  uint32_t maximumFrames
);

#ifdef __cplusplus
}
#endif

#endif
