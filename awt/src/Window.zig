//! Thin wrapper around the AWT-C window handle. Holds no widget logic —
//! that belongs to the framework layer above.

const std = @import("std");
const c = @import("c");

const Window = @This();

handle: *c.struct_nmWindow,

pub fn init(title: [:0]const u8, width: u32, height: u32) !Window {
    const h = c.nmCreateWindow(title.ptr, @intCast(width), @intCast(height)) orelse return error.WindowCreateFailed;
    return .{ .handle = h };
}

pub const WindowFlags = packed struct {
    borderless: bool = false,
    no_activate: bool = false,
    floating: bool = false,
    no_taskbar: bool = false,

    fn toCBits(self: WindowFlags) c_int {
        var flags: c_int = 0;
        if (self.borderless) flags |= c.nmWindowFlagBorderless;
        if (self.no_activate) flags |= c.nmWindowFlagNoActivate;
        if (self.floating) flags |= c.nmWindowFlagFloating;
        if (self.no_taskbar) flags |= c.nmWindowFlagNoTaskbar;
        return flags;
    }
};

pub fn initEx(title: [:0]const u8, width: u32, height: u32, flags: WindowFlags) !Window {
    const h = c.nmCreateWindowEx(title.ptr, @intCast(width), @intCast(height), flags.toCBits()) orelse return error.WindowCreateFailed;
    return .{ .handle = h };
}

pub fn initBorderless(title: [:0]const u8, width: u32, height: u32) !Window {
    return initEx(title, width, height, .{
        .borderless = true,
        .floating = true,
        .no_taskbar = true,
    });
}

pub fn deinit(self: *Window) void {
    c.nmDestroyWindow(self.handle);
    self.handle = undefined;
}

/// Replace the window's OS-visible title (title bar, taskbar). Pushes
/// the new value immediately; no event-loop sync diff is involved since
/// title changes are rare.
pub fn setTitle(self: Window, title: [:0]const u8) void {
    c.nmSetWindowTitle(self.handle, title.ptr);
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
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

/// Per-window DPI content scale (a.k.a. DPR). 1.0 on plain 1x displays,
/// 2.0 on Retina, 1.5 on Windows at 150%, etc. `framebufferSize` divided
/// by this gives `size`. Mouse coords delivered by the OS callback are in
/// framebuffer pixels — divide by this scale to translate to logical points.
pub fn contentScale(self: Window) f32 {
    var sx: f32 = 1.0;
    var sy: f32 = 1.0;
    c.nmGetWindowContentScale(self.handle, &sx, &sy);
    // x and y scale are practically always equal on supported platforms.
    return sx;
}

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

/// Window size in the same screen-coordinate units used by `pos` and
/// `setPos`. Use this for OS window placement calculations.
pub fn screenSize(self: Window) Size {
    var w: c_int = 0;
    var h: c_int = 0;
    c.nmGetWindowSize(self.handle, &w, &h);
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// Work area of the monitor containing this window's center, in the same
/// screen-coordinate units used by `pos` and `setPos`.
pub fn monitorWorkarea(self: Window) Rect {
    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    c.nmGetWindowMonitorWorkarea(self.handle, &x, &y, &w, &h);
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

/// Resize the window to `width` x `height` logical points (the same units
/// `size` reports). Fires the resize callback. Pairs with `setSize` driven
/// from the framework layer's window-geometry sync.
pub fn setSize(self: Window, width: i32, height: i32) void {
    // GLFW interprets setSize args as screen coordinates which on DPI-aware
    // Windows are physical pixels. Multiply by content scale so logical
    // input produces the right physical window.
    const scale = self.contentScale();
    const w_phys: c_int = @intFromFloat(@as(f32, @floatFromInt(width)) * scale);
    const h_phys: c_int = @intFromFloat(@as(f32, @floatFromInt(height)) * scale);
    c.nmSetWindowSize(self.handle, w_phys, h_phys);
}

/// Show or hide the OS window. Dialogs are created hidden and toggled on
/// show / close (they are not destroyed on close, unlike Frames).
pub fn setVisible(self: Window, visible: bool) void {
    c.nmSetWindowVisible(self.handle, visible);
}

/// Give the window OS input focus / bring it forward.
pub fn focus(self: Window) void {
    c.nmFocusWindow(self.handle);
}

/// Request user attention: flashes the window / taskbar. Used to flash a
/// modal dialog when the user pokes its (blocked) owner.
pub fn requestAttention(self: Window) void {
    c.nmRequestWindowAttention(self.handle);
}

/// Toggle always-on-top. Used to keep a modal dialog above its owner since
/// GLFW provides no OS-level window modality.
pub fn setFloating(self: Window, floating: bool) void {
    c.nmSetWindowFloating(self.handle, floating);
}

pub const CursorShape = enum { arrow, ibeam, hresize, vresize };

pub fn setCursor(self: Window, shape: CursorShape) void {
    const c_shape: c.nmCursorShape = switch (shape) {
        .arrow => c.nmCursorShapeArrow,
        .ibeam => c.nmCursorShapeIBeam,
        .hresize => c.nmCursorShapeHResize,
        .vresize => c.nmCursorShapeVResize,
    };
    c.nmSetWindowCursor(self.handle, c_shape);
}

/// Logical window size in points — what was requested at `init`. On HiDPI
/// displays this is smaller than `framebufferSize`; user-facing drawing
/// coordinates should be in these units. Derived from framebuffer / scale
/// because GLFW's screen-coordinate API on Windows returns pixels under
/// per-monitor DPI awareness (so we can't trust glfwGetWindowSize alone).
pub fn size(self: Window) Size {
    const fb = self.framebufferSize();
    const scale = self.contentScale();
    if (scale <= 0) return fb;
    return .{
        .width = @intFromFloat(@as(f32, @floatFromInt(fb.width)) / scale),
        .height = @intFromFloat(@as(f32, @floatFromInt(fb.height)) / scale),
    };
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
pub const MoveCallback = c.nmWindowMoveCallback;
pub const FocusCallback = c.nmWindowFocusCallback;
pub const MouseButtonCallback = c.nmMouseButtonCallback;
pub const CursorPosCallback = c.nmCursorPosCallback;
pub const ScrollCallback = c.nmScrollCallback;
pub const KeyCallback = c.nmKeyCallback;
pub const CharCallback = c.nmCharCallback;
pub const CompositionCallback = c.nmCompositionCallback;

pub fn setResizeCallback(self: Window, cb: ResizeCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowResizeCallback(self.handle, cb, user_data);
}

pub fn setRefreshCallback(self: Window, cb: RefreshCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowRefreshCallback(self.handle, cb, user_data);
}

/// Window-move callback. Fires for OS-driven moves (user dragging the title
/// bar) and programmatic `setPos`. The framework layer uses this to keep its
/// screen-position model in sync with the OS.
pub fn setMoveCallback(self: Window, cb: MoveCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowMoveCallback(self.handle, cb, user_data);
}

pub fn setFocusCallback(self: Window, cb: FocusCallback, user_data: ?*anyopaque) void {
    c.nmSetWindowFocusCallback(self.handle, cb, user_data);
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
