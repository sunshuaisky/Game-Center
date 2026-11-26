#ifndef GC_RETRO_HOST_H
#define GC_RETRO_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "GCSharedMemory.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GCRetroHost GCRetroHost;

typedef uint32_t *(*gc_acquire_frame_fn)(
    void *ctx,
    uint32_t width,
    uint32_t height,
    uint32_t *out_bytes_per_row,
    uint32_t *out_slot_index
);

typedef void (*gc_commit_frame_fn)(
    void *ctx,
    uint32_t slot_index,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row,
    float aspect_ratio
);

typedef void (*gc_audio_batch_fn)(
    void *ctx,
    const int16_t *samples,
    size_t frame_count
);

typedef struct GCRetroHostCallbacks {
    void *context;
    gc_acquire_frame_fn acquire_frame;
    gc_commit_frame_fn commit_frame;
    gc_audio_batch_fn audio_batch;
} GCRetroHostCallbacks;

typedef struct GCRetroOptionChoice {
    const char *value;
    const char *label;
} GCRetroOptionChoice;

typedef struct GCRetroOptionInfo {
    const char *key;
    const char *description;
    const char *current_value;
    const char *default_value;
    size_t choice_count;
} GCRetroOptionInfo;

const char *gc_host_last_error(void);

GCRetroHost *gc_host_open(
    const char *core_path,
    const char *rom_path,
    const char *system_dir,
    const char *save_dir,
    const char *battery_path,
    const char *moltenvk_path,
    const char *const *initial_option_keys,
    const char *const *initial_option_values,
    size_t initial_option_count,
    GCRetroHostCallbacks callbacks
);

void gc_host_close(GCRetroHost *host);

void gc_host_run_frame(
    GCRetroHost *host,
    const GCSharedInputState *input,
    int32_t mouse_dx,
    int32_t mouse_dy,
    int32_t mouse_wheel_y
);

void gc_host_reset(GCRetroHost *host);

double gc_host_fps(const GCRetroHost *host);
double gc_host_sample_rate(const GCRetroHost *host);
float gc_host_aspect_ratio(const GCRetroHost *host);
uint32_t gc_host_base_width(const GCRetroHost *host);
uint32_t gc_host_base_height(const GCRetroHost *host);
bool gc_host_is_vulkan(const GCRetroHost *host);

bool gc_host_save_battery(GCRetroHost *host, bool force);
bool gc_host_save_state(GCRetroHost *host, const char *path);
bool gc_host_load_state(GCRetroHost *host, const char *path);

size_t gc_host_option_count(const GCRetroHost *host);
bool gc_host_option_at(const GCRetroHost *host, size_t index, GCRetroOptionInfo *out_info);
bool gc_host_option_choice_at(const GCRetroHost *host, size_t option_index, size_t choice_index, GCRetroOptionChoice *out_choice);
bool gc_host_set_option(GCRetroHost *host, const char *key, const char *value);

#ifdef __cplusplus
}
#endif

#endif
