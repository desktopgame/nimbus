#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* awt-c internal header. Only accessed from the awt (Zig) layer via translate-c.
 * Never exposed to libnimbus consumers. */

/* ─── Global lifecycle ────────────────────────────────────────────────── */

/* Returns 0 on success. */
int nmInitAwt(void);
void nmTerminateAwt(void);

/* Backend identification string (for diagnostics / version display). */
const char* nmGetBackendVersion(void);

/* ─── Log ─────────────────────────────────────────────────────────────── */

typedef enum nmLogLevel {
    nmLogLevelDebug,
    nmLogLevelInfo,
    nmLogLevelWarn,
    nmLogLevelError,
} nmLogLevel;

typedef void (*nmLogCallback)(nmLogLevel level, const char* category, const char* message, void* user_data);

/* Pass NULL to restore the default stderr writer. */
void nmSetLogCallback(nmLogCallback cb, void* user_data);

/* ─── Window ──────────────────────────────────────────────────────────── */

typedef struct nmWindow nmWindow;

nmWindow* nmCreateWindow(const char* title, int width, int height);
void nmDestroyWindow(nmWindow* self);
bool nmShouldClose(nmWindow* self);
void nmSwapBuffers(nmWindow* self);

typedef void (*nmWindowResizeCallback)(nmWindow* window, int width, int height, void* user_data);
typedef void (*nmWindowRefreshCallback)(nmWindow* window, void* user_data);

void nmSetWindowResizeCallback(nmWindow* self, nmWindowResizeCallback cb, void* user_data);
void nmSetWindowRefreshCallback(nmWindow* self, nmWindowRefreshCallback cb, void* user_data);

/* ─── Event pump ──────────────────────────────────────────────────────── */

void nmPollEvents(void);
void nmWaitEvents(void);

/* ─── Device ──────────────────────────────────────────────────────────── */

typedef struct nmDevice nmDevice;

nmDevice* nmCreateDevice(void);
void nmDestroyDevice(nmDevice* self);
void nmWaitDeviceIdle(nmDevice* self);

/* ─── Render target (forward decl needed by swapchain/command_buffer) ─── */

typedef struct nmRenderTarget nmRenderTarget;

/* ─── Swapchain ───────────────────────────────────────────────────────── */

typedef struct nmSwapchain nmSwapchain;

nmSwapchain* nmCreateSwapchain(const nmDevice* device, const nmWindow* window);
void nmDestroySwapchain(nmSwapchain* self);
int nmResizeSwapchain(nmSwapchain* self, int width, int height);
nmRenderTarget* nmGetSwapchainTarget(nmSwapchain* self);
void nmPresentSwapchain(nmSwapchain* self);

/* ─── Command buffer ──────────────────────────────────────────────────── */

typedef struct nmCommandBuffer nmCommandBuffer;

nmCommandBuffer* nmAcquireCommandBuffer(nmDevice* device);
void nmReleaseCommandBuffer(nmCommandBuffer* self);
void nmBeginCommandBuffer(nmCommandBuffer* self);
void nmEndCommandBuffer(nmCommandBuffer* self);
void nmSubmitCommandBuffer(nmCommandBuffer* self, nmDevice* device);
void nmWaitForCommandBuffer(nmCommandBuffer* self);

/* ─── Render target (full API) ────────────────────────────────────────── */

nmRenderTarget* nmCreateRenderTarget(nmDevice* device, int width, int height);
void nmDestroyRenderTarget(nmRenderTarget* self);
void nmBindRenderTarget(nmCommandBuffer* self, nmRenderTarget* target);
void nmSetViewport(nmCommandBuffer* self, float x, float y, float width, float height);
void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a);
void nmClearStencil(nmCommandBuffer* self, uint8_t value);

/* ─── Shader ──────────────────────────────────────────────────────────── */

typedef enum nmShaderStage {
    nmShaderStageVertex,
    nmShaderStagePixel,
} nmShaderStage;

typedef struct nmShader nmShader;

nmShader* nmCompileShader(nmShaderStage stage, const char* source);
nmShader* nmLoadShader(nmShaderStage stage, const void* binary, size_t size);
void nmDestroyShader(nmShader* self);

/* ─── Buffer ──────────────────────────────────────────────────────────── */

typedef enum nmBufferUsage {
    nmBufferUsageVertex   = 1 << 0,
    nmBufferUsageIndex    = 1 << 1,
    nmBufferUsageConstant = 1 << 2,
} nmBufferUsage;

typedef enum nmIndexFormat {
    nmIndexFormatU16,
    nmIndexFormatU32,
} nmIndexFormat;

typedef struct nmBuffer nmBuffer;

nmBuffer* nmCreateBuffer(nmDevice* device, size_t size, nmBufferUsage usage);
void nmDestroyBuffer(nmBuffer* self);
void nmUploadBuffer(nmBuffer* self, const void* data, size_t size, size_t offset);
void nmBindVertexBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t stride, size_t offset);
void nmBindIndexBuffer(nmCommandBuffer* self, nmBuffer* buf, nmIndexFormat fmt, size_t offset);
void nmBindConstantBuffer(nmCommandBuffer* self, nmBuffer* buf, int slot, size_t offset, size_t size);

