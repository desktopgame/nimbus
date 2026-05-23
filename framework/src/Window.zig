//! Top-level UI window. See `framework/doc/window.md`.
//!
//! Wraps awt.Window + awt.Swapchain + a root Container, and routes OS input
//! callbacks into the framework event tree.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const BorderLayout = @import("BorderLayout.zig");

const Window = @This();

/// Floating overlay (menu popup, tooltip, etc.) drawn above the container
/// and menu_bar. Hit-tested first; outside-press dismisses everything.
pub const OverlayEntry = struct {
    /// Root component of the overlay subtree. Its `position` is window-local
    /// (the overlay's top-left), parent must be null. Children's
    /// `absoluteOriginInWindow` walks up and includes the root's position,
    /// so window-local mouse coords hit-test correctly.
    component:  *Component,
    /// Opaque owner (Menu / PopupMenu) for the dismiss callback.
    owner:      *anyopaque,
    /// Called when the overlay is removed (by outside-press, ESC, or
    /// programmatic dismissAllOverlays). Owner updates its `open` state.
    on_dismiss: *const fn (*anyopaque) void,
};

container:    Container,
awt_window:   awt.Window,
swapchain:    awt.Swapchain,
context:      *awt.Graphics.Context,
device:       *awt.Device,
app:          *anyopaque,                 // *Application (avoid circular import)
/// Borrowed reference to the Application-owned EventQueue. Input
/// callbacks post events here instead of dispatching synchronously,
/// so input / invokeLater / redraw all serialize through the same
/// queue (see `framework/doc/window.md`「イベント post と dispatch」).
event_queue:  *awt.EventQueue,
/// Optional top-strip menu bar. Generic `*Component` (typically the
/// `&MenuBar.component` set via Frame.setMenuBar). Not owned by Window —
/// Frame manages lifetime. When non-null, the container is laid out
/// below it (container.position.y = menu_bar.size.height).
menu_bar:     ?*Component,
/// Floating overlays (popups). Bottom = first opened, top = most recent.
overlays:     std.ArrayList(OverlayEntry),
/// Dirty-notify pointer used by overlays/menu_bar that share Window's
/// repaint propagation (same value the container's root uses via property).
title:        [:0]u8,
background:   awt.Graphics.Color,
fb_w:         i32,
fb_h:         i32,
cursor_x:     f32,
cursor_y:     f32,
paint_dirty:  bool,
layout_dirty: bool,
/// Mouse-capture target. While non-null, `.move` and `.release` events
/// bypass hit-testing and go straight to this component. Set when a
/// widget calls `ev.requestCapture(&self.component)` from a `.press`
/// handler; cleared on the matching `.release`.
mouse_capture: ?*Component,
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
    event_queue: *awt.EventQueue,
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
        .container     = Container.init(allocator),
        .awt_window    = aw,
        .swapchain     = sc,
        .context       = context,
        .device        = device,
        .app           = app_ptr,
        .event_queue   = event_queue,
        .menu_bar      = null,
        .overlays      = .empty,
        .title         = title_dup,
        .background    = awt.Graphics.Color.rgb(0.94, 0.94, 0.94),
        .fb_w          = fb.width,
        .fb_h          = fb.height,
        .cursor_x      = 0,
        .cursor_y      = 0,
        .paint_dirty   = true,
        .layout_dirty  = true,
        .mouse_capture = null,
        .allocator     = allocator,
        .dirty_notify  = undefined, // filled in install
    };
    win.container.component.vtable = &vtable;
    // Default layout: BorderLayout. Lets users compose a toolbar / status /
    // sidebar / center shell with no additional setup. Override via
    // `window.container.setLayout` if a different layout is desired.
    win.container.layout = BorderLayout.get();
    return win;
}

