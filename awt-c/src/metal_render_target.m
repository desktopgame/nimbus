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

#endif /* __APPLE__ */
