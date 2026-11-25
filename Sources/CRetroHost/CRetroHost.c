#include "CRetroHost.h"
#include "GCOpenGLHost.h"
#include "GCVulkanHost.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Libretro constants */
#define RETRO_ENVIRONMENT_EXPERIMENTAL 0x10000
#define RETRO_ENVIRONMENT_GET_CAN_DUPE 3
#define RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY 9
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10
#define RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS 11
#define RETRO_ENVIRONMENT_SET_HW_RENDER 14
#define RETRO_ENVIRONMENT_GET_VARIABLE 15
#define RETRO_ENVIRONMENT_SET_VARIABLES 16
#define RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE 17
#define RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME 18
#define RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE 23
#define RETRO_ENVIRONMENT_GET_LOG_INTERFACE 27
#define RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY 30
#define RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY 31
#define RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO 32
#define RETRO_ENVIRONMENT_SET_GEOMETRY 37
#define RETRO_ENVIRONMENT_GET_LANGUAGE 39
#define RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE 41
#define RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE 43
#define RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT 44
#define RETRO_ENVIRONMENT_GET_VFS_INTERFACE 45
#define RETRO_ENVIRONMENT_GET_LED_INTERFACE 46
#define RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER 56
#define RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION 59
#define RETRO_ENVIRONMENT_GET_INPUT_BITMASKS (51 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION 52
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS 53
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL 54
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY 55
#define RETRO_ENVIRONMENT_GET_FASTFORWARDING 64
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 67
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL 68
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK 69
#define RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT 73

#define RETRO_HW_CONTEXT_NONE 0
#define RETRO_HW_CONTEXT_OPENGL 1
#define RETRO_HW_CONTEXT_OPENGL_CORE 3
#define RETRO_HW_CONTEXT_VULKAN 6

typedef void (*retro_hw_context_reset_t)(void);
typedef uintptr_t (*retro_hw_get_current_framebuffer_t)(void);
typedef void (*retro_proc_address_t)(void);
typedef retro_proc_address_t (*retro_hw_get_proc_address_t)(const char *sym);

struct retro_hw_render_callback {
    unsigned context_type;
    retro_hw_context_reset_t context_reset;
    retro_hw_get_current_framebuffer_t get_current_framebuffer;
    retro_hw_get_proc_address_t get_proc_address;
    bool depth;
    bool stencil;
    bool bottom_left_origin;
    unsigned version_major;
    unsigned version_minor;
    bool cache_context;
    retro_hw_context_reset_t context_destroy;
    bool debug_context;
};

#define RETRO_PIXEL_FORMAT_0RGB1555 0
#define RETRO_PIXEL_FORMAT_XRGB8888 1
#define RETRO_PIXEL_FORMAT_RGB565 2

#define RETRO_DEVICE_JOYPAD 1
#define RETRO_DEVICE_MOUSE 2
#define RETRO_DEVICE_ANALOG 5
#define RETRO_DEVICE_POINTER 6

#define RETRO_DEVICE_ID_JOYPAD_MASK 256
#define RETRO_DEVICE_ID_MOUSE_X 0
#define RETRO_DEVICE_ID_MOUSE_Y 1
#define RETRO_DEVICE_ID_MOUSE_LEFT 2
#define RETRO_DEVICE_ID_MOUSE_RIGHT 3
#define RETRO_DEVICE_ID_MOUSE_WHEELUP 4
#define RETRO_DEVICE_ID_MOUSE_WHEELDOWN 5
#define RETRO_DEVICE_ID_MOUSE_MIDDLE 6

#define RETRO_DEVICE_ID_POINTER_X 0
#define RETRO_DEVICE_ID_POINTER_Y 1
#define RETRO_DEVICE_ID_POINTER_PRESSED 2

#define RETRO_MEMORY_SAVE_RAM 0

#define RETRO_NUM_CORE_OPTION_VALUES_MAX 128

struct retro_game_info {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

struct retro_variable {
    const char *key;
    const char *value;
};

struct retro_core_option_value {
    const char *value;
    const char *label;
};

struct retro_core_option_definition {
    const char *key;
    const char *desc;
    const char *info;
    struct retro_core_option_value values[RETRO_NUM_CORE_OPTION_VALUES_MAX];
    const char *default_value;
};

struct retro_core_options_intl {
    struct retro_core_option_definition *us;
    struct retro_core_option_definition *local;
};

struct retro_core_option_v2_category {
    const char *key;
    const char *desc;
    const char *info;
};

struct retro_core_option_v2_definition {
    const char *key;
    const char *desc;
    const char *desc_categorized;
    const char *info;
    const char *info_categorized;
    const char *category_key;
    struct retro_core_option_value values[RETRO_NUM_CORE_OPTION_VALUES_MAX];
    const char *default_value;
};

struct retro_core_options_v2 {
    struct retro_core_option_v2_category *categories;
    struct retro_core_option_v2_definition *definitions;
};

struct retro_core_options_v2_intl {
    struct retro_core_options_v2 *us;
    struct retro_core_options_v2 *local;
};

typedef struct GCOptionChoice {
    char *value;
    char *label;
} GCOptionChoice;

typedef struct GCOptionEntry {
    char *key;
    char *description;
    char *current_value;
    char *default_value;
    GCOptionChoice *choices;
    size_t choice_count;
} GCOptionEntry;

struct GCRetroHost {
    void *handle;
    void *rom_buffer;
    char *rom_path;
    char *system_dir;
    char *save_dir;
    char *battery_path;
    char *moltenvk_path;

