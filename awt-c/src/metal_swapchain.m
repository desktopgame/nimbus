/* Metal swapchain: CAMetalLayer attached to the GLFW NSWindow's content view,
 * with a persistent stencil texture and a single nmRenderTarget whose color
 * is refreshed from the layer's next drawable each frame. */

#import "metal_internal.h"

#ifdef __APPLE__

#import <AppKit/AppKit.h>

#include <stdlib.h>
#include <string.h>

/* ─── Internal helpers ────────────────────────────────────────────────── */

int nm_swapchain_allocate_stencil(nmSwapchain* self) {
    nmDevice* device = self->owner;
    MTLTextureDescriptor* d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:NM_STENCIL_FORMAT
                                     width:(NSUInteger)self->width
                                    height:(NSUInteger)self->height
                                 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> stencil = [device->device newTextureWithDescriptor:d];
    if (!stencil) {
        nm_log(nmLogLevelError, "swapchain", "stencil texture allocation failed");
        return -1;
    }
    self->target.stencil = stencil;  /* takes +1 ownership */
    return 0;
}

void nm_swapchain_release_stencil(nmSwapchain* self) {
    if (self->target.stencil) {
        [self->target.stencil release];
        self->target.stencil = nil;
    }
}

/* Attach a CAMetalLayer to the GLFW window's content view. Returns the
 * layer with +1 retain. */
static CAMetalLayer* nm_attach_metal_layer(nmDevice* device,
                                           const nmWindow* window,
                                           int width, int height) {
    NSWindow* nsWindow = (NSWindow*)nm_internal_get_nswindow(window);
    if (!nsWindow) return nil;

    CAMetalLayer* layer = [[CAMetalLayer alloc] init];
    layer.device = device->device;
    layer.pixelFormat = NM_COLOR_FORMAT;
    layer.framebufferOnly = YES;
    layer.drawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);

    NSView* contentView = [nsWindow contentView];
    [contentView setWantsLayer:YES];
    [contentView setLayer:layer];
    return layer;  /* +1 retain owned by caller */
}

/* ─── Public API ──────────────────────────────────────────────────────── */

nmSwapchain* nmCreateSwapchain(const nmDevice* device_const, const nmWindow* window) {
    if (!device_const || !window) return NULL;
    nmDevice* device = (nmDevice*)device_const;

    nmSwapchain* sc = (nmSwapchain*)calloc(1, sizeof(nmSwapchain));
    if (!sc) {
        nm_log(nmLogLevelError, "swapchain", "out of memory");
        return NULL;
    }
    sc->owner = device;

    @autoreleasepool {
        nmGetFramebufferSize(window, &sc->width, &sc->height);
        if (sc->width <= 0)  sc->width = 1;
        if (sc->height <= 0) sc->height = 1;

        sc->layer = nm_attach_metal_layer(device, window, sc->width, sc->height);
        if (!sc->layer) {
            nm_log(nmLogLevelError, "swapchain", "could not attach CAMetalLayer");
            goto fail;
        }

        /* Initialize the persistent target slot. Color is filled per-frame
         * from [layer nextDrawable]; stencil persists across frames. */
        sc->target.owner = device;
        sc->target.width = sc->width;
        sc->target.height = sc->height;
        sc->target.is_swapchain_owned = true;
        sc->target.color = nil;
        sc->target.stencil = nil;

        if (nm_swapchain_allocate_stencil(sc) != 0) goto fail;
    }

    nm_log(nmLogLevelInfo, "swapchain", "created (%dx%d)", sc->width, sc->height);
    return sc;

fail:
    nmDestroySwapchain(sc);
    return NULL;
}

void nmDestroySwapchain(nmSwapchain* self) {
    if (!self) return;
    if (self->owner) nmWaitDeviceIdle(self->owner);

    if (self->drawable) { [self->drawable release]; self->drawable = nil; }
    nm_swapchain_release_stencil(self);

    if (self->layer) {
        /* Best effort: detach from the view so subsequent rendering errors
         * don't reference a freed layer. */
        [self->layer release];
        self->layer = nil;
    }
    free(self);
}

int nmResizeSwapchain(nmSwapchain* self, int width, int height) {
    if (!self || !self->layer) return -1;
    if (width <= 0 || height <= 0) return 0;
    if (width == self->width && height == self->height) return 0;

    nmWaitDeviceIdle(self->owner);

    if (self->drawable) { [self->drawable release]; self->drawable = nil; }
    nm_swapchain_release_stencil(self);

    self->width = width;
    self->height = height;
    self->layer.drawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);
    self->target.width = width;
    self->target.height = height;

    if (nm_swapchain_allocate_stencil(self) != 0) return -1;
    return 0;
}

nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self) {
    if (!self || !self->layer) return NULL;
    /* Acquire the next drawable on demand and cache it for the rest of the
     * frame; releases happen in Present. */
    if (!self->drawable) {
        @autoreleasepool {
            id<CAMetalDrawable> d = [self->layer nextDrawable];
            if (!d) {
                nm_log(nmLogLevelWarn, "swapchain", "nextDrawable returned nil");
                return NULL;
            }
            self->drawable = [d retain];
        }
    }
    /* Drawable's texture is not retained by us; the drawable owns it. We
     * stash the bare reference for the bind code path. */
    self->target.color = self->drawable.texture;
    self->target.swapchain_drawable = self->drawable;
    return &self->target;
}

void nmPresentSwapchain(nmSwapchain* self) {
    if (!self) return;
    /* The actual [cb presentDrawable:drawable] call happens inside
     * nmEndCommandBuffer because Metal requires it before commit. Here we
     * simply drop our reference so the next frame's nextDrawable call can
     * acquire a fresh one. */
    if (self->drawable) {
        [self->drawable release];
        self->drawable = nil;
    }
    self->target.color = nil;
    self->target.swapchain_drawable = nil;
}

#endif /* __APPLE__ */
