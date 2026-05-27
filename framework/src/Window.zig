//! Top-level UI window. See `framework/doc/window.md`.
//!
//! Wraps awt.Window + awt.Swapchain + a root Container, and routes OS input
//! callbacks into the framework event tree.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const dnd = @import("dnd.zig");
const Container = @import("Container.zig");
const BorderLayout = @import("BorderLayout.zig");
const Application = @import("Application.zig");
const log = @import("log.zig");

const Window = @This();

/// Squared pixel distance the cursor must travel from the press point before an
/// armed drag becomes active. Squared to avoid a sqrt in the hot move path.
const DRAG_THRESHOLD_SQ: f32 = 4 * 4;

/// Input model of an overlay. See `framework/doc/overlay.md`.
pub const OverlayPolicy = enum {
    /// Hit-tested; outside-press / ESC dismiss it. Menus, combobox popups.
    modal_popup,
    /// Non-interactive: skipped by hit-test and dismiss, painted only.
    /// Drag ghosts, (future) tooltips.
    passthrough,
};

/// Floating overlay (menu popup, drag ghost, tooltip, etc.) drawn above the
/// container and menu_bar. `modal_popup` entries are hit-tested first and an
/// outside-press dismisses them; `passthrough` entries are paint-only.
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
    /// Input model. Default modal (the common popup case).
    policy:     OverlayPolicy = .modal_popup,
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
/// Desired window geometry in logical screen units, held at the framework
/// layer. `setPos`/`setSize` update these; Application pushes any change to
/// the OS at each event-loop tail (see `application.md`「OS との同期」). The
/// OS resize callback writes the realized size back here so the loop's diff
/// does not fight a live user resize.
win_pos:      awt.Window.Point,
win_size:     awt.Window.Size,
cursor_x:     f32,
cursor_y:     f32,
paint_dirty:  bool,
layout_dirty: bool,
/// Mouse-capture target. While non-null, `.move` and `.release` events
/// bypass hit-testing and go straight to this component. Set when a
/// widget calls `ev.requestCapture(&self.component)` from a `.press`
/// handler; cleared on the matching `.release`.
mouse_capture: ?*Component,
/// Keyboard-focus owner. When non-null, `.key` and `.char` events are
/// delivered only to this component (instead of fan-out via container).
/// Cleared automatically if the owning component is detached.
focus_owner:  ?*Component,
/// When true, `dispatchInput` drops all user input for this window. Set by
/// Application while a modal Dialog is active on a *different* window (the
/// modal one stays false). This is how nimbus implements per-window modality
/// since GLFW/OS do not (see `dialog.md`「モーダル入力ブロック」).
input_blocked: bool,
// ── drag-and-drop controller state (see `framework/doc/dnd.md`) ──
/// A press landed on a component with a `drag_source`; waiting to exceed the
/// movement threshold before the drag actually starts. Null = not armed.
drag_armed:    ?*Component,
/// Window coords of the arming press (threshold + onDragStart origin).
drag_start:    Component.Point,
/// True while a drag is active (onDragStart returned a transfer).
dragging:      bool,
/// The source component of the active drag (for `onDragDone`).
drag_source_c: ?*Component,
/// The payload of the active drag. Valid only while `dragging`.
drag_transfer: dnd.Transfer,
/// The drop target the cursor is currently over (for enter/leave).
drag_target:   ?*Component,
/// Whether the last `onOver` accepted (drives whether `onDrop` fires).
drag_accepted: bool,
allocator:    std.mem.Allocator,
dirty_notify: Component.DirtyNotify,
focus_controller: Component.FocusController,

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
    const init_pos = aw.pos();
    const init_size = aw.size();

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
        .win_pos       = init_pos,
        .win_size      = init_size,
        .cursor_x      = 0,
        .cursor_y      = 0,
        .paint_dirty   = true,
        .layout_dirty  = true,
        .mouse_capture    = null,
        .focus_owner      = null,
        .input_blocked    = false,
        .drag_armed       = null,
        .drag_start       = .{ .x = 0, .y = 0 },
        .dragging         = false,
        .drag_source_c    = null,
        .drag_transfer    = undefined,
        .drag_target      = null,
        .drag_accepted    = false,
        .allocator        = allocator,
        .dirty_notify     = undefined,     // filled in install
        .focus_controller = undefined,     // filled in install
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

