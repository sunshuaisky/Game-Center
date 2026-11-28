#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct GCRetro GCRetro;

bool gc_ios_jit_available(void);
void gc_retro_set_moltenvk_path(const char *path);
void gc_retro_set_performance_profile(int profile);
void gc_retro_apply_performance_profile(GCRetro *core, int profile);
bool gc_retro_is_hw_rendered(GCRetro *core);

GCRetro *gc_retro_open(const char *core, const char *rom, const char *system, const char *save);
const char *gc_retro_error(void);
const char *gc_retro_last_log_error(void);
bool gc_retro_shutdown_requested(GCRetro *core);
double gc_retro_fps(GCRetro *core);
double gc_retro_sample_rate(GCRetro *core);
void gc_retro_set_analog(GCRetro *core, int16_t lx, int16_t ly, int16_t rx, int16_t ry);
void gc_retro_set_pointer(GCRetro *core, int16_t x, int16_t y, bool pressed);
void gc_retro_run(GCRetro *core, uint16_t buttons);
const void *gc_retro_frame(GCRetro *core, int *width, int *height, uint64_t *sequence);
size_t gc_retro_audio(GCRetro *core, int16_t *output, size_t frames);
void gc_retro_save(GCRetro *core);
void gc_retro_close(GCRetro *core);
