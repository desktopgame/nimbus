#pragma once

/* Internal shared header for the DX12 backend. Included only from dx12_*.c.
 * Not fed to translate-c, so it can safely expose D3D12 / Win32 types. */

#include "internal.h"

#ifdef _WIN32

/* C-flavored COM access: enable IXxx_Method(p, ...) macros and the C vtbl ABI.
 * Already supplied via -D in build.zig; defined here as well so language
 * tooling that doesn't see those flags still expands COM calls correctly. */
#ifndef COBJMACROS
#define COBJMACROS
#endif
#ifndef CINTERFACE
#define CINTERFACE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <stddef.h>
#include <stdint.h>

/* ─── Fixed sizes ─────────────────────────────────────────────────────── */

#define NM_CBV_SRV_UAV_HEAP_SIZE 4096
#define NM_SAMPLER_HEAP_SIZE     16
#define NM_RTV_HEAP_SIZE         64
#define NM_DSV_HEAP_SIZE         16

#define NM_CB_POOL_SIZE          1
#define NM_SWAPCHAIN_BUFFER_COUNT 2

#define NM_COLOR_FORMAT          DXGI_FORMAT_R8G8B8A8_UNORM
#define NM_STENCIL_FORMAT        DXGI_FORMAT_D24_UNORM_S8_UINT

/* ─── Opaque struct bodies ────────────────────────────────────────────── */

struct nmRenderTarget {
    struct nmDevice*         owner;              /* for slot release on destroy */
    ID3D12Resource*          color_resource;
    ID3D12Resource*          stencil_resource;
    int                      rtv_index;          /* slot in device rtv heap, -1 if unallocated */
    int                      dsv_index;          /* slot in device dsv heap, -1 if unallocated */
    int                      width;
    int                      height;
    D3D12_RESOURCE_STATES    color_state;        /* tracked for auto-transitions */
    int                      is_swapchain_owned; /* skip color_resource release if true */
};

struct nmCommandBuffer {
    struct nmDevice*                owner;
    ID3D12CommandAllocator*         allocator;
    ID3D12GraphicsCommandList*      list;
    uint64_t                        submitted_fence_value; /* 0 if never submitted */
    nmRenderTarget*                 current_rt;            /* last bound RT for end-time transition */
    struct nmPipeline*              current_pipeline;      /* last bound pipeline (for CBV/SRV bind lookups) */
    int                             in_use;                /* pool occupancy flag */
    int                             recording;             /* between Begin and End */
};

#define NM_MAX_ROOT_PARAMS 16

struct nmShader {
    nmShaderStage           stage;
    ID3DBlob*               blob;   /* bytecode, owned */
};

struct nmBuffer {
    ID3D12Resource*           resource;
    void*                     mapped_ptr;  /* persistent map (UPLOAD heap) */
    D3D12_GPU_VIRTUAL_ADDRESS gpu_va;
    size_t                    size;
    nmBufferUsage             usage;
};

struct nmRootSignature {
    ID3D12RootSignature* root_signature;
    int                  param_count;
    struct {
        nmRootBindingType type;
        int               slot;
        int               root_param_index;
    } params[NM_MAX_ROOT_PARAMS];
};

struct nmPipeline {
    ID3D12PipelineState*       pso;
    nmRootSignature*           root_signature;  /* borrowed; needed for bind */
    D3D_PRIMITIVE_TOPOLOGY     topology;
};

struct nmTexture {
    struct nmDevice*         owner;
    ID3D12Resource*          resource;
    ID3D12Resource*          upload;        /* persistent UPLOAD heap staging */
    int                      srv_index;     /* slot in device cbv_srv_uav heap, -1 if none */
    int                      width;
    int                      height;
    nmTextureFormat          format;
    UINT                     bytes_per_pixel;
    D3D12_RESOURCE_STATES    state;
};

struct nmDevice {
    IDXGIFactory6*           factory;
    IDXGIAdapter1*           adapter;
    ID3D12Device*            device;
    ID3D12CommandQueue*      queue;
    ID3D12Fence*             fence;
    HANDLE                   fence_event;
    uint64_t                 next_fence_value;

    /* Debug layer (optional, may be NULL). */
    ID3D12InfoQueue*         info_queue;

    /* Descriptor heaps. */
    ID3D12DescriptorHeap*    cbv_srv_uav_heap;
    ID3D12DescriptorHeap*    sampler_heap;
    ID3D12DescriptorHeap*    rtv_heap;
    ID3D12DescriptorHeap*    dsv_heap;
    UINT                     rtv_descriptor_size;
    UINT                     dsv_descriptor_size;
    UINT                     cbv_srv_uav_descriptor_size;

    /* RTV / DSV / SRV slot free-stacks. */
    int                      rtv_free[NM_RTV_HEAP_SIZE];
    int                      rtv_top;
    int                      dsv_free[NM_DSV_HEAP_SIZE];
    int                      dsv_top;
    int                      srv_free[NM_CBV_SRV_UAV_HEAP_SIZE];
    int                      srv_top;

    /* Command buffer pool. */
    struct nmCommandBuffer   cb_pool[NM_CB_POOL_SIZE];
    int                      cb_pool_count;
};

struct nmSwapchain {
    struct nmDevice*         owner;
    IDXGISwapChain3*         swapchain;
    HWND                     hwnd;
    int                      width;
    int                      height;
    nmRenderTarget           targets[NM_SWAPCHAIN_BUFFER_COUNT];
    int                      back_index;
};

/* ─── Internal helpers ────────────────────────────────────────────────── */

/* Logger (implemented in nm_log.c, cross-platform). */
void nm_log(nmLogLevel level, const char* category, const char* fmt, ...);

/* HWND access (implemented in glfw_shim.c). */
HWND nm_internal_get_hwnd(const nmWindow* w);

/* Window framebuffer size in pixels (implemented in glfw_shim.c). */
void nm_internal_get_framebuffer_size(const nmWindow* w, int* width, int* height);

/* Resource state transitions (implemented in dx12_render_target.c). */
void nm_transition(nmCommandBuffer* cb, nmRenderTarget* rt, D3D12_RESOURCE_STATES new_state);

/* GPU sync (implemented in dx12_device.c). */
void nm_device_wait_idle(nmDevice* device);

/* Descriptor slot allocation (implemented in dx12_device.c). */
int  nm_alloc_rtv_slot(nmDevice* device);
void nm_free_rtv_slot(nmDevice* device, int slot);
int  nm_alloc_dsv_slot(nmDevice* device);
void nm_free_dsv_slot(nmDevice* device, int slot);
int  nm_alloc_srv_slot(nmDevice* device);
void nm_free_srv_slot(nmDevice* device, int slot);
D3D12_CPU_DESCRIPTOR_HANDLE nm_rtv_cpu_handle(nmDevice* device, int slot);
D3D12_CPU_DESCRIPTOR_HANDLE nm_dsv_cpu_handle(nmDevice* device, int slot);
D3D12_CPU_DESCRIPTOR_HANDLE nm_srv_cpu_handle(nmDevice* device, int slot);
D3D12_GPU_DESCRIPTOR_HANDLE nm_srv_gpu_handle(nmDevice* device, int slot);

/* Drain DX12 debug layer messages and forward to nm_log. No-op if no InfoQueue. */
void nm_drain_info_queue(nmDevice* device);

/* Swapchain back buffer (re)creation (implemented in dx12_swapchain.c). */
int  nm_swapchain_allocate_targets(nmSwapchain* self);
void nm_swapchain_release_targets(nmSwapchain* self);

#endif /* _WIN32 */
