#ifndef GC_VULKAN_HOST_H
#define GC_VULKAN_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GCVulkanHost GCVulkanHost;

GCVulkanHost *gc_vk_create(
    const char *moltenvk_path,
    const void *negotiation_interface,
    bool bottom_left_origin,
    char *err_buf,
    size_t err_buf_size
);

void gc_vk_destroy(GCVulkanHost *vk);

/* Returns pointer to struct retro_hw_render_interface_vulkan for GET_HW_RENDER_INTERFACE. */
void *gc_vk_get_retro_interface(GCVulkanHost *vk);

/* Copies the latest rendered VkImage submitted via set_image() into a BGRA8 destination buffer. */
bool gc_vk_readback_frame(
    GCVulkanHost *vk,
    uint32_t width,
    uint32_t height,
    uint32_t *dst_bgra,
    uint32_t dst_stride_bytes
);

#ifdef __cplusplus
}
#endif

#endif