    struct retro_system_av_info av_info;
    int pixel_format;
    bool initialized;
    bool loaded;
    bool hardware_requested;
    bool options_dirty;
    bool fast_forwarding;

    /* Hardware render state (Vulkan via MoltenVK / OpenGL Core 4.1) */
    struct retro_hw_render_callback hw_cb;
    const void *vk_negotiation;
    GCVulkanHost *vk_host;
    GCOpenGLHost *gl_host;
    bool hw_context_active;

    GCRetroHostCallbacks callbacks;
    GCSharedInputState current_input;
    int32_t mouse_dx;
    int32_t mouse_dy;
    int32_t mouse_wheel_y;

    uint64_t last_battery_hash;
    bool has_battery_hash;

    GCOptionEntry *options;
    size_t option_count;
    size_t option_capacity;

    void (*retro_init)(void);
    void (*retro_deinit)(void);
    void (*retro_run)(void);
    void (*retro_reset)(void);
    void (*retro_unload_game)(void);
    void *(*retro_get_memory_data)(unsigned id);
    size_t (*retro_get_memory_size)(unsigned id);
    size_t (*retro_serialize_size)(void);
    bool (*retro_serialize)(void *data, size_t size);
    bool (*retro_unserialize)(const void *data, size_t size);
    void (*retro_set_controller_port_device)(unsigned port, unsigned device);
};

static GCRetroHost *g_active = NULL;
static char g_last_error[512] = {0};

static void set_error(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_last_error, sizeof(g_last_error), fmt, args);
    va_end(args);
}

static char *dup_or_null(const char *s) {
    return s ? strdup(s) : NULL;
}

static void free_option(GCOptionEntry *entry) {
    if (!entry) return;
    free(entry->key);
    free(entry->description);
    free(entry->current_value);
    free(entry->default_value);
    for (size_t i = 0; i < entry->choice_count; ++i) {
        free(entry->choices[i].value);
        free(entry->choices[i].label);
    }
    free(entry->choices);
    memset(entry, 0, sizeof(*entry));
}

static GCOptionEntry *find_option(GCRetroHost *h, const char *key) {
    if (!h || !key) return NULL;
    for (size_t i = 0; i < h->option_count; ++i) {
        if (h->options[i].key && strcmp(h->options[i].key, key) == 0) {
            return &h->options[i];
        }
    }
    return NULL;
}

static GCOptionEntry *ensure_option(GCRetroHost *h, const char *key) {
    GCOptionEntry *existing = find_option(h, key);
    if (existing) return existing;
    if (h->option_count >= h->option_capacity) {
        size_t next_cap = h->option_capacity ? h->option_capacity * 2 : 64;
        GCOptionEntry *grown = realloc(h->options, next_cap * sizeof(GCOptionEntry));
        if (!grown) return NULL;
        h->options = grown;
        h->option_capacity = next_cap;
    }
    GCOptionEntry *entry = &h->options[h->option_count++];
    memset(entry, 0, sizeof(*entry));
    entry->key = dup_or_null(key);
    return entry;
}

static void register_option_choices(
    GCRetroHost *h,
    const char *key,
    const char *desc,
    const char *default_value,
    const struct retro_core_option_value *values
) {
    if (!h || !key) return;
    GCOptionEntry *entry = ensure_option(h, key);
    if (!entry) return;

    if (desc) {
        free(entry->description);
        entry->description = dup_or_null(desc);
    }
    if (default_value) {
        free(entry->default_value);
        entry->default_value = dup_or_null(default_value);
    }

    for (size_t i = 0; i < entry->choice_count; ++i) {
        free(entry->choices[i].value);
        free(entry->choices[i].label);
    }
    free(entry->choices);
    entry->choices = NULL;
    entry->choice_count = 0;

    if (values) {
        size_t count = 0;
        while (count < RETRO_NUM_CORE_OPTION_VALUES_MAX && values[count].value != NULL) {
            ++count;
        }
        if (count > 0) {
            entry->choices = calloc(count, sizeof(GCOptionChoice));
            if (entry->choices) {
                entry->choice_count = count;
                for (size_t i = 0; i < count; ++i) {
                    entry->choices[i].value = dup_or_null(values[i].value);
                    entry->choices[i].label = dup_or_null(values[i].label ? values[i].label : values[i].value);
                }
            }
        }
    }

    if (!entry->current_value) {
        if (entry->default_value) {
            entry->current_value = dup_or_null(entry->default_value);
        } else if (entry->choice_count > 0 && entry->choices[0].value) {
            entry->current_value = dup_or_null(entry->choices[0].value);
        }
    }
}

