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

pub const Size = struct { width: i32, height: i32 };

/// Logical window size in points — what was requested at `init`. On HiDPI
/// displays this is smaller than `framebufferSize`; user-facing drawing
/// coordinates should be in these units.
pub fn size(self: Window) Size {
    var w: c_int = 0;
    var h: c_int = 0;
    c.nmGetWindowSize(self.handle, &w, &h);
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// Framebuffer pixel size — the actual drawable resolution. On HiDPI displays
/// this is larger than `size`; viewport / scissor / swapchain arithmetic uses
/// these units.
pub fn framebufferSize(self: Window) Size {
    var w: c_int = 0;
    var h: c_int = 0;
    c.nmGetFramebufferSize(self.handle, &w, &h);
    return .{ .width = @intCast(w), .height = @intCast(h) };
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
