#include "GCVulkanHost.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* =========================================================================
 * Minimal Vulkan 1.1+ ABI definitions (64-bit macOS / MoltenVK)
 * ========================================================================= */
typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef uint64_t VkDeviceSize;
typedef int32_t VkResult;
typedef uint32_t VkStructureType;
typedef uint32_t VkFormat;
typedef uint32_t VkImageLayout;
typedef uint32_t VkImageViewType;
typedef uint32_t VkComponentSwizzle;
typedef uint32_t VkImageAspectFlags;
typedef uint32_t VkImageType;
typedef uint32_t VkImageTiling;
typedef uint32_t VkImageUsageFlags;
typedef uint32_t VkSharingMode;
typedef uint32_t VkSampleCountFlagBits;
typedef uint32_t VkBufferUsageFlags;
typedef uint32_t VkMemoryPropertyFlags;
typedef uint32_t VkPipelineStageFlags;
typedef uint32_t VkAccessFlags;
typedef uint32_t VkFilter;
typedef uint32_t VkCommandBufferLevel;

typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef struct VkDevice_T *VkDevice;
typedef struct VkQueue_T *VkQueue;
typedef struct VkCommandBuffer_T *VkCommandBuffer;

typedef uint64_t VkSurfaceKHR;
typedef uint64_t VkImage;
typedef uint64_t VkImageView;
typedef uint64_t VkBuffer;
typedef uint64_t VkDeviceMemory;
typedef uint64_t VkCommandPool;
typedef uint64_t VkFence;
typedef uint64_t VkSemaphore;

typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char *);
typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(VkDevice, const char *);

#define VK_SUCCESS 0
#define VK_NULL_HANDLE 0
#define VK_TRUE 1
#define VK_FALSE 0
#define VK_QUEUE_FAMILY_IGNORED (~0U)
#define VK_WHOLE_SIZE (~0ULL)
#define VK_API_VERSION_1_1 ((1U << 22) | (1U << 12))
#define VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR 0x00000001u

#define VK_STRUCTURE_TYPE_APPLICATION_INFO 0
#define VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO 1
#define VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO 2
#define VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO 3
#define VK_STRUCTURE_TYPE_SUBMIT_INFO 4
#define VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO 5
#define VK_STRUCTURE_TYPE_FENCE_CREATE_INFO 8
#define VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO 12
#define VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO 14
#define VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO 39
#define VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO 40
#define VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO 42
#define VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER 45

#define VK_FORMAT_B8G8R8A8_UNORM 44
#define VK_FORMAT_B8G8R8A8_SRGB 50

#define VK_IMAGE_TYPE_2D 1
#define VK_IMAGE_TILING_OPTIMAL 0
#define VK_IMAGE_USAGE_TRANSFER_SRC_BIT 0x00000001u
#define VK_IMAGE_USAGE_TRANSFER_DST_BIT 0x00000002u
#define VK_BUFFER_USAGE_TRANSFER_DST_BIT 0x00000002u
#define VK_SHARING_MODE_EXCLUSIVE 0
#define VK_SAMPLE_COUNT_1_BIT 1

#define VK_IMAGE_LAYOUT_UNDEFINED 0
#define VK_IMAGE_LAYOUT_GENERAL 1
#define VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL 6
#define VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 7

#define VK_IMAGE_ASPECT_COLOR_BIT 0x00000001u
#define VK_FILTER_NEAREST 0

#define VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT 0x00000001u
#define VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT 0x00000002u
#define VK_MEMORY_PROPERTY_HOST_COHERENT_BIT 0x00000004u

#define VK_QUEUE_GRAPHICS_BIT 0x00000001u
#define VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT 0x00000002u
#define VK_COMMAND_BUFFER_LEVEL_PRIMARY 0
#define VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT 0x00000001u
#define VK_FENCE_CREATE_SIGNALED_BIT 0x00000001u

#define VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT 0x00000001u
#define VK_PIPELINE_STAGE_TRANSFER_BIT 0x00001000u
#define VK_PIPELINE_STAGE_ALL_COMMANDS_BIT 0x00010000u
#define VK_ACCESS_TRANSFER_READ_BIT 0x00000800u
#define VK_ACCESS_TRANSFER_WRITE_BIT 0x00001000u
#define VK_ACCESS_MEMORY_READ_BIT 0x00008000u
#define VK_ACCESS_MEMORY_WRITE_BIT 0x00010000u

typedef struct VkExtent3D { uint32_t width, height, depth; } VkExtent3D;
typedef struct VkOffset3D { int32_t x, y, z; } VkOffset3D;
typedef struct VkComponentMapping { VkComponentSwizzle r, g, b, a; } VkComponentMapping;
typedef struct VkImageSubresourceRange {
    VkImageAspectFlags aspectMask;
    uint32_t baseMipLevel, levelCount, baseArrayLayer, layerCount;
} VkImageSubresourceRange;
typedef struct VkImageSubresourceLayers {
    VkImageAspectFlags aspectMask;
    uint32_t mipLevel, baseArrayLayer, layerCount;
} VkImageSubresourceLayers;

typedef struct VkImageViewCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    VkImage image;
    VkImageViewType viewType;
    VkFormat format;
    VkComponentMapping components;
    VkImageSubresourceRange subresourceRange;
} VkImageViewCreateInfo;

typedef struct VkApplicationInfo {
    VkStructureType sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} VkApplicationInfo;

typedef struct VkInstanceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct VkDeviceQueueCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    uint32_t queueFamilyIndex;
    uint32_t queueCount;
    const float *pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct VkPhysicalDeviceFeatures {
    VkBool32 features[55];
} VkPhysicalDeviceFeatures;

typedef struct VkDeviceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    uint32_t queueCreateInfoCount;
    const VkDeviceQueueCreateInfo *pQueueCreateInfos;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
    const VkPhysicalDeviceFeatures *pEnabledFeatures;
} VkDeviceCreateInfo;

typedef struct VkQueueFamilyProperties {
    VkFlags queueFlags;
    uint32_t queueCount;
    uint32_t timestampValidBits;
    VkExtent3D minImageTransferGranularity;
} VkQueueFamilyProperties;