/// Move the window's top-left to (`x`, `y`) in logical screen units. The
/// move is applied to the OS at the next event-loop tail by Application's
/// geometry sync — `getPos` reflects the requested value immediately.
pub fn setPos(self: *Window, x: i32, y: i32) void {
    self.win_pos = .{ .x = x, .y = y };
    awt.postEmptyEvent();
}

/// Resize the window to `width` x `height` logical points. Applied to the OS
/// at the next event-loop tail; triggers re-layout once the new size lands.
pub fn setSize(self: *Window, width: i32, height: i32) void {
    self.win_size = .{ .width = width, .height = height };
    self.layout_dirty = true;
    self.paint_dirty = true;
    awt.postEmptyEvent();
}

/// Current window position in logical screen units. Tracks both code-driven
/// `setPos` and OS-driven moves (user dragging the title bar), kept in sync
/// by the window-move callback.
pub fn getPos(self: Window) awt.Window.Point {
    return self.win_pos;
}

/// Current window size in logical points. Tracks both code-driven `setSize`
/// and user resizes (kept in sync by the OS resize callback).
pub fn getSize(self: Window) awt.Window.Size {
    return self.win_size;
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
pub fn setMenuBar(self: *Window, bar: ?*Component) !void {
    if (bar) |b| {
        b.parent = null;
        // Wire dirty-notify + focus-controller so child repaint/markLayoutDirty
        // and requestFocus propagate to this Window (the menu_bar is a
        // separate root, not inside container).
        try b.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&self.dirty_notify), null);
        try b.putProperty(@typeName(Component.FocusController), @ptrCast(&self.focus_controller), null);
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
    try component.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&self.dirty_notify), null);
    try component.putProperty(@typeName(Component.FocusController), @ptrCast(&self.focus_controller), null);
    try self.overlays.append(self.allocator, .{
        .component = component,
        .owner = owner,
        .on_dismiss = on_dismiss,
    });
    self.paint_dirty = true;
    awt.postEmptyEvent();
}

/// Register a `passthrough` overlay (non-interactive, paint-only): a drag
/// ghost or tooltip that floats above everything without being hit-tested or
/// dismissed. `component.position` is window-local. Remove with `removeOverlay`
/// (keyed by the component pointer). See `framework/doc/overlay.md`.
pub fn addPassthroughOverlay(self: *Window, component: *Component) !void {
    component.parent = null;
    try self.overlays.append(self.allocator, .{
        .component = component,
        .owner = @ptrCast(component),
        .on_dismiss = noopDismiss,
        .policy = .passthrough,
    });
    self.paint_dirty = true;
    awt.postEmptyEvent();
}

fn noopDismiss(_: *anyopaque) void {}

