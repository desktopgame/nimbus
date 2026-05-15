const std = @import("std");

pub const c = @import("c");

test "awt-c shim is callable from zig" {
    try std.testing.expectEqual(@as(c_int, 84), c.nimbus_awt_test_double(42));
}
