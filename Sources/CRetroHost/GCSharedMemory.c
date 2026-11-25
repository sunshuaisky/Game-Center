#include "GCSharedMemory.h"
#include <stdatomic.h>
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
    atomic_store_explicit(seq, odd, memory_order_release);

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
        uint64_t s2 = atomic_load_explicit(seq, memory_order_acquire);
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

    uint64_t current_seq = atomic_load_explicit(seq, memory_order_acquire);
    if (current_seq == 0 || current_seq == last_seen_sequence) return false;

    uint32_t slot = atomic_load_explicit(active, memory_order_acquire);
    if (slot >= GC_FRAME_SLOTS) return false;

    GCSharedFrameSlotMeta meta = ring->slots[slot];
    if (meta.width == 0 || meta.height == 0) return false;

    if (out_slot_index) *out_slot_index = slot;
    if (out_width) *out_width = meta.width;
    if (out_height) *out_height = meta.height;
    if (out_bytes_per_row) *out_bytes_per_row = meta.bytes_per_row;
    if (out_aspect_ratio) *out_aspect_ratio = meta.aspect_ratio;
    if (out_sequence) *out_sequence = current_seq;
    return true;
}
