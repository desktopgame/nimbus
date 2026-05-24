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

/// Set or clear the OS close flag. Clearing (false) lets a window that was
/// closed via its X button be reused — e.g. re-showing a reusable dialog.
pub fn setShouldClose(self: Window, value: bool) void {
    c.nmSetShouldClose(self.handle, value);
}

pub const Size = struct { width: i32, height: i32 };
pub const Point = struct { x: i32, y: i32 };

/// Window position in logical screen units (top-left, relative to the
/// virtual screen). Pairs with `setPos`; used e.g. to center a dialog.
pub fn pos(self: Window) Point {
    var x: c_int = 0;
    var y: c_int = 0;
    c.nmGetWindowPos(self.handle, &x, &y);
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

pub fn setPos(self: Window, x: i32, y: i32) void {
    c.nmSetWindowPos(self.handle, @intCast(x), @intCast(y));
}

/// Show or hide the OS window. Dialogs are created hidden and toggled on
/// show / close (they are not destroyed on close, unlike Frames).
pub fn setVisible(self: Window, visible: bool) void {
    c.nmSetWindowVisible(self.handle, visible);
}

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

pub const ResizeCallback       = c.nmWindowResizeCallback;
pub const RefreshCallback      = c.nmWindowRefreshCallback;
pub const MouseButtonCallback  = c.nmMouseButtonCallback;
pub const CursorPosCallback    = c.nmCursorPosCallback;
pub const ScrollCallback       = c.nmScrollCallback;
pub const KeyCallback          = c.nmKeyCallback;
pub const CharCallback         = c.nmCharCallback;
pub const CompositionCallback  = c.nmCompositionCallback;

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

/// IME preedit callback. The C-layer event struct (`*const c.nmCompositionEvent`)
/// is passed through verbatim — convert to `awt.Event.CompositionEvent` in
/// the bridge layer (e.g. framework.Window.onComposition).
pub fn setCompositionCallback(self: Window, cb: CompositionCallback, user_data: ?*anyopaque) void {
    c.nmSetCompositionCallback(self.handle, cb, user_data);
}

/// Push the current caret position (window-local pixels + line height) so
/// the OS IME can place its candidate window appropriately. Cheap; safe
/// to call on every caret move.
pub fn setCompositionCursorPos(self: Window, x: i32, y: i32, height: i32) void {
    c.nmSetCompositionCursorPos(self.handle, @intCast(x), @intCast(y), @intCast(height));
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
