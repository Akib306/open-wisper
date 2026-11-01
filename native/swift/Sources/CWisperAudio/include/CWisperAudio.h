#ifndef CWISPER_AUDIO_H
#define CWISPER_AUDIO_H

#include <CoreAudioTypes/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>

/// One producer (the audio tap), one consumer (the capture queue). Frames are
/// stored as interleaved Float32. The producer copies borrowed input before
/// returning; no framework buffer or pointer is retained.
typedef struct WisperAudioRing WisperAudioRing;

typedef enum WisperAudioRingError {
    WisperAudioRingErrorNone = 0,
    WisperAudioRingErrorOverflow = 1,
    WisperAudioRingErrorDurationLimit = 2,
    WisperAudioRingErrorInvalidBuffer = 3,
    WisperAudioRingErrorConcurrentProducer = 4,
    WisperAudioRingErrorDeviceChanged = 5,
    WisperAudioRingErrorInterrupted = 6
} WisperAudioRingError;

/// Allocation happens only here. Returns NULL if arguments/allocation or
/// lock-free atomics are unavailable. A capture uses a fresh ring, never reset.
WisperAudioRing *wisper_audio_ring_create(uint32_t capacity_frames,
                                         uint32_t channels,
                                         uint64_t maximum_frames);
/// The producer, consumer and any notification callbacks must have released
/// their ownership before destroy. close + producer_idle alone is not ownership.
void wisper_audio_ring_destroy(WisperAudioRing *ring);

/// Realtime safe: bounded copies and lock-free C11 atomics only. All or nothing;
/// overflow/malformed input closes the ring with a sticky error. A closed ring
/// accepts nothing. Both planar and interleaved Float32 ABLs are supported.
bool wisper_audio_ring_write(WisperAudioRing *ring,
                             const AudioBufferList *buffers,
                             uint32_t frames);
/// Consumer only. Copies at most capacity_frames into caller-owned storage.
uint32_t wisper_audio_ring_read(WisperAudioRing *ring,
                                float *destination,
                                uint32_t capacity_frames);

/// Prevents new writes, preserving an in-flight accepted write. The consumer
/// must wait for producer_idle before its final drain.
void wisper_audio_ring_close(WisperAudioRing *ring);
bool wisper_audio_ring_producer_idle(const WisperAudioRing *ring);
WisperAudioRingError wisper_audio_ring_error(const WisperAudioRing *ring);
/// An external interruption closes an open ring atomically. Notifications after
/// normal close cannot invalidate an already stopping session.
void wisper_audio_ring_abort(WisperAudioRing *ring, WisperAudioRingError error);

/// Test/reuse facility: call only with both producer and consumer quiescent,
/// after close, and with no callbacks able to use the old generation.
bool wisper_audio_ring_reset(WisperAudioRing *ring);

#endif
