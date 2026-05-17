/* Non-Windows fallbacks for the DX12 backend.
 * Returns NULL / no-ops so the awt (Zig) layer can link on Mac/Linux while
 * the Metal / Vulkan backends are being developed. */

#include "internal.h"

#ifndef _WIN32

nmDevice* nmCreateDevice(void) { return NULL; }
void nmDestroyDevice(nmDevice* self) { (void)self; }
void nmWaitDeviceIdle(nmDevice* self) { (void)self; }

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
void nmSetScissor(nmCommandBuffer* self, int x, int y, int width, int height) {
    (void)self; (void)x; (void)y; (void)width; (void)height;
}
void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a) {
    (void)self; (void)r; (void)g; (void)b; (void)a;
}
void nmClearStencil(nmCommandBuffer* self, uint8_t value) {
    (void)self; (void)value;
}

/* ─── Stage 2 stubs ───────────────────────────────────────────────────── */

nmShader* nmCompileShader(nmShaderStage stage, const char* source) {
    (void)stage; (void)source; return NULL;
}
nmShader* nmLoadShader(nmShaderStage stage, const void* binary, size_t size) {
    (void)stage; (void)binary; (void)size; return NULL;
}
void nmDestroyShader(nmShader* self) { (void)self; }

nmBuffer* nmCreateBuffer(nmDevice* device, size_t size, nmBufferUsage usage) {
    (void)device; (void)size; (void)usage; return NULL;
}
void nmDestroyBuffer(nmBuffer* self) { (void)self; }
void nmUploadBuffer(nmBuffer* self, const void* data, size_t size, size_t offset) {
    (void)self; (void)data; (void)size; (void)offset;
}
void nmBindVertexBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t stride, size_t offset) {
    (void)self; (void)buf; (void)slot; (void)stride; (void)offset;
}
void nmBindIndexBuffer(nmCommandBuffer* self, nmBuffer* buf, nmIndexFormat fmt, size_t offset) {
    (void)self; (void)buf; (void)fmt; (void)offset;
}
void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t offset, size_t size) {
    (void)self; (void)buf; (void)slot; (void)offset; (void)size;
}

nmRootSignature* nmCreateRootSignature(nmDevice* device, const nmRootBinding* bindings, int count) {
    (void)device; (void)bindings; (void)count; return NULL;
}
void nmDestroyRootSignature(nmRootSignature* self) { (void)self; }

nmPipeline* nmCreatePipeline(nmDevice* device, const nmPipelineDesc* desc) {
    (void)device; (void)desc; return NULL;
}
void nmDestroyPipeline(nmPipeline* self) { (void)self; }
void nmBindPipeline(nmCommandBuffer* self, nmPipeline* pipeline) {
    (void)self; (void)pipeline;
}
void nmSetStencilRef(nmCommandBuffer* self, uint32_t value) {
    (void)self; (void)value;
}

void nmDraw(nmCommandBuffer* self, int vertex_count, int start_vertex) {
    (void)self; (void)vertex_count; (void)start_vertex;
}
void nmDrawIndexed(nmCommandBuffer* self, int index_count, int start_index, int base_vertex) {
    (void)self; (void)index_count; (void)start_index; (void)base_vertex;
}

/* ─── Texture stubs ───────────────────────────────────────────────────── */

nmTexture* nmCreateTexture(nmDevice* device, int width, int height, nmTextureFormat format) {
    (void)device; (void)width; (void)height; (void)format; return NULL;
}
void nmDestroyTexture(nmTexture* self) { (void)self; }
void nmUploadTexture(nmTexture* self, const void* data, size_t size) {
    (void)self; (void)data; (void)size;
}
void nmUploadTextureRegion(nmTexture* self, int x, int y, int width, int height,
                           const void* data, size_t row_pitch) {
    (void)self; (void)x; (void)y; (void)width; (void)height; (void)data; (void)row_pitch;
}
void nmBindTexture(nmCommandBuffer* self, nmTexture* texture, int slot) {
    (void)self; (void)texture; (void)slot;
}

/* Cross-platform-callable leak detection (no-op on non-Windows). */
void nm_dxgi_report_live_objects(void) {}

#endif /* !_WIN32 */
