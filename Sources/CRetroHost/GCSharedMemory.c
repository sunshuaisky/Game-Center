#include "GCSharedMemory.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define GC_FRAME_MAGIC 0x47434631u
#define GC_FRAME_VERSION 1u

size_t gc_shm_input_size(void) {
    return sizeof(GCSharedInputState);
}

size_t gc_shm_frame_ring_size(void) {
    return sizeof(GCSharedFrameRing) + (size_t)GC_FRAME_SLOTS * GC_FRAME_SLOT_BYTES;
}

uint8_t *gc_shm_frame_slot_ptr(GCSharedFrameRing *ring, uint32_t slot_index) {
    if (!ring || slot_index >= GC_FRAME_SLOTS) return NULL;
    uint8_t *base = (uint8_t *)ring + sizeof(GCSharedFrameRing);
    return base + (size_t)slot_index * GC_FRAME_SLOT_BYTES;
}

void gc_shm_input_write(
    GCSharedInputState *dst,
    const uint16_t *buttons,
    const int16_t *axes,
    int16_t pointer_x,
    int16_t pointer_y,
    uint8_t pointer_pressed,
    uint8_t mouse_buttons,
    int32_t mouse_dx_delta,
    int32_t mouse_dy_delta,
    int32_t mouse_wheel_delta,
    uint8_t fast_forward,
    uint8_t paused
) {
    if (!dst) return;
    _Atomic uint64_t *seq = (_Atomic uint64_t *)&dst->sequence;
    _Atomic int32_t *dx = (_Atomic int32_t *)&dst->mouse_dx_accum;
    _Atomic int32_t *dy = (_Atomic int32_t *)&dst->mouse_dy_accum;
    _Atomic int32_t *wh = (_Atomic int32_t *)&dst->mouse_wheel_y_accum;

    if (mouse_dx_delta != 0) atomic_fetch_add_explicit(dx, mouse_dx_delta, memory_order_relaxed);
    if (mouse_dy_delta != 0) atomic_fetch_add_explicit(dy, mouse_dy_delta, memory_order_relaxed);
    if (mouse_wheel_delta != 0) atomic_fetch_add_explicit(wh, mouse_wheel_delta, memory_order_relaxed);

    /* Odd sequence number signals writer-in-progress (seqlock). */
    uint64_t current = atomic_load_explicit(seq, memory_order_relaxed);
    uint64_t odd = (current & 1ULL) ? current : (current + 1ULL);
    atomic_store_explicit(seq, odd, memory_order_relaxed);
    /* Prevent payload writes from being reordered before seq becomes odd on ARM64. */
    atomic_thread_fence(memory_order_release);

    if (buttons) {
        memcpy(dst->buttons, buttons, sizeof(dst->buttons));
    }
    if (axes) {
        memcpy(dst->axes, axes, sizeof(dst->axes));
    }
    dst->pointer_x = pointer_x;
    dst->pointer_y = pointer_y;
    dst->pointer_pressed = pointer_pressed;
    dst->mouse_buttons = mouse_buttons;
    dst->fast_forward = fast_forward ? fast_forward : 1;
    dst->paused = paused;

    atomic_store_explicit(seq, odd + 1ULL, memory_order_release);
}

void gc_shm_input_read(
    GCSharedInputState *src,
    GCSharedInputState *out_snapshot,
    int32_t *out_mouse_dx,
    int32_t *out_mouse_dy,
    int32_t *out_mouse_wheel_y
) {
    if (!src || !out_snapshot) return;
    _Atomic uint64_t *seq = (_Atomic uint64_t *)&src->sequence;
    GCSharedInputState copy;
    for (int attempt = 0; attempt < 8; ++attempt) {
        uint64_t s1 = atomic_load_explicit(seq, memory_order_acquire);
        if (s1 & 1ULL) continue;
        memcpy(&copy, src, sizeof(copy));
        /* Prevent payload reads from being reordered after loading s2 on ARM64. */
        atomic_thread_fence(memory_order_acquire);
        uint64_t s2 = atomic_load_explicit(seq, memory_order_relaxed);
        if (s1 == s2) {
            *out_snapshot = copy;
            break;
        }
    }

    _Atomic int32_t *dx = (_Atomic int32_t *)&src->mouse_dx_accum;
    _Atomic int32_t *dy = (_Atomic int32_t *)&src->mouse_dy_accum;
    _Atomic int32_t *wh = (_Atomic int32_t *)&src->mouse_wheel_y_accum;
    int32_t rdx = atomic_exchange_explicit(dx, 0, memory_order_acq_rel);
    int32_t rdy = atomic_exchange_explicit(dy, 0, memory_order_acq_rel);
    int32_t rwh = atomic_exchange_explicit(wh, 0, memory_order_acq_rel);
    if (out_mouse_dx) *out_mouse_dx = rdx;
    if (out_mouse_dy) *out_mouse_dy = rdy;
    if (out_mouse_wheel_y) *out_mouse_wheel_y = rwh;
}