static void register_legacy_variables(GCRetroHost *h, const struct retro_variable *vars) {
    if (!h || !vars) return;
    for (const struct retro_variable *item = vars; item->key != NULL; ++item) {
        if (!item->value) continue;
        const char *sep = strstr(item->value, "; ");
        if (!sep) continue;
        char *desc = strndup(item->value, (size_t)(sep - item->value));
        const char *list = sep + 2;

        GCOptionEntry *entry = ensure_option(h, item->key);
        if (!entry) {
            free(desc);
            continue;
        }
        free(entry->description);
        entry->description = desc;

        for (size_t i = 0; i < entry->choice_count; ++i) {
            free(entry->choices[i].value);
            free(entry->choices[i].label);
        }
        free(entry->choices);
        entry->choices = NULL;
        entry->choice_count = 0;

        size_t count = 1;
        for (const char *p = list; *p; ++p) {
            if (*p == '|') ++count;
        }
        entry->choices = calloc(count, sizeof(GCOptionChoice));
        if (entry->choices) {
            size_t idx = 0;
            const char *cur = list;
            while (*cur && idx < count) {
                const char *bar = strchr(cur, '|');
                size_t len = bar ? (size_t)(bar - cur) : strlen(cur);
                entry->choices[idx].value = strndup(cur, len);
                entry->choices[idx].label = strndup(cur, len);
                ++idx;
                if (!bar) break;
                cur = bar + 1;
            }
            entry->choice_count = idx;
            if (idx > 0 && entry->choices[0].value) {
                free(entry->default_value);
                entry->default_value = dup_or_null(entry->choices[0].value);
                if (!entry->current_value) {
                    entry->current_value = dup_or_null(entry->choices[0].value);
                }
            }
        }
    }
}

static void core_log(int level, const char *fmt, ...) {
    if (level < 2) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

static bool rumble_noop(unsigned port, unsigned effect, uint16_t strength) {
    (void)port; (void)effect; (void)strength;
    return false;
}

static uintptr_t gl_current_fb_trampoline(void) {
    return (g_active && g_active->gl_host) ? gc_gl_current_framebuffer(g_active->gl_host) : 0;
}

static retro_proc_address_t gl_get_proc_trampoline(const char *sym) {
    return (retro_proc_address_t)gc_gl_get_proc_address(sym);
}

static bool env_callback(unsigned cmd, void *data) {
    GCRetroHost *h = g_active;
    if (!h) return false;

    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            if (data) *(bool *)data = true;
            return true;

        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            if (data) {
                struct { void (*log)(int, const char *, ...); } *cb = data;
                cb->log = core_log;
            }
            return true;

        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
            if (data) *(const char **)data = h->system_dir;
            return true;

        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (data) *(const char **)data = h->save_dir;
            return true;

        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            if (!data) return false;
            int fmt = *(const int *)data;
            if (fmt < 0 || fmt > 2) return false;
            h->pixel_format = fmt;
            return true;
        }

        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
            return true;

        case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
            if (data) {
                struct { bool (*set_rumble_state)(unsigned, unsigned, uint16_t); } *r = data;
                r->set_rumble_state = rumble_noop;
            }
            return true;

        case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        case (RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER | RETRO_ENVIRONMENT_EXPERIMENTAL):
            if (data) {
                *(unsigned *)data = (h->moltenvk_path && h->moltenvk_path[0])
                    ? RETRO_HW_CONTEXT_VULKAN
                    : RETRO_HW_CONTEXT_OPENGL_CORE;
            }
            return true;

        case RETRO_ENVIRONMENT_SET_HW_RENDER:
        case (RETRO_ENVIRONMENT_SET_HW_RENDER | RETRO_ENVIRONMENT_EXPERIMENTAL): {
            h->hardware_requested = true;
            if (!data) return false;
            struct retro_hw_render_callback *cb = (struct retro_hw_render_callback *)data;
            if (cb->context_type == RETRO_HW_CONTEXT_VULKAN) {
                if (!h->moltenvk_path || !h->moltenvk_path[0]) return false;
                h->hw_cb = *cb;
                return true;
            }
            if (cb->context_type == RETRO_HW_CONTEXT_OPENGL_CORE || cb->context_type == RETRO_HW_CONTEXT_OPENGL) {
                cb->get_current_framebuffer = gl_current_fb_trampoline;
                cb->get_proc_address = gl_get_proc_trampoline;
                h->hw_cb = *cb;
                return true;
            }
            return false;
        }

        case RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT:
        case (RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT | RETRO_ENVIRONMENT_EXPERIMENTAL):
            if (data && h->moltenvk_path && h->moltenvk_path[0]) {
                struct { int interface_type; unsigned interface_version; } *sup = data;
                sup->interface_type = 0; /* RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN */
                sup->interface_version = 2;
                return true;
            }
            return false;

        case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:
        case (RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE | RETRO_ENVIRONMENT_EXPERIMENTAL):
            h->vk_negotiation = data;
            return true;

        case RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT:
        case (RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT | RETRO_ENVIRONMENT_EXPERIMENTAL):
            return true;

        case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        case (RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE | RETRO_ENVIRONMENT_EXPERIMENTAL):
            if (!data || !h->vk_host) return false;
            *(void **)data = gc_vk_get_retro_interface(h->vk_host);
            return true;

        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
            if (data) *(unsigned *)data = 2;
            return true;

        case RETRO_ENVIRONMENT_SET_VARIABLES:
            register_legacy_variables(h, (const struct retro_variable *)data);
            return true;

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS: {
            const struct retro_core_option_definition *defs = data;
            if (!defs) return false;
            for (const struct retro_core_option_definition *d = defs; d->key != NULL; ++d) {
                register_option_choices(h, d->key, d->desc, d->default_value, d->values);
            }
            return true;
        }

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL: {
            const struct retro_core_options_intl *intl = data;
            const struct retro_core_option_definition *defs = (intl && intl->local) ? intl->local : (intl ? intl->us : NULL);
            if (!defs) return false;
            for (const struct retro_core_option_definition *d = defs; d->key != NULL; ++d) {
                register_option_choices(h, d->key, d->desc, d->default_value, d->values);
            }
            return true;
        }

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2: {
            const struct retro_core_options_v2 *v2 = data;
            if (!v2 || !v2->definitions) return false;
            for (const struct retro_core_option_v2_definition *d = v2->definitions; d->key != NULL; ++d) {
                register_option_choices(h, d->key, d->desc ? d->desc : d->desc_categorized, d->default_value, d->values);
            }
            return true;
        }

        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
            const struct retro_core_options_v2_intl *intl = data;
            const struct retro_core_options_v2 *v2 = (intl && intl->local) ? intl->local : (intl ? intl->us : NULL);
            if (!v2 || !v2->definitions) return false;
            for (const struct retro_core_option_v2_definition *d = v2->definitions; d->key != NULL; ++d) {
                register_option_choices(h, d->key, d->desc ? d->desc : d->desc_categorized, d->default_value, d->values);
            }
            return true;
        }

        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *var = data;
            if (!var || !var->key) return false;
            GCOptionEntry *entry = find_option(h, var->key);
            if (entry && entry->current_value) {
                var->value = entry->current_value;
                return true;
            }
            var->value = NULL;
            return false;
        }

        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            if (data) {
                *(bool *)data = h->options_dirty;
                h->options_dirty = false;
            }
            return true;

        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
            if (data) {
                h->av_info = *(const struct retro_system_av_info *)data;
            }
            return true;

        case RETRO_ENVIRONMENT_SET_GEOMETRY:
            if (data) {
                h->av_info.geometry = *(const struct retro_game_geometry *)data;
            }
            return true;

        case RETRO_ENVIRONMENT_GET_LANGUAGE:
            if (data) *(unsigned *)data = 12; /* Simplified Chinese */
            return true;

        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
        case 51:
            return true;

        case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
            if (data) *(unsigned *)data = 0;
            return true;

        case RETRO_ENVIRONMENT_GET_FASTFORWARDING:
            if (data) *(bool *)data = h->fast_forwarding;
            return true;

        case RETRO_ENVIRONMENT_GET_VFS_INTERFACE:
            return false;

        default:
            return false;
    }
}