typedef struct VkExtensionProperties {
    char extensionName[256];
    uint32_t specVersion;
} VkExtensionProperties;

typedef struct VkMemoryType { VkMemoryPropertyFlags propertyFlags; uint32_t heapIndex; } VkMemoryType;
typedef struct VkMemoryHeap { VkDeviceSize size; VkFlags flags; } VkMemoryHeap;
typedef struct VkPhysicalDeviceMemoryProperties {
    uint32_t memoryTypeCount;
    VkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount;
    VkMemoryHeap memoryHeaps[16];
} VkPhysicalDeviceMemoryProperties;

typedef struct VkMemoryRequirements {
    VkDeviceSize size;
    VkDeviceSize alignment;
    uint32_t memoryTypeBits;
} VkMemoryRequirements;

typedef struct VkMemoryAllocateInfo {
    VkStructureType sType;
    const void *pNext;
    VkDeviceSize allocationSize;
    uint32_t memoryTypeIndex;
} VkMemoryAllocateInfo;

typedef struct VkCommandPoolCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    uint32_t queueFamilyIndex;
} VkCommandPoolCreateInfo;

typedef struct VkCommandBufferAllocateInfo {
    VkStructureType sType;
    const void *pNext;
    VkCommandPool commandPool;
    VkCommandBufferLevel level;
    uint32_t commandBufferCount;
} VkCommandBufferAllocateInfo;

typedef struct VkCommandBufferBeginInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    const void *pInheritanceInfo;
} VkCommandBufferBeginInfo;

typedef struct VkFenceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
} VkFenceCreateInfo;

typedef struct VkImageCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    VkImageType imageType;
    VkFormat format;
    VkExtent3D extent;
    uint32_t mipLevels;
    uint32_t arrayLayers;
    VkSampleCountFlagBits samples;
    VkImageTiling tiling;
    VkImageUsageFlags usage;
    VkSharingMode sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
    VkImageLayout initialLayout;
} VkImageCreateInfo;

typedef struct VkBufferCreateInfo {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    VkDeviceSize size;
    VkBufferUsageFlags usage;
    VkSharingMode sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
} VkBufferCreateInfo;

typedef struct VkImageMemoryBarrier {
    VkStructureType sType;
    const void *pNext;
    VkAccessFlags srcAccessMask;
    VkAccessFlags dstAccessMask;
    VkImageLayout oldLayout;
    VkImageLayout newLayout;
    uint32_t srcQueueFamilyIndex;
    uint32_t dstQueueFamilyIndex;
    VkImage image;
    VkImageSubresourceRange subresourceRange;
} VkImageMemoryBarrier;

typedef struct VkImageBlit {
    VkImageSubresourceLayers srcSubresource;
    VkOffset3D srcOffsets[2];
    VkImageSubresourceLayers dstSubresource;
    VkOffset3D dstOffsets[2];
} VkImageBlit;

typedef struct VkBufferImageCopy {
    VkDeviceSize bufferOffset;
    uint32_t bufferRowLength;
    uint32_t bufferImageHeight;
    VkImageSubresourceLayers imageSubresource;
    VkOffset3D imageOffset;
    VkExtent3D imageExtent;
} VkBufferImageCopy;

typedef struct VkSubmitInfo {
    VkStructureType sType;
    const void *pNext;
    uint32_t waitSemaphoreCount;
    const VkSemaphore *pWaitSemaphores;
    const VkPipelineStageFlags *pWaitDstStageMask;
    uint32_t commandBufferCount;
    const VkCommandBuffer *pCommandBuffers;
    uint32_t signalSemaphoreCount;
    const VkSemaphore *pSignalSemaphores;
} VkSubmitInfo;

/* =========================================================================
 * Libretro Vulkan HW Render ABI
 * ========================================================================= */
#define RETRO_HW_RENDER_INTERFACE_VULKAN 0
#define RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION 5
#define RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN 0

struct retro_vulkan_image {
    VkImageView image_view;
    VkImageLayout image_layout;
    VkImageViewCreateInfo create_info;
};

struct retro_vulkan_context {
    VkPhysicalDevice gpu;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family_index;
    VkQueue presentation_queue;
    uint32_t presentation_queue_family_index;
};

typedef VkInstance (*retro_vulkan_create_instance_wrapper_t)(void *opaque, const VkInstanceCreateInfo *create_info);
typedef VkDevice (*retro_vulkan_create_device_wrapper_t)(VkPhysicalDevice gpu, void *opaque, const VkDeviceCreateInfo *create_info);

struct retro_hw_render_context_negotiation_interface_vulkan {
    int interface_type;
    unsigned interface_version;
    const VkApplicationInfo *(*get_application_info)(void);
    bool (*create_device)(
        struct retro_vulkan_context *context,
        VkInstance instance,
        VkPhysicalDevice gpu,
        VkSurfaceKHR surface,
        PFN_vkGetInstanceProcAddr get_instance_proc_addr,
        const char **required_device_extensions,
        unsigned num_required_device_extensions,
        const char **required_device_layers,
        unsigned num_required_device_layers,
        const VkPhysicalDeviceFeatures *required_features
    );
    void (*destroy_device)(void);
    VkInstance (*create_instance)(
        PFN_vkGetInstanceProcAddr get_instance_proc_addr,
        const VkApplicationInfo *app,
        retro_vulkan_create_instance_wrapper_t create_instance_wrapper,
        void *opaque
    );
    bool (*create_device2)(
        struct retro_vulkan_context *context,
        VkInstance instance,
        VkPhysicalDevice gpu,
        VkSurfaceKHR surface,
        PFN_vkGetInstanceProcAddr get_instance_proc_addr,
        retro_vulkan_create_device_wrapper_t create_device_wrapper,
        void *opaque
    );
};

