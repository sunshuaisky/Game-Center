#include "RetroCore.h"
#include "RetroVulkanHost.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GC_RETRO_AUDIO_FRAMES 16384u
#define GC_RETRO_AUDIO_MASK (GC_RETRO_AUDIO_FRAMES - 1u)

#define GC_CS_OPS_STATUS 0
#define GC_CS_DEBUGGED 0x10000000u

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool gc_ios_jit_available(void) {
    uint32_t flags = 0;
    if (csops(getpid(), GC_CS_OPS_STATUS, &flags, sizeof(flags)) == 0) {
        return (flags & GC_CS_DEBUGGED) != 0;
    }
    return false;
}

static char g_moltenvk_path[1024];
static int g_performance_profile = 0; /* 0 = Performance (default), 1 = Balanced, 2 = Quality */

void gc_retro_set_moltenvk_path(const char *path) {
    if (!path) {
        g_moltenvk_path[0] = '\0';
        return;
    }
    snprintf(g_moltenvk_path, sizeof(g_moltenvk_path), "%s", path);
}

void gc_retro_set_performance_profile(int profile) {
    if (profile < 0) profile = 0;
    if (profile > 2) profile = 2;
    g_performance_profile = profile;
}

/* Libretro HW render structures */
#define RETRO_HW_CONTEXT_VULKAN 6u
#define RETRO_HW_FRAME_BUFFER_VALID ((const void *)(intptr_t)-1)

struct retro_hw_render_callback {
    unsigned context_type;
    void (*context_reset)(void);
    uintptr_t (*get_current_framebuffer)(void);
    void (*(*get_proc_address)(const char *sym))(void);
    bool depth;
    bool stencil;
    bool bottom_left_origin;
    unsigned version_major;
    unsigned version_minor;
    bool cache_context;
    void (*context_destroy)(void);
    bool debug_context;
};

/* The libretro ABI uses process-wide callbacks. The app presents one core at a time. */
struct GameInfo { const char *path; const void *data; size_t size; const char *meta; };
struct SystemInfo { const char *name, *version, *extensions; bool full_path, block_extract; };
struct Geometry { unsigned width, height, max_width, max_height; float aspect; };
struct Timing { double fps, sample_rate; };
struct AVInfo { struct Geometry geometry; struct Timing timing; };
struct Variable { const char *key, *value; };
struct GCRetro {
    void *handle, *rom;
    char *rom_path, *system, *save, *battery;
    struct Timing timing;
    uint32_t *pixels;
    int width, height, format;
    uint64_t sequence;
    uint16_t buttons;
    int16_t axes[4], pointer_x, pointer_y;
    bool pointer_pressed;
    int16_t audio[GC_RETRO_AUDIO_FRAMES * 2];
    size_t audio_read, audio_write;
    bool initialized, loaded, hardware_requested, shutdown_requested;
    bool hw_vulkan_enabled;
    struct retro_hw_render_callback hw_cb;
    const void *hw_negotiation;
    GCRetroVulkanHost *vk;
    bool jit_available;
    int performance_profile;
    bool options_dirty;
    void (*run)(void), (*unload)(void), (*deinit)(void);
    size_t (*memory_size)(unsigned);
    void *(*memory_data)(unsigned);
    struct { char *key, *value; } options[512];
    unsigned option_count;
};

static GCRetro *active;
static char error[512];
static char last_log_error[1024];
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

static void core_log(int level, const char *format, ...) {
    if (level < 3) return;
    va_list args, copy;
    va_start(args, format);
    va_copy(copy, args);
    char buf[256];
    int n = vsnprintf(buf, sizeof(buf), format, copy);
    va_end(copy);
    if (n > 0) {
        if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';
        if (n > 0) {
            pthread_mutex_lock(&log_mutex);
            if (last_log_error[0] == '\0') {
                snprintf(last_log_error, sizeof(last_log_error), "%s", buf);
            } else if (strstr(last_log_error, buf) == NULL) {
                size_t cur = strlen(last_log_error);
                size_t add = 3 + (size_t)n;
                /* Drop oldest entries so the most recent fatal error is never lost. */
                while (cur + add >= sizeof(last_log_error)) {
                    char *sep = strstr(last_log_error, " | ");
                    if (!sep) {
                        last_log_error[0] = '\0';
                        cur = 0;
                        break;
                    }
                    size_t rest = strlen(sep + 3);
                    memmove(last_log_error, sep + 3, rest + 1);
                    cur = rest;
                }
                if (cur == 0) {
                    snprintf(last_log_error, sizeof(last_log_error), "%s", buf);
                } else {
                    snprintf(last_log_error + cur, sizeof(last_log_error) - cur, " | %s", buf);
                }
            }
            pthread_mutex_unlock(&log_mutex);
        }
    }
    vfprintf(stderr, format, args);
    va_end(args);
}

