/* Metal command buffer pool: acquire/release with [cb waitUntilCompleted]
 * synchronization, begin/end of the MTLCommandBuffer + MTLRenderCommandEncoder
 * lifecycle, deferred encoder materialization so loadAction-based clears can
 * fold in. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <string.h>

/* ─── Encoder materialization ─────────────────────────────────────────── */

void nm_cb_ensure_encoder(nmCommandBuffer* self) {
    if (!self || !self->pass_pending || self->encoder) return;
    nmRenderTarget* rt = self->pending_rt;
    if (!rt || !self->cb) return;

    MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor* ca = d.colorAttachments[0];
    ca.texture = rt->color;
    ca.loadAction = self->pending_color_load;
    ca.storeAction = MTLStoreActionStore;
    ca.clearColor = MTLClearColorMake(
        self->pending_clear_color[0],
        self->pending_clear_color[1],
        self->pending_clear_color[2],
        self->pending_clear_color[3]);

    MTLRenderPassStencilAttachmentDescriptor* sa = d.stencilAttachment;
    sa.texture = rt->stencil;
    sa.loadAction = self->pending_stencil_load;
    sa.storeAction = MTLStoreActionStore;
    sa.clearStencil = self->pending_clear_stencil;

    self->encoder = [[self->cb renderCommandEncoderWithDescriptor:d] retain];
    /* CCW winding is the Metal default; explicit set is harmless and
     * documents the project-wide convention from CLAUDE.md. */
    [self->encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [self->encoder setCullMode:MTLCullModeNone];

    /* Bind the four built-in static samplers to both vertex and fragment
     * stages so MSL [[sampler(0..3)]] is always populated. */
    nmDevice* dev = self->owner;
    for (int i = 0; i < NM_STATIC_SAMPLER_COUNT; i++) {
        [self->encoder setVertexSamplerState:dev->samplers[i] atIndex:(NSUInteger)i];
        [self->encoder setFragmentSamplerState:dev->samplers[i] atIndex:(NSUInteger)i];
    }

    /* Default viewport spans the whole RT. nmSetViewport can override. */
    MTLViewport vp;
    vp.originX = 0.0; vp.originY = 0.0;
    vp.width = (double)rt->width; vp.height = (double)rt->height;
    vp.znear = 0.0; vp.zfar = 1.0;
    [self->encoder setViewport:vp];

    MTLScissorRect sr;
    sr.x = 0; sr.y = 0;
    sr.width = (NSUInteger)rt->width; sr.height = (NSUInteger)rt->height;
    [self->encoder setScissorRect:sr];

    self->current_rt = rt;
    self->pass_pending = false;
    self->pending_rt = NULL;
}

void nm_cb_end_encoder(nmCommandBuffer* self) {
    if (!self || !self->encoder) return;
    [self->encoder endEncoding];
    [self->encoder release];
    self->encoder = nil;
}

/* ─── Pool ────────────────────────────────────────────────────────────── */

nmCommandBuffer* nmAcquireCommandBuffer(nmDevice* device) {
    if (!device) return NULL;

    for (int i = 0; i < device->cb_pool_count; i++) {
        nmCommandBuffer* cb = &device->cb_pool[i];
        if (cb->in_use) continue;

        /* Wait for the previous submission of this slot (if any) before
         * handing the slot out. Mirrors dx12_command_buffer.c. */
        if (cb->cb) {
            [cb->cb waitUntilCompleted];
            [cb->cb release];
            cb->cb = nil;
        }

        cb->in_use = true;
        cb->recording = false;
        cb->current_rt = NULL;
        cb->current_pipeline = NULL;
        cb->pending_rt = NULL;
        cb->pass_pending = false;
        cb->stencil_ref = 0;
        cb->index_buffer = nil;
        cb->index_offset = 0;
        return cb;
    }

    nm_log(nmLogLevelError, "command_buffer",
        "no free command buffer in pool (size %d)", device->cb_pool_count);
    return NULL;
}

void nmReleaseCommandBuffer(nmCommandBuffer* self) {
    if (!self) return;
    self->in_use = false;
}

void nmBeginCommandBuffer(nmCommandBuffer* self) {
    if (!self) return;

    /* Discard any previous MTLCommandBuffer from this slot (defensive — the
     * pool's Acquire already waited and released, but a caller that calls
     * Begin twice without Submit must not leak). */
    if (self->cb) {
        [self->cb waitUntilCompleted];
        [self->cb release];
        self->cb = nil;
    }
    /* +1 retained ownership for the duration of this recording / GPU run. */
    self->cb = [[self->owner->queue commandBuffer] retain];

    self->recording = true;
    self->current_rt = NULL;
    self->current_pipeline = NULL;
    self->pending_rt = NULL;
    self->pass_pending = false;
    self->index_buffer = nil;
    self->index_offset = 0;
}

void nmEndCommandBuffer(nmCommandBuffer* self) {
    if (!self) return;

    /* Flush any pending pass with no draws so its clears still happen. */
    if (self->pass_pending && !self->encoder) {
        nm_cb_ensure_encoder(self);
    }
    nm_cb_end_encoder(self);

    /* Schedule presentation of the current swapchain drawable (Metal requires
     * this before commit). The drawable reference is borrowed from the
     * swapchain-owned render target, which stays alive until nmPresentSwapchain. */
    if (self->current_rt && self->current_rt->is_swapchain_owned
            && self->current_rt->swapchain_drawable && self->cb) {
        [self->cb presentDrawable:self->current_rt->swapchain_drawable];
    }

    self->recording = false;
}

void nmSubmitCommandBuffer(nmCommandBuffer* self, nmDevice* device) {
    (void)device;
    if (!self || !self->cb) return;
    [self->cb commit];
    /* Do NOT release here — nmAcquireCommandBuffer waits on it on the next
     * slot grab and releases it then. */
}

void nmWaitForCommandBuffer(nmCommandBuffer* self) {
    if (!self || !self->cb) return;
    [self->cb waitUntilCompleted];
}

/* ─── Draw ────────────────────────────────────────────────────────────── */

void nmDraw(nmCommandBuffer* self, int vertex_count, int start_vertex) {
    if (!self) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder || !self->current_pipeline) return;
    [self->encoder drawPrimitives:self->current_pipeline->primitive_type
                      vertexStart:(NSUInteger)start_vertex
                      vertexCount:(NSUInteger)vertex_count];
}

void nmDrawIndexed(nmCommandBuffer* self, int index_count, int start_index, int base_vertex) {
    if (!self) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder || !self->current_pipeline || !self->index_buffer) return;

    /* Metal's drawIndexedPrimitives: has no start_index parameter; we fold it
     * into indexBufferOffset by advancing the offset by start_index * stride. */
    NSUInteger stride = (self->index_type == MTLIndexTypeUInt16) ? 2 : 4;
    NSUInteger offset = self->index_offset + (NSUInteger)start_index * stride;
    [self->encoder drawIndexedPrimitives:self->current_pipeline->primitive_type
                              indexCount:(NSUInteger)index_count
                               indexType:self->index_type
                             indexBuffer:self->index_buffer
                       indexBufferOffset:offset
                           instanceCount:1
                              baseVertex:(NSInteger)base_vertex
                            baseInstance:0];
}

#endif /* __APPLE__ */
