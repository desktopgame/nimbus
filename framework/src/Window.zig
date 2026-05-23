//! Top-level UI window. See `framework/doc/window.md`.
//!
//! Wraps awt.Window + awt.Swapchain + a root Container, and routes OS input
//! callbacks into the framework event tree.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const BoxLayout = @import("BoxLayout.zig");

const Window = @This();

container:    Container,
awt_window:   awt.Window,
swapchain:    awt.Swapchain,
context:      *awt.Graphics.Context,
device:       *awt.Device,
app:          *anyopaque,                 // *Application (avoid circular import)
title:        [:0]u8,
background:   awt.Graphics.Color,
fb_w:         i32,
fb_h:         i32,
cursor_x:     f32,
cursor_y:     f32,
paint_dirty:  bool,
layout_dirty: bool,
allocator:    std.mem.Allocator,
dirty_notify: Component.DirtyNotify,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paintWindow,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn init(
    allocator: std.mem.Allocator,
    app_ptr: *anyopaque,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Window {
    const title_dup = try allocator.dupeZ(u8, title);
    errdefer allocator.free(title_dup);

    var aw = try awt.Window.init(title_dup, w, h);
    errdefer aw.deinit();

    var sc = try awt.Swapchain.init(device.*, aw);
    errdefer sc.deinit();

    const fb = aw.framebufferSize();

    var win = Window{
        .container    = Container.init(allocator),
        .awt_window   = aw,
        .swapchain    = sc,
        .context      = context,
        .device       = device,
        .app          = app_ptr,
        .title        = title_dup,
        .background   = awt.Graphics.Color.rgb(0.94, 0.94, 0.94),
        .fb_w         = fb.width,
        .fb_h         = fb.height,
        .cursor_x     = 0,
        .cursor_y     = 0,
        .paint_dirty  = true,
        .layout_dirty = true,
        .allocator    = allocator,
        .dirty_notify = undefined, // filled in install
    };
    win.container.component.vtable = &vtable;
    // Default layout: vertical box. Children fill the window width, height
    // distributed via grow_y. Users can override via window.container.setLayout.
    win.container.layout = BoxLayout.vertical();
    return win;
}

pub fn deinit(self: *Window) void {
    self.container.deinit();      // drops children + container component
    self.swapchain.deinit();
    self.awt_window.deinit();
    self.allocator.free(self.title);
}

pub fn add(self: *Window, child: *Component) !void {
    try self.container.add(child);
}

pub fn addWithHint(
    self: *Window,
    child: *Component,
    hint: *anyopaque,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void {
    try self.container.addWithHint(child, hint, hint_destroy);
}

pub fn setTitle(self: *Window, title: []const u8) !void {
    const new_title = try self.allocator.dupeZ(u8, title);
    self.allocator.free(self.title);
    self.title = new_title;
    // Title is pushed to OS by awt.Window directly here; no Application sync
    // mechanism implemented in v1 (window.md describes one for future).
}

pub fn getTitle(self: Window) []const u8 {
    return self.title;
}

pub fn getBackground(self: Window) awt.Graphics.Color {
    return self.background;
}

pub fn setBackground(self: *Window, color: awt.Graphics.Color) void {
    self.background = color;
    self.paint_dirty = true;
}

pub fn repaint(self: *Window) void {
    self.paint_dirty = true;
    awt.postEmptyEvent();
}

pub fn repaintRect(self: *Window, r: Component.Rect) void {
    _ = r;
    self.repaint();
}

pub fn shouldClose(self: Window) bool {
    return self.awt_window.shouldClose();
}

pub fn dispose(self: *Window) void {
    _ = self;
    // GLFW does not have a "set should close" exposed via our awt-c shim yet.
    // Workaround for v1: a future awt-c addition can wire this. Marking
    // best-effort no-op for now (機能要望).
}

/// Render one frame and clear paint_dirty. Called by Application.run().
pub fn redraw(self: *Window) void {
    if (self.layout_dirty) {
        // Resync the root container to the current window size before painting.
        const win_size = self.awt_window.size();
        const new_bounds = Component.Rect{
            .x = 0, .y = 0,
            .width = @floatFromInt(win_size.width),
            .height = @floatFromInt(win_size.height),
        };
        self.container.setBounds(new_bounds);
        self.layout_dirty = false;
    }

    const cb = awt.CommandBuffer.acquire(self.device.*) catch return;
    defer cb.release();

    self.context.uniforms.reset();
    self.context.vertex_ring.reset();

    cb.begin();
    cb.bindRenderTarget(self.swapchain.getTarget());
    cb.clearColor(self.background.r, self.background.g, self.background.b, self.background.a);
    cb.clearStencil(0);

    const win_size = self.awt_window.size();
    var g = awt.Graphics.init(
        cb,
        self.context,
        win_size.width,
        win_size.height,
        self.fb_w,
        self.fb_h,
    );

    // Paint children directly (skip Window's own paint translate since it
    // would attempt to translate by component.position which is unused here).
    for (self.container.children.items) |elem| {
        elem.component.paintAt(&g);
    }

    cb.end();
    cb.submit(self.device.*);
    self.swapchain.present();

    self.paint_dirty = false;
}

// ── dirty notify wiring ──────────────────────────────────────────────────

fn notifyPaint(user_data: *anyopaque) void {
    const win: *Window = @ptrCast(@alignCast(user_data));
    win.paint_dirty = true;
    awt.postEmptyEvent();
}

fn notifyLayout(user_data: *anyopaque) void {
    const win: *Window = @ptrCast(@alignCast(user_data));
    win.layout_dirty = true;
    win.paint_dirty = true;
    awt.postEmptyEvent();
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) void {
    const cont: *Container = @fieldParentPtr("component", self);
    const win: *Window = @fieldParentPtr("container", cont);
    self.container = cont;

    // Register dirty notification so child component.repaint / markLayoutDirty
    // walks up here and sets our flags.
    win.dirty_notify = .{
        .user_data = @ptrCast(win),
        .paint     = notifyPaint,
        .layout    = notifyLayout,
    };
    self.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&win.dirty_notify), null) catch {};

    // Wire OS-level input callbacks into our dispatcher.
    win.awt_window.setResizeCallback(onResize, @ptrCast(win));
    win.awt_window.setRefreshCallback(onRefresh, @ptrCast(win));
    win.awt_window.setMouseButtonCallback(onMouseButton, @ptrCast(win));
    win.awt_window.setCursorPosCallback(onCursorPos, @ptrCast(win));
    win.awt_window.setScrollCallback(onScroll, @ptrCast(win));
    win.awt_window.setKeyCallback(onKey, @ptrCast(win));
}