static float effective_aspect(const GCRetroHost *h, unsigned width, unsigned height) {
    if (h && h->av_info.geometry.aspect_ratio > 0.05f) {
        return h->av_info.geometry.aspect_ratio;
    }
    return height > 0 ? ((float)width / (float)height) : (4.0f / 3.0f);
}

static void video_callback(const void *data, unsigned width, unsigned height, size_t pitch) {
    GCRetroHost *h = g_active;
    if (!h || !data) return;
    if (width == 0 || height == 0 || width > GC_FRAME_MAX_WIDTH || height > GC_FRAME_MAX_HEIGHT) return;
    if (!h->callbacks.acquire_frame || !h->callbacks.commit_frame) return;

    if (data == (const void *)-1) {
        /* RETRO_HW_FRAME_BUFFER_VALID */
        uint32_t out_stride = 0;
        uint32_t slot_index = 0;
        uint32_t *dst = h->callbacks.acquire_frame(h->callbacks.context, width, height, &out_stride, &slot_index);
        if (!dst || out_stride < width * 4u) return;
        bool ok = false;
        if (h->vk_host) {
            ok = gc_vk_readback_frame(h->vk_host, width, height, dst, out_stride);
        } else if (h->gl_host) {
            ok = gc_gl_readback_frame(h->gl_host, width, height, dst, out_stride);
        }
        if (ok) {
            h->callbacks.commit_frame(
                h->callbacks.context,
                slot_index,
                width,
                height,
                out_stride,
                effective_aspect(h, width, height)
            );
        }
        return;
    }

    size_t min_pitch = (size_t)width * (h->pixel_format == RETRO_PIXEL_FORMAT_XRGB8888 ? 4u : 2u);
    if (pitch < min_pitch) return;

    uint32_t out_stride = 0;
    uint32_t slot_index = 0;
    uint32_t *dst = h->callbacks.acquire_frame(h->callbacks.context, width, height, &out_stride, &slot_index);
    if (!dst || out_stride < width * 4u) return;

    uint32_t dst_pixels_per_row = out_stride / 4u;
    if (h->pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
        for (unsigned y = 0; y < height; ++y) {
            const uint32_t *src_row = (const uint32_t *)((const uint8_t *)data + (size_t)y * pitch);
            uint32_t *dst_row = dst + (size_t)y * dst_pixels_per_row;
            for (unsigned x = 0; x < width; ++x) {
                /* XRGB8888 in little-endian memory is [B, G, R, X] -> BGRA8 with A=0xFF. */
                dst_row[x] = src_row[x] | 0xFF000000u;
            }
        }
    } else if (h->pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
        for (unsigned y = 0; y < height; ++y) {
            const uint16_t *src_row = (const uint16_t *)((const uint8_t *)data + (size_t)y * pitch);
            uint32_t *dst_row = dst + (size_t)y * dst_pixels_per_row;
            for (unsigned x = 0; x < width; ++x) {
                uint32_t p = src_row[x];
                uint32_t r = ((p >> 11) & 31u);
                uint32_t g = ((p >> 5) & 63u);
                uint32_t b = (p & 31u);
                r = (r << 3) | (r >> 2);
                g = (g << 2) | (g >> 4);
                b = (b << 3) | (b >> 2);
                dst_row[x] = 0xFF000000u | (r << 16) | (g << 8) | b;
            }
        }
    } else {
        /* 0RGB1555 */
        for (unsigned y = 0; y < height; ++y) {
            const uint16_t *src_row = (const uint16_t *)((const uint8_t *)data + (size_t)y * pitch);
            uint32_t *dst_row = dst + (size_t)y * dst_pixels_per_row;
            for (unsigned x = 0; x < width; ++x) {
                uint32_t p = src_row[x];
                uint32_t r = ((p >> 10) & 31u);
                uint32_t g = ((p >> 5) & 31u);
                uint32_t b = (p & 31u);
                r = (r << 3) | (r >> 2);
                g = (g << 3) | (g >> 2);
                b = (b << 3) | (b >> 2);
                dst_row[x] = 0xFF000000u | (r << 16) | (g << 8) | b;
            }
        }
    }

    h->callbacks.commit_frame(
        h->callbacks.context,
        slot_index,
        width,
        height,
        out_stride,
        effective_aspect(h, width, height)
    );
}

