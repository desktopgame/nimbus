/* Metal texture: MTLStorageModePrivate texture backed by a shared-storage
 * staging MTLBuffer, uploaded via a one-shot blit command buffer. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

static MTLPixelFormat metal_format(nmTextureFormat f) {
    switch (f) {
        case nmTextureFormatRGBA8: return MTLPixelFormatRGBA8Unorm;
        case nmTextureFormatBGRA8: return MTLPixelFormatBGRA8Unorm;
        case nmTextureFormatR8:    return MTLPixelFormatR8Unorm;
    }
    return MTLPixelFormatInvalid;
}

static int bytes_per_pixel(nmTextureFormat f) {
    switch (f) {
        case nmTextureFormatRGBA8: return 4;
        case nmTextureFormatBGRA8: return 4;
        case nmTextureFormatR8:    return 1;
    }
    return 0;
}

nmTexture* nmCreateTexture(nmDevice* device, int width, int height, nmTextureFormat format) {
    if (!device || width <= 0 || height <= 0) return NULL;
    int bpp = bytes_per_pixel(format);
    MTLPixelFormat fmt = metal_format(format);
    if (bpp == 0 || fmt == MTLPixelFormatInvalid) {
        nm_log(nmLogLevelError, "texture", "unsupported format %d", (int)format);
        return NULL;
    }

    nmTexture* t = (nmTexture*)calloc(1, sizeof(nmTexture));
    if (!t) return NULL;
    t->owner = device;
    t->width = width;
    t->height = height;
    t->format = format;
    t->bytes_per_pixel = bpp;

    @autoreleasepool {
        MTLTextureDescriptor* d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:fmt
                                         width:(NSUInteger)width
                                        height:(NSUInteger)height
                                     mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        /* newTextureWithDescriptor: returns +1 retained — own directly. */
        t->texture = [device->device newTextureWithDescriptor:d];
        if (!t->texture) {
            nm_log(nmLogLevelError, "texture", "newTextureWithDescriptor failed");
            free(t);
            return NULL;
        }
    }
    return t;
}

void nmDestroyTexture(nmTexture* self) {
    if (!self) return;
    if (self->texture) [self->texture release];
    free(self);
}

/* Synchronous upload of a rectangular sub-region. Stages into a transient
 * MTLBuffer (shared storage), then issues a blitEncoder copy and waits. */
static void upload_region_sync(nmTexture* self, int x, int y, int w, int h,
                               const void* data, size_t src_row_pitch) {
    nmDevice* dev = self->owner;
    size_t row_bytes = (size_t)w * (size_t)self->bytes_per_pixel;
    size_t total = row_bytes * (size_t)h;
    if (total == 0) return;

    @autoreleasepool {
        id<MTLBuffer> staging = [dev->device newBufferWithLength:total
                                                         options:MTLResourceStorageModeShared];
        if (!staging) {
            nm_log(nmLogLevelError, "texture", "staging newBufferWithLength failed");
            return;
        }
        uint8_t* dst = (uint8_t*)[staging contents];
        const uint8_t* src = (const uint8_t*)data;
        for (int row = 0; row < h; row++) {
            memcpy(dst + (size_t)row * row_bytes,
                   src + (size_t)row * src_row_pitch,
                   row_bytes);
        }

        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:staging
                sourceOffset:0
           sourceBytesPerRow:row_bytes
         sourceBytesPerImage:total
                  sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                   toTexture:self->texture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0)];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        [staging release];
    }
}

void nmUploadTexture(nmTexture* self, const void* data, size_t size) {
    if (!self || !data) return;
    size_t expected = (size_t)self->width * (size_t)self->height * (size_t)self->bytes_per_pixel;
    if (size < expected) {
        nm_log(nmLogLevelError, "texture",
            "nmUploadTexture: size %zu < expected %zu", size, expected);
        return;
    }
    upload_region_sync(self, 0, 0, self->width, self->height,
                       data, (size_t)self->width * (size_t)self->bytes_per_pixel);
}

void nmUploadTextureRegion(nmTexture* self, int x, int y, int w, int h,
                           const void* data, size_t row_pitch) {
    if (!self || !data) return;
    if (x < 0 || y < 0 || w <= 0 || h <= 0
            || x + w > self->width || y + h > self->height) {
        nm_log(nmLogLevelError, "texture",
            "nmUploadTextureRegion: out of bounds (%d,%d %dx%d in %dx%d)",
            x, y, w, h, self->width, self->height);
        return;
    }
    upload_region_sync(self, x, y, w, h, data, row_pitch);
}

void nmBindTexture(nmCommandBuffer* self, nmTexture* texture, int slot) {
    if (!self || !texture || !self->current_pipeline) return;
    nm_cb_ensure_encoder(self);
    if (!self->encoder) return;

    nmRootSignature* sig = self->current_pipeline->root_signature;
    if (!sig) return;

    for (int i = 0; i < sig->param_count; i++) {
        if (sig->params[i].type != nmRootBindingTypeTexture) continue;
        if (sig->params[i].slot != slot) continue;
        NSUInteger idx = (NSUInteger)slot;
        if (sig->params[i].stage == nmShaderStageVertex) {
            [self->encoder setVertexTexture:texture->texture atIndex:idx];
        } else {
            [self->encoder setFragmentTexture:texture->texture atIndex:idx];
        }
        return;
    }
    nm_log(nmLogLevelWarn, "texture",
        "nmBindTexture: no Texture binding for slot %d in current pipeline", slot);
}

#endif /* __APPLE__ */
