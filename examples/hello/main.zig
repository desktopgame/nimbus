const std = @import("std");
const nimbus = @import("nimbus");

pub fn main() !void {
    const c = nimbus.awt.c;

    std.debug.print("nimbus_awt_test_double(21) = {d}\n", .{c.nimbus_awt_test_double(21)});
    std.debug.print("GLFW version: {s}\n", .{c.nimbus_glfw_version_string()});

    if (c.nimbus_glfw_init() != 0) {
        std.debug.print("glfwInit failed\n", .{});
        return;
    }
    defer c.nimbus_glfw_terminate();
    std.debug.print("glfwInit OK\n", .{});
}
