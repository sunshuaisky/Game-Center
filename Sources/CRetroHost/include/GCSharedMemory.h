#ifndef GC_SHARED_MEMORY_H
#define GC_SHARED_MEMORY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GC_MAX_PLAYERS 4
#define GC_FRAME_SLOTS 3
#define GC_FRAME_MAX_WIDTH 2560
#define GC_FRAME_MAX_HEIGHT 1600
#define GC_FRAME_SLOT_BYTES ((size_t)GC_FRAME_MAX_WIDTH * (size_t)GC_FRAME_MAX_HEIGHT * 4u)

/* Lock-free input snapshot written by main app and read by helper each frame. */
typedef struct GCSharedInputState {
    uint64_t sequence;
    uint16_t buttons[GC_MAX_PLAYERS];     /* Libretro joypad 16-bit bitmask */
    int16_t axes[GC_MAX_PLAYERS][4];      /* LX, LY, RX, RY (-32768..32767) */
    int16_t pointer_x;                    /* Normalized [-32767, 32767] */
    int16_t pointer_y;                    /* Normalized [-32767, 32767] */
    uint8_t pointer_pressed;              /* 0 or 1 */
    uint8_t mouse_buttons;                /* bit0=L, bit1=R, bit2=M */
    int32_t mouse_dx_accum;               /* Accumulated relative mouse delta X */
    int32_t mouse_dy_accum;               /* Accumulated relative mouse delta Y */
    int32_t mouse_wheel_y_accum;          /* Accumulated vertical wheel steps */
    uint8_t fast_forward;                 /* 1=normal, 2=2x, 3=3x */
    uint8_t paused;                       /* 0=running, 1=paused */
    uint8_t reserved[6];
} GCSharedInputState;

typedef struct GCSharedFrameSlotMeta {
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    float aspect_ratio;
    uint64_t frame_number;
} GCSharedFrameSlotMeta;

typedef struct GCSharedFrameRing {
    uint32_t magic;                       /* 'GCF1' = 0x47434631 */
    uint32_t version;                     /* 1 */
    uint32_t slot_count;                  /* GC_FRAME_SLOTS */
    uint32_t active_slot;                 /* Most recently committed slot index */
    uint64_t frame_sequence;              /* Monotonically incremented on commit */
    GCSharedFrameSlotMeta slots[GC_FRAME_SLOTS];
    uint8_t reserved[64];
    /* Followed immediately by GC_FRAME_SLOTS * GC_FRAME_SLOT_BYTES of BGRA8 pixels */
} GCSharedFrameRing;

size_t gc_shm_input_size(void);
size_t gc_shm_frame_ring_size(void);
uint8_t *gc_shm_frame_slot_ptr(GCSharedFrameRing *ring, uint32_t slot_index);

/* C11 atomic helpers usable cleanly from Swift on macOS 14+ */
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
);

void gc_shm_input_read(
    GCSharedInputState *src,
    GCSharedInputState *out_snapshot,
    int32_t *out_mouse_dx,
    int32_t *out_mouse_dy,
    int32_t *out_mouse_wheel_y
);

void gc_shm_frame_init(GCSharedFrameRing *ring);
uint32_t gc_shm_frame_next_write_slot(const GCSharedFrameRing *ring);
void gc_shm_frame_commit(
    GCSharedFrameRing *ring,
    uint32_t slot_index,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row,
    float aspect_ratio
);
bool gc_shm_frame_latest(
    const GCSharedFrameRing *ring,
    uint64_t last_seen_sequence,
    uint32_t *out_slot_index,
    uint32_t *out_width,
    uint32_t *out_height,
    uint32_t *out_bytes_per_row,
    float *out_aspect_ratio,
    uint64_t *out_sequence
);

#ifdef __cplusplus
}
#endif

#endif
