#ifndef GC_MOBILE_RETRO_VULKAN_HOST_H
#define GC_MOBILE_RETRO_VULKAN_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct GCRetroVulkanHost GCRetroVulkanHost;

GCRetroVulkanHost *gc_ios_vk_create(
    const char *moltenvk_path,
    const void *negotiation_interface,
    bool bottom_left_origin,
    char *err_buf,
    size_t err_buf_size
);

void gc_ios_vk_destroy(GCRetroVulkanHost *vk);
void *gc_ios_vk_get_retro_interface(GCRetroVulkanHost *vk);

bool gc_ios_vk_readback_frame(
    GCRetroVulkanHost *vk,
    uint32_t width,
    uint32_t height,
    uint32_t *dst_bgra,
    uint32_t dst_stride_bytes
);

#endif
