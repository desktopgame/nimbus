#include <GLFW/glfw3.h>

#ifdef _WIN32
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#include <windows.h>
#endif

#ifdef __APPLE__
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>
#endif

#include <stdlib.h>

#include "internal.h"
#include "window_internal.h"

/* Implemented in nm_font.c (cross-platform). */
int  nm_font_internal_init(void);
void nm_font_internal_terminate(void);

/* Implemented in dx12_device.c (Windows) or dx12_stub.c (no-op elsewhere). */
void nm_dxgi_report_live_objects(void);

/* Implemented in win32_ime.c (Windows) or ime_stub.c (no-op elsewhere).
 * Hooks per-window IME plumbing; safe to call once per nmCreateWindow. */
void nm_ime_attach(nmWindow* w);
void nm_ime_set_cursor_pos(nmWindow* w, int x, int y, int height);

static void on_framebuffer_size(GLFWwindow* gw, int w, int h) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (cb && cb->resize_cb) {
        cb->resize_cb((nmWindow*)gw, w, h, cb->resize_user);
    }
}

static void on_window_refresh(GLFWwindow* gw) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (cb && cb->refresh_cb) {
        cb->refresh_cb((nmWindow*)gw, cb->refresh_user);
    }
}

static void on_window_pos(GLFWwindow* gw, int x, int y) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (cb && cb->move_cb) {
        cb->move_cb((nmWindow*)gw, x, y, cb->move_user);
    }
}

/* Map GLFW mouse button → nmMouseButton. Returns -1 for unsupported buttons. */
static int map_mouse_button(int glfw_button) {
    switch (glfw_button) {
        case GLFW_MOUSE_BUTTON_LEFT:   return nmMouseButtonLeft;
        case GLFW_MOUSE_BUTTON_MIDDLE: return nmMouseButtonMiddle;
        case GLFW_MOUSE_BUTTON_RIGHT:  return nmMouseButtonRight;
        default: return -1;
    }
}

/* Map GLFW action → nmKeyAction. */
static nmKeyAction map_action(int glfw_action) {
    switch (glfw_action) {
        case GLFW_PRESS:   return nmKeyActionPress;
        case GLFW_RELEASE: return nmKeyActionRelease;
        case GLFW_REPEAT:  return nmKeyActionRepeat;
        default:           return nmKeyActionRelease;
    }
}

/* Map GLFW modifier bits → nmModifiers bitmask. */
static int map_modifiers(int glfw_mods) {
    int m = 0;
    if (glfw_mods & GLFW_MOD_SHIFT)   m |= nmModifierShift;
    if (glfw_mods & GLFW_MOD_CONTROL) m |= nmModifierCtrl;
    if (glfw_mods & GLFW_MOD_ALT)     m |= nmModifierAlt;
    if (glfw_mods & GLFW_MOD_SUPER)   m |= nmModifierMeta;
    return m;
}

static void on_mouse_button(GLFWwindow* gw, int button, int action, int mods) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (!cb || !cb->mouse_button_cb) return;
    const int mapped = map_mouse_button(button);
    if (mapped < 0) return;  /* skip unsupported buttons */
    cb->mouse_button_cb(
        (nmWindow*)gw,
        (nmMouseButton)mapped,
        map_action(action),
        map_modifiers(mods),
        cb->mouse_button_user
    );
}

static void on_cursor_pos(GLFWwindow* gw, double x, double y) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (!cb || !cb->cursor_pos_cb) return;
    cb->cursor_pos_cb((nmWindow*)gw, x, y, cb->cursor_pos_user);
}

static void on_scroll(GLFWwindow* gw, double dx, double dy) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (!cb || !cb->scroll_cb) return;
    cb->scroll_cb((nmWindow*)gw, dx, dy, cb->scroll_user);
}

static void on_key(GLFWwindow* gw, int key, int scancode, int action, int mods) {
    (void)scancode;
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (!cb || !cb->key_cb) return;
    cb->key_cb(
        (nmWindow*)gw,
        (nmKeyCode)key,
        map_action(action),
        map_modifiers(mods),
        cb->key_user
    );
}

static void on_char(GLFWwindow* gw, unsigned int codepoint) {
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (!cb || !cb->char_cb) return;
    cb->char_cb((nmWindow*)gw, (uint32_t)codepoint, cb->char_user);
}

