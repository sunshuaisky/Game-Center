#ifndef GC_OPENGL_HOST_H
#define GC_OPENGL_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GCOpenGLHost GCOpenGLHost;

GCOpenGLHost *gc_gl_create(
    bool core_profile,
    bool depth,
    bool stencil,
    bool bottom_left_origin,
    uint32_t initial_width,
    uint32_t initial_height,
    char *err_buf,
    size_t err_buf_size
);

void gc_gl_destroy(GCOpenGLHost *gl);
void gc_gl_make_current(GCOpenGLHost *gl);
uintptr_t gc_gl_current_framebuffer(GCOpenGLHost *gl);
void *gc_gl_get_proc_address(const char *symbol);

bool gc_gl_readback_frame(
    GCOpenGLHost *gl,
    uint32_t width,
    uint32_t height,
    uint32_t *dst_bgra,
    uint32_t dst_stride_bytes
);

#ifdef __cplusplus
}
#endif

#endif