pub fn deinit(self: *Window) void {
    // Overlays are not owned (Menu/PopupMenu owners hold them) — just drop the list.
    // menu_bar is owned by Frame, not Window — do not destroy.
    self.overlays.deinit(self.allocator);
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
        const win_size = self.awt_window.size();
        const win_w: f32 = @floatFromInt(win_size.width);
        const win_h: f32 = @floatFromInt(win_size.height);
        const bar_h: f32 = if (self.menu_bar) |bar| bar.min_size.height else 0;

        if (self.menu_bar) |bar| {
            bar.setBounds(.{ .x = 0, .y = 0, .width = win_w, .height = bar_h });
        }
        self.container.setBounds(.{
            .x = 0, .y = bar_h,
            .width = win_w,
            .height = @max(0, win_h - bar_h),
        });
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

    // 1. Container. Use paintAt so the clip translates by container.position
    //    (which is non-zero when a menu_bar is set, shifting content down).
    self.container.component.paintAt(&g);
    // 2. menu_bar (above container)
    if (self.menu_bar) |bar| {
        bar.paintAt(&g);
    }
    // 3. Overlays (above everything; bottom = oldest, top = newest)
    for (self.overlays.items) |entry| {
        entry.component.paintAt(&g);
    }

    cb.end();
    cb.submit(self.device.*);
    self.swapchain.present();

    self.paint_dirty = false;
}

// ── menu_bar / overlays management ───────────────────────────────────────

/// Set or clear the top-strip menu bar. The component is **not owned** by
/// Window — caller (Frame) handles lifetime. Pass null to remove.
/// Triggers re-layout (container y-offset adjusts to bar height).
pub fn setMenuBar(self: *Window, bar: ?*Component) void {
    if (bar) |b| {
        b.parent = null;
        // Wire dirty-notify so child repaint/markLayoutDirty propagates up
        // to this Window (the menu_bar is a separate root, not inside container).
        b.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&self.dirty_notify), null) catch {};
    }
    self.menu_bar = bar;
    self.layout_dirty = true;
    self.paint_dirty = true;
    awt.postEmptyEvent();
}

/// Register an overlay. The component's `parent` will be set to null and
/// dirty-notify wired to this Window. Position should already be set
/// (window-local coordinates).
pub fn addOverlay(
    self: *Window,
    component: *Component,
    owner: *anyopaque,
    on_dismiss: *const fn (*anyopaque) void,
) !void {
    component.parent = null;
    component.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&self.dirty_notify), null) catch {};
    try self.overlays.append(self.allocator, .{
        .component = component,
        .owner = owner,
        .on_dismiss = on_dismiss,
    });
    self.paint_dirty = true;
    awt.postEmptyEvent();
}

/// Remove the overlay registered by `owner`. No-op if not found.
/// Does NOT call on_dismiss (caller is presumably the owner itself).
pub fn removeOverlay(self: *Window, owner: *anyopaque) void {
    var i: usize = 0;
    while (i < self.overlays.items.len) : (i += 1) {
        if (self.overlays.items[i].owner == owner) {
            _ = self.overlays.orderedRemove(i);
            self.paint_dirty = true;
            awt.postEmptyEvent();
            return;
        }
    }
}