int nmInitAwt(void) {
#ifdef _WIN32
    /* Per-monitor DPI awareness so the OS hands us real physical pixels
     * instead of bitmap-scaling our swapchain. Failure (already set, or
     * Windows < 10) is non-fatal. */
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
#endif
    if (glfwInit() != GLFW_TRUE) return -1;
    if (nm_font_internal_init() != 0) {
        glfwTerminate();
        return -1;
    }
    return 0;
}

void nmTerminateAwt(void) {
    /* Run leak detection before tearing down anything else so we catch
     * resources the caller forgot to release. No-op in non-debug builds. */
    nm_dxgi_report_live_objects();
    nm_font_internal_terminate();
    glfwTerminate();
}

const char* nmAwtBackendVersion(void) {
    return glfwGetVersionString();
}

nmWindow* nmCreateWindow(const char* title, int width, int height) {
    /* No OpenGL context: rendering is handled by the chosen backend (DX12 etc). */
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    /* Treat (width, height) as logical points: GLFW multiplies by the target
     * monitor's content scale so the window is created at the correct physical
     * pixel size. With this hint the framebuffer is also scaled accordingly. */
    glfwWindowHint(GLFW_SCALE_TO_MONITOR, GLFW_TRUE);
    GLFWwindow* w = glfwCreateWindow(width, height, title, NULL, NULL);
    if (!w) return NULL;

    nmWindowCallbacks* cb = (nmWindowCallbacks*)calloc(1, sizeof(nmWindowCallbacks));
    if (!cb) {
        glfwDestroyWindow(w);
        return NULL;
    }
    glfwSetWindowUserPointer(w, cb);
    glfwSetFramebufferSizeCallback(w, on_framebuffer_size);
    glfwSetWindowRefreshCallback(w, on_window_refresh);
    glfwSetWindowPosCallback(w, on_window_pos);
    glfwSetMouseButtonCallback(w, on_mouse_button);
    glfwSetCursorPosCallback(w, on_cursor_pos);
    glfwSetScrollCallback(w, on_scroll);
    glfwSetKeyCallback(w, on_key);
    glfwSetCharCallback(w, on_char);
    nm_ime_attach((nmWindow*)w);
    return (nmWindow*)w;
}

void nmDestroyWindow(nmWindow* self) {
    if (!self) return;
    GLFWwindow* gw = (GLFWwindow*)self;
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    glfwSetWindowUserPointer(gw, NULL);
    glfwDestroyWindow(gw);
    free(cb);
}

void nmSetWindowTitle(nmWindow* self, const char* title) {
    glfwSetWindowTitle((GLFWwindow*)self, title);
}

bool nmShouldClose(nmWindow* self) {
    return glfwWindowShouldClose((GLFWwindow*)self) != 0;
}

void nmSetShouldClose(nmWindow* self, bool value) {
    glfwSetWindowShouldClose((GLFWwindow*)self, value ? GLFW_TRUE : GLFW_FALSE);
}

void nmSetWindowVisible(nmWindow* self, bool visible) {
    if (visible) {
        glfwShowWindow((GLFWwindow*)self);
    } else {
        glfwHideWindow((GLFWwindow*)self);
    }
}

void nmFocusWindow(nmWindow* self) {
    glfwFocusWindow((GLFWwindow*)self);
}

void nmRequestWindowAttention(nmWindow* self) {
#ifdef _WIN32
    /* GLFW's glfwRequestWindowAttention is a single FlashWindow (one subtle
     * caption invert) — barely visible. Use FlashWindowEx with FLASHW_ALL +
     * a repeat count so the title bar / taskbar (and the DWM drop shadow)
     * visibly pulse, matching native modal-dialog attention behavior.
     * Only flashes while the window is NOT foreground, which is the case
     * here: the user just clicked the (blocked) owner, so the owner is
     * foreground and the dialog is behind it. */
    FLASHWINFO fi;
    fi.cbSize    = sizeof(fi);
    fi.hwnd      = nm_internal_get_hwnd(self);
    fi.dwFlags   = FLASHW_ALL;
    fi.uCount    = 6;
    /* Explicit fast rate. dwTimeout == 0 means the default caret-blink rate
     * (~500ms), which looks sluggish — use a short interval for a snappy
     * "chika-chika" flash. */
    fi.dwTimeout = 80; /* ms between flashes */
    FlashWindowEx(&fi);
#else
    glfwRequestWindowAttention((GLFWwindow*)self);
#endif
}

void nmSetWindowFloating(nmWindow* self, bool floating) {
    glfwSetWindowAttrib((GLFWwindow*)self, GLFW_FLOATING, floating ? GLFW_TRUE : GLFW_FALSE);
}

