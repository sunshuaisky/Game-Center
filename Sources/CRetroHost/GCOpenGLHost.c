#include "GCOpenGLHost.h"

#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GCOpenGLHost {
    CGLContextObj context;
    GLuint fbo;
    GLuint color_tex;
    GLuint depth_rbo;
    uint32_t fbo_width;
    uint32_t fbo_height;
    bool depth;
    bool stencil;
    bool bottom_left_origin;
    uint32_t *readback_scratch;
    size_t readback_scratch_cap;
};

static void set_gl_err(char *buf, size_t size, const char *fmt, ...) {
    if (!buf || size == 0) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, size, fmt, args);
    va_end(args);
}

static bool ensure_fbo(GCOpenGLHost *gl, uint32_t width, uint32_t height) {
    if (width == 0) width = 640;
    if (height == 0) height = 480;
    if (gl->fbo && gl->fbo_width == width && gl->fbo_height == height) return true;

    CGLSetCurrentContext(gl->context);
    if (!gl->fbo) glGenFramebuffers(1, &gl->fbo);
    if (!gl->color_tex) glGenTextures(1, &gl->color_tex);

    glBindTexture(GL_TEXTURE_2D, gl->color_tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)width, (GLsizei)height, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D, 0);

    glBindFramebuffer(GL_FRAMEBUFFER, gl->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gl->color_tex, 0);

    if (gl->depth || gl->stencil) {
        if (!gl->depth_rbo) glGenRenderbuffers(1, &gl->depth_rbo);
        glBindRenderbuffer(GL_RENDERBUFFER, gl->depth_rbo);
        glRenderbufferStorage(GL_RENDERBUFFER, gl->stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24, (GLsizei)width, (GLsizei)height);
        glFramebufferRenderbuffer(
            GL_FRAMEBUFFER,
            gl->stencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
            GL_RENDERBUFFER,
            gl->depth_rbo
        );
        glBindRenderbuffer(GL_RENDERBUFFER, 0);
    }

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (status != GL_FRAMEBUFFER_COMPLETE) return false;
    gl->fbo_width = width;
    gl->fbo_height = height;
    return true;
}

GCOpenGLHost *gc_gl_create(
    bool core_profile,
    bool depth,
    bool stencil,
    bool bottom_left_origin,
    uint32_t initial_width,
    uint32_t initial_height,
    char *err_buf,
    size_t err_buf_size
) {
    GCOpenGLHost *gl = calloc(1, sizeof(GCOpenGLHost));
    if (!gl) return NULL;
    gl->depth = depth;
    gl->stencil = stencil;
    gl->bottom_left_origin = bottom_left_origin;

    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)(core_profile ? kCGLOGLPVersion_3_2_Core : kCGLOGLPVersion_Legacy),
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
        kCGLPFADepthSize, (CGLPixelFormatAttribute)(depth ? 24 : 0),
        kCGLPFAStencilSize, (CGLPixelFormatAttribute)(stencil ? 8 : 0),
        kCGLPFAAccelerated,
        (CGLPixelFormatAttribute)0
    };

    CGLPixelFormatObj pix = NULL;
    GLint npix = 0;
    CGLError err = CGLChoosePixelFormat(attrs, &pix, &npix);
    if (err != kCGLNoError || !pix) {
        set_gl_err(err_buf, err_buf_size, "无法创建 macOS OpenGL 像素格式 (%d)", (int)err);
        gc_gl_destroy(gl);
        return NULL;
    }

    err = CGLCreateContext(pix, NULL, &gl->context);
    CGLDestroyPixelFormat(pix);
    if (err != kCGLNoError || !gl->context) {
        set_gl_err(err_buf, err_buf_size, "无法创建 macOS OpenGL 上下文 (%d)", (int)err);
        gc_gl_destroy(gl);
        return NULL;
    }

    CGLSetCurrentContext(gl->context);
    if (!ensure_fbo(gl, initial_width ? initial_width : 1280, initial_height ? initial_height : 720)) {
        set_gl_err(err_buf, err_buf_size, "无法初始化 OpenGL 离屏帧缓冲");
        gc_gl_destroy(gl);
        return NULL;
    }
    return gl;
}

void gc_gl_destroy(GCOpenGLHost *gl) {
    if (!gl) return;
    if (gl->context) {
        CGLSetCurrentContext(gl->context);
        if (gl->depth_rbo) glDeleteRenderbuffers(1, &gl->depth_rbo);
        if (gl->color_tex) glDeleteTextures(1, &gl->color_tex);
        if (gl->fbo) glDeleteFramebuffers(1, &gl->fbo);
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(gl->context);
    }
    free(gl->readback_scratch);
    free(gl);
}

void gc_gl_make_current(GCOpenGLHost *gl) {
    if (gl && gl->context) {
        CGLSetCurrentContext(gl->context);
    }
}

uintptr_t gc_gl_current_framebuffer(GCOpenGLHost *gl) {
    return gl ? (uintptr_t)gl->fbo : 0;
}

void *gc_gl_get_proc_address(const char *symbol) {
    if (!symbol) return NULL;
    static void *gl_framework = NULL;
    if (!gl_framework) {
        gl_framework = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    }
    void *fn = gl_framework ? dlsym(gl_framework, symbol) : NULL;
    return fn ? fn : dlsym(RTLD_DEFAULT, symbol);
}

bool gc_gl_readback_frame(
    GCOpenGLHost *gl,
    uint32_t width,
    uint32_t height,
    uint32_t *dst_bgra,
    uint32_t dst_stride_bytes
) {
    if (!gl || !gl->context || !dst_bgra || width == 0 || height == 0) return false;
    CGLSetCurrentContext(gl->context);
    if (width > gl->fbo_width || height > gl->fbo_height) {
        ensure_fbo(gl, width, height);
    }

    size_t needed = (size_t)width * (size_t)height;
    if (needed > gl->readback_scratch_cap) {
        uint32_t *grown = realloc(gl->readback_scratch, needed * sizeof(uint32_t));
        if (!grown) return false;
        gl->readback_scratch = grown;
        gl->readback_scratch_cap = needed;
    }

    GLint prev_fbo = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_fbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, gl->fbo);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, gl->readback_scratch);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_fbo);

    uint32_t dst_stride_px = dst_stride_bytes / 4u;
    for (uint32_t y = 0; y < height; ++y) {
        uint32_t src_y = gl->bottom_left_origin ? (height - 1u - y) : y;
        const uint32_t *srow = gl->readback_scratch + (size_t)src_y * width;
        uint32_t *drow = dst_bgra + (size_t)y * dst_stride_px;
        for (uint32_t x = 0; x < width; ++x) {
            drow[x] = srow[x] | 0xFF000000u;
        }
    }
    return true;
}
