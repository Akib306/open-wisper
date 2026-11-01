#include "CWisperAudio.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RING_CLOSED (UINT32_C(1) << 31)
#define RING_WRITING (UINT32_C(1) << 30)
#define RING_ERROR_MASK UINT32_C(255)

struct WisperAudioRing {
    _Atomic uint64_t read_position;
    _Atomic uint64_t write_position;
    // Closed, in-flight writer and first failure share one atomic, so a normal
    // Stop and a device notification have one unambiguous ordering.
    _Atomic uint32_t state;
    uint32_t capacity;
    uint32_t channels;
    uint64_t maximum_frames;
    float *samples;
};

static void fail_writer(WisperAudioRing *ring, WisperAudioRingError error) {
    uint32_t old = atomic_load_explicit(&ring->state, memory_order_relaxed);
    for (;;) {
        uint32_t next = old | RING_CLOSED;
        if ((old & RING_ERROR_MASK) == 0) next |= (uint32_t)error;
        if (atomic_compare_exchange_weak_explicit(&ring->state, &old, next,
                                                  memory_order_release,
                                                  memory_order_relaxed)) return;
    }
}

WisperAudioRing *wisper_audio_ring_create(uint32_t capacity_frames,
                                         uint32_t channels,
                                         uint64_t maximum_frames) {
    if (capacity_frames == 0 || channels == 0 || channels > 32 ||
        maximum_frames == 0 ||
        (uint64_t)capacity_frames * channels > SIZE_MAX / sizeof(float)) return NULL;
    WisperAudioRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    atomic_init(&ring->read_position, 0);
    atomic_init(&ring->write_position, 0);
    atomic_init(&ring->state, 0);
    if (!atomic_is_lock_free(&ring->read_position) ||
        !atomic_is_lock_free(&ring->write_position) ||
        !atomic_is_lock_free(&ring->state)) {
        free(ring);
        return NULL;
    }
    ring->samples = calloc((size_t)capacity_frames * channels, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity_frames;
    ring->channels = channels;
    ring->maximum_frames = maximum_frames;
    return ring;
}

void wisper_audio_ring_destroy(WisperAudioRing *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring);
}

bool wisper_audio_ring_write(WisperAudioRing *ring,
                             const AudioBufferList *buffers,
                             uint32_t frames) {
    if (!ring) return false;
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&ring->state, &expected, RING_WRITING,
                                                 memory_order_acquire,
                                                 memory_order_relaxed)) {
        if (!(expected & RING_CLOSED))
            fail_writer(ring, WisperAudioRingErrorConcurrentProducer);
        return false;
    }

    bool accepted = false;
    if (frames == 0) { accepted = true; goto done; }
    uint64_t write = atomic_load_explicit(&ring->write_position, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read_position, memory_order_acquire);
    if (frames > ring->maximum_frames - write) {
        fail_writer(ring, WisperAudioRingErrorDurationLimit);
        goto done;
    }
    if (frames > ring->capacity || write - read > ring->capacity - frames) {
        fail_writer(ring, WisperAudioRingErrorOverflow);
        goto done;
    }
    if (!buffers || (buffers->mNumberBuffers != 1 &&
                     buffers->mNumberBuffers != ring->channels)) {
        fail_writer(ring, WisperAudioRingErrorInvalidBuffer);
        goto done;
    }
    bool interleaved = buffers->mNumberBuffers == 1;
    for (uint32_t c = 0; c < buffers->mNumberBuffers; ++c) {
        const AudioBuffer *buffer = &buffers->mBuffers[c];
        uint32_t stride = interleaved ? ring->channels : 1;
        if (!buffer->mData || buffer->mNumberChannels != stride ||
            (uint64_t)frames * stride * sizeof(float) > buffer->mDataByteSize) {
            fail_writer(ring, WisperAudioRingErrorInvalidBuffer);
            goto done;
        }
    }
    uint32_t offset = (uint32_t)(write % ring->capacity);
    uint32_t first = frames < ring->capacity - offset ? frames : ring->capacity - offset;
    if (interleaved) {
        const float *source = buffers->mBuffers[0].mData;
        memcpy(ring->samples + (size_t)offset * ring->channels, source,
               (size_t)first * ring->channels * sizeof(float));
        memcpy(ring->samples, source + (size_t)first * ring->channels,
               (size_t)(frames - first) * ring->channels * sizeof(float));
    } else {
        for (uint32_t c = 0; c < ring->channels; ++c) {
            const float *source = buffers->mBuffers[c].mData;
            for (uint32_t f = 0; f < first; ++f)
                ring->samples[(size_t)(offset + f) * ring->channels + c] = source[f];
            for (uint32_t f = first; f < frames; ++f)
                ring->samples[(size_t)(f - first) * ring->channels + c] = source[f];
        }
    }
    atomic_store_explicit(&ring->write_position, write + frames, memory_order_release);
    accepted = true;
done:
    atomic_fetch_and_explicit(&ring->state, ~RING_WRITING, memory_order_release);
    return accepted;
}

uint32_t wisper_audio_ring_read(WisperAudioRing *ring, float *destination,
                                uint32_t capacity_frames) {
    if (!ring || !destination || capacity_frames == 0) return 0;
    uint64_t read = atomic_load_explicit(&ring->read_position, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->write_position, memory_order_acquire);
    uint32_t frames = (uint32_t)(write - read);
    if (frames > capacity_frames) frames = capacity_frames;
    uint32_t offset = (uint32_t)(read % ring->capacity);
    uint32_t first = frames < ring->capacity - offset ? frames : ring->capacity - offset;
    memcpy(destination, ring->samples + (size_t)offset * ring->channels,
           (size_t)first * ring->channels * sizeof(float));
    memcpy(destination + (size_t)first * ring->channels, ring->samples,
           (size_t)(frames - first) * ring->channels * sizeof(float));
    atomic_store_explicit(&ring->read_position, read + frames, memory_order_release);
    return frames;
}

void wisper_audio_ring_close(WisperAudioRing *ring) {
    atomic_fetch_or_explicit(&ring->state, RING_CLOSED, memory_order_acq_rel);
}

bool wisper_audio_ring_producer_idle(const WisperAudioRing *ring) {
    return !(atomic_load_explicit(&ring->state, memory_order_acquire) & RING_WRITING);
}

WisperAudioRingError wisper_audio_ring_error(const WisperAudioRing *ring) {
    return (WisperAudioRingError)(atomic_load_explicit(&ring->state, memory_order_acquire)
                                 & RING_ERROR_MASK);
}

void wisper_audio_ring_abort(WisperAudioRing *ring, WisperAudioRingError error) {
    if (error == WisperAudioRingErrorNone || ((uint32_t)error & ~RING_ERROR_MASK)) return;
    uint32_t old = atomic_load_explicit(&ring->state, memory_order_relaxed);
    while (!(old & RING_CLOSED)) {
        uint32_t next = old | RING_CLOSED | (uint32_t)error;
        if (atomic_compare_exchange_weak_explicit(&ring->state, &old, next,
                                                  memory_order_release,
                                                  memory_order_relaxed)) return;
    }
}

bool wisper_audio_ring_reset(WisperAudioRing *ring) {
    uint32_t state = atomic_load_explicit(&ring->state, memory_order_acquire);
    if (!(state & RING_CLOSED) || (state & RING_WRITING)) return false;
    atomic_store_explicit(&ring->read_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->write_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->state, 0, memory_order_release);
    return true;
}
