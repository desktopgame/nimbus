/* Metal buffer: MTLBuffer with MTLResourceStorageModeShared so the contents
 * pointer is persistently CPU-writable, mirroring DX12's UPLOAD-heap +
 * persistent map. Vertex / Index / Constant share the same underlying buffer. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

nmBuffer* nmCreateBuffer(nmDevice* device, size_t size, nmBufferUsage usage) {
    if (!device || size == 0) return NULL;

    nmBuffer* b = (nmBuffer*)calloc(1, sizeof(nmBuffer));
    if (!b) {
        nm_log(nmLogLevelError, "buffer", "out of memory");
        return NULL;
    }
    b->size = size;
    b->usage = usage;

    @autoreleasepool {
        /* newBufferWithLength: returns a +1 retained instance per Cocoa
         * convention — own it directly without an extra retain. */
        b->buffer = [device->device newBufferWithLength:(NSUInteger)size
                                                options:MTLResourceStorageModeShared];
        if (!b->buffer) {
            nm_log(nmLogLevelError, "buffer", "newBufferWithLength failed (size=%zu)", size);
            free(b);
            return NULL;
        }
        b->contents = [b->buffer contents];
    }
    return b;
}

void nmDestroyBuffer(nmBuffer* self) {
    if (!self) return;
    if (self->buffer) [self->buffer release];
    free(self);
}

void nmUploadBuffer(nmBuffer* self, const void* data, size_t size, size_t offset) {
    if (!self || !data || !self->contents) return;
    if (offset + size > self->size) {
        nm_log(nmLogLevelError, "buffer",
            "upload out of range (offset=%zu size=%zu buf=%zu)", offset, size, self->size);
        return;
    }
    memcpy((char*)self->contents + offset, data, size);
}

void nmBindVertexBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot,
                        size_t stride, size_t offset) {
    (void)stride;  /* Stride lives in the vertex descriptor on the pipeline. */
    if (!self || !buf) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder) return;
    NSUInteger index = (NSUInteger)(NM_VERTEX_BUFFER_INDEX_BASE - slot);
    [self->encoder setVertexBuffer:buf->buffer
                            offset:(NSUInteger)offset
                           atIndex:index];
}

void nmBindIndexBuffer(nmCommandBuffer* self, nmBuffer* buf,
                       nmIndexFormat fmt, size_t offset) {
    if (!self || !buf) return;
    /* Metal has no "set index buffer" encoder state — the buffer is passed
     * to drawIndexedPrimitives: directly. Stash here, replay at draw time. */
    self->index_buffer = buf->buffer;
    self->index_type = (fmt == nmIndexFormatU16) ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
    self->index_offset = (NSUInteger)offset;
}

void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot,
                          size_t offset, size_t size) {
    if (!self || !buf) return;

    if (!self->current_pipeline) {
        nm_log(nmLogLevelError, "buffer",
            "nmBindConstantBuffer: no pipeline bound (call nmBindPipeline first)");
        return;
    }
    if (offset + size > buf->size) {
        nm_log(nmLogLevelError, "buffer",
            "nmBindConstantBuffer: range out of bounds (offset=%zu size=%zu buf=%zu)",
            offset, size, buf->size);
        return;
    }

    nm_cb_ensure_encoder(self);
    if (!self->encoder) return;

    nmRootSignature* sig = self->current_pipeline->root_signature;
    if (!sig) return;

    for (int i = 0; i < sig->param_count; i++) {
        if (sig->params[i].type != nmRootBindingTypeConstantBuffer) continue;
        if (sig->params[i].slot != slot) continue;
        /* size is validated above for caller intent; Metal binds the buffer
         * with offset and infers extent from the MSL constant struct itself. */
        NSUInteger idx = (NSUInteger)slot;
        if (sig->params[i].stage == nmShaderStageVertex) {
            [self->encoder setVertexBuffer:buf->buffer
                                    offset:(NSUInteger)offset
                                   atIndex:idx];
        } else {
            [self->encoder setFragmentBuffer:buf->buffer
                                      offset:(NSUInteger)offset
                                     atIndex:idx];
        }
        return;
    }
    nm_log(nmLogLevelWarn, "buffer",
        "nmBindConstantBuffer: no ConstantBuffer binding for slot %d in current pipeline", slot);
}

#endif /* __APPLE__ */