struct retro_hw_render_interface_vulkan {
    int interface_type;
    unsigned interface_version;
    void *handle;
    VkInstance instance;
    VkPhysicalDevice gpu;
    VkDevice device;
    PFN_vkGetDeviceProcAddr get_device_proc_addr;
    PFN_vkGetInstanceProcAddr get_instance_proc_addr;
    VkQueue queue;
    unsigned queue_index;
    void (*set_image)(void *handle, const struct retro_vulkan_image *image, uint32_t num_semaphores, const VkSemaphore *semaphores, uint32_t src_queue_family);
    uint32_t (*get_sync_index)(void *handle);
    uint32_t (*get_sync_index_mask)(void *handle);
    void (*set_command_buffers)(void *handle, uint32_t num_cmd, const VkCommandBuffer *cmd);
    void (*wait_sync_index)(void *handle);
    void (*lock_queue)(void *handle);
    void (*unlock_queue)(void *handle);
    void (*set_signal_semaphore)(void *handle, VkSemaphore semaphore);
};

#define GC_VK_SYNC_COUNT 2
#define GC_VK_MAX_PENDING_CMDS 64
#define GC_VK_MAX_WAIT_SEMS 16

struct GCVulkanHost {
    void *dl_handle;
    PFN_vkGetInstanceProcAddr get_inst_proc;
    PFN_vkGetDeviceProcAddr get_dev_proc;

    VkInstance instance;
    VkPhysicalDevice gpu;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family_index;
    bool core_owns_device;
    void (*core_destroy_device)(void);
    bool bottom_left_origin;

    pthread_mutex_t queue_mutex;
    VkCommandPool cmd_pool;
    VkCommandBuffer copy_cmds[GC_VK_SYNC_COUNT];
    VkFence fences[GC_VK_SYNC_COUNT];
    uint32_t sync_index;

    /* Core-submitted per-frame state */
    bool has_image;
    struct retro_vulkan_image current_image;
    VkSemaphore wait_sems[GC_VK_MAX_WAIT_SEMS];
    uint32_t wait_sem_count;
    VkCommandBuffer pending_cmds[GC_VK_MAX_PENDING_CMDS];
    uint32_t pending_cmd_count;
    VkSemaphore signal_sem;

    /* Blit target + persistently mapped staging buffer */
    uint32_t staging_width;
    uint32_t staging_height;
    VkImage blit_image;
    VkDeviceMemory blit_memory;
    VkBuffer staging_buffer;
    VkDeviceMemory staging_memory;
    void *staging_mapped;

    /* Loaded Vulkan functions */
    VkResult (*vkCreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
    void (*vkDestroyInstance)(VkInstance, const void *);
    VkResult (*vkEnumerateInstanceExtensionProperties)(const char *, uint32_t *, VkExtensionProperties *);
    VkResult (*vkEnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
    void (*vkGetPhysicalDeviceQueueFamilyProperties)(VkPhysicalDevice, uint32_t *, VkQueueFamilyProperties *);
    void (*vkGetPhysicalDeviceMemoryProperties)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties *);
    VkResult (*vkEnumerateDeviceExtensionProperties)(VkPhysicalDevice, const char *, uint32_t *, VkExtensionProperties *);
    VkResult (*vkCreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo *, const void *, VkDevice *);
    void (*vkDestroyDevice)(VkDevice, const void *);
    void (*vkGetDeviceQueue)(VkDevice, uint32_t, uint32_t, VkQueue *);
    VkResult (*vkDeviceWaitIdle)(VkDevice);
    VkResult (*vkCreateCommandPool)(VkDevice, const VkCommandPoolCreateInfo *, const void *, VkCommandPool *);
    void (*vkDestroyCommandPool)(VkDevice, VkCommandPool, const void *);
    VkResult (*vkAllocateCommandBuffers)(VkDevice, const VkCommandBufferAllocateInfo *, VkCommandBuffer *);
    VkResult (*vkResetCommandBuffer)(VkCommandBuffer, VkFlags);
    VkResult (*vkBeginCommandBuffer)(VkCommandBuffer, const VkCommandBufferBeginInfo *);
    VkResult (*vkEndCommandBuffer)(VkCommandBuffer);
    VkResult (*vkCreateFence)(VkDevice, const VkFenceCreateInfo *, const void *, VkFence *);
    void (*vkDestroyFence)(VkDevice, VkFence, const void *);
    VkResult (*vkWaitForFences)(VkDevice, uint32_t, const VkFence *, VkBool32, uint64_t);
    VkResult (*vkResetFences)(VkDevice, uint32_t, const VkFence *);
    VkResult (*vkQueueSubmit)(VkQueue, uint32_t, const VkSubmitInfo *, VkFence);
    VkResult (*vkCreateImage)(VkDevice, const VkImageCreateInfo *, const void *, VkImage *);
    void (*vkDestroyImage)(VkDevice, VkImage, const void *);
    void (*vkGetImageMemoryRequirements)(VkDevice, VkImage, VkMemoryRequirements *);
    VkResult (*vkBindImageMemory)(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
    VkResult (*vkCreateBuffer)(VkDevice, const VkBufferCreateInfo *, const void *, VkBuffer *);
    void (*vkDestroyBuffer)(VkDevice, VkBuffer, const void *);
    void (*vkGetBufferMemoryRequirements)(VkDevice, VkBuffer, VkMemoryRequirements *);
    VkResult (*vkBindBufferMemory)(VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize);
    VkResult (*vkAllocateMemory)(VkDevice, const VkMemoryAllocateInfo *, const void *, VkDeviceMemory *);
    void (*vkFreeMemory)(VkDevice, VkDeviceMemory, const void *);
    VkResult (*vkMapMemory)(VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, void **);
    void (*vkUnmapMemory)(VkDevice, VkDeviceMemory);
    void (*vkCmdPipelineBarrier)(VkCommandBuffer, VkPipelineStageFlags, VkPipelineStageFlags, VkFlags, uint32_t, const void *, uint32_t, const void *, uint32_t, const VkImageMemoryBarrier *);
    void (*vkCmdBlitImage)(VkCommandBuffer, VkImage, VkImageLayout, VkImage, VkImageLayout, uint32_t, const VkImageBlit *, VkFilter);
    void (*vkCmdCopyImageToBuffer)(VkCommandBuffer, VkImage, VkImageLayout, VkBuffer, uint32_t, const VkBufferImageCopy *);

    struct retro_hw_render_interface_vulkan retro_iface;
};

static void set_vk_err(char *buf, size_t size, const char *fmt, ...) {
    if (!buf || size == 0) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, size, fmt, args);
    va_end(args);
}

static bool has_instance_ext(GCVulkanHost *vk, const char *name) {
    if (!vk->vkEnumerateInstanceExtensionProperties) return false;
    uint32_t count = 0;
    vk->vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);
    if (count == 0) return false;
    VkExtensionProperties *exts = calloc(count, sizeof(*exts));
    if (!exts) return false;
    vk->vkEnumerateInstanceExtensionProperties(NULL, &count, exts);
    bool found = false;
    for (uint32_t i = 0; i < count; ++i) {
        if (strcmp(exts[i].extensionName, name) == 0) { found = true; break; }
    }
    free(exts);
    return found;
}