/// Dismiss every overlay, top-down, invoking each on_dismiss callback so
/// owners can update their `open` state. Used for outside-click / ESC.
pub fn dismissAllOverlays(self: *Window) void {
    while (self.overlays.items.len > 0) {
        const top = self.overlays.pop().?;
        top.on_dismiss(top.owner);
    }
    self.paint_dirty = true;
    awt.postEmptyEvent();
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

/// Dispatch an input event to this window's component tree, honoring
/// mouse capture, overlays (popups), and the optional menu bar. Order:
///   1. mouse_capture (drag continuation)
///   2. overlays (top-down hit-test; outside-press dismisses all)
///   3. menu_bar
///   4. container
pub fn dispatchInput(self: *Window, ev: *awt.Event) void {
    switch (ev.payload) {
        .mouse => |m| {
            // 1. Mouse-capture priority (active drag).
            if (m.action == .release and self.mouse_capture != null) {
                const cap = self.mouse_capture.?;
                cap.vtable.processEvent(cap, ev);
                self.mouse_capture = null;
                return;
            }
            if (m.action == .move and self.mouse_capture != null) {
                const cap = self.mouse_capture.?;
                cap.vtable.processEvent(cap, ev);
                return;
            }

            // 2. Overlays (top-down).
            if (self.overlays.items.len > 0) {
                var hit_overlay = false;
                var i: usize = self.overlays.items.len;
                while (i > 0) {
                    i -= 1;
                    const entry = self.overlays.items[i];
                    if (entry.component.containsWindowPoint(m.x, m.y)) {
                        entry.component.vtable.processEvent(entry.component, ev);
                        hit_overlay = true;
                        if (m.action == .press) {
                            if (ev.capture_target) |t| {
                                self.mouse_capture = @ptrCast(@alignCast(t));
                            }
                        }
                        break;
                    }
                }
                if (!hit_overlay) {
                    if (m.action == .press) {
                        // Outside-click while popup is open: dismiss all,
                        // swallow the click (do not propagate to bar/container).
                        self.dismissAllOverlays();
                    }
                    // Hover/scroll outside overlay is also swallowed while
                    // popup is open (typical menu modal feel).
                    return;
                }
                // If consumed, we're done. Otherwise still don't bubble below
                // overlays — overlays are modal.
                return;
            }

            // 3. menu_bar (above container if no overlay handled the event).
            if (self.menu_bar) |bar| {
                const over_bar = bar.containsWindowPoint(m.x, m.y);
                if (m.action == .move) {
                    // Always dispatch .move to the bar (even when outside)
                    // so its menus can clear rollover when cursor leaves.
                    bar.vtable.processEvent(bar, ev);
                } else if (over_bar) {
                    bar.vtable.processEvent(bar, ev);
                    if (m.action == .press) {
                        if (ev.capture_target) |t| {
                            self.mouse_capture = @ptrCast(@alignCast(t));
                        }
                    }
                    if (ev.isConsumed()) return;
                }
            }

            // 4. Container.
            self.container.component.vtable.processEvent(&self.container.component, ev);
            if (m.action == .press) {
                if (ev.capture_target) |t| {
                    self.mouse_capture = @ptrCast(@alignCast(t));
                }
            }
        },
        .key => {
            // Overlays first (e.g., ESC closes top overlay).
            if (self.overlays.items.len > 0) {
                const top = self.overlays.items[self.overlays.items.len - 1];
                top.component.vtable.processEvent(top.component, ev);
                if (ev.isConsumed()) return;
                if (ev.payload.key.code == .escape and ev.payload.key.action == .press) {
                    self.dismissAllOverlays();
                    return;
                }
                return;  // modal: don't propagate
            }
            if (self.menu_bar) |bar| {
                bar.vtable.processEvent(bar, ev);
                if (ev.isConsumed()) return;
            }
            self.container.component.vtable.processEvent(&self.container.component, ev);
        },
    }
}

/// Thunk for EventQueue.postEvent so awt can store a type-erased pointer.
fn dispatchInputThunk(target: *anyopaque, ev: *awt.Event) void {
    const win: *Window = @ptrCast(@alignCast(target));
    win.dispatchInput(ev);
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
    const ev = awt.Event{
        .payload = .{ .mouse = .{
            .x = win.cursor_x,
            .y = win.cursor_y,
            .button = mb,
            .action = ev_action,
            .modifiers = awt.Event.Modifiers.fromCBits(modifiers),
        } },
    };
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch {};
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
    const ev = awt.Event{
        .payload = .{ .mouse = .{
            .x = win.cursor_x,
            .y = win.cursor_y,
            .button = null,
            .action = .move,
        } },
    };
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch {};
}

fn onScroll(
    _: ?*awt.c.struct_nmWindow,
    dx: f64,
    dy: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = dx;
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    const ev = awt.Event{
        .payload = .{ .mouse = .{
            .x = win.cursor_x,
            .y = win.cursor_y,
            .button = null,
            .action = .scroll,
            .wheel = @floatCast(dy),
        } },
    };
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch {};
}

fn onKey(
    _: ?*awt.c.struct_nmWindow,
    key: awt.c.nmKeyCode,
    action: awt.c.nmKeyAction,
    modifiers: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    const ev = awt.Event{
        .payload = .{ .key = .{
            .code = awt.Event.KeyCode.fromCInt(@intCast(key)),
            .action = awt.Event.KeyAction.fromC(action),
            .modifiers = awt.Event.Modifiers.fromCBits(modifiers),
        } },
    };
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch {};
}
