#include <GLFW/glfw3.h>
#include "internal.h"

int nimbus_awt_init(void) {
    return glfwInit() == GLFW_TRUE ? 0 : -1;
}

void nimbus_awt_terminate(void) {
    glfwTerminate();
}

const char* nimbus_awt_backend_version(void) {
    return glfwGetVersionString();
}

nimbus_window* nimbus_window_create(const char* title, int width, int height) {
    GLFWwindow* w = glfwCreateWindow(width, height, title, NULL, NULL);
    if (!w) return NULL;
    glfwMakeContextCurrent(w);
    return (nimbus_window*)w;
}

void nimbus_window_destroy(nimbus_window* w) {
    glfwDestroyWindow((GLFWwindow*)w);
}

int nimbus_window_should_close(nimbus_window* w) {
    return glfwWindowShouldClose((GLFWwindow*)w);
}

void nimbus_window_swap_buffers(nimbus_window* w) {
    glfwSwapBuffers((GLFWwindow*)w);
}

void nimbus_awt_poll_events(void) {
    glfwPollEvents();
}

void nimbus_awt_wait_events(void) {
    glfwWaitEvents();
}