static bool has_device_ext(GCVulkanHost *vk, VkPhysicalDevice gpu, const char *name) {
    if (!vk->vkEnumerateDeviceExtensionProperties) return false;
    uint32_t count = 0;
    vk->vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, NULL);
    if (count == 0) return false;
    VkExtensionProperties *exts = calloc(count, sizeof(*exts));
    if (!exts) return false;
    vk->vkEnumerateDeviceExtensionProperties(gpu, NULL, &count, exts);
    bool found = false;
    for (uint32_t i = 0; i < count; ++i) {
        if (strcmp(exts[i].extensionName, name) == 0) { found = true; break; }
    }
    free(exts);
    return found;
}

static VkInstance create_instance_wrapper(void *opaque, const VkInstanceCreateInfo *in_info) {
    GCVulkanHost *vk = (GCVulkanHost *)opaque;
    VkInstanceCreateInfo info = *in_info;
    bool need_portability = has_instance_ext(vk, "VK_KHR_portability_enumeration");
    bool already_has = false;
    for (uint32_t i = 0; i < info.enabledExtensionCount; ++i) {
        if (strcmp(info.ppEnabledExtensionNames[i], "VK_KHR_portability_enumeration") == 0) {
            already_has = true;
            break;
        }
    }
    const char **exts = NULL;
    if (need_portability && !already_has) {
        exts = calloc(info.enabledExtensionCount + 1, sizeof(const char *));
        if (exts) {
            for (uint32_t i = 0; i < info.enabledExtensionCount; ++i) exts[i] = info.ppEnabledExtensionNames[i];
            exts[info.enabledExtensionCount] = "VK_KHR_portability_enumeration";
            info.ppEnabledExtensionNames = exts;
            info.enabledExtensionCount += 1;
            info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }
    } else if (need_portability) {
        info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    VkInstance instance = NULL;
    VkResult res = vk->vkCreateInstance(&info, NULL, &instance);
    free(exts);
    return (res == VK_SUCCESS) ? instance : NULL;
}

static VkDevice create_device_wrapper(VkPhysicalDevice gpu, void *opaque, const VkDeviceCreateInfo *in_info) {
    GCVulkanHost *vk = (GCVulkanHost *)opaque;
    VkDeviceCreateInfo info = *in_info;
    bool need_subset = has_device_ext(vk, gpu, "VK_KHR_portability_subset");
    bool already_has = false;
    for (uint32_t i = 0; i < info.enabledExtensionCount; ++i) {
        if (strcmp(info.ppEnabledExtensionNames[i], "VK_KHR_portability_subset") == 0) {
            already_has = true;
            break;
        }
    }
    const char **exts = NULL;
    if (need_subset && !already_has) {
        exts = calloc(info.enabledExtensionCount + 1, sizeof(const char *));
        if (exts) {
            for (uint32_t i = 0; i < info.enabledExtensionCount; ++i) exts[i] = info.ppEnabledExtensionNames[i];
            exts[info.enabledExtensionCount] = "VK_KHR_portability_subset";
            info.ppEnabledExtensionNames = exts;
            info.enabledExtensionCount += 1;
        }
    }
    VkDevice device = NULL;
    VkResult res = vk->vkCreateDevice(gpu, &info, NULL, &device);
    free(exts);
    return (res == VK_SUCCESS) ? device : NULL;
}

static uint32_t find_memory_type(GCVulkanHost *vk, uint32_t type_bits, VkMemoryPropertyFlags required) {
    VkPhysicalDeviceMemoryProperties props;
    memset(&props, 0, sizeof(props));
    vk->vkGetPhysicalDeviceMemoryProperties(vk->gpu, &props);
    for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
        if ((type_bits & (1u << i)) && ((props.memoryTypes[i].propertyFlags & required) == required)) {
            return i;
        }
    }
    return UINT32_MAX;
}

/* --- Libretro Vulkan interface callbacks --- */
static void retro_vk_set_image(
    void *handle,
    const struct retro_vulkan_image *image,
    uint32_t num_semaphores,
    const VkSemaphore *semaphores,
    uint32_t src_queue_family
) {
    (void)src_queue_family;
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    if (!vk) return;
    if (!image) {
        vk->has_image = false;
        vk->wait_sem_count = 0;
        return;
    }
    vk->current_image = *image;
    vk->has_image = true;
    uint32_t count = num_semaphores > GC_VK_MAX_WAIT_SEMS ? GC_VK_MAX_WAIT_SEMS : num_semaphores;
    vk->wait_sem_count = count;
    if (count > 0 && semaphores) {
        memcpy(vk->wait_sems, semaphores, count * sizeof(VkSemaphore));
    }
}

static uint32_t retro_vk_get_sync_index(void *handle) {
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    return vk ? vk->sync_index : 0;
}

static uint32_t retro_vk_get_sync_index_mask(void *handle) {
    (void)handle;
    return (1u << GC_VK_SYNC_COUNT) - 1u;
}