static size_t audio_batch_callback(const int16_t *data, size_t frames) {
    GCRetroHost *h = g_active;
    if (!h || !data || frames == 0) return frames;
    if (h->callbacks.audio_batch) {
        h->callbacks.audio_batch(h->callbacks.context, data, frames);
    }
    return frames;
}

static void audio_sample_callback(int16_t left, int16_t right) {
    int16_t pair[2] = {left, right};
    audio_batch_callback(pair, 1);
}

static void input_poll_callback(void) {
    /* Input snapshot is updated before each retro_run call. */
}

static int16_t clamp_i16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

static int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id) {
    GCRetroHost *h = g_active;
    if (!h || port >= GC_MAX_PLAYERS) return 0;

    unsigned base_device = device & 0xFFu;
    if (base_device == RETRO_DEVICE_JOYPAD) {
        if (index != 0) return 0;
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
            return (int16_t)h->current_input.buttons[port];
        }
        return (id < 16u && ((h->current_input.buttons[port] >> id) & 1u)) ? 1 : 0;
    }

    if (base_device == RETRO_DEVICE_ANALOG) {
        if (index < 2u && id < 2u) {
            return h->current_input.axes[port][index * 2u + id];
        }
        return 0;
    }

    if (base_device == RETRO_DEVICE_POINTER && port == 0 && index == 0) {
        if (id == RETRO_DEVICE_ID_POINTER_X) return h->current_input.pointer_x;
        if (id == RETRO_DEVICE_ID_POINTER_Y) return h->current_input.pointer_y;
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return h->current_input.pointer_pressed ? 1 : 0;
        return 0;
    }

    if (base_device == RETRO_DEVICE_MOUSE && port == 0 && index == 0) {
        switch (id) {
            case RETRO_DEVICE_ID_MOUSE_X: return clamp_i16(h->mouse_dx);
            case RETRO_DEVICE_ID_MOUSE_Y: return clamp_i16(h->mouse_dy);
            case RETRO_DEVICE_ID_MOUSE_LEFT: return (h->current_input.mouse_buttons & 1u) ? 1 : 0;
            case RETRO_DEVICE_ID_MOUSE_RIGHT: return (h->current_input.mouse_buttons & 2u) ? 1 : 0;
            case RETRO_DEVICE_ID_MOUSE_MIDDLE: return (h->current_input.mouse_buttons & 4u) ? 1 : 0;
            case RETRO_DEVICE_ID_MOUSE_WHEELUP: return h->mouse_wheel_y > 0 ? 1 : 0;
            case RETRO_DEVICE_ID_MOUSE_WHEELDOWN: return h->mouse_wheel_y < 0 ? 1 : 0;
            default: return 0;
        }
    }

    return 0;
}

static uint64_t fnv1a_64(const void *data, size_t size) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = 14695981039346656037ULL;
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

