#pragma once

/* Internal shared header for window-related C files (glfw_shim, per-platform
 * IME backends, native access helpers). Not fed to translate-c so it can
 * safely expose Win32 / Cocoa types. */

#include "internal.h"

typedef struct GLFWcursor GLFWcursor;

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

/* Per-window callback table — stored as the GLFW window user pointer.
 * Owned by glfw_shim.c (allocated in nmCreateWindow / freed in
 * nmDestroyWindow). Per-platform IME backends read / write the
 * composition_* fields and the prev_wndproc slot. */
typedef struct nmWindowCallbacks {
    nmWindowResizeCallback  resize_cb;
    void*                   resize_user;
    nmWindowRefreshCallback refresh_cb;
    void*                   refresh_user;
    nmWindowMoveCallback    move_cb;
    void*                   move_user;
    nmMouseButtonCallback   mouse_button_cb;
    void*                   mouse_button_user;
    nmCursorPosCallback     cursor_pos_cb;
    void*                   cursor_pos_user;
    nmScrollCallback        scroll_cb;
    void*                   scroll_user;
    nmKeyCallback           key_cb;
    void*                   key_user;
    nmCharCallback          char_cb;
    void*                   char_user;
    nmCompositionCallback   composition_cb;
    void*                   composition_user;
    /* Last cursor position pushed by `nmSetCompositionCursorPos`. Stored
     * here so platform backends that get pulled (macOS NSTextInputClient)
     * can answer with the latest framework-known value. */
    int                     composition_cursor_x;
    int                     composition_cursor_y;
    int                     composition_cursor_h;
#ifdef _WIN32
    /* Original GLFW wndproc; preserved when our IME subclass is installed,
     * tail-called for every message we do not handle. */
    WNDPROC                 prev_wndproc;
#endif
    GLFWcursor*             cursors[4];
} nmWindowCallbacks;

/* Native handle accessors (implemented in glfw_shim.c). */
#ifdef _WIN32
HWND  nm_internal_get_hwnd(const nmWindow* w);
#endif
#ifdef __APPLE__
void* nm_internal_get_nswindow(const nmWindow* w);
#endif