struct CoreOptionValue { const char *value, *label; };
struct CoreOptionDefV1 { const char *key, *desc, *info; struct CoreOptionValue values[128]; const char *default_value; };
struct CoreOptionsIntlV1 { struct CoreOptionDefV1 *us, *local; };
struct CoreOptionDefV2 { const char *key, *desc, *desc_cat, *info, *info_cat, *cat_key; struct CoreOptionValue values[128]; const char *default_value; };
struct CoreOptionsV2 { void *categories; struct CoreOptionDefV2 *definitions; };
struct CoreOptionsIntlV2 { struct CoreOptionsV2 *us, *local; };

static void store_option(const char *key, const char *value) {
    if (!active || !key || !value) return;
    for (unsigned i = 0; i < active->option_count; ++i) {
        if (!strcmp(active->options[i].key, key)) {
            char *copy = strdup(value);
            if (copy) { free(active->options[i].value); active->options[i].value = copy; }
            return;
        }
    }
    if (active->option_count >= 512) return;
    char *k = strdup(key), *v = strdup(value);
    if (k && v) {
        active->options[active->option_count].key = k;
        active->options[active->option_count].value = v;
        ++active->option_count;
    } else {
        free(k); free(v);
    }
}

void gc_retro_apply_performance_profile(GCRetro *s, int profile) {
    if (profile < 0) profile = 0;
    if (profile > 2) profile = 2;
    g_performance_profile = profile;
    if (!s) return;
    s->performance_profile = profile;
    s->options_dirty = true;
}

bool gc_retro_is_hw_rendered(GCRetro *s) {
    return s ? (s->vk != NULL) : false;
}