static void retro_vk_set_command_buffers(void *handle, uint32_t num_cmd, const VkCommandBuffer *cmd) {
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    if (!vk) return;
    uint32_t count = num_cmd > GC_VK_MAX_PENDING_CMDS ? GC_VK_MAX_PENDING_CMDS : num_cmd;
    vk->pending_cmd_count = count;
    if (count > 0 && cmd) {
        memcpy(vk->pending_cmds, cmd, count * sizeof(VkCommandBuffer));
    }
}

static void retro_vk_wait_sync_index(void *handle) {
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    if (!vk || !vk->vkWaitForFences) return;
    VkFence fence = vk->fences[vk->sync_index];
    if (fence) {
        vk->vkWaitForFences(vk->device, 1, &fence, VK_TRUE, UINT64_MAX);
    }
}

static void retro_vk_lock_queue(void *handle) {
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    if (vk) pthread_mutex_lock(&vk->queue_mutex);
}

static void retro_vk_unlock_queue(void *handle) {
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    if (vk) pthread_mutex_unlock(&vk->queue_mutex);
}

static void retro_vk_set_signal_semaphore(void *handle, VkSemaphore semaphore) {
    GCVulkanHost *vk = (GCVulkanHost *)handle;
    if (vk) vk->signal_sem = semaphore;
}

static void destroy_staging(GCVulkanHost *vk) {
    if (!vk || !vk->device) return;
    if (vk->staging_mapped && vk->staging_memory && vk->vkUnmapMemory) {
        vk->vkUnmapMemory(vk->device, vk->staging_memory);
        vk->staging_mapped = NULL;
    }
    if (vk->staging_buffer && vk->vkDestroyBuffer) {
        vk->vkDestroyBuffer(vk->device, vk->staging_buffer, NULL);
        vk->staging_buffer = VK_NULL_HANDLE;
    }
    if (vk->staging_memory && vk->vkFreeMemory) {
        vk->vkFreeMemory(vk->device, vk->staging_memory, NULL);
        vk->staging_memory = VK_NULL_HANDLE;
    }
    if (vk->blit_image && vk->vkDestroyImage) {
        vk->vkDestroyImage(vk->device, vk->blit_image, NULL);
        vk->blit_image = VK_NULL_HANDLE;
    }
    if (vk->blit_memory && vk->vkFreeMemory) {
        vk->vkFreeMemory(vk->device, vk->blit_memory, NULL);
        vk->blit_memory = VK_NULL_HANDLE;
    }
    vk->staging_width = 0;
    vk->staging_height = 0;
}

static bool ensure_staging(GCVulkanHost *vk, uint32_t width, uint32_t height) {
    if (vk->staging_width == width && vk->staging_height == height && vk->staging_mapped && vk->blit_image) {
        return true;
    }
    if (vk->vkDeviceWaitIdle) vk->vkDeviceWaitIdle(vk->device);
    destroy_staging(vk);

    VkImageCreateInfo img_info;
    memset(&img_info, 0, sizeof(img_info));
    img_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    img_info.imageType = VK_IMAGE_TYPE_2D;
    img_info.format = VK_FORMAT_B8G8R8A8_UNORM;
    img_info.extent.width = width;
    img_info.extent.height = height;
    img_info.extent.depth = 1;
    img_info.mipLevels = 1;
    img_info.arrayLayers = 1;
    img_info.samples = VK_SAMPLE_COUNT_1_BIT;
    img_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    img_info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    img_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    img_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    if (vk->vkCreateImage(vk->device, &img_info, NULL, &vk->blit_image) != VK_SUCCESS) return false;
    VkMemoryRequirements img_req;
    vk->vkGetImageMemoryRequirements(vk->device, vk->blit_image, &img_req);
    uint32_t img_mem_type = find_memory_type(vk, img_req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (img_mem_type == UINT32_MAX) { destroy_staging(vk); return false; }

    VkMemoryAllocateInfo img_alloc = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, img_req.size, img_mem_type };
    if (vk->vkAllocateMemory(vk->device, &img_alloc, NULL, &vk->blit_memory) != VK_SUCCESS) { destroy_staging(vk); return false; }
    if (vk->vkBindImageMemory(vk->device, vk->blit_image, vk->blit_memory, 0) != VK_SUCCESS) { destroy_staging(vk); return false; }

    VkDeviceSize buf_size = (VkDeviceSize)width * (VkDeviceSize)height * 4ULL;
    VkBufferCreateInfo buf_info;
    memset(&buf_info, 0, sizeof(buf_info));
    buf_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buf_info.size = buf_size;
    buf_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    buf_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    if (vk->vkCreateBuffer(vk->device, &buf_info, NULL, &vk->staging_buffer) != VK_SUCCESS) { destroy_staging(vk); return false; }
    VkMemoryRequirements buf_req;
    vk->vkGetBufferMemoryRequirements(vk->device, vk->staging_buffer, &buf_req);
    uint32_t buf_mem_type = find_memory_type(vk, buf_req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (buf_mem_type == UINT32_MAX) { destroy_staging(vk); return false; }

    VkMemoryAllocateInfo buf_alloc = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, buf_req.size, buf_mem_type };
    if (vk->vkAllocateMemory(vk->device, &buf_alloc, NULL, &vk->staging_memory) != VK_SUCCESS) { destroy_staging(vk); return false; }
    if (vk->vkBindBufferMemory(vk->device, vk->staging_buffer, vk->staging_memory, 0) != VK_SUCCESS) { destroy_staging(vk); return false; }
    if (vk->vkMapMemory(vk->device, vk->staging_memory, 0, buf_size, 0, &vk->staging_mapped) != VK_SUCCESS) { destroy_staging(vk); return false; }

    vk->staging_width = width;
    vk->staging_height = height;
    return true;
}

#define LOAD_INST(field, name) do { vk->field = (void *)vk->get_inst_proc(vk->instance, name); } while (0)
#define LOAD_DEV(field, name) do { vk->field = (void *)vk->get_dev_proc(vk->device, name); } while (0)