void nmGetWindowPos(nmWindow* self, int* x, int* y) {
    glfwGetWindowPos((GLFWwindow*)self, x, y);
}

void nmSetWindowPos(nmWindow* self, int x, int y) {
    glfwSetWindowPos((GLFWwindow*)self, x, y);
}

void nmSetWindowSize(nmWindow* self, int width, int height) {
    glfwSetWindowSize((GLFWwindow*)self, width, height);
}

void nmSwapBuffers(nmWindow* self) {
    glfwSwapBuffers((GLFWwindow*)self);
}

void nmSetWindowResizeCallback(nmWindow* self, nmWindowResizeCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->resize_cb = cb;
    cbs->resize_user = user_data;
}

void nmSetWindowRefreshCallback(nmWindow* self, nmWindowRefreshCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->refresh_cb = cb;
    cbs->refresh_user = user_data;
}

void nmSetWindowMoveCallback(nmWindow* self, nmWindowMoveCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->move_cb = cb;
    cbs->move_user = user_data;
}

void nmSetMouseButtonCallback(nmWindow* self, nmMouseButtonCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->mouse_button_cb = cb;
    cbs->mouse_button_user = user_data;
}

void nmSetCursorPosCallback(nmWindow* self, nmCursorPosCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->cursor_pos_cb = cb;
    cbs->cursor_pos_user = user_data;
}

void nmSetScrollCallback(nmWindow* self, nmScrollCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->scroll_cb = cb;
    cbs->scroll_user = user_data;
}

void nmSetKeyCallback(nmWindow* self, nmKeyCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->key_cb = cb;
    cbs->key_user = user_data;
}

void nmSetCharCallback(nmWindow* self, nmCharCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->char_cb = cb;
    cbs->char_user = user_data;
}

void nmSetCompositionCallback(nmWindow* self, nmCompositionCallback cb, void* user_data) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->composition_cb = cb;
    cbs->composition_user = user_data;
}

void nmSetCompositionCursorPos(nmWindow* self, int x, int y, int height) {
    if (!self) return;
    nmWindowCallbacks* cbs = (nmWindowCallbacks*)glfwGetWindowUserPointer((GLFWwindow*)self);
    if (!cbs) return;
    cbs->composition_cursor_x = x;
    cbs->composition_cursor_y = y;
    cbs->composition_cursor_h = height;
    /* Hand the cached value to the platform-specific IME backend so it can
     * push it to the OS immediately (Windows: ImmSetCompositionWindow).
     * On macOS / Wayland this may be a no-op until the OS pulls. */
    nm_ime_set_cursor_pos(self, x, y, height);
}

void nmPollEvents(void) {
    glfwPollEvents();
}

void nmWaitEvents(void) {
    glfwWaitEvents();
}

void nmWaitEventsTimeout(double seconds) {
    glfwWaitEventsTimeout(seconds);
}

void nmPostEmptyEvent(void) {
    glfwPostEmptyEvent();
}

double nmGetTime(void) {
    return glfwGetTime();
}

const char* nmGetClipboardString(nmWindow* self) {
    return glfwGetClipboardString((GLFWwindow*)self);
}

void nmSetClipboardString(nmWindow* self, const char* utf8) {
    glfwSetClipboardString((GLFWwindow*)self, utf8);
}

void nmGetWindowSize(const nmWindow* self, int* width, int* height) {
    glfwGetWindowSize((GLFWwindow*)self, width, height);
}

void nmGetFramebufferSize(const nmWindow* self, int* width, int* height) {
    glfwGetFramebufferSize((GLFWwindow*)self, width, height);
}

void nmGetWindowContentScale(const nmWindow* self, float* xscale, float* yscale) {
    glfwGetWindowContentScale((GLFWwindow*)self, xscale, yscale);
}

/* ─── Internal accessors used by backend C files ──────────────────────── */

#ifdef _WIN32
HWND nm_internal_get_hwnd(const nmWindow* w) {
    return glfwGetWin32Window((GLFWwindow*)w);
}
#endif

#ifdef __APPLE__
/* Returns NSWindow* as a void* — caller (metal_swapchain.m) casts back. Kept
 * untyped here so glfw_shim.c stays a pure-C translation unit. */
void* nm_internal_get_nswindow(const nmWindow* w) {
    return (void*)glfwGetCocoaWindow((GLFWwindow*)w);
}
#endif