void gc_shm_frame_init(GCSharedFrameRing *ring) {
    if (!ring) return;
    memset(ring, 0, sizeof(GCSharedFrameRing));
    ring->magic = GC_FRAME_MAGIC;
    ring->version = GC_FRAME_VERSION;
    ring->slot_count = GC_FRAME_SLOTS;
    _Atomic uint32_t *active = (_Atomic uint32_t *)&ring->active_slot;
    _Atomic uint64_t *seq = (_Atomic uint64_t *)&ring->frame_sequence;
    atomic_store_explicit(active, 0, memory_order_release);
    atomic_store_explicit(seq, 0, memory_order_release);
}

uint32_t gc_shm_frame_next_write_slot(const GCSharedFrameRing *ring) {
    if (!ring) return 0;
    const _Atomic uint32_t *active = (const _Atomic uint32_t *)&ring->active_slot;
    uint32_t cur = atomic_load_explicit(active, memory_order_acquire);
    return (cur + 1u) % GC_FRAME_SLOTS;
}

void gc_shm_frame_commit(
    GCSharedFrameRing *ring,
    uint32_t slot_index,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row,
    float aspect_ratio
) {
    if (!ring || slot_index >= GC_FRAME_SLOTS) return;
    _Atomic uint64_t *seq = (_Atomic uint64_t *)&ring->frame_sequence;
    _Atomic uint32_t *active = (_Atomic uint32_t *)&ring->active_slot;

    uint64_t next_seq = atomic_load_explicit(seq, memory_order_relaxed) + 1ULL;
    ring->slots[slot_index].width = width;
    ring->slots[slot_index].height = height;
    ring->slots[slot_index].bytes_per_row = bytes_per_row;
    ring->slots[slot_index].aspect_ratio = aspect_ratio;
    ring->slots[slot_index].frame_number = next_seq;

    atomic_store_explicit(active, slot_index, memory_order_release);
    atomic_store_explicit(seq, next_seq, memory_order_release);
}

bool gc_shm_frame_latest(
    const GCSharedFrameRing *ring,
    uint64_t last_seen_sequence,
    uint32_t *out_slot_index,
    uint32_t *out_width,
    uint32_t *out_height,
    uint32_t *out_bytes_per_row,
    float *out_aspect_ratio,
    uint64_t *out_sequence
) {
    if (!ring || ring->magic != GC_FRAME_MAGIC) return false;
    const _Atomic uint64_t *seq = (const _Atomic uint64_t *)&ring->frame_sequence;
    const _Atomic uint32_t *active = (const _Atomic uint32_t *)&ring->active_slot;

    for (int attempt = 0; attempt < 3; ++attempt) {
        uint64_t current_seq = atomic_load_explicit(seq, memory_order_acquire);
        if (current_seq == 0 || current_seq == last_seen_sequence) return false;

        uint32_t slot = atomic_load_explicit(active, memory_order_acquire);
        if (slot >= GC_FRAME_SLOTS) return false;

        GCSharedFrameSlotMeta meta = ring->slots[slot];
        if (meta.width == 0 || meta.height == 0) return false;
        if (meta.frame_number != current_seq) continue;

        if (out_slot_index) *out_slot_index = slot;
        if (out_width) *out_width = meta.width;
        if (out_height) *out_height = meta.height;
        if (out_bytes_per_row) *out_bytes_per_row = meta.bytes_per_row;
        if (out_aspect_ratio) *out_aspect_ratio = meta.aspect_ratio;
        if (out_sequence) *out_sequence = current_seq;
        return true;
    }
    return false;
}

