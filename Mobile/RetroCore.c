#include "RetroCore.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define GC_RETRO_AUDIO_FRAMES 16384u
#define GC_RETRO_AUDIO_MASK (GC_RETRO_AUDIO_FRAMES - 1u)

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
    void (*run)(void), (*unload)(void), (*deinit)(void);
    size_t (*memory_size)(unsigned);
    void *(*memory_data)(unsigned);
    struct { char *key, *value; } options[512];
    unsigned option_count;
};

static GCRetro *active;
static char error[512];
static char last_log_error[512];
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
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';
        if (n > 0) {
            pthread_mutex_lock(&log_mutex);
            if (last_log_error[0] == '\0') {
                snprintf(last_log_error, sizeof(last_log_error), "%s", buf);
            } else if (strstr(last_log_error, buf) == NULL) {
                size_t cur = strlen(last_log_error);
                if (cur + 3 < sizeof(last_log_error)) {
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

static bool environment(unsigned command, void *arg) {
    if (!active) return false;
    switch (command) {
        case 27: ((struct { void (*log)(int, const char *, ...); } *)arg)->log = core_log; return true;
        case 3: *(bool *)arg = true; return true;  /* Can duplicate video frames. */
        case 9: *(const char **)arg = active->system; return true;
        case 30: *(const char **)arg = active->system; return true; /* GET_CORE_ASSETS_DIRECTORY */
        case 10:
            if (*(const int *)arg < 0 || *(const int *)arg > 2) return false;
            active->format = *(const int *)arg;
            return true;
        case 11: return true; /* SET_INPUT_DESCRIPTORS */
        case 13: /* RETRO_ENVIRONMENT_SHUTDOWN */
            active->shutdown_requested = true;
            return true;
        case 14: case (14 | 0x10000):  /* SET_HW_RENDER */
            active->hardware_requested = true;
            return false;
        case 15: {
            struct Variable *variable = arg;
            // Ordinary iOS signing provides no JIT entitlement. Match the CPU
            // and renderer to this host's software-framebuffer implementation.
            static const struct Variable software_options[] = {
                {"desmume_cpu_mode", "interpreter"},
                {"desmume_pointer_type", "touch"},
                {"dolphin_cpu_core", "5"},
                {"dolphin_renderer", "Software"},
                {"dolphin_main_cpu_thread", "disabled"},
                {"pcsx2_renderer", "metal"},
                {"pcsx2_bios", "auto"},
                {"pcsx2_fast_boot", "enabled"},
                {"pcsx2_cpu_recompiler", "disabled"},
                {"pcsx2_rec_ee", "disabled"},
                {"pcsx2_rec_iop", "disabled"},
                {"pcsx2_rec_vu0", "disabled"},
                {"pcsx2_rec_vu1", "disabled"},
                {"citra_use_cpu_jit", "disabled"},
                {"citra_use_fastinterp", "enabled"},
                {"citra_is_new_3ds", "Old 3DS"},
                {"citra_cpu_clock_percentage", "75"},
                {"citra_audio_emulation", "hle"},
                {"citra_use_shader_jit", "disabled"},
                {"citra_use_hw_shader", "disabled"},
                {"citra_shaders_accurate_mul", "disabled"},
                {"citra_use_disk_shader_cache", "disabled"},
                {"citra_graphics_api", "Software"},
                {"citra_resolution_factor", "1"},
                {"citra_texture_filter", "none"},
                {"citra_texture_sampling", "NearestNeighbor"},
                {"citra_render_3d", "off"},
                {"citra_factor_3d", "0"},
                {"citra_enable_motion", "disabled"},
                {"ppsspp_cpu_core", "Interpreter"},
                {"ppsspp_software_rendering", "enabled"},
                {"ppsspp_backend", "Software"},
                {"pcsx_rearmed_drc", "disabled"},
                {"pcsx_rearmed_bios", "auto"},
                {"swanstation_CPU_ExecutionMode", "Interpreter"},
                {"swanstation_GPU_Renderer", "Software"},
                {"swanstation_BIOS_PathNTSCJ", "scph5500.bin"},
                {"swanstation_BIOS_PathNTSCU", "scph5501.bin"},
                {"swanstation_BIOS_PathPAL", "scph5502.bin"},
            };
            for (size_t i = 0; i < sizeof(software_options) / sizeof(software_options[0]); ++i) {
                if (!strcmp(variable->key, software_options[i].key)) {
                    variable->value = software_options[i].value;
                    return true;
                }
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
        case 17: *(bool *)arg = false; return true;
        case 31: *(const char **)arg = active->save; return true;
        case 32: active->timing = ((const struct AVInfo *)arg)->timing; return true;
        case 37: return true; /* SET_GEOMETRY */
        case 39: *(unsigned *)arg = 12; return true;  /* GET_LANGUAGE: simplified Chinese */
        case 47: *(unsigned *)arg = 1; return true;   /* GET_INPUT_MAX_USERS */
        case 52: *(unsigned *)arg = 2; return true;   /* GET_CORE_OPTIONS_VERSION */
        case 55: return true; /* SET_CORE_OPTIONS_DISPLAY */
        case 59: *(unsigned *)arg = 0; return true;   /* GET_MESSAGE_INTERFACE_VERSION */
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
        g_rgb565_lut[p] = (r8 << 16) | (g8 << 8) | b8;

        uint32_t r15 = (p >> 10) & 31u;
        uint32_t g15 = (p >> 5) & 31u;
        uint32_t r15_8 = (r15 << 3) | (r15 >> 2);
        uint32_t g15_8 = (g15 << 3) | (g15 >> 2);
        g_xrgb1555_lut[p] = (r15_8 << 16) | (g15_8 << 8) | b8;
    }
}

static void video(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!active || !data || data == (const void *)-1 || !w || !h || w > 4096 || h > 4096
        || pitch < w * (active->format == 1 ? 4 : 2)) return;
    if (w != (unsigned)active->width || h != (unsigned)active->height) {
        void *buffer = realloc(active->pixels, (size_t)w * h * sizeof(uint32_t));
        if (!buffer) return;
        active->pixels = buffer;
        active->width = w;
        active->height = h;
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
    static char snapshot[512];
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
        if (s->hardware_requested) {
            snprintf(error, sizeof(error), "该核心需要 Game Center 尚未接入的硬件渲染接口");
        } else if (last_log_error[0]) {
            snprintf(error, sizeof(error), "核心无法读取游戏，请检查 ROM 格式和 BIOS（%s）", last_log_error);
        } else {
            snprintf(error, sizeof(error), "核心无法读取游戏，请检查 ROM 格式和 BIOS");
        }
        goto fail;
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
    if (s->loaded) { gc_retro_save(s); s->unload(); }
    if (s->initialized) s->deinit();
    if (s->handle) dlclose(s->handle);
    for (unsigned i = 0; i < s->option_count; ++i) { free(s->options[i].key); free(s->options[i].value); }
    free(s->rom); free(s->rom_path); free(s->system); free(s->save); free(s->battery); free(s->pixels);
    free(s); active = NULL;
}
