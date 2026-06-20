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
const char* nmAwtBackendVersion(void);

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
/* Replace the window title shown by the OS (title bar, taskbar). Pushes the
 * new value immediately. `title` must be NUL-terminated UTF-8. */
void nmSetWindowTitle(nmWindow* self, const char* title);
bool nmShouldClose(nmWindow* self);
/* Set or clear the OS close flag. Clearing (false) lets a window that was
 * closed via its X button be reused (e.g. re-showing a dialog). */
void nmSetShouldClose(nmWindow* self, bool value);
void nmSwapBuffers(nmWindow* self);

typedef void (*nmWindowResizeCallback)(nmWindow* window, int width, int height, void* user_data);
typedef void (*nmWindowRefreshCallback)(nmWindow* window, void* user_data);
/* Window moved. x / y are the new top-left in logical screen units (points),
 * the same units nmGetWindowPos reports. Fires for OS-driven moves (user drag)
 * as well as programmatic nmSetWindowPos. */
typedef void (*nmWindowMoveCallback)(nmWindow* window, int x, int y, void* user_data);

typedef enum nmKeyAction {
    nmKeyActionRelease,
    nmKeyActionPress,
    nmKeyActionRepeat,
} nmKeyAction;

typedef enum nmMouseButton {
    nmMouseButtonLeft,
    nmMouseButtonMiddle,
    nmMouseButtonRight,
} nmMouseButton;

/* Modifier bitmask. Combine with bitwise OR. */
typedef enum nmModifiers {
    nmModifierShift = 1 << 0,
    nmModifierCtrl  = 1 << 1,
    nmModifierAlt   = 1 << 2,
    nmModifierMeta  = 1 << 3,
} nmModifiers;

/* Mirrors GLFW_KEY_* values. */
typedef int nmKeyCode;

typedef void (*nmMouseButtonCallback)(nmWindow* window, nmMouseButton button, nmKeyAction action, int modifiers, void* user_data);
typedef void (*nmCursorPosCallback)(nmWindow* window, double x, double y, void* user_data);
typedef void (*nmScrollCallback)(nmWindow* window, double dx, double dy, void* user_data);
typedef void (*nmKeyCallback)(nmWindow* window, nmKeyCode key, nmKeyAction action, int modifiers, void* user_data);
/* Text input character callback. Receives one Unicode codepoint per call —
 * already mapped through the OS keyboard layout (Shift+1 → '!', AZERTY etc).
 * Use this for text entry; nmKeyCallback for shortcuts and navigation. */
typedef void (*nmCharCallback)(nmWindow* window, uint32_t codepoint, void* user_data);

void nmSetWindowResizeCallback(nmWindow* self, nmWindowResizeCallback cb, void* user_data);
void nmSetWindowRefreshCallback(nmWindow* self, nmWindowRefreshCallback cb, void* user_data);
void nmSetWindowMoveCallback(nmWindow* self, nmWindowMoveCallback cb, void* user_data);
void nmSetMouseButtonCallback(nmWindow* self, nmMouseButtonCallback cb, void* user_data);
void nmSetCursorPosCallback(nmWindow* self, nmCursorPosCallback cb, void* user_data);
void nmSetScrollCallback(nmWindow* self, nmScrollCallback cb, void* user_data);
void nmSetKeyCallback(nmWindow* self, nmKeyCallback cb, void* user_data);
void nmSetCharCallback(nmWindow* self, nmCharCallback cb, void* user_data);

/* ─── IME composition ─────────────────────────────────────────────────── */

/* Preedit (under-composition) state delivered by the OS IME.
 *
 * `text` is the current preedit string in UTF-8 (no NUL guarantee — use
 * `text_len`). It is owned by awt-c and valid only for the duration of the
 * callback. Callers that need to keep it must copy.
 *
 * `target_start` / `target_end` are byte offsets into `text` that mark the
 * "selection" / target clause — the part the user is currently converting.
 * When the IME does not report one, both fall back to the caret position
 * inside the preedit. `target_start == target_end == text_len` is valid
 * (caret at the end, no selection).
 *
 * An empty `text` (`text_len == 0`) signals "composition cleared"
 * (cancellation or commit). The committed string itself is delivered via
 * the existing `nmCharCallback`, so consumers do not need a separate
 * commit callback. */
typedef struct nmCompositionEvent {
    const char* text;
    size_t      text_len;
    size_t      target_start;
    size_t      target_end;
} nmCompositionEvent;

typedef void (*nmCompositionCallback)(nmWindow* window,
                                       const nmCompositionEvent* ev,
                                       void* user_data);

void nmSetCompositionCallback(nmWindow* self, nmCompositionCallback cb, void* user_data);

/* Tell the IME where the text caret currently sits, in window-local
 * pixels. `height` is the line height (so the candidate window can avoid
 * overlapping the caret line). IMEs use this to position their candidate
 * popup. Safe to call every time the caret moves; cheap. */
