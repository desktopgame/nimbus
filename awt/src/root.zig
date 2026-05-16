//! Nimbus AWT layer: platform abstraction over the C shim (`awt-c`).

const std = @import("std");

pub const c = @import("c");
pub const Window = @import("Window.zig");

/// Initialize the AWT backend (GLFW). Must be called once before any
/// other AWT call (apart from `backendVersion`).
pub fn init() !void {
    if (c.nimbus_awt_init() != 0) return error.AwtInitFailed;
}

pub fn deinit() void {
    c.nimbus_awt_terminate();
}

/// Pump pending events without blocking.
pub fn pollEvents() void {
    c.nimbus_awt_poll_events();
}

/// Block the calling thread until at least one event arrives.
pub fn waitEvents() void {
    c.nimbus_awt_wait_events();
}

/// Backend identification string (e.g. "3.4.0 Win32 WGL ...").
/// Safe to call before `init`.
pub fn backendVersion() [:0]const u8 {
    const ptr: [*:0]const u8 = @ptrCast(c.nimbus_awt_backend_version());
    return std.mem.span(ptr);
}

test "awt-c build sanity" {
    try std.testing.expectEqual(@as(c_int, 84), c.nimbus_awt_test_double(42));
}

test "backend version reports GLFW 3.4" {
    const ver = backendVersion();
    try std.testing.expect(std.mem.indexOf(u8, ver, "3.4") != null);
}
