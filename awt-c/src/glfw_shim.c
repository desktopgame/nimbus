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

/* Implemented in nm_font.c (cross-platform). */
int  nm_font_internal_init(void);
void nm_font_internal_terminate(void);

/* Implemented in dx12_device.c (Windows) or dx12_stub.c (no-op elsewhere). */
void nm_dxgi_report_live_objects(void);

typedef struct nmWindowCallbacks {
    nmWindowResizeCallback  resize_cb;
    void*                   resize_user;
    nmWindowRefreshCallback refresh_cb;
    void*                   refresh_user;
} nmWindowCallbacks;

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

int nmInitAwt(void) {
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

const char* nmGetBackendVersion(void) {
    return glfwGetVersionString();
}

nmWindow* nmCreateWindow(const char* title, int width, int height) {
    /* No OpenGL context: rendering is handled by the chosen backend (DX12 etc). */
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
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

bool nmShouldClose(nmWindow* self) {
    return glfwWindowShouldClose((GLFWwindow*)self) != 0;
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

void nmPollEvents(void) {
    glfwPollEvents();
}

void nmWaitEvents(void) {
    glfwWaitEvents();
}

double nmGetTime(void) {
    return glfwGetTime();
}

void nmGetWindowSize(const nmWindow* self, int* width, int* height) {
    glfwGetWindowSize((GLFWwindow*)self, width, height);
}

void nmGetFramebufferSize(const nmWindow* self, int* width, int* height) {
    glfwGetFramebufferSize((GLFWwindow*)self, width, height);
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
