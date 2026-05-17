//! Thin wrapper around the AWT-C window handle. Holds no widget logic —
//! that belongs to the framework layer above.

const std = @import("std");
const c = @import("c");

const Window = @This();

handle: *c.struct_nmWindow,

pub fn init(title: [:0]const u8, width: u32, height: u32) !Window {
    const h = c.nmCreateWindow(title.ptr, @intCast(width), @intCast(height))
        orelse return error.WindowCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Window) void {
    c.nmDestroyWindow(self.handle);
    self.handle = undefined;
}

pub fn shouldClose(self: Window) bool {
    return c.nmShouldClose(self.handle);
}

pub fn swapBuffers(self: Window) void {
    c.nmSwapBuffers(self.handle);
}

pub const ResizeCallback = c.nmWindowResizeCallback;
pub const RefreshCallback = c.nmWindowRefreshCallback;

pub fn setResizeCallback(self: Window, cb: ResizeCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowResizeCallback(self.handle, cb, user_data);
}

pub fn setRefreshCallback(self: Window, cb: RefreshCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowRefreshCallback(self.handle, cb, user_data);
}