static const char *resolve_tuned_option(const GCRetro *s, const char *key) {
    if (!s || !key) return NULL;
    const bool jit = s->jit_available;
    const bool has_vk = g_moltenvk_path[0] != '\0';
    const int p = s->performance_profile; /* 0=Performance, 1=Balanced, 2=Quality */

    /* ---- NDS (DeSmuME) ---- */
    if (!strcmp(key, "desmume_cpu_mode")) return jit ? "jit" : "interpreter";
    if (!strcmp(key, "desmume_pointer_type")) return "touch";
    if (!strcmp(key, "desmume_frameskip")) return p == 0 ? "1" : "0";

    /* ---- Wii / GameCube (Dolphin) ---- */
    if (!strcmp(key, "dolphin_cpu_core")) return jit ? "1" : "5";
    if (!strcmp(key, "dolphin_renderer")) return has_vk ? "Vulkan" : "Software";
    if (!strcmp(key, "dolphin_main_cpu_thread")) return "disabled";
    if (!strcmp(key, "dolphin_dsp_hle")) return "enabled";
    if (!strcmp(key, "dolphin_efb_scale")) return "x1 (640 x 528)";
    if (!strcmp(key, "dolphin_shader_compilation_mode")) return "a-sync Skip Rendering";

    /* ---- PS2 (PCEE2 / PCSX2 — Zeta-inspired JIT-less speed tuning + auto-JIT) ---- */
    if (!strcmp(key, "pcsx2_renderer")) return "metal";
    if (!strcmp(key, "pcsx2_bios")) return "auto";
    if (!strcmp(key, "pcsx2_fast_boot")) return "enabled";
    if (!strcmp(key, "pcsx2_osd_messages")) return "disabled";
    if (!strcmp(key, "pcsx2_cpu_recompiler")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx2_rec_ee")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx2_rec_iop")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx2_rec_vu0")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx2_rec_vu1")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx2_mtvu")) return "enabled";
    if (!strcmp(key, "pcsx2_instant_vu1")) return "enabled";
    if (!strcmp(key, "pcsx2_ee_cycle_rate")) {
        if (jit) return "0";
        return p == 0 ? "-3" : (p == 1 ? "-2" : "-1");
    }
    if (!strcmp(key, "pcsx2_ee_cycle_skip")) {
        if (jit) return "0";
        return p == 0 ? "2" : (p == 1 ? "1" : "0");
    }
    if (!strcmp(key, "pcsx2_hw_download_mode")) return p == 0 ? "disabled" : "unsynchronized";
    if (!strcmp(key, "pcsx2_blending_accuracy")) return p == 2 ? "basic" : "minimum";
    if (!strcmp(key, "pcsx2_rov")) return "enabled";
    if (!strcmp(key, "pcsx2_mipmapping")) return p == 2 ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx2_dithering")) return "0";
    if (!strcmp(key, "pcsx2_fxaa")) return "disabled";
    if (!strcmp(key, "pcsx2_anisotropic_filtering")) return "0";
    if (!strcmp(key, "pcsx2_upscale_multiplier")) return (jit && p == 2) ? "2" : "1";
    if (!strcmp(key, "pcsx2_frame_handover")) return "previous";
    if (!strcmp(key, "pcsx2_frame_limiter")) return "internal";
    if (!strcmp(key, "pcsx2_skip_duplicate_frames")) return "enabled";
    if (!strcmp(key, "pcsx2_audio_buffer_ms")) return "150";

    /* ---- 3DS (Azahar libretro fallback — Manic EMU tuned) ---- */
    if (!strcmp(key, "citra_use_cpu_jit")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "citra_use_fastinterp")) return "enabled";
    if (!strcmp(key, "citra_is_new_3ds")) return p == 2 ? "New 3DS" : "Old 3DS";
    if (!strcmp(key, "citra_cpu_clock_percentage")) {
        if (jit) return p == 0 ? "50" : (p == 1 ? "60" : "75");
        return p == 0 ? "15" : (p == 1 ? "20" : "25");
    }
    if (!strcmp(key, "citra_audio_emulation")) return "hle";
    if (!strcmp(key, "citra_use_shader_jit")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "citra_use_hw_shader")) return has_vk ? "enabled" : "disabled";
    if (!strcmp(key, "citra_shaders_accurate_mul")) return "disabled";
    if (!strcmp(key, "citra_use_disk_shader_cache")) return has_vk ? "enabled" : "disabled";
    if (!strcmp(key, "citra_graphics_api")) return has_vk ? "Vulkan" : "Software";
    if (!strcmp(key, "citra_resolution_factor")) return (has_vk && p == 2) ? "2" : "1";
    if (!strcmp(key, "citra_texture_filter")) return "none";
    if (!strcmp(key, "citra_texture_sampling")) return "NearestNeighbor";
    if (!strcmp(key, "citra_render_3d")) return "off";
    if (!strcmp(key, "citra_factor_3d")) return "0";
    if (!strcmp(key, "citra_enable_motion")) return "disabled";

    /* ---- PSP (Manic EMU PPSSPP — IR Interpreter + Vulkan/MoltenVK GPU) ---- */
    if (!strcmp(key, "ppsspp_cpu_core")) return jit ? "Dynarec (JIT)" : "IR Interpreter";
    if (!strcmp(key, "ppsspp_backend")) return "none";
    if (!strcmp(key, "ppsspp_software_rendering")) return "enabled";
    if (!strcmp(key, "ppsspp_software_rendering_jit")) return "disabled";
    if (!strcmp(key, "ppsspp_gpu_hardware_transform")) return "enabled";
    if (!strcmp(key, "ppsspp_software_skinning")) return "enabled";
    if (!strcmp(key, "ppsspp_lazy_texture_caching")) return "enabled";
    if (!strcmp(key, "ppsspp_skip_gpu_readbacks")) return p == 0 ? "enabled" : "disabled";
    if (!strcmp(key, "ppsspp_lower_resolution_for_effects")) return p == 0 ? "Aggressive" : (p == 1 ? "Balanced" : "Safe");
    if (!strcmp(key, "ppsspp_spline_quality")) return p == 2 ? "Medium" : "Low";
    if (!strcmp(key, "ppsspp_texture_deposterize")) return "disabled";
    if (!strcmp(key, "ppsspp_texture_scaling_level")) return "Off";
    if (!strcmp(key, "ppsspp_fast_memory")) return "enabled";
    if (!strcmp(key, "ppsspp_ignore_bad_memory_access")) return "enabled";
    if (!strcmp(key, "ppsspp_io_timing_method")) return "Fast";
    if (!strcmp(key, "ppsspp_auto_frameskip")) return p == 0 ? "enabled" : "disabled";
    if (!strcmp(key, "ppsspp_frameskip")) return p == 0 ? "1" : "0";
    if (!strcmp(key, "ppsspp_frameskiptype")) return "Number of frames";
    if (!strcmp(key, "ppsspp_frame_duplication")) return "enabled";
    if (!strcmp(key, "ppsspp_inflight_frames")) return "Up to 2";
    if (!strcmp(key, "ppsspp_internal_resolution")) {
        if (!has_vk) return "480x272";
        return p == 0 ? "480x272" : (p == 1 ? "960x544" : "1440x816");
    }

    /* ---- PS1 (PCSX-ReARMed / SwanStation) ---- */
    if (!strcmp(key, "pcsx_rearmed_drc")) return jit ? "enabled" : "disabled";
    if (!strcmp(key, "pcsx_rearmed_bios")) return "auto";
    if (!strcmp(key, "swanstation_CPU_ExecutionMode")) return jit ? "Recompiler" : "Interpreter";
    if (!strcmp(key, "swanstation_GPU_Renderer")) return has_vk ? "Vulkan" : "Software";
    if (!strcmp(key, "swanstation_BIOS_PathNTSCJ")) return "scph5500.bin";
    if (!strcmp(key, "swanstation_BIOS_PathNTSCU")) return "scph5501.bin";
    if (!strcmp(key, "swanstation_BIOS_PathPAL")) return "scph5502.bin";

    return NULL;
}