const char *gc_host_last_error(void) {
    return g_last_error;
}

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
) {
    if (g_active) {
        set_error("已有核心正在运行");
        return NULL;
    }
    if (!core_path || !rom_path || !system_dir || !save_dir) {
        set_error("缺少核心或游戏路径参数");
        return NULL;
    }

    GCRetroHost *h = calloc(1, sizeof(GCRetroHost));
    if (!h) {
        set_error("内存不足");
        return NULL;
    }
    g_active = h;
    h->callbacks = callbacks;
    h->rom_path = dup_or_null(rom_path);
    h->system_dir = dup_or_null(system_dir);
    h->save_dir = dup_or_null(save_dir);
    h->battery_path = dup_or_null(battery_path);
    h->moltenvk_path = dup_or_null(moltenvk_path);

    for (size_t i = 0; i < initial_option_count; ++i) {
        if (initial_option_keys[i] && initial_option_values[i]) {
            GCOptionEntry *entry = ensure_option(h, initial_option_keys[i]);
            if (entry) {
                free(entry->current_value);
                entry->current_value = dup_or_null(initial_option_values[i]);
            }
        }
    }

    h->handle = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
    if (!h->handle) {
        set_error("无法加载核心动态库：%s", dlerror());
        goto fail;
    }

    const char *required_symbols[] = {
        "retro_init",
        "retro_deinit",
        "retro_run",
        "retro_reset",
        "retro_get_system_info",
        "retro_get_system_av_info",
        "retro_set_environment",
        "retro_set_video_refresh",
        "retro_set_audio_sample",
        "retro_set_audio_sample_batch",
        "retro_set_input_poll",
        "retro_set_input_state",
        "retro_load_game",
        "retro_unload_game",
        "retro_get_memory_data",
        "retro_get_memory_size",
        "retro_api_version",
        "retro_set_controller_port_device"
    };
    void *fn[sizeof(required_symbols) / sizeof(required_symbols[0])];
    for (size_t i = 0; i < sizeof(required_symbols) / sizeof(required_symbols[0]); ++i) {
        fn[i] = dlsym(h->handle, required_symbols[i]);
        if (!fn[i]) {
            set_error("核心缺少符号：%s", required_symbols[i]);
            goto fail;
        }
    }

    if (((unsigned (*)(void))fn[16])() != 1u) {
        set_error("核心 Libretro ABI 版本不兼容");
        goto fail;
    }

    h->retro_init = fn[0];
    h->retro_deinit = fn[1];
    h->retro_run = fn[2];
    h->retro_reset = fn[3];
    h->retro_unload_game = fn[13];
    h->retro_get_memory_data = fn[14];
    h->retro_get_memory_size = fn[15];
    h->retro_set_controller_port_device = fn[17];

    h->retro_serialize_size = dlsym(h->handle, "retro_serialize_size");
    h->retro_serialize = dlsym(h->handle, "retro_serialize");
    h->retro_unserialize = dlsym(h->handle, "retro_unserialize");

    ((void (*)(bool (*)(unsigned, void *)))fn[6])(env_callback);
    ((void (*)(void (*)(const void *, unsigned, unsigned, size_t)))fn[7])(video_callback);
    ((void (*)(void (*)(int16_t, int16_t)))fn[8])(audio_sample_callback);
    ((void (*)(size_t (*)(const int16_t *, size_t)))fn[9])(audio_batch_callback);
    ((void (*)(void (*)(void)))fn[10])(input_poll_callback);
    ((void (*)(int16_t (*)(unsigned, unsigned, unsigned, unsigned)))fn[11])(input_state_callback);

    h->retro_init();
    h->initialized = true;

    struct retro_system_info sys_info = {0};
    ((void (*)(struct retro_system_info *))fn[4])(&sys_info);

    struct retro_game_info game_info = {0};
    game_info.path = h->rom_path;
    if (!sys_info.need_fullpath) {
        FILE *f = fopen(rom_path, "rb");
        if (!f) {
            set_error("无法打开游戏文件：%s", rom_path);
            goto fail;
        }
        if (fseeko(f, 0, SEEK_END) != 0) {
            fclose(f);
            set_error("无法读取游戏文件大小");
            goto fail;
        }
        off_t length = ftello(f);
        rewind(f);
        if (length <= 0 || length > 512LL * 1024 * 1024) {
            fclose(f);
            set_error("游戏文件为空或超过单文件加载限制");
            goto fail;
        }
        h->rom_buffer = malloc((size_t)length);
        if (!h->rom_buffer) {
            fclose(f);
            set_error("内存不足，无法载入游戏文件");
            goto fail;
        }
        size_t read = fread(h->rom_buffer, 1, (size_t)length, f);
        fclose(f);
        if (read != (size_t)length) {
            set_error("读取游戏文件失败");
            goto fail;
        }
        game_info.data = h->rom_buffer;
        game_info.size = read;
    }

    h->loaded = ((bool (*)(const struct retro_game_info *))fn[12])(&game_info);
    if (!h->loaded) {
        if (h->hardware_requested) {
            set_error("该核心请求硬件渲染上下文，尚未在当前阶段启用");
        } else {
            set_error("核心无法加载该游戏，请检查 ROM 格式或 BIOS 文件");
        }
        goto fail;
    }

    /* Configure Port 0 default device per core conventions. */
    if (strstr(core_path, "dolphin") != NULL) {
        /* Wii Classic Controller / GameCube style standard joypad subclass */
        h->retro_set_controller_port_device(0, 0x301);
    } else if (strstr(core_path, "swanstation") != NULL || strstr(core_path, "pcee2") != NULL || strstr(core_path, "pcsx2") != NULL) {
        h->retro_set_controller_port_device(0, RETRO_DEVICE_ANALOG);
    } else {
        h->retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    }

    ((void (*)(struct retro_system_av_info *))fn[5])(&h->av_info);
    if (h->av_info.timing.fps <= 1.0 || h->av_info.timing.fps > 240.0) {
        h->av_info.timing.fps = 60.0;
    }
    if (h->av_info.timing.sample_rate <= 1000.0 || h->av_info.timing.sample_rate > 192000.0) {
        h->av_info.timing.sample_rate = 44100.0;
    }

    /* Bring up Vulkan (via MoltenVK) or OpenGL Core 4.1 HW context if the core requested it. */
    if (h->hw_cb.context_type == RETRO_HW_CONTEXT_VULKAN) {
        char vk_err[256] = {0};
        h->vk_host = gc_vk_create(h->moltenvk_path, h->vk_negotiation, h->hw_cb.bottom_left_origin, vk_err, sizeof(vk_err));
        if (!h->vk_host) {
            set_error("%s", vk_err[0] ? vk_err : "Vulkan 硬件渲染初始化失败");
            goto fail;
        }
        h->hw_context_active = true;
        if (h->hw_cb.context_reset) {
            h->hw_cb.context_reset();
        }
    } else if (h->hw_cb.context_type == RETRO_HW_CONTEXT_OPENGL_CORE || h->hw_cb.context_type == RETRO_HW_CONTEXT_OPENGL) {
        char gl_err[256] = {0};
        h->gl_host = gc_gl_create(
            h->hw_cb.context_type == RETRO_HW_CONTEXT_OPENGL_CORE,
            h->hw_cb.depth,
            h->hw_cb.stencil,
            h->hw_cb.bottom_left_origin,
            h->av_info.geometry.max_width ? h->av_info.geometry.max_width : h->av_info.geometry.base_width,
            h->av_info.geometry.max_height ? h->av_info.geometry.max_height : h->av_info.geometry.base_height,
            gl_err,
            sizeof(gl_err)
        );
        if (!h->gl_host) {
            set_error("%s", gl_err[0] ? gl_err : "OpenGL 硬件渲染初始化失败");
            goto fail;
        }
        h->hw_context_active = true;
        if (h->hw_cb.context_reset) {
            h->hw_cb.context_reset();
        }
    }

    /* Load battery SRAM if present. */
    if (h->battery_path && h->battery_path[0]) {
        void *mem = h->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
        size_t mem_size = h->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
        if (mem && mem_size > 0) {
            FILE *bf = fopen(h->battery_path, "rb");
            if (bf) {
                size_t n = fread(mem, 1, mem_size, bf);
                (void)n;
                fclose(bf);
            }
            h->last_battery_hash = fnv1a_64(mem, mem_size);
            h->has_battery_hash = true;
        }
    }

    return h;

fail:
    if (h->battery_path) h->battery_path[0] = '\0';
    gc_host_close(h);
    return NULL;
}

