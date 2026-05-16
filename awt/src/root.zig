const std = @import("std");

pub const c = @import("c");

test "awt-c shim is callable from zig" {
    try std.testing.expectEqual(@as(c_int, 84), c.nimbus_awt_test_double(42));
}

test "glfw is linked and version string is reachable" {
    const ver_ptr = c.nimbus_glfw_version_string();
    try std.testing.expect(ver_ptr != null);
    const ver = std.mem.span(ver_ptr);
    try std.testing.expect(std.mem.indexOf(u8, ver, "3.4") != null);
}