static bool environment(unsigned command, void *arg) {
    if (!active) return false;
    switch (command) {
        case 27: ((struct { void (*log)(int, const char *, ...); } *)arg)->log = core_log; return true;
        case 3: *(bool *)arg = true; return true;  /* Can duplicate video frames. */
        case 7: /* RETRO_ENVIRONMENT_SHUTDOWN */
            active->shutdown_requested = true;
            return true;
        case 9: *(const char **)arg = active->system; return true;
        case 30: *(const char **)arg = active->system; return true; /* GET_CORE_ASSETS_DIRECTORY */
        case 10:
            if (*(const int *)arg < 0 || *(const int *)arg > 2) return false;
            active->format = *(const int *)arg;
            return true;
        case 11: return true; /* SET_INPUT_DESCRIPTORS */
        case 14: case (14 | 0x10000): { /* SET_HW_RENDER */
            struct retro_hw_render_callback *cb = (struct retro_hw_render_callback *)arg;
            active->hardware_requested = true;
            if (cb && cb->context_type == RETRO_HW_CONTEXT_VULKAN && g_moltenvk_path[0] != '\0') {
                active->hw_cb = *cb;
                active->hw_vulkan_enabled = true;
                return true;
            }
            return false;
        }
        case 41: case (41 | 0x10000): { /* RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE */
            if (!active->vk || !arg) return false;
            *(const void **)arg = gc_ios_vk_get_retro_interface(active->vk);
            return *(const void **)arg != NULL;
        }
        case 43: case (43 | 0x10000): { /* RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE */
            active->hw_negotiation = arg;
            return true;
        }
        case 56: { /* RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER */
            if (!arg || g_moltenvk_path[0] == '\0') return false;
            *(unsigned *)arg = RETRO_HW_CONTEXT_VULKAN;
            return true;
        }
        case 15: {
            struct Variable *variable = arg;
            const char *tuned = resolve_tuned_option(active, variable->key);
            if (tuned) {
                variable->value = tuned;
                return true;
            }
            variable->value = NULL;
            for (unsigned i = 0; i < active->option_count; ++i) {
                if (!strcmp(active->options[i].key, variable->key)) {
                    variable->value = active->options[i].value;
                    return true;
                }
            }
            return variable->value != NULL;
        }
        case 16: {
            for (const struct Variable *item = arg; item && item->key && active->option_count < 512; ++item) {
                const char *separator = item->value ? strstr(item->value, "; ") : NULL;
                if (!separator) continue;
                const char *start = separator + 2;
                char *val = strndup(start, strcspn(start, "|"));
                if (val) { store_option(item->key, val); free(val); }
            }
            return true;
        }
        case 53: case 54: {
            const struct CoreOptionDefV1 *defs = command == 54
                ? (arg ? ((const struct CoreOptionsIntlV1 *)arg)->us : NULL)
                : (const struct CoreOptionDefV1 *)arg;
            for (size_t i = 0; defs && defs[i].key; ++i) {
                const char *val = defs[i].default_value ? defs[i].default_value : defs[i].values[0].value;
                store_option(defs[i].key, val);
            }
            return true;
        }
        case 67: case 68: {
            const struct CoreOptionsV2 *opts = command == 68
                ? (arg ? ((const struct CoreOptionsIntlV2 *)arg)->us : NULL)
                : (const struct CoreOptionsV2 *)arg;
            const struct CoreOptionDefV2 *defs = opts ? opts->definitions : NULL;
            for (size_t i = 0; defs && defs[i].key; ++i) {
                const char *val = defs[i].default_value ? defs[i].default_value : defs[i].values[0].value;
                store_option(defs[i].key, val);
            }
            return true;
        }
        case 17: {
            *(bool *)arg = active->options_dirty;
            active->options_dirty = false;
            return true;
        }
        case 31: *(const char **)arg = active->save; return true;
        case 32: active->timing = ((const struct AVInfo *)arg)->timing; return true;
        case 37: return true; /* SET_GEOMETRY */
        case 39: *(unsigned *)arg = 12; return true;  /* GET_LANGUAGE: simplified Chinese */
        case 52: *(unsigned *)arg = 2; return true;   /* GET_CORE_OPTIONS_VERSION */
        case 55: return true; /* SET_CORE_OPTIONS_DISPLAY */
        case 59: *(unsigned *)arg = 0; return true;   /* GET_MESSAGE_INTERFACE_VERSION */
        case 61: *(unsigned *)arg = 1; return true;   /* GET_INPUT_MAX_USERS */
        case 74: *(bool *)arg = active->jit_available; return true; /* GET_JIT_CAPABLE */
        case 51: case (51 | 0x10000): return true;    /* GET_INPUT_BITMASKS */
        default: return false;
    }
}

