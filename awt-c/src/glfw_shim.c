#include <GLFW/glfw3.h>
#include "internal.h"

const char* nimbus_glfw_version_string(void) {
    return glfwGetVersionString();
}

int nimbus_glfw_init(void) {
    return glfwInit() == GLFW_TRUE ? 0 : -1;
}

void nimbus_glfw_terminate(void) {
    glfwTerminate();
}
