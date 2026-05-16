/* Non-Windows fallbacks for the DX12 backend.
 * Returns NULL / no-ops so the awt (Zig) layer can link on Mac/Linux while
 * the Metal / Vulkan backends are being developed. */

#include "internal.h"

#ifndef _WIN32

nmDevice* nmCreateDevice(void) { return NULL; }
void nmDestroyDevice(nmDevice* self) { (void)self; }

nmSwapchain* nmCreateSwapchain(const nmDevice* device, const nmWindow* window) {
    (void)device; (void)window; return NULL;
}
void nmDestroySwapchain(nmSwapchain* self) { (void)self; }
int  nmResizeSwapchain(nmSwapchain* self, int width, int height) {
    (void)self; (void)width; (void)height; return -1;
}
nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self) { (void)self; return NULL; }
void nmPresentSwapchain(nmSwapchain* self) { (void)self; }

nmCommandBuffer* nmAcquireCommandBuffer(nmDevice* device) { (void)device; return NULL; }
void nmReleaseCommandBuffer(nmCommandBuffer* self) { (void)self; }
void nmBeginCommandBuffer(nmCommandBuffer* self) { (void)self; }
void nmEndCommandBuffer(nmCommandBuffer* self) { (void)self; }
void nmSubmitCommandBuffer(nmCommandBuffer* self, nmDevice* device) {
    (void)self; (void)device;
}
void nmWaitForCommandBuffer(nmCommandBuffer* self) { (void)self; }

nmRenderTarget* nmCreateRenderTarget(nmDevice* device, int width, int height) {
    (void)device; (void)width; (void)height; return NULL;
}
void nmDestroyRenderTarget(nmRenderTarget* self) { (void)self; }
void nmBindRenderTarget(nmCommandBuffer* self, nmRenderTarget* target) {
    (void)self; (void)target;
}
void nmSetViewport(nmCommandBuffer* self, float x, float y, float width, float height) {
    (void)self; (void)x; (void)y; (void)width; (void)height;
}
void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a) {
    (void)self; (void)r; (void)g; (void)b; (void)a;
}
void nmClearStencil(nmCommandBuffer* self, uint8_t value) {
    (void)self; (void)value;
}

#endif /* !_WIN32 */
