//! Thin wrapper around the AWT-C window handle. Holds no widget logic —
//! that belongs to the framework layer above.

const std = @import("std");
const c = @import("c");

const Window = @This();

handle: *c.struct_nimbus_window,

pub fn init(title: [:0]const u8, width: u32, height: u32) !Window {
    const h = c.nimbus_window_create(title.ptr, @intCast(width), @intCast(height))
        orelse return error.WindowCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Window) void {
    c.nimbus_window_destroy(self.handle);
    self.handle = undefined;
}

pub fn shouldClose(self: Window) bool {
    return c.nimbus_window_should_close(self.handle) != 0;
}

pub fn swapBuffers(self: Window) void {
    c.nimbus_window_swap_buffers(self.handle);
}
