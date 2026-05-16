#pragma once

#include <stdint.h>

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
int nmShouldClose(nmWindow* self);
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