void nmSetCompositionCursorPos(nmWindow* self, int x, int y, int height);

/* Clipboard (system-wide; the window argument is required by the GLFW
 * surface but the clipboard itself is process / OS scoped).
 *
 * `nmGetClipboardString` returns a pointer owned by awt-c. It stays valid
 * only until the next nmGet/SetClipboardString call on the same thread —
 * callers must copy the bytes before doing further clipboard work.
 * Returns NULL if the clipboard is empty or does not hold UTF-8 text.
 *
 * `nmSetClipboardString` copies `utf8` into the system clipboard. */
const char* nmGetClipboardString(nmWindow* self);
void        nmSetClipboardString(nmWindow* self, const char* utf8);

/* Window size in logical screen units (points). This is what the user
 * requested in nmCreateWindow; on HiDPI displays it is smaller than the
 * framebuffer size. Use these values for any DPI-independent coordinates
 * exposed to user drawing code. */
void nmGetWindowSize(const nmWindow* self, int* width, int* height);

/* Resize the window. width / height are logical screen units (points), the
 * same units nmGetWindowSize reports. The framebuffer is resized accordingly
 * and the resize callback (if any) fires. */
void nmSetWindowSize(nmWindow* self, int width, int height);

/* Show or hide the window. Dialogs are created hidden and toggled on
 * show / close (they are not destroyed on close, unlike Frames). */
void nmSetWindowVisible(nmWindow* self, bool visible);

/* Give the window OS input focus / bring it forward. */
void nmFocusWindow(nmWindow* self);

/* Request user attention: flashes the window / taskbar (Win32 FlashWindowEx).
 * Used to flash a modal dialog when the user pokes its blocked owner. */
void nmRequestWindowAttention(nmWindow* self);

/* Toggle always-on-top. Used to keep a modal dialog above its owner since
 * GLFW provides no OS-level window modality. */
void nmSetWindowFloating(nmWindow* self, bool floating);

/* Window position in logical screen units (points), top-left corner relative
 * to the virtual screen. Used e.g. to center a dialog over its owner. */
void nmGetWindowPos(nmWindow* self, int* x, int* y);
void nmSetWindowPos(nmWindow* self, int x, int y);

/* Work area (taskbar/dock excluded) of the monitor containing the window
 * center, in the same screen-coordinate units nmGet/SetWindowPos use.
 * Falls back to the primary monitor when no containing monitor is found. */
void nmGetWindowMonitorWorkarea(const nmWindow* self, int* x, int* y, int* width, int* height);

/* Framebuffer pixel size. On HiDPI displays (Retina) this can differ from the
 * window's logical size — e.g. a 800x600 window has a 1600x1200 framebuffer.
 * Use these values for swapchain / scissor / viewport — anything that talks
 * to the GPU in pixel units. */
void nmGetFramebufferSize(const nmWindow* self, int* width, int* height);

/* Window's content scale (DPR). On a regular 1x display both values are 1.0;
 * on Retina 2x they are 2.0; on Windows scaled to 150% they are 1.5.
 * framebuffer = logical * scale. Use this when the upper layers need to
 * convert between logical user coordinates and physical pixel coordinates
 * (mouse coords from GLFW, font rasterization size, etc.). */
void nmGetWindowContentScale(const nmWindow* self, float* xscale, float* yscale);

/* ─── Event pump ──────────────────────────────────────────────────────── */

void nmPollEvents(void);
void nmWaitEvents(void);

/* Wait for at most `seconds` for an OS event to arrive, then return.
 * Returns even when no event arrived (timeout fired). Negative or zero
 * `seconds` degenerates to a non-blocking poll. Use this when the UI
 * thread needs to wake on a future deadline (timers, caret blink). */
void nmWaitEventsTimeout(double seconds);

/* Wake up the UI thread blocked in nmWaitEvents. Safe to call from any thread.
 * No side effects beyond unblocking — the wake-up just resumes polling. */
void nmPostEmptyEvent(void);

/* Seconds since nmInitAwt; monotonic. */
double nmGetTime(void);

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
void nmSetScissor(nmCommandBuffer* self, int x, int y, int width, int height);
void nmClearRenderTarget(nmCommandBuffer* self, float r, float g, float b, float a);
void nmClearStencil(nmCommandBuffer* self, uint8_t value);

/* Read back the current contents of an offscreen render target into a
 * caller-supplied buffer as tightly-packed RGBA8 (channel order normalized
 * regardless of the underlying GPU format). Blocking: synchronizes with the
 * GPU. Intended for tests / snapshots; not for the render hot path. Returns 0
 * on success, non-zero on failure. */
int nmReadbackRenderTarget(nmRenderTarget* self, void* out_rgba, size_t out_size);

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
