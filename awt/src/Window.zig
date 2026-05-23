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

pub const ResizeCallback      = c.nmWindowResizeCallback;
pub const RefreshCallback     = c.nmWindowRefreshCallback;
pub const MouseButtonCallback = c.nmMouseButtonCallback;
pub const CursorPosCallback   = c.nmCursorPosCallback;
pub const ScrollCallback      = c.nmScrollCallback;
pub const KeyCallback         = c.nmKeyCallback;
pub const CharCallback        = c.nmCharCallback;

pub fn setResizeCallback(self: Window, cb: ResizeCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowResizeCallback(self.handle, cb, user_data);
}

pub fn setRefreshCallback(self: Window, cb: RefreshCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowRefreshCallback(self.handle, cb, user_data);
}

pub fn setMouseButtonCallback(self: Window, cb: MouseButtonCallback, user_data: ?*anyopaque) void {
    c.nmSetMouseButtonCallback(self.handle, cb, user_data);
}

pub fn setCursorPosCallback(self: Window, cb: CursorPosCallback, user_data: ?*anyopaque) void {
    c.nmSetCursorPosCallback(self.handle, cb, user_data);
}

pub fn setScrollCallback(self: Window, cb: ScrollCallback, user_data: ?*anyopaque) void {
    c.nmSetScrollCallback(self.handle, cb, user_data);
}

pub fn setKeyCallback(self: Window, cb: KeyCallback, user_data: ?*anyopaque) void {
    c.nmSetKeyCallback(self.handle, cb, user_data);
}

pub fn setCharCallback(self: Window, cb: CharCallback, user_data: ?*anyopaque) void {
    c.nmSetCharCallback(self.handle, cb, user_data);
}

/// System clipboard. Returns null if the clipboard is empty or does not
/// hold UTF-8 text. The returned slice is owned by the underlying C
/// layer and only valid until the next clipboard call — copy if needed.
pub fn getClipboardString(self: Window) ?[:0]const u8 {
    const p = c.nmGetClipboardString(self.handle) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

pub fn setClipboardString(self: Window, text: [:0]const u8) void {
    c.nmSetClipboardString(self.handle, text.ptr);
}
