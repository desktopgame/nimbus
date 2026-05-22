/* Metal offscreen render target: color + stencil textures. Bind primes a
 * pending pass on the command buffer; the encoder itself is materialized
 * lazily so clearColor/clearStencil can fold into loadAction. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

nmRenderTarget* nmCreateRenderTarget(nmDevice* device, int width, int height) {
    if (!device || width <= 0 || height <= 0) return NULL;

    nmRenderTarget* rt = (nmRenderTarget*)calloc(1, sizeof(nmRenderTarget));
    if (!rt) {
        nm_log(nmLogLevelError, "render_target", "out of memory");
        return NULL;
    }
    rt->owner = device;
    rt->width = width;
    rt->height = height;
    rt->is_swapchain_owned = false;
    rt->color = nil;
    rt->stencil = nil;
    rt->swapchain_drawable = nil;

    @autoreleasepool {
        MTLTextureDescriptor* cd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:NM_COLOR_FORMAT
                                         width:(NSUInteger)width
                                        height:(NSUInteger)height
                                     mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        cd.storageMode = MTLStorageModePrivate;
        rt->color = [device->device newTextureWithDescriptor:cd];
        if (!rt->color) {
            nm_log(nmLogLevelError, "render_target", "color texture allocation failed");
            goto fail;
        }

        MTLTextureDescriptor* sd = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:NM_STENCIL_FORMAT
                                         width:(NSUInteger)width
                                        height:(NSUInteger)height
                                     mipmapped:NO];
        sd.usage = MTLTextureUsageRenderTarget;
        sd.storageMode = MTLStorageModePrivate;
        rt->stencil = [device->device newTextureWithDescriptor:sd];
        if (!rt->stencil) {
            nm_log(nmLogLevelError, "render_target", "stencil texture allocation failed");
            goto fail;
        }
    }
    return rt;

fail:
    nmDestroyRenderTarget(rt);
    return NULL;
}

void nmDestroyRenderTarget(nmRenderTarget* self) {
    if (!self) return;
    if (self->is_swapchain_owned) {
        nm_log(nmLogLevelWarn, "render_target",
            "nmDestroyRenderTarget called on swapchain-owned target (ignored)");
        return;
    }
    if (self->color)   { [self->color release];   self->color = nil; }
    if (self->stencil) { [self->stencil release]; self->stencil = nil; }
    free(self);
}

void nmBindRenderTarget(nmCommandBuffer* self, nmRenderTarget* target) {
    if (!self || !target) return;

    /* Switching RTs ends the open encoder so a new pass descriptor takes
     * effect. The encoder for the new pass is materialized lazily on the
     * first draw/state-change after Bind. */
    nm_cb_end_encoder(self);

    self->pending_rt = target;
    self->pending_color_load = MTLLoadActionLoad;
    self->pending_clear_color[0] = 0.0f;
    self->pending_clear_color[1] = 0.0f;
    self->pending_clear_color[2] = 0.0f;
    self->pending_clear_color[3] = 0.0f;
    self->pending_stencil_load = MTLLoadActionLoad;
    self->pending_clear_stencil = 0;
    self->pass_pending = true;
    self->current_rt = target;  /* remembered for present-time decisions */
}

void nmSetViewport(nmCommandBuffer* self, float x, float y, float width, float height) {
    if (!self) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder) return;
    MTLViewport vp;
    vp.originX = (double)x; vp.originY = (double)y;
    vp.width = (double)width; vp.height = (double)height;
    vp.znear = 0.0; vp.zfar = 1.0;
    [self->encoder setViewport:vp];

    MTLScissorRect sr;
    sr.x = (NSUInteger)(x > 0.0f ? x : 0.0f);
    sr.y = (NSUInteger)(y > 0.0f ? y : 0.0f);
    sr.width  = (NSUInteger)(width  > 0.0f ? width  : 0.0f);
    sr.height = (NSUInteger)(height > 0.0f ? height : 0.0f);
    [self->encoder setScissorRect:sr];
}