void gc_host_close(GCRetroHost *h) {
    if (!h) return;
    if (h->hw_context_active && h->hw_cb.context_destroy) {
        if (h->gl_host) gc_gl_make_current(h->gl_host);
        h->hw_cb.context_destroy();
        h->hw_context_active = false;
    }
    if (h->loaded) {
        gc_host_save_battery(h, true);
        if (h->retro_unload_game) h->retro_unload_game();
        h->loaded = false;
    }
    if (h->initialized) {
        if (h->retro_deinit) h->retro_deinit();
        h->initialized = false;
    }
    if (h->vk_host) {
        gc_vk_destroy(h->vk_host);
        h->vk_host = NULL;
    }
    if (h->gl_host) {
        gc_gl_destroy(h->gl_host);
        h->gl_host = NULL;
    }
    if (h->handle) {
        dlclose(h->handle);
        h->handle = NULL;
    }
    for (size_t i = 0; i < h->option_count; ++i) {
        free_option(&h->options[i]);
    }
    free(h->options);
    free(h->rom_buffer);
    free(h->rom_path);
    free(h->system_dir);
    free(h->save_dir);
    free(h->battery_path);
    free(h->moltenvk_path);
    if (g_active == h) g_active = NULL;
    free(h);
}

void gc_host_run_frame(
    GCRetroHost *h,
    const GCSharedInputState *input,
    int32_t mouse_dx,
    int32_t mouse_dy,
    int32_t mouse_wheel_y
) {
    if (!h || !h->loaded || !h->retro_run) return;
    if (h->gl_host) {
        gc_gl_make_current(h->gl_host);
    }
    if (input) {
        h->current_input = *input;
        h->fast_forwarding = input->fast_forward > 1;
    }
    h->mouse_dx = mouse_dx;
    h->mouse_dy = mouse_dy;
    h->mouse_wheel_y = mouse_wheel_y;
    h->retro_run();
}

void gc_host_reset(GCRetroHost *h) {
    if (!h || !h->loaded || !h->retro_reset) return;
    h->retro_reset();
}

double gc_host_fps(const GCRetroHost *h) {
    return h ? h->av_info.timing.fps : 60.0;
}

double gc_host_sample_rate(const GCRetroHost *h) {
    return h ? h->av_info.timing.sample_rate : 44100.0;
}

float gc_host_aspect_ratio(const GCRetroHost *h) {
    if (!h) return 4.0f / 3.0f;
    return effective_aspect(h, h->av_info.geometry.base_width, h->av_info.geometry.base_height);
}

uint32_t gc_host_base_width(const GCRetroHost *h) {
    return h ? h->av_info.geometry.base_width : 0;
}