/* ─── Root signature ──────────────────────────────────────────────────── */

typedef enum nmRootBindingType {
    nmRootBindingTypeConstantBuffer,
    nmRootBindingTypeTexture,
} nmRootBindingType;

typedef struct nmRootBinding {
    nmRootBindingType type;
    nmShaderStage stage;
    int slot;
} nmRootBinding;

typedef struct nmRootSignature nmRootSignature;

nmRootSignature* nmCreateRootSignature(nmDevice* device, const nmRootBinding* bindings, int count);
void nmDestroyRootSignature(nmRootSignature* self);

/* ─── Pipeline ────────────────────────────────────────────────────────── */

typedef enum nmVertexLayout {
    nmVertexLayoutVertex2D,         /* (x, y)             */
    nmVertexLayoutVertexTexCoord2D, /* (x, y, u, v)       */
} nmVertexLayout;

typedef enum nmPrimitiveTopology {
    nmPrimitiveTopologyTriangleList,
    nmPrimitiveTopologyLineList,
    nmPrimitiveTopologyPointList,
} nmPrimitiveTopology;

typedef enum nmBlendMode {
    nmBlendModeNone,
    nmBlendModeAlpha,
    nmBlendModePremultipliedAlpha,
} nmBlendMode;

typedef enum nmStencilOp {
    nmStencilOpKeep,
    nmStencilOpZero,
    nmStencilOpReplace,
    nmStencilOpIncrementSat,
    nmStencilOpDecrementSat,
    nmStencilOpInvert,
    nmStencilOpIncrementWrap,
    nmStencilOpDecrementWrap,
} nmStencilOp;

typedef enum nmCompareFunc {
    nmCompareFuncNever,
    nmCompareFuncLess,
    nmCompareFuncEqual,
    nmCompareFuncLessEqual,
    nmCompareFuncGreater,
    nmCompareFuncNotEqual,
    nmCompareFuncGreaterEqual,
    nmCompareFuncAlways,
} nmCompareFunc;

typedef struct nmStencilState {
    bool enable;
    nmStencilOp fail_op;
    nmStencilOp depth_fail_op;
    nmStencilOp pass_op;
    nmCompareFunc compare_func;
    uint8_t read_mask;
    uint8_t write_mask;
} nmStencilState;

typedef struct nmPipelineDesc {
    nmRootSignature* root_signature;
    nmShader* vertex_shader;
    nmShader* pixel_shader;
    nmVertexLayout vertex_layout;
    nmPrimitiveTopology topology;
    nmBlendMode blend;
    nmStencilState stencil;
    bool color_write_enable;
} nmPipelineDesc;

typedef struct nmPipeline nmPipeline;

nmPipeline* nmCreatePipeline(nmDevice* device, const nmPipelineDesc* desc);
void nmDestroyPipeline(nmPipeline* self);
void nmBindPipeline(nmCommandBuffer* self, nmPipeline* pipeline);
void nmSetStencilRef(nmCommandBuffer* self, uint32_t value);

/* ─── Texture ─────────────────────────────────────────────────────────── */

typedef enum nmTextureFormat {
    nmTextureFormatRGBA8,
    nmTextureFormatBGRA8,
    nmTextureFormatR8,
} nmTextureFormat;

typedef struct nmTexture nmTexture;

nmTexture* nmCreateTexture(nmDevice* device, int width, int height, nmTextureFormat format);
void nmDestroyTexture(nmTexture* self);
void nmUploadTexture(nmTexture* self, const void* data, size_t size);
void nmUploadTextureRegion(nmTexture* self, int x, int y, int width, int height,
                           const void* data, size_t row_pitch);
void nmBindTexture(nmCommandBuffer* self, nmTexture* texture, int slot);

/* ─── Font ────────────────────────────────────────────────────────────── */

typedef struct nmGlyphMetrics {
    int   bitmap_width;
    int   bitmap_height;
    int   bitmap_pitch;       /* row stride in bytes; may exceed bitmap_width due to padding */
    int   bearing_x;
    int   bearing_y;
    float advance_x;
} nmGlyphMetrics;

typedef struct nmFontMetrics {
    float ascender;
    float descender;
    float line_gap;
    float line_height;
} nmFontMetrics;

typedef struct nmFont nmFont;

nmFont* nmCreateFont(const void* data, size_t size, int face_index);
void nmDestroyFont(nmFont* self);
void nmSetFontPixelSize(nmFont* self, int pixel_size);
void nmGetFontMetrics(nmFont* self, nmFontMetrics* out);
int  nmRasterizeGlyph(nmFont* self, uint32_t codepoint,
                      nmGlyphMetrics* out_metrics,
                      const uint8_t** out_bitmap);
float nmGetGlyphAdvance(nmFont* self, uint32_t codepoint);
bool nmFontHasGlyph(nmFont* self, uint32_t codepoint);

/* ─── Draw ────────────────────────────────────────────────────────────── */

void nmDraw(nmCommandBuffer* self, int vertex_count, int start_vertex);
void nmDrawIndexed(nmCommandBuffer* self, int index_count, int start_index, int base_vertex);