void nmSetScissor(nmCommandBuffer* self, int x, int y, int width, int height) {
    if (!self) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder) return;
    /* Clamp negative origins to 0 — MTLScissorRect uses NSUInteger so it
     * can't represent negatives, and Metal validation rejects rects that
     * extend outside the attachment. */
    MTLScissorRect sr;
    sr.x = (NSUInteger)(x > 0 ? x : 0);
    sr.y = (NSUInteger)(y > 0 ? y : 0);
    sr.width  = (NSUInteger)(width  > 0 ? width  : 0);
    sr.height = (NSUInteger)(height > 0 ? height : 0);
    [self->encoder setScissorRect:sr];
}

void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a) {
    if (!self || !self->pass_pending) return;
    self->pending_color_load = MTLLoadActionClear;
    self->pending_clear_color[0] = r;
    self->pending_clear_color[1] = g;
    self->pending_clear_color[2] = b;
    self->pending_clear_color[3] = a;
}

void nmClearStencil(nmCommandBuffer* self, uint8_t value) {
    if (!self || !self->pass_pending) return;
    self->pending_stencil_load = MTLLoadActionClear;
    self->pending_clear_stencil = (uint32_t)value;
}

int nmReadbackRenderTarget(nmRenderTarget* self, void* out_rgba, size_t out_size) {
    if (!self || !out_rgba || !self->owner || !self->color) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: invalid argument");
        return -1;
    }
    if (self->is_swapchain_owned) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: swapchain-owned target is not supported");
        return -1;
    }

    nmDevice* dev = self->owner;
    const NSUInteger width = (NSUInteger)self->width;
    const NSUInteger height = (NSUInteger)self->height;
    const size_t required = (size_t)width * (size_t)height * 4u;
    if (out_size < required) {
        nm_log(nmLogLevelError, "render_target",
            "nmReadbackRenderTarget: out_size %zu < required %zu",
            out_size, required);
        return -1;
    }

    int result = -1;
    @autoreleasepool {
        const NSUInteger row_bytes = width * 4u;
        const NSUInteger total = row_bytes * height;

        /* Shared staging so the CPU can read the bytes after the blit. */
        id<MTLBuffer> staging = [dev->device newBufferWithLength:total
                                                         options:MTLResourceStorageModeShared];
        if (!staging) {
            nm_log(nmLogLevelError, "render_target",
                "nmReadbackRenderTarget: staging buffer allocation failed");
            return -1;
        }

        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        if (!cb) {
            nm_log(nmLogLevelError, "render_target",
                "nmReadbackRenderTarget: command buffer allocation failed");
            [staging release];
            return -1;
        }

        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:self->color
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(width, height, 1)
                     toBuffer:staging
            destinationOffset:0
       destinationBytesPerRow:row_bytes
     destinationBytesPerImage:total];
        [blit endEncoding];

        [cb commit];
        [cb waitUntilCompleted];

        /* NM_COLOR_FORMAT is BGRA8Unorm; the public contract is RGBA8 so we
         * swizzle R<->B on copy. */
        const uint8_t* src = (const uint8_t*)[staging contents];
        uint8_t* dst = (uint8_t*)out_rgba;
        const size_t pixel_count = (size_t)width * (size_t)height;
        for (size_t i = 0; i < pixel_count; i++) {
            const uint8_t b = src[i * 4 + 0];
            const uint8_t g = src[i * 4 + 1];
            const uint8_t r = src[i * 4 + 2];
            const uint8_t a = src[i * 4 + 3];
            dst[i * 4 + 0] = r;
            dst[i * 4 + 1] = g;
            dst[i * 4 + 2] = b;
            dst[i * 4 + 3] = a;
        }

        [staging release];
        result = 0;
    }
    return result;
}

#endif /* __APPLE__ */