static uint32_t g_rgb565_lut[65536];
static uint32_t g_xrgb1555_lut[65536];
static pthread_once_t g_lut_once = PTHREAD_ONCE_INIT;

static void init_pixel_luts(void) {
    for (uint32_t p = 0; p < 65536u; ++p) {
        uint32_t b5 = p & 31u;
        uint32_t b8 = (b5 << 3) | (b5 >> 2);
        uint32_t r5 = (p >> 11) & 31u;
        uint32_t g6 = (p >> 5) & 63u;
        uint32_t r8 = (r5 << 3) | (r5 >> 2);
        uint32_t g8 = (g6 << 2) | (g6 >> 4);
        g_rgb565_lut[p] = 0xFF000000u | (r8 << 16) | (g8 << 8) | b8;

        uint32_t r15 = (p >> 10) & 31u;
        uint32_t g15 = (p >> 5) & 31u;
        uint32_t r15_8 = (r15 << 3) | (r15 >> 2);
        uint32_t g15_8 = (g15 << 3) | (g15 >> 2);
        g_xrgb1555_lut[p] = 0xFF000000u | (r15_8 << 16) | (g15_8 << 8) | b8;
    }
}

static void video(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!active || !data || !w || !h || w > 4096 || h > 4096) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        if (!active->vk) return;
        if (w != (unsigned)active->width || h != (unsigned)active->height) {
            void *buffer = realloc(active->pixels, (size_t)w * h * sizeof(uint32_t));
            if (!buffer) return;
            active->pixels = buffer;
            active->width = (int)w;
            active->height = (int)h;
        }
        if (gc_ios_vk_readback_frame(active->vk, w, h, active->pixels, w * 4u)) {
            ++active->sequence;
        }
        return;
    }
    if (pitch < w * (active->format == 1 ? 4u : 2u)) return;
    if (w != (unsigned)active->width || h != (unsigned)active->height) {
        void *buffer = realloc(active->pixels, (size_t)w * h * sizeof(uint32_t));
        if (!buffer) return;
        active->pixels = buffer;
        active->width = (int)w;
        active->height = (int)h;
    }
    if (active->format == 1) {
        size_t row_bytes = (size_t)w * 4u;
        if (pitch == row_bytes) {
            memcpy(active->pixels, data, row_bytes * (size_t)h);
        } else {
            for (unsigned y = 0; y < h; y++) {
                memcpy(active->pixels + (size_t)y * w, (const uint8_t *)data + (size_t)y * pitch, row_bytes);
            }
        }
    } else {
        pthread_once(&g_lut_once, init_pixel_luts);
        const uint32_t *lut = active->format == 2 ? g_rgb565_lut : g_xrgb1555_lut;
        for (unsigned y = 0; y < h; y++) {
            const uint16_t *src = (const uint16_t *)((const uint8_t *)data + (size_t)y * pitch);
            uint32_t *out = active->pixels + (size_t)y * w;
            for (unsigned x = 0; x < w; x++) {
                out[x] = lut[src[x]];
            }
        }
    }
    ++active->sequence;
}