/// Index of the topmost `modal_popup` overlay, or null if none is open.
/// `passthrough` entries (ghost/tooltip) are skipped — they do not make the
/// window modal.
fn topModalIndex(self: *Window) ?usize {
    var i: usize = self.overlays.items.len;
    while (i > 0) {
        i -= 1;
        if (self.overlays.items[i].policy == .modal_popup) return i;
    }
    return null;
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

// ── focus management ────────────────────────────────────────────────────

/// Make `c` the keyboard-focus owner. Pass null to clear focus.
/// Dispatches `FocusEvent{ .gained = false }` to the previous owner and
/// `FocusEvent{ .gained = true }` to the new owner (synchronously, not via
/// the event queue), and marks both regions for repaint so focus rings /
/// carets re-render. No-op if the new owner equals the current owner.
pub fn requestFocusFor(self: *Window, c: ?*Component) void {
    if (self.focus_owner == c) return;
    const old = self.focus_owner;
    self.focus_owner = c;
    if (old) |o| {
        var ev = awt.Event{ .payload = .{ .focus = .{ .gained = false } } };
        o.vtable.processEvent(o, &ev);
        o.repaint();
    }
    if (c) |n| {
        var ev = awt.Event{ .payload = .{ .focus = .{ .gained = true } } };
        n.vtable.processEvent(n, &ev);
        n.repaint();
    }
}

/// Dismiss every `modal_popup` overlay, top-down, invoking each on_dismiss so
/// owners can update their `open` state. Used for outside-click / ESC.
/// `passthrough` entries (drag ghost) are left in place.
pub fn dismissAllOverlays(self: *Window) void {
    var i: usize = self.overlays.items.len;
    while (i > 0) {
        i -= 1;
        if (self.overlays.items[i].policy != .modal_popup) continue;
        const e = self.overlays.orderedRemove(i);
        e.on_dismiss(e.owner);
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

fn install(self: *Component) !void {
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
    try self.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&win.dirty_notify), null);

    // Focus controller — lets descendants call `c.requestFocus()` and have
    // it bubble back to this Window via property lookup.
    win.focus_controller = .{
        .user_data         = @ptrCast(win),
        .request_focus_for = focusControllerCallback,
    };
    try self.putProperty(@typeName(Component.FocusController), @ptrCast(&win.focus_controller), null);

    // Wire OS-level input callbacks into our dispatcher.
    win.awt_window.setResizeCallback(onResize, @ptrCast(win));
    win.awt_window.setRefreshCallback(onRefresh, @ptrCast(win));
    win.awt_window.setMoveCallback(onWindowPos, @ptrCast(win));
    win.awt_window.setMouseButtonCallback(onMouseButton, @ptrCast(win));
    win.awt_window.setCursorPosCallback(onCursorPos, @ptrCast(win));
    win.awt_window.setScrollCallback(onScroll, @ptrCast(win));
    win.awt_window.setKeyCallback(onKey, @ptrCast(win));
    win.awt_window.setCharCallback(onChar, @ptrCast(win));
    win.awt_window.setCompositionCallback(onComposition, @ptrCast(win));
}

fn focusControllerCallback(user_data: *anyopaque, c: ?*Component) void {
    const win: *Window = @ptrCast(@alignCast(user_data));
    win.requestFocusFor(c);
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
    // Modality gate: a modal Dialog elsewhere blocks all input to this window.
    // Composition/focus are internal-ish but blocking everything is simplest
    // and a blocked window should not be the focus/IME target anyway.
    if (self.input_blocked) {
        // Poking a window behind a modal flashes the modal (Swing-style
        // "deal with me first"). Only react to deliberate presses, not
        // passive moves / scroll, so the dialog doesn't flash on hover.
        if (isAttentionPoke(ev)) {
            const app: *Application = @ptrCast(@alignCast(self.app));
            app.flashActiveModal();
        }
        return;
    }
    switch (ev.payload) {
        .mouse => |m| {
            // 0a. Active DnD drag: the controller owns move/release; normal
            //     dispatch is suspended until the drag ends.
            if (self.dragging) {
                switch (m.action) {
                    .move => self.updateDrag(m.x, m.y),
                    .release => self.finishDrag(m.x, m.y),
                    else => {},
                }
                return;
            }
            // 0b. Armed (pressed on a draggable): promote to an active drag once
            //     the cursor moves past the threshold.
            if (self.drag_armed != null and m.action == .move) {
                const dx = m.x - self.drag_start.x;
                const dy = m.y - self.drag_start.y;
                if (dx * dx + dy * dy >= DRAG_THRESHOLD_SQ) {
                    if (self.beginDrag(m.x, m.y)) return; // started → consume this move
                    // onDragStart declined: disarm, fall through to normal move.
                }
            }
            if (m.action == .release) self.drag_armed = null;

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

            // 2. Overlays (top-down). Only when a modal popup is open; the
            //    drag ghost / tooltips are passthrough and never gate input.
            if (self.topModalIndex() != null) {
                var hit_overlay = false;
                var i: usize = self.overlays.items.len;
                while (i > 0) {
                    i -= 1;
                    const entry = self.overlays.items[i];
                    if (entry.policy == .passthrough) continue; // non-interactive
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
            const focus_before = self.focus_owner;
            self.container.component.vtable.processEvent(&self.container.component, ev);
            if (m.action == .press) {
                if (ev.capture_target) |t| {
                    self.mouse_capture = @ptrCast(@alignCast(t));
                }
                // Auto-focus fallback: if the press landed on a focusable
                // widget, make it the focus owner. We approximate "landed on"
                // by hit-testing the container subtree against window-local
                // coords. menu_bar / overlay clicks are excluded earlier
                // (they returned before reaching this branch).
                //
                // Only when the dispatch did NOT already set focus itself: a
                // widget that called requestFocus during the press wins. This
                // matters for focus targets the child-walk cannot reach — e.g.
                // a List materializes its cells outside the container tree, so
                // its in-cell editor field is invisible to findFocusableAt.
                if (self.focus_owner == focus_before) {
                    if (self.findFocusableAt(m.x, m.y)) |w| self.requestFocusFor(w)
                    else self.requestFocusFor(null);
                }
                // DnD: arm a drag gesture if the press landed on a draggable and
                // nothing grabbed the mouse (a captured widget / button takes
                // precedence). Promotion to an active drag happens on the next
                // move past the threshold (see the `.move` handling above).
                if (ev.capture_target == null and !ev.isConsumed()) {
                    self.drag_armed = self.findDraggableAt(m.x, m.y);
                    self.drag_start = .{ .x = m.x, .y = m.y };
                }
            }
        },
        .key => {
            // ESC cancels an active drag; all keys are swallowed while dragging.
            if (self.dragging) {
                const k = ev.payload.key;
                if (k.code == .escape and k.action == .press) self.cancelDrag();
                return;
            }
            // Overlays first (e.g., ESC closes top overlay).
            if (self.topModalIndex()) |ti| {
                const top = self.overlays.items[ti];
                top.component.vtable.processEvent(top.component, ev);
                if (ev.isConsumed()) return;
                if (ev.payload.key.code == .escape and ev.payload.key.action == .press) {
                    self.dismissAllOverlays();
                    return;
                }
                return;  // modal: don't propagate
            }
            // Focused widget gets first shot.
            if (self.focus_owner) |fo| {
                fo.vtable.processEvent(fo, ev);
                if (ev.isConsumed()) return;
            }
            if (self.menu_bar) |bar| {
                bar.vtable.processEvent(bar, ev);
                if (ev.isConsumed()) return;
            }
            // Fan-out fallback when no focus owner consumed the key.
            if (self.focus_owner == null) {
                self.container.component.vtable.processEvent(&self.container.component, ev);
            }
        },
        .char => {
            if (self.topModalIndex()) |ti| {
                const top = self.overlays.items[ti];
                top.component.vtable.processEvent(top.component, ev);
                return;  // modal
            }
            if (self.focus_owner) |fo| {
                fo.vtable.processEvent(fo, ev);
                return;  // text input only goes to focused widget
            }
            // No focus owner: drop on the floor (nothing to type into).
        },
        .focus => {
            // Focus events are dispatched synchronously by requestFocusFor
            // (B-2) directly to the gaining/losing component — they should
            // not normally arrive here via the event queue. No-op as a safety net.
        },
        .composition => {
            // IME preedit. v1 wiring: not yet routed to focus_owner (the
            // TextField-side handler is the next milestone). Drop silently
            // so awt-c can still fire the callback without breaking.
        },
    }
}

/// Thunk for EventQueue.postEvent so awt can store a type-erased pointer.
fn dispatchInputThunk(target: *anyopaque, ev: *awt.Event) void {
    const win: *Window = @ptrCast(@alignCast(target));
    win.dispatchInput(ev);
}

/// True for events that count as the user deliberately trying to interact
/// with a window (mouse button press, key press) — used to decide whether
/// poking a modal-blocked window should flash the modal. Excludes passive
/// move / scroll / release so the modal does not flash on mere hover.
fn isAttentionPoke(ev: *const awt.Event) bool {
    return switch (ev.payload) {
        .mouse => |m| m.action == .press,
        .key   => |k| k.action == .press,
        else   => false,
    };
}

/// Walk the container subtree (children top-most-first), returning the
/// deepest focusable component whose absolute window-bounds contain
/// (`x`, `y`). Used by the dispatcher to auto-focus on left-press.
fn findFocusableAt(self: *Window, x: f32, y: f32) ?*Component {
    return findFocusableInSubtree(&self.container.component, x, y);
}

fn findFocusableInSubtree(c: *Component, x: f32, y: f32) ?*Component {
    if (!c.containsWindowPoint(x, y)) return null;
    // Descend into children first so a focusable inside a container wins
    // over the container itself.
    if (c.container) |cont| {
        var i: usize = cont.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = cont.children.items[i].component;
            if (findFocusableInSubtree(child, x, y)) |hit| return hit;
        }
    }
    return if (c.focusable) c else null;
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cont: *Container = @fieldParentPtr("component", self);
    const win: *Window = @fieldParentPtr("container", cont);
    win.deinit();
    allocator.destroy(win);
}

// ── drag-and-drop controller ─────────────────────────────────────────────
// Source-agnostic entry points. v1 feeds them from the in-app mouse gesture;
// a future OS-drop layer can call the same updateDrag/finishDrag. See
// `framework/doc/dnd.md`「ドラッグの司令塔」.

/// Promote the armed gesture to an active drag. Calls the source's
/// `onDragStart` with the press point in source-local coords; returns true if
/// it produced a transfer (drag started) and runs the first `updateDrag`.
fn beginDrag(self: *Window, wx: f32, wy: f32) bool {
    const src = self.drag_armed orelse return false;
    self.drag_armed = null;
    const ds = src.drag_source orelse return false;
    const o = src.absoluteOriginInWindow();
    const transfer = ds.onDragStart(ds.user_data, self.drag_start.x - o.x, self.drag_start.y - o.y) orelse
        return false;
    self.drag_transfer = transfer;
    self.drag_source_c = src;
    self.dragging = true;
    self.drag_target = null;
    self.drag_accepted = false;
    self.updateDrag(wx, wy);
    return true;
}

/// Resolve the drop target under the cursor, drive enter/over/leave, and record
/// whether the current point is droppable.
fn updateDrag(self: *Window, wx: f32, wy: f32) void {
    const target = self.findDropTargetAt(wx, wy);
    if (target != self.drag_target) {
        if (self.drag_target) |old| {
            if (old.drop_target.?.onLeave) |on_leave| on_leave(old.drop_target.?.user_data);
        }
        self.drag_target = target;
        if (target) |t| {
            if (t.drop_target.?.onEnter) |on_enter| {
                var e = self.makeDragEvent(t, wx, wy);
                on_enter(t.drop_target.?.user_data, &e);
            }
        }
    }
    if (target) |t| {
        var e = self.makeDragEvent(t, wx, wy);
        self.drag_accepted = t.drop_target.?.onOver(t.drop_target.?.user_data, &e);
    } else {
        self.drag_accepted = false;
    }
    // Hand the source the cursor position (window coords) every move, so it can
    // drive its own ghost / feedback. nimbus draws no ghost itself.
    if (self.drag_source_c) |src| {
        if (src.drag_source.?.onDrag) |on_drag| on_drag(src.drag_source.?.user_data, wx, wy);
    }
    self.repaint();
}

/// Release: commit the drop if accepted, then notify the source. Ends the drag.
fn finishDrag(self: *Window, wx: f32, wy: f32) void {
    const dropped = self.drag_accepted and self.drag_target != null;
    if (dropped) {
        const t = self.drag_target.?;
        var e = self.makeDragEvent(t, wx, wy);
        t.drop_target.?.onDrop(t.drop_target.?.user_data, &e);
    } else if (self.drag_target) |t| {
        if (t.drop_target.?.onLeave) |on_leave| on_leave(t.drop_target.?.user_data);
    }
    if (self.drag_source_c) |src| {
        if (src.drag_source.?.onDragDone) |on_done| {
            on_done(src.drag_source.?.user_data, if (dropped) .move else null);
        }
    }
    self.endDrag();
}

/// Cancel an active drag (ESC): clear feedback, tell the source nothing landed.
fn cancelDrag(self: *Window) void {
    if (self.drag_target) |t| {
        if (t.drop_target.?.onLeave) |on_leave| on_leave(t.drop_target.?.user_data);
    }
    if (self.drag_source_c) |src| {
        if (src.drag_source.?.onDragDone) |on_done| on_done(src.drag_source.?.user_data, null);
    }
    self.endDrag();
}

fn endDrag(self: *Window) void {
    self.dragging = false;
    self.drag_target = null;
    self.drag_source_c = null;
    self.drag_accepted = false;
    self.repaint();
}

/// Build a `DragEvent` with the cursor translated into `target`-local coords.
/// v1 always reports `.move` (move events carry no modifiers, so copy/move
/// switching is deferred — see `dnd.md`).
fn makeDragEvent(self: *Window, target: *Component, wx: f32, wy: f32) dnd.DragEvent {
    const o = target.absoluteOriginInWindow();
    return .{
        .x = wx - o.x,
        .y = wy - o.y,
        .transfer = &self.drag_transfer,
        .action = .move,
    };
}

fn findDraggableAt(self: *Window, x: f32, y: f32) ?*Component {
    return findCapabilityInSubtree(&self.container.component, x, y, .drag);
}

fn findDropTargetAt(self: *Window, x: f32, y: f32) ?*Component {
    return findCapabilityInSubtree(&self.container.component, x, y, .drop);
}

const Capability = enum { drag, drop };

/// Deepest component under (`x`, `y`) carrying the requested DnD capability.
/// Walks the container tree top-most-first (mirrors `findFocusableInSubtree`).
/// Note: List cells live outside the container tree, so a draggable/droppable
/// List is found at the List component itself (its `onDragStart` maps the local
/// point to a row) — see `dnd.md`「List の行並べ替え」.
fn findCapabilityInSubtree(c: *Component, x: f32, y: f32, cap: Capability) ?*Component {
    if (!c.containsWindowPoint(x, y)) return null;
    if (c.container) |cont| {
        var i: usize = cont.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = cont.children.items[i].component;
            if (findCapabilityInSubtree(child, x, y, cap)) |hit| return hit;
        }
    }
    const has = switch (cap) {
        .drag => c.drag_source != null,
        .drop => c.drop_target != null,
    };
    return if (has) c else null;
}

// ── OS callback bridges ──────────────────────────────────────────────────

fn onResize(
    _: ?*awt.c.struct_nmWindow,
    fb_w: c_int,
    fb_h: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    win.swapchain.resize(@intCast(fb_w), @intCast(fb_h)) catch |err|
        log.warn("window", "swapchain.resize ({d}x{d}) failed: {s}", .{ fb_w, fb_h, @errorName(err) });
    win.fb_w = @intCast(fb_w);
    win.fb_h = @intCast(fb_h);
    // Track the realized logical size in our geometry model and mark it as
    // already synced with the OS, so Application's loop-tail diff does not
    // push this size back (which would fight a live user resize). See
    // `application.md`「OS との同期」.
    win.win_size = win.awt_window.size();
    const app: *Application = @ptrCast(@alignCast(win.app));
    app.noteOsGeometry(win);
    win.layout_dirty = true;
    win.paint_dirty = true;
    // Trigger an immediate redraw so live resize keeps painting on Windows.
    win.redraw();
}

fn onWindowPos(
    _: ?*awt.c.struct_nmWindow,
    x: c_int,
    y: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    // OS moved the window (user drag, or our own setPos echoing back). Write
    // the new screen position into the geometry model and mark it synced so
    // Application's loop-tail diff does not push it back. See
    // `application.md`「OS との同期」.
    win.win_pos = .{ .x = @intCast(x), .y = @intCast(y) };
    const app: *Application = @ptrCast(@alignCast(win.app));
    app.noteOsGeometry(win);
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
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch |err|
        log.warn("window", "input dropped (mouse button): {s}", .{@errorName(err)});
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
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch |err|
        log.warn("window", "input dropped (cursor move): {s}", .{@errorName(err)});
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
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch |err|
        log.warn("window", "input dropped (scroll): {s}", .{@errorName(err)});
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
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch |err|
        log.warn("window", "input dropped (key): {s}", .{@errorName(err)});
}

fn onChar(
    _: ?*awt.c.struct_nmWindow,
    codepoint: u32,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    const ev = awt.Event{
        .payload = .{ .char = .{ .codepoint = codepoint } },
    };
    win.event_queue.postEvent(ev, @ptrCast(win), dispatchInputThunk) catch |err|
        log.warn("window", "input dropped (char): {s}", .{@errorName(err)});
}

/// Composition events carry a *borrowed* UTF-8 string owned by awt-c
/// that is only valid for the duration of this callback. We therefore
/// dispatch synchronously to `focus_owner` instead of going through the
/// event queue (which would defer dispatch past the borrow window).
fn onComposition(
    _: ?*awt.c.struct_nmWindow,
    ev_c: ?*const awt.c.nmCompositionEvent,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(user_data.?));
    const c_ev = ev_c orelse return;
    const text: []const u8 = if (c_ev.text != null and c_ev.text_len > 0)
        c_ev.text[0..c_ev.text_len]
    else
        &[_]u8{};

    var ev = awt.Event{ .payload = .{ .composition = .{
        .text = text,
        .target_start = c_ev.target_start,
        .target_end = c_ev.target_end,
    } } };
    if (win.focus_owner) |fo| {
        fo.vtable.processEvent(fo, &ev);
    }
}