uint32_t gc_host_base_height(const GCRetroHost *h) {
    return h ? h->av_info.geometry.base_height : 0;
}

bool gc_host_save_battery(GCRetroHost *h, bool force) {
    if (!h || !h->loaded || !h->battery_path || !h->battery_path[0]) return false;
    void *mem = h->retro_get_memory_data ? h->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM) : NULL;
    size_t size = h->retro_get_memory_size ? h->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM) : 0;
    if (!mem || size == 0) return true;

    uint64_t hash = fnv1a_64(mem, size);
    if (!force && h->has_battery_hash && hash == h->last_battery_hash) {
        return true;
    }

    char *tmp_path = NULL;
    if (asprintf(&tmp_path, "%s.tmp", h->battery_path) < 0 || !tmp_path) return false;
    FILE *f = fopen(tmp_path, "wb");
    if (!f) {
        free(tmp_path);
        return false;
    }
    bool ok = fwrite(mem, 1, size, f) == size;
    if (fclose(f) != 0) ok = false;
    if (ok && rename(tmp_path, h->battery_path) == 0) {
        h->last_battery_hash = hash;
        h->has_battery_hash = true;
    } else {
        ok = false;
        remove(tmp_path);
    }
    free(tmp_path);
    return ok;
}

bool gc_host_save_state(GCRetroHost *h, const char *path) {
    if (!h || !h->loaded || !path || !h->retro_serialize_size || !h->retro_serialize) {
        set_error("该核心不支持即时存档");
        return false;
    }
    size_t size = h->retro_serialize_size();
    if (size == 0) {
        set_error("当前状态无法生成即时存档");
        return false;
    }
    void *buf = malloc(size);
    if (!buf) {
        set_error("内存不足，无法保存即时存档");
        return false;
    }
    if (!h->retro_serialize(buf, size)) {
        free(buf);
        set_error("核心序列化状态失败");
        return false;
    }
    char *tmp = NULL;
    if (asprintf(&tmp, "%s.tmp", path) < 0 || !tmp) {
        free(buf);
        set_error("无法创建临时存档路径");
        return false;
    }
    FILE *f = fopen(tmp, "wb");
    if (!f) {
        free(tmp);
        free(buf);
        set_error("无法写入即时存档文件");
        return false;
    }
    bool ok = fwrite(buf, 1, size, f) == size;
    if (fclose(f) != 0) ok = false;
    if (ok && rename(tmp, path) != 0) ok = false;
    if (!ok) {
        remove(tmp);
        set_error("保存即时存档到磁盘失败");
    }
    free(tmp);
    free(buf);
    return ok;
}

bool gc_host_load_state(GCRetroHost *h, const char *path) {
    if (!h || !h->loaded || !path || !h->retro_unserialize) {
        set_error("该核心不支持读取即时存档");
        return false;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        set_error("找不到指定的即时存档文件");
        return false;
    }
    if (fseeko(f, 0, SEEK_END) != 0) {
        fclose(f);
        set_error("无法读取即时存档大小");
        return false;
    }
    off_t length = ftello(f);
    rewind(f);
    if (length <= 0 || length > 256LL * 1024 * 1024) {
        fclose(f);
        set_error("即时存档文件损坏或过大");
        return false;
    }
    void *buf = malloc((size_t)length);
    if (!buf) {
        fclose(f);
        set_error("内存不足，无法读取即时存档");
        return false;
    }
    size_t read = fread(buf, 1, (size_t)length, f);
    fclose(f);
    if (read != (size_t)length) {
        free(buf);
        set_error("读取即时存档失败");
        return false;
    }
    bool ok = h->retro_unserialize(buf, read);
    free(buf);
    if (!ok) {
        set_error("即时存档与当前游戏或核心版本不兼容");
    }
    return ok;
}

size_t gc_host_option_count(const GCRetroHost *h) {
    return h ? h->option_count : 0;
}

bool gc_host_option_at(const GCRetroHost *h, size_t index, GCRetroOptionInfo *out_info) {
    if (!h || !out_info || index >= h->option_count) return false;
    const GCOptionEntry *e = &h->options[index];
    out_info->key = e->key;
    out_info->description = e->description ? e->description : e->key;
    out_info->current_value = e->current_value ? e->current_value : "";
    out_info->default_value = e->default_value ? e->default_value : "";
    out_info->choice_count = e->choice_count;
    return true;
}

bool gc_host_option_choice_at(const GCRetroHost *h, size_t option_index, size_t choice_index, GCRetroOptionChoice *out_choice) {
    if (!h || !out_choice || option_index >= h->option_count) return false;
    const GCOptionEntry *e = &h->options[option_index];
    if (choice_index >= e->choice_count) return false;
    out_choice->value = e->choices[choice_index].value;
    out_choice->label = e->choices[choice_index].label ? e->choices[choice_index].label : e->choices[choice_index].value;
    return true;
}

bool gc_host_set_option(GCRetroHost *h, const char *key, const char *value) {
    if (!h || !key || !value) return false;
    GCOptionEntry *entry = ensure_option(h, key);
    if (!entry) return false;
    if (entry->current_value && strcmp(entry->current_value, value) == 0) {
        return true;
    }
    free(entry->current_value);
    entry->current_value = dup_or_null(value);
    h->options_dirty = true;
    return true;
}