static size_t audio(const int16_t *data, size_t frames) {
    if (!active || !data || frames == 0) return 0;
    size_t used = active->audio_write - active->audio_read;
    size_t count = GC_RETRO_AUDIO_FRAMES - used;
    if (count > frames) count = frames;
    if (count == 0) return frames;
    size_t idx = active->audio_write & GC_RETRO_AUDIO_MASK;
    size_t first = GC_RETRO_AUDIO_FRAMES - idx;
    if (first > count) first = count;
    memcpy(active->audio + idx * 2, data, first * 2 * sizeof(int16_t));
    size_t rem = count - first;
    if (rem > 0) {
        memcpy(active->audio, data + first * 2, rem * 2 * sizeof(int16_t));
    }
    active->audio_write += count;
    return frames;
}
static void sample(int16_t l, int16_t r) { const int16_t pair[] = {l, r}; audio(pair, 1); }
static void input_poll(void) {}
static int16_t input(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (!active || port) return 0;
    unsigned base = device & 0xFF;
    if (base == 5 && index < 2 && id < 2) return active->axes[index * 2 + id];
    if (base == 6 && index == 0) {
        if (id == 0) return active->pointer_x;
        if (id == 1) return active->pointer_y;
        if (id == 2) return active->pointer_pressed;
    }
    if (base != 1 || index) return 0;
    if (id == 256) return (int16_t)active->buttons;
    return id < 16 && ((active->buttons >> id) & 1);
}

const char *gc_retro_error(void) { return error; }
const char *gc_retro_last_log_error(void) {
    static char snapshot[1024];
    pthread_mutex_lock(&log_mutex);
    snprintf(snapshot, sizeof(snapshot), "%s", last_log_error);
    pthread_mutex_unlock(&log_mutex);
    return snapshot;
}
bool gc_retro_shutdown_requested(GCRetro *s) { return s ? s->shutdown_requested : false; }