GCVulkanHost *gc_vk_create(
    const char *moltenvk_path,
    const void *negotiation_interface,
    bool bottom_left_origin,
    char *err_buf,
    size_t err_buf_size
) {
    if (!moltenvk_path || !moltenvk_path[0]) {
        set_vk_err(err_buf, err_buf_size, "缺少 libMoltenVK.dylib，无法初始化 Vulkan 硬件渲染");
        return NULL;
    }

    GCVulkanHost *vk = calloc(1, sizeof(GCVulkanHost));
    if (!vk) return NULL;
    pthread_mutex_init(&vk->queue_mutex, NULL);
    vk->bottom_left_origin = bottom_left_origin;

    vk->dl_handle = dlopen(moltenvk_path, RTLD_NOW | RTLD_LOCAL);
    if (!vk->dl_handle) {
        set_vk_err(err_buf, err_buf_size, "无法加载 MoltenVK：%s", dlerror());
        gc_vk_destroy(vk);
        return NULL;
    }
    vk->get_inst_proc = (PFN_vkGetInstanceProcAddr)dlsym(vk->dl_handle, "vkGetInstanceProcAddr");
    vk->get_dev_proc = (PFN_vkGetDeviceProcAddr)dlsym(vk->dl_handle, "vkGetDeviceProcAddr");
    if (!vk->get_inst_proc) {
        set_vk_err(err_buf, err_buf_size, "MoltenVK 缺少 vkGetInstanceProcAddr");
        gc_vk_destroy(vk);
        return NULL;
    }

    vk->vkCreateInstance = (void *)vk->get_inst_proc(NULL, "vkCreateInstance");
    vk->vkEnumerateInstanceExtensionProperties = (void *)vk->get_inst_proc(NULL, "vkEnumerateInstanceExtensionProperties");
    if (!vk->vkCreateInstance) {
        set_vk_err(err_buf, err_buf_size, "MoltenVK 缺少 vkCreateInstance");
        gc_vk_destroy(vk);
        return NULL;
    }

    const struct retro_hw_render_context_negotiation_interface_vulkan *neg = negotiation_interface;
    VkApplicationInfo default_app;
    memset(&default_app, 0, sizeof(default_app));
    default_app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    default_app.pApplicationName = "Game Center";
    default_app.pEngineName = "Game Center";
    default_app.apiVersion = VK_API_VERSION_1_1;

    const VkApplicationInfo *app_info = (neg && neg->get_application_info) ? neg->get_application_info() : &default_app;
    if (!app_info) app_info = &default_app;

    if (neg && neg->interface_version >= 2 && neg->create_instance) {
        vk->instance = neg->create_instance(vk->get_inst_proc, app_info, create_instance_wrapper, vk);
    } else {
        VkInstanceCreateInfo ici;
        memset(&ici, 0, sizeof(ici));
        ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        ici.pApplicationInfo = app_info;
        vk->instance = create_instance_wrapper(vk, &ici);
    }
    if (!vk->instance) {
        set_vk_err(err_buf, err_buf_size, "Vulkan Instance 初始化失败");
        gc_vk_destroy(vk);
        return NULL;
    }

    LOAD_INST(vkDestroyInstance, "vkDestroyInstance");
    LOAD_INST(vkEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices");
    LOAD_INST(vkGetPhysicalDeviceQueueFamilyProperties, "vkGetPhysicalDeviceQueueFamilyProperties");
    LOAD_INST(vkGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties");
    LOAD_INST(vkEnumerateDeviceExtensionProperties, "vkEnumerateDeviceExtensionProperties");
    LOAD_INST(vkCreateDevice, "vkCreateDevice");
    if (!vk->get_dev_proc) {
        vk->get_dev_proc = (PFN_vkGetDeviceProcAddr)vk->get_inst_proc(vk->instance, "vkGetDeviceProcAddr");
    }

    uint32_t gpu_count = 0;
    vk->vkEnumeratePhysicalDevices(vk->instance, &gpu_count, NULL);
    if (gpu_count == 0) {
        set_vk_err(err_buf, err_buf_size, "未找到可用的 Metal/Vulkan GPU");
        gc_vk_destroy(vk);
        return NULL;
    }
    VkPhysicalDevice *gpus = calloc(gpu_count, sizeof(VkPhysicalDevice));
    vk->vkEnumeratePhysicalDevices(vk->instance, &gpu_count, gpus);
    vk->gpu = gpus[0];
    free(gpus);

    struct retro_vulkan_context ctx;
    memset(&ctx, 0, sizeof(ctx));
    bool negotiated = false;
    if (negotiated == false && neg && neg->interface_version >= 2 && neg->create_device2) {
        negotiated = neg->create_device2(&ctx, vk->instance, vk->gpu, VK_NULL_HANDLE, vk->get_inst_proc, create_device_wrapper, vk);
    } else if (neg && neg->create_device) {
        VkPhysicalDeviceFeatures req_feats;
        memset(&req_feats, 0, sizeof(req_feats));
        const char *portability_exts[1] = { "VK_KHR_portability_subset" };
        bool need_portability = has_device_ext(vk, vk->gpu, "VK_KHR_portability_subset");
        negotiated = neg->create_device(
            &ctx,
            vk->instance,
            vk->gpu,
            VK_NULL_HANDLE,
            vk->get_inst_proc,
            need_portability ? portability_exts : NULL,
            need_portability ? 1u : 0u,
            NULL,
            0,
            &req_feats
        );
    }

    if (negotiated && ctx.device && ctx.queue) {
        vk->gpu = ctx.gpu ? ctx.gpu : vk->gpu;
        vk->device = ctx.device;
        vk->queue = ctx.queue;
        vk->queue_family_index = ctx.queue_family_index;
        vk->core_owns_device = true;
        vk->core_destroy_device = neg ? neg->destroy_device : NULL;
    } else {
        uint32_t qcount = 0;
        vk->vkGetPhysicalDeviceQueueFamilyProperties(vk->gpu, &qcount, NULL);
        VkQueueFamilyProperties *qprops = calloc(qcount ? qcount : 1, sizeof(*qprops));
        vk->vkGetPhysicalDeviceQueueFamilyProperties(vk->gpu, &qcount, qprops);
        uint32_t family = 0;
        for (uint32_t i = 0; i < qcount; ++i) {
            if (qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { family = i; break; }
        }
        free(qprops);

        float priority = 1.0f;
        VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, family, 1, &priority };
        VkDeviceCreateInfo dci;
        memset(&dci, 0, sizeof(dci));
        dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dci.queueCreateInfoCount = 1;
        dci.pQueueCreateInfos = &qci;

        vk->device = create_device_wrapper(vk->gpu, vk, &dci);
        if (!vk->device) {
            set_vk_err(err_buf, err_buf_size, "Vulkan Device 创建失败");
            gc_vk_destroy(vk);
            return NULL;
        }
        vk->queue_family_index = family;
        LOAD_DEV(vkGetDeviceQueue, "vkGetDeviceQueue");
        vk->vkGetDeviceQueue(vk->device, family, 0, &vk->queue);
    }

    LOAD_DEV(vkDestroyDevice, "vkDestroyDevice");
    LOAD_DEV(vkDeviceWaitIdle, "vkDeviceWaitIdle");
    LOAD_DEV(vkCreateCommandPool, "vkCreateCommandPool");
    LOAD_DEV(vkDestroyCommandPool, "vkDestroyCommandPool");
    LOAD_DEV(vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
    LOAD_DEV(vkResetCommandBuffer, "vkResetCommandBuffer");
    LOAD_DEV(vkBeginCommandBuffer, "vkBeginCommandBuffer");
    LOAD_DEV(vkEndCommandBuffer, "vkEndCommandBuffer");
    LOAD_DEV(vkCreateFence, "vkCreateFence");
    LOAD_DEV(vkDestroyFence, "vkDestroyFence");
    LOAD_DEV(vkWaitForFences, "vkWaitForFences");
    LOAD_DEV(vkResetFences, "vkResetFences");
    LOAD_DEV(vkQueueSubmit, "vkQueueSubmit");
    LOAD_DEV(vkCreateImage, "vkCreateImage");
    LOAD_DEV(vkDestroyImage, "vkDestroyImage");
    LOAD_DEV(vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
    LOAD_DEV(vkBindImageMemory, "vkBindImageMemory");
    LOAD_DEV(vkCreateBuffer, "vkCreateBuffer");
    LOAD_DEV(vkDestroyBuffer, "vkDestroyBuffer");
    LOAD_DEV(vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
    LOAD_DEV(vkBindBufferMemory, "vkBindBufferMemory");
    LOAD_DEV(vkAllocateMemory, "vkAllocateMemory");
    LOAD_DEV(vkFreeMemory, "vkFreeMemory");
    LOAD_DEV(vkMapMemory, "vkMapMemory");
    LOAD_DEV(vkUnmapMemory, "vkUnmapMemory");
    LOAD_DEV(vkCmdPipelineBarrier, "vkCmdPipelineBarrier");
    LOAD_DEV(vkCmdBlitImage, "vkCmdBlitImage");
    LOAD_DEV(vkCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer");

    VkCommandPoolCreateInfo cpci = {
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, vk->queue_family_index
    };
    if (vk->vkCreateCommandPool(vk->device, &cpci, NULL, &vk->cmd_pool) != VK_SUCCESS) {
        set_vk_err(err_buf, err_buf_size, "Vulkan CommandPool 创建失败");
        gc_vk_destroy(vk);
        return NULL;
    }

    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL,
        vk->cmd_pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, GC_VK_SYNC_COUNT
    };
    if (vk->vkAllocateCommandBuffers(vk->device, &cbai, vk->copy_cmds) != VK_SUCCESS) {
        set_vk_err(err_buf, err_buf_size, "Vulkan CommandBuffer 分配失败");
        gc_vk_destroy(vk);
        return NULL;
    }

    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT };
    for (int i = 0; i < GC_VK_SYNC_COUNT; ++i) {
        if (vk->vkCreateFence(vk->device, &fci, NULL, &vk->fences[i]) != VK_SUCCESS) {
            set_vk_err(err_buf, err_buf_size, "Vulkan Fence 创建失败");
            gc_vk_destroy(vk);
            return NULL;
        }
    }

    vk->retro_iface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    vk->retro_iface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    vk->retro_iface.handle = vk;
    vk->retro_iface.instance = vk->instance;
    vk->retro_iface.gpu = vk->gpu;
    vk->retro_iface.device = vk->device;
    vk->retro_iface.get_device_proc_addr = vk->get_dev_proc;
    vk->retro_iface.get_instance_proc_addr = vk->get_inst_proc;
    vk->retro_iface.queue = vk->queue;
    vk->retro_iface.queue_index = vk->queue_family_index;
    vk->retro_iface.set_image = retro_vk_set_image;
    vk->retro_iface.get_sync_index = retro_vk_get_sync_index;
    vk->retro_iface.get_sync_index_mask = retro_vk_get_sync_index_mask;
    vk->retro_iface.set_command_buffers = retro_vk_set_command_buffers;
    vk->retro_iface.wait_sync_index = retro_vk_wait_sync_index;
    vk->retro_iface.lock_queue = retro_vk_lock_queue;
    vk->retro_iface.unlock_queue = retro_vk_unlock_queue;
    vk->retro_iface.set_signal_semaphore = retro_vk_set_signal_semaphore;

    return vk;
}

void gc_vk_destroy(GCVulkanHost *vk) {
    if (!vk) return;
    if (vk->device && vk->vkDeviceWaitIdle) {
        vk->vkDeviceWaitIdle(vk->device);
    }
    destroy_staging(vk);
    for (int i = 0; i < GC_VK_SYNC_COUNT; ++i) {
        if (vk->fences[i] && vk->vkDestroyFence) {
            vk->vkDestroyFence(vk->device, vk->fences[i], NULL);
        }
    }
    if (vk->cmd_pool && vk->vkDestroyCommandPool) {
        vk->vkDestroyCommandPool(vk->device, vk->cmd_pool, NULL);
    }
    if (vk->core_owns_device) {
        if (vk->core_destroy_device) vk->core_destroy_device();
        if (vk->device && vk->vkDestroyDevice) vk->vkDestroyDevice(vk->device, NULL);
    } else if (vk->device && vk->vkDestroyDevice) {
        vk->vkDestroyDevice(vk->device, NULL);
    }
    if (vk->instance && vk->vkDestroyInstance) {
        vk->vkDestroyInstance(vk->instance, NULL);
    }
    if (vk->dl_handle) {
        dlclose(vk->dl_handle);
    }
    pthread_mutex_destroy(&vk->queue_mutex);
    free(vk);
}

void *gc_vk_get_retro_interface(GCVulkanHost *vk) {
    return vk ? &vk->retro_iface : NULL;
}

bool gc_vk_readback_frame(
    GCVulkanHost *vk,
    uint32_t width,
    uint32_t height,
    uint32_t *dst_bgra,
    uint32_t dst_stride_bytes
) {
    if (!vk || !vk->has_image || !vk->current_image.create_info.image || !dst_bgra || width == 0 || height == 0) {
        return false;
    }
    if (!ensure_staging(vk, width, height)) return false;

    uint32_t idx = vk->sync_index;
    VkFence fence = vk->fences[idx];
    VkCommandBuffer cmd = vk->copy_cmds[idx];

    vk->vkWaitForFences(vk->device, 1, &fence, VK_TRUE, UINT64_MAX);
    vk->vkResetFences(vk->device, 1, &fence);
    vk->vkResetCommandBuffer(cmd, 0);

    VkCommandBufferBeginInfo begin = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL };
    if (vk->vkBeginCommandBuffer(cmd, &begin) != VK_SUCCESS) return false;

    VkImage src_img = vk->current_image.create_info.image;
    VkImageLayout src_layout = vk->current_image.image_layout;
    VkFormat src_fmt = vk->current_image.create_info.format;
    bool direct_copy = (!vk->bottom_left_origin) && (src_fmt == VK_FORMAT_B8G8R8A8_UNORM || src_fmt == VK_FORMAT_B8G8R8A8_SRGB);

    VkImageSubresourceRange color_range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    VkImageMemoryBarrier to_src = {
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
        src_layout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        src_img, color_range
    };
    vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_src);

    VkImage copy_source = src_img;
    if (!direct_copy) {
        VkImageMemoryBarrier blit_dst_barrier = {
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
            vk->blit_image, color_range
        };
        vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &blit_dst_barrier);

        VkImageBlit blit;
        memset(&blit, 0, sizeof(blit));
        blit.srcSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        blit.srcOffsets[0] = (VkOffset3D){ 0, vk->bottom_left_origin ? (int32_t)height : 0, 0 };
        blit.srcOffsets[1] = (VkOffset3D){ (int32_t)width, vk->bottom_left_origin ? 0 : (int32_t)height, 1 };
        blit.dstSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
        blit.dstOffsets[0] = (VkOffset3D){ 0, 0, 0 };
        blit.dstOffsets[1] = (VkOffset3D){ (int32_t)width, (int32_t)height, 1 };
        vk->vkCmdBlitImage(cmd, src_img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk->blit_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, VK_FILTER_NEAREST);

        VkImageMemoryBarrier blit_to_src = {
            VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
            vk->blit_image, color_range
        };
        vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &blit_to_src);
        copy_source = vk->blit_image;
    }

    VkBufferImageCopy region;
    memset(&region, 0, sizeof(region));
    region.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    region.imageExtent = (VkExtent3D){ width, height, 1 };
    vk->vkCmdCopyImageToBuffer(cmd, copy_source, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk->staging_buffer, 1, &region);

    VkImageMemoryBarrier restore_src = {
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        VK_ACCESS_TRANSFER_READ_BIT, VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, src_layout,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        src_img, color_range
    };
    vk->vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &restore_src);

    if (vk->vkEndCommandBuffer(cmd) != VK_SUCCESS) return false;

    VkCommandBuffer submit_cmds[GC_VK_MAX_PENDING_CMDS + 1];
    uint32_t total_cmds = 0;
    for (uint32_t i = 0; i < vk->pending_cmd_count; ++i) {
        submit_cmds[total_cmds++] = vk->pending_cmds[i];
    }
    submit_cmds[total_cmds++] = cmd;
    vk->pending_cmd_count = 0;

    VkPipelineStageFlags wait_stages[GC_VK_MAX_WAIT_SEMS];
    for (uint32_t i = 0; i < vk->wait_sem_count; ++i) wait_stages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;

    VkSemaphore signal_sem = vk->signal_sem;
    vk->signal_sem = VK_NULL_HANDLE;

    VkSubmitInfo submit;
    memset(&submit, 0, sizeof(submit));
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = vk->wait_sem_count;
    submit.pWaitSemaphores = vk->wait_sem_count ? vk->wait_sems : NULL;
    submit.pWaitDstStageMask = vk->wait_sem_count ? wait_stages : NULL;
    submit.commandBufferCount = total_cmds;
    submit.pCommandBuffers = submit_cmds;
    submit.signalSemaphoreCount = signal_sem ? 1u : 0u;
    submit.pSignalSemaphores = signal_sem ? &signal_sem : NULL;
    vk->wait_sem_count = 0;

    pthread_mutex_lock(&vk->queue_mutex);
    VkResult sub_res = vk->vkQueueSubmit(vk->queue, 1, &submit, fence);
    pthread_mutex_unlock(&vk->queue_mutex);
    if (sub_res != VK_SUCCESS) return false;

    vk->vkWaitForFences(vk->device, 1, &fence, VK_TRUE, UINT64_MAX);
    vk->sync_index = (vk->sync_index + 1u) % GC_VK_SYNC_COUNT;

    const uint32_t *src_pixels = (const uint32_t *)vk->staging_mapped;
    uint32_t dst_stride_px = dst_stride_bytes / 4u;
    for (uint32_t y = 0; y < height; ++y) {
        const uint32_t *srow = src_pixels + (size_t)y * width;
        uint32_t *drow = dst_bgra + (size_t)y * dst_stride_px;
        for (uint32_t x = 0; x < width; ++x) {
            drow[x] = srow[x] | 0xFF000000u;
        }
    }
    return true;
}
