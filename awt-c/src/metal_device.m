/* Metal device implementation: MTLDevice + queue, built-in static samplers,
 * command-buffer pool. Mirrors dx12_device.c. */

#import "metal_internal.h"

#ifdef __APPLE__

#include <stdlib.h>
#include <string.h>

/* ─── Static samplers ──────────────────────────────────────────────────
 * Four built-in samplers matching DX12's static-sampler set. Layout follows
 * awt-c/doc/sampler.md:
 *   s0: Linear + Clamp   s1: Linear + Wrap
 *   s2: Point  + Clamp   s3: Point  + Wrap
 * Bound at encoder start so MSL can reference [[sampler(0..3)]] directly. */
static id<MTLSamplerState> nm_make_sampler(id<MTLDevice> device,
                                           MTLSamplerMinMagFilter filter,
                                           MTLSamplerAddressMode address) {
    MTLSamplerDescriptor* d = [[MTLSamplerDescriptor alloc] init];
    d.minFilter = filter;
    d.magFilter = filter;
    d.mipFilter = (filter == MTLSamplerMinMagFilterLinear)
        ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
    d.sAddressMode = address;
    d.tAddressMode = address;
    d.rAddressMode = address;
    d.normalizedCoordinates = YES;
    id<MTLSamplerState> s = [device newSamplerStateWithDescriptor:d];
    [d release];
    return s;  /* caller owns +1 */
}

/* ─── Internal helpers ────────────────────────────────────────────────── */

void nmWaitDeviceIdle(nmDevice* self) {
    if (!self || !self->queue) return;
    /* Drain by submitting an empty cb and waiting. MTLCommandQueue lacks a
     * direct "wait idle" so we synchronize through a no-op submission. */
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [self->queue commandBuffer];
        [cb commit];
        [cb waitUntilCompleted];
    }
}

/* Cross-platform-callable leak-detection entry point. Metal has no direct
 * ReportLiveObjects analogue; we rely on the validation layer (enabled via
 * the MTL_DEBUG_LAYER env var) to log live-object diagnostics to stderr. */
void nm_dxgi_report_live_objects(void) {}

/* ─── Public API ──────────────────────────────────────────────────────── */

nmDevice* nmCreateDevice(void) {
    nmDevice* dev = (nmDevice*)calloc(1, sizeof(nmDevice));
    if (!dev) {
        nm_log(nmLogLevelError, "device", "out of memory");
        return NULL;
    }

    @autoreleasepool {
        /* 1. Default device (highest-perf GPU on Apple Silicon = the only one). */
        dev->device = MTLCreateSystemDefaultDevice();
        if (!dev->device) {
            nm_log(nmLogLevelError, "metal", "MTLCreateSystemDefaultDevice returned nil");
            goto fail;
        }
        nm_log(nmLogLevelInfo, "metal", "device created (adapter: %s)",
            [[dev->device name] UTF8String]);

#ifdef NM_METAL_DEBUG
        /* Validation is opt-in via the MTL_DEBUG_LAYER=1 env var (set by the
         * launcher); we just log its presence so it's visible in CI output. */
        const char* val = getenv("MTL_DEBUG_LAYER");
        if (val && val[0] == '1') {
            nm_log(nmLogLevelInfo, "metal", "Metal validation layer enabled");
        } else {
            nm_log(nmLogLevelInfo, "metal",
                "Metal validation layer NOT enabled — export MTL_DEBUG_LAYER=1 to enable");
        }
#endif

        /* 2. Command queue. */
        dev->queue = [dev->device newCommandQueue];
        if (!dev->queue) {
            nm_log(nmLogLevelError, "metal", "newCommandQueue returned nil");
            goto fail;
        }

        /* 3. Static samplers (s0..s3). */
        dev->samplers[0] = nm_make_sampler(dev->device,
            MTLSamplerMinMagFilterLinear, MTLSamplerAddressModeClampToEdge);
        dev->samplers[1] = nm_make_sampler(dev->device,
            MTLSamplerMinMagFilterLinear, MTLSamplerAddressModeRepeat);
        dev->samplers[2] = nm_make_sampler(dev->device,
            MTLSamplerMinMagFilterNearest, MTLSamplerAddressModeClampToEdge);
        dev->samplers[3] = nm_make_sampler(dev->device,
            MTLSamplerMinMagFilterNearest, MTLSamplerAddressModeRepeat);
        for (int i = 0; i < NM_STATIC_SAMPLER_COUNT; i++) {
            if (!dev->samplers[i]) {
                nm_log(nmLogLevelError, "metal", "newSamplerStateWithDescriptor failed (s%d)", i);
                goto fail;
            }
        }

        /* 4. Command-buffer pool: lazy MTLCommandBuffer creation in Begin. */
        for (int i = 0; i < NM_CB_POOL_SIZE; i++) {
            nmCommandBuffer* cb = &dev->cb_pool[i];
            cb->owner = dev;
            cb->in_use = false;
            cb->recording = false;
            cb->cb = nil;
            cb->encoder = nil;
            cb->current_rt = NULL;
            cb->current_pipeline = NULL;
            cb->pending_rt = NULL;
            cb->pass_pending = false;
        }
        dev->cb_pool_count = NM_CB_POOL_SIZE;
    }

    nm_log(nmLogLevelInfo, "device", "device initialized");
    return dev;

fail:
    nmDestroyDevice(dev);
    return NULL;
}

void nmDestroyDevice(nmDevice* self) {
    if (!self) return;

    if (self->queue) {
        nmWaitDeviceIdle(self);
    }

    for (int i = 0; i < self->cb_pool_count; i++) {
        nmCommandBuffer* cb = &self->cb_pool[i];
        if (cb->encoder) { [cb->encoder release]; cb->encoder = nil; }
        if (cb->cb)      { [cb->cb release];      cb->cb = nil; }
    }
    self->cb_pool_count = 0;

    for (int i = 0; i < NM_STATIC_SAMPLER_COUNT; i++) {
        if (self->samplers[i]) {
            [self->samplers[i] release];
            self->samplers[i] = nil;
        }
    }
    if (self->queue)  { [self->queue release];  self->queue = nil; }
    if (self->device) { [self->device release]; self->device = nil; }

    free(self);
}

#endif /* __APPLE__ */
