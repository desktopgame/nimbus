#include <GLFW/glfw3.h>
#include "internal.h"

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
    GLFWwindow* w = glfwCreateWindow(width, height, title, NULL, NULL);
    if (!w) return NULL;
    glfwMakeContextCurrent(w);
    return (nmWindow*)w;
}

void nmDestroyWindow(nmWindow* self) {
    glfwDestroyWindow((GLFWwindow*)self);
}

int nmShouldClose(nmWindow* self) {
    return glfwWindowShouldClose((GLFWwindow*)self);
}

void nmSwapBuffers(nmWindow* self) {
    glfwSwapBuffers((GLFWwindow*)self);
}

void nmPollEvents(void) {
    glfwPollEvents();
}

void nmWaitEvents(void) {
    glfwWaitEvents();
}