struct GCAudioRing {
    uint32_t mask;
    uint32_t capacity;
    _Atomic uint32_t read_pos;
    _Atomic uint32_t write_pos;
    _Atomic bool muted;
    int16_t *samples;
};

GCAudioRing *gc_audio_ring_create(uint32_t capacity_frames_pow2) {
    uint32_t cap = 1024u;
    while (cap < capacity_frames_pow2 && cap < (1u << 20)) cap <<= 1u;
    GCAudioRing *ring = calloc(1, sizeof(GCAudioRing));
    if (!ring) return NULL;
    ring->samples = calloc((size_t)cap * 2u, sizeof(int16_t));
    if (!ring->samples) {
        free(ring);
        return NULL;
    }
    ring->capacity = cap;
    ring->mask = cap - 1u;
    atomic_init(&ring->read_pos, 0u);
    atomic_init(&ring->write_pos, 0u);
    atomic_init(&ring->muted, false);
    return ring;
}

void gc_audio_ring_destroy(GCAudioRing *ring) {
    if (!ring) return;
    free(ring->samples);
    free(ring);
}

void gc_audio_ring_clear(GCAudioRing *ring) {
    if (!ring) return;
    uint32_t w = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    atomic_store_explicit(&ring->read_pos, w, memory_order_release);
}

uint32_t gc_audio_ring_available(const GCAudioRing *ring) {
    if (!ring) return 0u;
    uint32_t w = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&ring->read_pos, memory_order_acquire);
    return w - r;
}

uint32_t gc_audio_ring_write(GCAudioRing *ring, const int16_t *samples, uint32_t frame_count) {
    if (!ring || !samples || frame_count == 0u) return 0u;
    uint32_t w = atomic_load_explicit(&ring->write_pos, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&ring->read_pos, memory_order_acquire);
    uint32_t free_frames = ring->capacity - (w - r);
    uint32_t to_write = frame_count < free_frames ? frame_count : free_frames;
    if (to_write == 0u) return 0u;

    uint32_t idx = w & ring->mask;
    uint32_t first = ring->capacity - idx;
    if (first > to_write) first = to_write;
    memcpy(ring->samples + (size_t)idx * 2u, samples, (size_t)first * 4u);
    uint32_t rem = to_write - first;
    if (rem > 0u) {
        memcpy(ring->samples, samples + (size_t)first * 2u, (size_t)rem * 4u);
    }
    atomic_store_explicit(&ring->write_pos, w + to_write, memory_order_release);
    return to_write;
}

uint32_t gc_audio_ring_read(GCAudioRing *ring, int16_t *out_samples, uint32_t frame_count) {
    if (!ring || !out_samples || frame_count == 0u) return 0u;
    uint32_t r = atomic_load_explicit(&ring->read_pos, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&ring->write_pos, memory_order_acquire);
    uint32_t avail = w - r;
    uint32_t to_read = frame_count < avail ? frame_count : avail;
    if (to_read == 0u) return 0u;

    if (atomic_load_explicit(&ring->muted, memory_order_relaxed)) {
        memset(out_samples, 0, (size_t)to_read * 4u);
    } else {
        uint32_t idx = r & ring->mask;
        uint32_t first = ring->capacity - idx;
        if (first > to_read) first = to_read;
        memcpy(out_samples, ring->samples + (size_t)idx * 2u, (size_t)first * 4u);
        uint32_t rem = to_read - first;
        if (rem > 0u) {
            memcpy(out_samples + (size_t)first * 2u, ring->samples, (size_t)rem * 4u);
        }
    }
    atomic_store_explicit(&ring->read_pos, r + to_read, memory_order_release);
    return to_read;
}

void gc_audio_ring_set_muted(GCAudioRing *ring, bool muted) {
    if (!ring) return;
    atomic_store_explicit(&ring->muted, muted, memory_order_relaxed);
}

bool gc_audio_ring_is_muted(const GCAudioRing *ring) {
    return ring ? atomic_load_explicit(&ring->muted, memory_order_relaxed) : false;
}
