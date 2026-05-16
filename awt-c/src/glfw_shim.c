#include <GLFW/glfw3.h>

#ifdef _WIN32
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#include <windows.h>
#endif

#include <stdlib.h>

#include "internal.h"

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
    return glfwInit() == GLFW_TRUE ? 0 : -1;
}

void nmTerminateAwt(void) {
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

int nmShouldClose(nmWindow* self) {
    return glfwWindowShouldClose((GLFWwindow*)self);
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

/* ─── Internal accessors used by backend C files ──────────────────────── */

void nm_internal_get_framebuffer_size(const nmWindow* w, int* width, int* height) {
    glfwGetFramebufferSize((GLFWwindow*)w, width, height);
}

#ifdef _WIN32
HWND nm_internal_get_hwnd(const nmWindow* w) {
    return glfwGetWin32Window((GLFWwindow*)w);
}
#endif
