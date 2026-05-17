#pragma once

/* Internal shared header for the Metal backend. Included only from metal_*.m.
 * Not fed to translate-c, so it can safely expose Metal / Objective-C types. */

#include "internal.h"

#ifdef __APPLE__

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>

#include <stddef.h>
#include <stdint.h>

/* ─── Fixed sizes ─────────────────────────────────────────────────────── */

#define NM_CB_POOL_SIZE           1
#define NM_MAX_ROOT_PARAMS        16

/* Vertex-stream MTLBuffer indices live high to avoid colliding with constant
 * buffer slots (which start at 0). Stream `slot` -> Metal index
 * NM_VERTEX_BUFFER_INDEX_BASE - slot. Mirrors DX12's separate input-assembler. */
#define NM_VERTEX_BUFFER_INDEX_BASE 30

/* Sampler indices for s0..s3 (matches the four built-in samplers; bound to
 * both vertex and fragment stages at encoder materialization). */
#define NM_STATIC_SAMPLER_COUNT   4

/* All render targets (swapchain & offscreen) share a single format so a
 * pipeline created against one is reusable against the other. BGRA8Unorm is
 * the CAMetalLayer default, so we use it everywhere to avoid drawable warnings. */
#define NM_COLOR_FORMAT   MTLPixelFormatBGRA8Unorm
#define NM_STENCIL_FORMAT MTLPixelFormatStencil8

/* ─── Opaque struct bodies ────────────────────────────────────────────── */

struct nmRenderTarget {
    struct nmDevice*        owner;
    id<MTLTexture>          color;           /* retained for offscreen; not retained for swapchain (drawable owns it) */
    id<MTLTexture>          stencil;         /* retained */
    int                     width;
    int                     height;
    bool                    is_swapchain_owned;
    /* For swapchain RTs only: borrowed pointer to the drawable that backs
     * `color` for the current frame. Strong reference lives on nmSwapchain.
     * Used by nmEndCommandBuffer to schedule [cb presentDrawable:]. */
    id<CAMetalDrawable>     swapchain_drawable;
};

struct nmCommandBuffer {
    struct nmDevice*               owner;
    id<MTLCommandBuffer>           cb;       /* retained while in flight; nil between frames */
    id<MTLRenderCommandEncoder>    encoder;  /* retained while a pass is open */

    /* Pending render-pass state. Encoder is materialized lazily so that
     * nmClearRenderTarget / nmClearStencil can fold into loadAction. */
    nmRenderTarget*                pending_rt;
    MTLLoadAction                  pending_color_load;
    float                          pending_clear_color[4];
    MTLLoadAction                  pending_stencil_load;
    uint32_t                       pending_clear_stencil;
    bool                           pass_pending;

    nmRenderTarget*                current_rt;            /* last bound RT (for present at end) */
    struct nmPipeline*             current_pipeline;      /* needed for slot->index lookups */
    uint32_t                       stencil_ref;
    bool                           in_use;
    bool                           recording;
};

struct nmShader {
    nmShaderStage   stage;
    id<MTLLibrary>  library;     /* retained */
    id<MTLFunction> function;    /* retained */
};

struct nmBuffer {
    id<MTLBuffer>  buffer;       /* retained, MTLResourceStorageModeShared */
    void*          contents;     /* persistent pointer = [buffer contents] */
    size_t         size;
    nmBufferUsage  usage;
};

struct nmRootSignature {
    int param_count;
    struct {
        nmRootBindingType type;
        nmShaderStage     stage;
        int               slot;
    } params[NM_MAX_ROOT_PARAMS];
};

struct nmPipeline {
    id<MTLRenderPipelineState>  pso;          /* retained */
    id<MTLDepthStencilState>    dss;          /* retained */
    nmRootSignature*            root_signature;  /* borrowed */
    MTLPrimitiveType            primitive_type;
    bool                        stencil_enabled;
};

struct nmTexture {
    struct nmDevice*  owner;
    id<MTLTexture>    texture;       /* retained, MTLStorageModePrivate */
    int               width;
    int               height;
    nmTextureFormat   format;
    int               bytes_per_pixel;
};

struct nmDevice {
    id<MTLDevice>          device;     /* retained */
    id<MTLCommandQueue>    queue;      /* retained */
    id<MTLSamplerState>    samplers[NM_STATIC_SAMPLER_COUNT]; /* retained, s0..s3 */
    struct nmCommandBuffer cb_pool[NM_CB_POOL_SIZE];
    int                    cb_pool_count;
};

struct nmSwapchain {
    struct nmDevice*    owner;
    CAMetalLayer*       layer;        /* retained */
    id<CAMetalDrawable> drawable;     /* retained while a frame is in flight; nil otherwise */
    int                 width;
    int                 height;
    nmRenderTarget      target;       /* one persistent slot; color refreshed each frame */
};

/* ─── Internal helpers ────────────────────────────────────────────────── */

/* Logger (implemented in nm_log.c, cross-platform). */
void nm_log(nmLogLevel level, const char* category, const char* fmt, ...);

/* NSWindow access (implemented in glfw_shim.c). Returns id<NSWindow> via void*. */
void* nm_internal_get_nswindow(const nmWindow* w);

/* Window framebuffer size in pixels (implemented in glfw_shim.c). */
void nm_internal_get_framebuffer_size(const nmWindow* w, int* width, int* height);

/* Swapchain back buffer (re)allocation (implemented in metal_swapchain.m). */
int  nm_swapchain_allocate_stencil(nmSwapchain* self);
void nm_swapchain_release_stencil(nmSwapchain* self);

/* Render encoder materialization (implemented in metal_command_buffer.m). */
void nm_cb_ensure_encoder(nmCommandBuffer* self);
void nm_cb_end_encoder(nmCommandBuffer* self);

#endif /* __APPLE__ */