GCRetro *gc_retro_open(const char *core, const char *rom, const char *system, const char *save) {
    if (active) { snprintf(error, sizeof(error), "已有游戏正在运行"); return NULL; }
    pthread_mutex_lock(&log_mutex);
    last_log_error[0] = '\0';
    pthread_mutex_unlock(&log_mutex);
    GCRetro *s = calloc(1, sizeof(*s));
    if (!s) { snprintf(error, sizeof(error), "内存不足"); return NULL; }
    s->jit_available = gc_ios_jit_available();
    s->performance_profile = g_performance_profile;
    snprintf(error, sizeof(error), "无法读取 ROM 或存档目录");
    active = s;
    s->rom_path = strdup(rom); s->system = strdup(system); s->save = strdup(save);
    if (!s->rom_path || !s->system || !s->save || asprintf(&s->battery, "%s/battery.srm", save) < 0) goto fail;
    s->handle = dlopen(core, RTLD_NOW | RTLD_LOCAL);
    if (!s->handle) { snprintf(error, sizeof(error), "%s", dlerror()); goto fail; }

    /* Validate the complete set of entry points before running untrusted ROM data. */
    const char *symbols[] = {
        "retro_init", "retro_deinit", "retro_run", "retro_get_system_info", "retro_get_system_av_info",
        "retro_set_environment", "retro_set_video_refresh", "retro_set_audio_sample", "retro_set_audio_sample_batch",
        "retro_set_input_poll", "retro_set_input_state", "retro_load_game", "retro_unload_game",
        "retro_get_memory_data", "retro_get_memory_size", "retro_api_version", "retro_set_controller_port_device"
    };
    void *fn[sizeof(symbols) / sizeof(symbols[0])];
    for (size_t i = 0; i < sizeof(fn) / sizeof(fn[0]); ++i) {
        fn[i] = dlsym(s->handle, symbols[i]);
        if (!fn[i]) { snprintf(error, sizeof(error), "核心缺少 %s", symbols[i]); goto fail; }
    }
    if (((unsigned (*)(void))fn[15])() != 1) { snprintf(error, sizeof(error), "核心 ABI 不兼容"); goto fail; }
    s->deinit = fn[1]; s->run = fn[2]; s->unload = fn[12]; s->memory_data = fn[13]; s->memory_size = fn[14];
    ((void (*)(bool (*)(unsigned, void *)))fn[5])(environment);
    ((void (*)(void (*)(const void *, unsigned, unsigned, size_t)))fn[6])(video);
    ((void (*)(void (*)(int16_t, int16_t)))fn[7])(sample);
    ((void (*)(size_t (*)(const int16_t *, size_t)))fn[8])(audio);
    ((void (*)(void (*)(void)))fn[9])(input_poll);
    ((void (*)(int16_t (*)(unsigned, unsigned, unsigned, unsigned)))fn[10])(input);
    ((void (*)(void))fn[0])();
    s->initialized = true;
    struct SystemInfo info = {0};
    ((void (*)(struct SystemInfo *))fn[3])(&info);
    struct GameInfo game = {.path = s->rom_path};
    if (!info.full_path) {
        FILE *file = fopen(rom, "rb");
        if (!file) goto fail;
        if (fseeko(file, 0, SEEK_END)) { fclose(file); goto fail; }
        off_t length = ftello(file);
        rewind(file);
        if (length <= 0 || length > 512LL * 1024 * 1024) { fclose(file); goto fail; }
        s->rom = malloc((size_t)length);
        size_t read = s->rom ? fread(s->rom, 1, (size_t)length, file) : 0;
        fclose(file);
        if (read != (size_t)length) goto fail;
        game.data = s->rom; game.size = read;
    }
    s->loaded = ((bool (*)(const struct GameInfo *))fn[11])(&game);
    if (!s->loaded) {
        if (s->hardware_requested && !s->hw_vulkan_enabled) {
            snprintf(error, sizeof(error), "该核心需要硬件渲染接口，请重新生成包含 MoltenVK 的最新版 IPA");
        } else {
            const char *log_detail = gc_retro_last_log_error();
            if (log_detail[0]) {
                snprintf(error, sizeof(error), "核心无法读取游戏，请检查 ROM 格式和 BIOS（%s）", log_detail);
            } else {
                snprintf(error, sizeof(error), "核心无法读取游戏，请检查 ROM 格式和 BIOS");
            }
        }
        goto fail;
    }
    if (s->hw_vulkan_enabled) {
        char vk_err[256] = {0};
        s->vk = gc_ios_vk_create(
            g_moltenvk_path,
            s->hw_negotiation,
            s->hw_cb.bottom_left_origin,
            vk_err,
            sizeof(vk_err)
        );
        if (!s->vk) {
            snprintf(error, sizeof(error), "%s", vk_err[0] ? vk_err : "Vulkan/MoltenVK 硬件渲染初始化失败");
            goto fail;
        }
        if (s->hw_cb.context_reset) {
            s->hw_cb.context_reset();
        }
    }
    ((void (*)(unsigned, unsigned))fn[16])(0, strstr(core, "dolphin_libretro") ? 0x301 : 1);
    struct AVInfo av = {0};
    ((void (*)(struct AVInfo *))fn[4])(&av);
    s->timing = av.timing;
    void *memory = s->memory_data(0);
    size_t size = s->memory_size(0);
    FILE *file = memory && size ? fopen(s->battery, "rb") : NULL;
    if (file) { fread(memory, 1, size, file); fclose(file); }
    return s;
fail:
    if (s->battery) s->battery[0] = 0;
    gc_retro_close(s);
    return NULL;
}