fn uninstall(self: *Component) void {
    self.container = null;
}

fn paintWindow(self: *Component, g: *awt.Graphics) void {
    // Used when Window is treated as a generic Component (not via redraw).
    // Just delegate to children rendering.
    const cont = self.container orelse return;
    for (cont.children.items) |elem| {
        elem.component.paintAt(g);
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    // Container.processEvent handles dispatch to children.
    const cont = self.container orelse return;
    Container.vtable.processEvent(&cont.component, ev);
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cont: *Container = @fieldParentPtr("component", self);
    const win: *Window = @fieldParentPtr("container", cont);
    win.deinit();
    allocator.destroy(win);
}

// ── OS callback bridges ──────────────────────────────────────────────────

fn onResize(
    _: ?*awt.c.struct_nmWindow,
    fb_w: c_int,
    fb_h: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    win.swapchain.resize(@intCast(fb_w), @intCast(fb_h)) catch {};
    win.fb_w = @intCast(fb_w);
    win.fb_h = @intCast(fb_h);
    win.layout_dirty = true;
    win.paint_dirty = true;
    // Trigger an immediate redraw so live resize keeps painting on Windows.
    win.redraw();
}

fn onRefresh(_: ?*awt.c.struct_nmWindow, user_data: ?*anyopaque) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    win.paint_dirty = true;
    win.redraw();
}

fn onMouseButton(
    _: ?*awt.c.struct_nmWindow,
    button: awt.c.nmMouseButton,
    action: awt.c.nmKeyAction,
    modifiers: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    const mb = awt.Event.MouseButton.fromC(button);
    const ma = awt.Event.KeyAction.fromC(action);
    const ev_action: awt.Event.MouseAction = switch (ma) {
        .press => .press,
        .release => .release,
        else => return,
    };
    var ev = awt.Event{
        .payload = .{ .mouse = .{
            .x = win.cursor_x,
            .y = win.cursor_y,
            .button = mb,
            .action = ev_action,
            .modifiers = awt.Event.Modifiers.fromCBits(modifiers),
        } },
    };
    win.container.component.vtable.processEvent(&win.container.component, &ev);
}

fn onCursorPos(
    _: ?*awt.c.struct_nmWindow,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    win.cursor_x = @floatCast(x);
    win.cursor_y = @floatCast(y);
    var ev = awt.Event{
        .payload = .{ .mouse = .{
            .x = win.cursor_x,
            .y = win.cursor_y,
            .button = null,
            .action = .move,
        } },
    };
    win.container.component.vtable.processEvent(&win.container.component, &ev);
}

fn onScroll(
    _: ?*awt.c.struct_nmWindow,
    dx: f64,
    dy: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = dx;
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    var ev = awt.Event{
        .payload = .{ .mouse = .{
            .x = win.cursor_x,
            .y = win.cursor_y,
            .button = null,
            .action = .scroll,
            .wheel = @floatCast(dy),
        } },
    };
    win.container.component.vtable.processEvent(&win.container.component, &ev);
}

fn onKey(
    _: ?*awt.c.struct_nmWindow,
    key: awt.c.nmKeyCode,
    action: awt.c.nmKeyAction,
    modifiers: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    var ev = awt.Event{
        .payload = .{ .key = .{
            .code = awt.Event.KeyCode.fromCInt(@intCast(key)),
            .action = awt.Event.KeyAction.fromC(action),
            .modifiers = awt.Event.Modifiers.fromCBits(modifiers),
        } },
    };
    win.container.component.vtable.processEvent(&win.container.component, &ev);
}