double gc_retro_fps(GCRetro *s) { return s->timing.fps; }
double gc_retro_sample_rate(GCRetro *s) { return s->timing.sample_rate; }
void gc_retro_set_analog(GCRetro *s, int16_t lx, int16_t ly, int16_t rx, int16_t ry) {
    s->axes[0] = lx; s->axes[1] = ly; s->axes[2] = rx; s->axes[3] = ry;
}
void gc_retro_set_pointer(GCRetro *s, int16_t x, int16_t y, bool pressed) {
    s->pointer_x = x; s->pointer_y = y; s->pointer_pressed = pressed;
}
void gc_retro_run(GCRetro *s, uint16_t buttons) { s->buttons = buttons; s->run(); }
const void *gc_retro_frame(GCRetro *s, int *w, int *h, uint64_t *sequence) {
    *w = s->width; *h = s->height; *sequence = s->sequence; return s->pixels;
}
size_t gc_retro_audio(GCRetro *s, int16_t *output, size_t frames) {
    size_t avail = s->audio_write - s->audio_read;
    if (frames > avail) frames = avail;
    if (frames == 0) return 0;
    size_t idx = s->audio_read & GC_RETRO_AUDIO_MASK;
    size_t first = GC_RETRO_AUDIO_FRAMES - idx;
    if (first > frames) first = frames;
    memcpy(output, s->audio + idx * 2, first * 2 * sizeof(int16_t));
    size_t rem = frames - first;
    if (rem > 0) {
        memcpy(output + first * 2, s->audio, rem * 2 * sizeof(int16_t));
    }
    s->audio_read += frames;
    return frames;
}
void gc_retro_save(GCRetro *s) {
    if (!s->loaded || !s->battery || !s->battery[0]) return;
    size_t size = s->memory_size(0);
    const void *memory = s->memory_data(0);
    if (!size || !memory) return;
    char *temporary;
    if (asprintf(&temporary, "%s.tmp", s->battery) < 0) return;
    FILE *file = fopen(temporary, "wb");
    if (file) {
        bool written = fwrite(memory, 1, size, file) == size;
        if (fclose(file) != 0 || !written || rename(temporary, s->battery) != 0) {
            remove(temporary);
        }
    }
    free(temporary);
}
void gc_retro_close(GCRetro *s) {
    if (!s) return;
    if (s->loaded) { gc_retro_save(s); }
    if (s->vk && s->hw_cb.context_destroy) {
        s->hw_cb.context_destroy();
    }
    if (s->loaded) { s->unload(); }
    if (s->vk) {
        gc_ios_vk_destroy(s->vk);
        s->vk = NULL;
    }
    if (s->initialized) s->deinit();
    if (s->handle) dlclose(s->handle);
    for (unsigned i = 0; i < s->option_count; ++i) { free(s->options[i].key); free(s->options[i].value); }
    free(s->rom); free(s->rom_path); free(s->system); free(s->save); free(s->battery); free(s->pixels);
    free(s); active = NULL;
}
