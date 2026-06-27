//! Top-level UI window. See `framework/doc/window.md`.
//!
//! Wraps awt.Window + awt.Swapchain + a root Container, and routes OS input
//! callbacks into the framework event tree.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const dnd = @import("dnd.zig");
const OverlayManager = @import("OverlayManager.zig");
const Container = @import("Container.zig");
const BorderLayout = @import("BorderLayout.zig");
const Application = @import("Application.zig");
const keybinding = @import("keybinding.zig");
const MenuBar = @import("MenuBar.zig");
const Menu = @import("Menu.zig");
const MenuItem = @import("MenuItem.zig");
const Button = @import("Button.zig");
const log = @import("log.zig");

const Window = @This();

/// Squared pixel distance the cursor must travel from the press point before an
/// armed drag becomes active. Squared to avoid a sqrt in the hot move path.
const DRAG_THRESHOLD_SQ: f32 = 4 * 4;

// Overlay types live in `OverlayManager`. Re-exported for callers that still
// say `Window.OverlayEntry` / `Window.OverlayPolicy`.
pub const OverlayEntry = OverlayManager.OverlayEntry;
pub const OverlayPolicy = OverlayManager.OverlayPolicy;

container: Container,
/// OS window. Null in headless mode (no OS window opened; rendered to
/// `render_target` instead). See `framework/doc/robot.md`「�EチE��レスサーフェス、E
awt_window: ?awt.Window,
/// Swapchain presenting to `awt_window`. Null in headless mode.
swapchain: ?awt.Swapchain,
/// Offscreen render target. Non-null only in headless mode; `redraw` binds it
/// instead of the swapchain and `snapshotPixels` reads it back.
render_target: ?awt.RenderTarget,
context: *awt.Graphics.Context,
device: *awt.Device,
app: *anyopaque, // *Application (avoid circular import)
/// Borrowed reference to the Application-owned EventQueue. Input
/// callbacks post events here instead of dispatching synchronously,
/// so input / invokeLater / redraw all serialize through the same
/// queue (see `framework/doc/window.md`「イベンチEpost と dispatch、E.
event_queue: *awt.EventQueue,
/// Optional top-strip menu bar. Generic `*Component` (typically the
/// `&MenuBar.component` set via Frame.setMenuBar). Not owned by Window  E/// Frame manages lifetime. When non-null, the container is laid out
/// below it (container.position.y = menu_bar.size.height).
menu_bar: ?*Component,
/// Floating overlays (popups / drag ghost / tooltips). See `OverlayManager`.
overlays: OverlayManager,
/// Dirty-notify pointer used by overlays/menu_bar that share Window's
/// repaint propagation (same value the container's root uses via property).
title: [:0]u8,
background: awt.Graphics.Color,
fb_w: i32,
fb_h: i32,
/// Desired window geometry in logical screen units, held at the framework
/// layer. `setPos`/`setSize` update these; Application pushes any change to
/// the OS at each event-loop tail (see `application.md`「OS との同期、E. The
/// OS resize callback writes the realized size back here so the loop's diff
/// does not fight a live user resize.
win_pos: awt.Window.Point,
win_size: awt.Window.Size,
cursor_x: f32,
cursor_y: f32,
current_cursor: awt.Window.CursorShape,
paint_dirty: bool,
layout_dirty: bool,
/// True for headless windows (no `awt_window`/`swapchain`; renders offscreen,
/// input injected synthetically). See `initHeadless`.
headless: bool,
/// Close request for headless windows (no OS `shouldClose` flag to poll).
headless_close: bool,
/// True only while `redraw` is executing. Used by the dirty notify callbacks
/// to suppress `awt.postEmptyEvent()` when `markLayoutDirty` / `repaint` is
/// triggered from inside the layout cascade itself (e.g. `setBounds` called
/// during `doLayout`): we're already in the middle of a frame, so waking the
/// event loop is wasted work. Real external triggers (timers, input handlers,
/// background callbacks) run with `in_redraw == false` and still wake.
in_redraw: bool,
/// Mouse-capture target. While non-null, `.move` and `.release` events
/// bypass hit-testing and go straight to this component. Set when a
/// widget calls `ev.requestCapture(&self.component)` from a `.press`
/// handler; cleared on the matching `.release`.
mouse_capture: ?*Component,
/// Keyboard-focus owner. `.key` and `.char` events are delivered only to
/// this component (raw key events never reach anyone else  Esee
/// `narrative/keybinding.md`「processEvent に .key が届く篁E��、E.
/// Cleared (set to null) when the owning component is torn down.
focus_owner: ?*Component,
/// One-shot guard for the initial-focus rule: on the first frame, focus
/// moves to the first focusable in traversal order (see `redraw`).
initial_focus_done: bool,
/// When true, `dispatchInput` drops all user input for this window. Set by
/// Application while a modal Dialog is active on a *different* window (the
/// modal one stays false). This is how nimbus implements per-window modality
/// since GLFW/OS do not (see `dialog.md`「モーダル入力ブロチE��、E.
input_blocked: bool,
// ── drag-and-drop controller state (see `framework/doc/dnd.md`) ──
/// A press landed on a component with a `drag_source`; waiting to exceed the
/// movement threshold before the drag actually starts. Null = not armed.
drag_armed: ?*Component,
/// Window coords of the arming press (threshold + onDragStart origin).
drag_start: Component.Point,
/// True while a drag is active (onDragStart returned a transfer).
dragging: bool,
/// The source component of the active drag (for `onDragDone`).
drag_source_c: ?*Component,
/// The payload of the active drag. Valid only while `dragging`.
drag_transfer: dnd.Transfer,
/// The drop target the cursor is currently over (for enter/leave).
drag_target: ?*Component,
/// Whether the last `onOver` accepted (drives whether `onDrop` fires).
drag_accepted: bool,
allocator: std.mem.Allocator,
dirty_notify: Component.DirtyNotify,
focus_controller: Component.FocusController,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub const look_vtable = Component.LookVTable{
    .paint = lookPaint,
    .paintOver = lookPaintOver,
    .measureMinSize = lookMeasureMinSize,
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
        .container = Container.init(allocator),
        .awt_window = aw,
        .swapchain = sc,
        .render_target = null,
        .context = context,
        .device = device,
        .app = app_ptr,
        .event_queue = event_queue,
        .menu_bar = null,
        .overlays = OverlayManager.init(allocator),
        .title = title_dup,
        .background = awt.Graphics.Color.rgb(0.94, 0.94, 0.94),
        .fb_w = fb.width,
        .fb_h = fb.height,
        .win_pos = init_pos,
        .win_size = init_size,
        .cursor_x = 0,
        .cursor_y = 0,
        .current_cursor = .arrow,
        .paint_dirty = true,
        .layout_dirty = true,
        .headless = false,
        .headless_close = false,
        .in_redraw = false,
        .mouse_capture = null,
        .focus_owner = null,
        .initial_focus_done = false,
        .input_blocked = false,
        .drag_armed = null,
        .drag_start = .{ .x = 0, .y = 0 },
        .dragging = false,
        .drag_source_c = null,
        .drag_transfer = undefined,
        .drag_target = null,
        .drag_accepted = false,
        .allocator = allocator,
        .dirty_notify = undefined, // filled in install
        .focus_controller = undefined, // filled in install
    };
    win.container.component.vtable = &vtable;
    win.container.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    // Default layout: BorderLayout. Lets users compose a toolbar / status /
    // sidebar / center shell with no additional setup. Override via
    // `window.container.setLayout` if a different layout is desired.
    win.container.layout = BorderLayout.get();
    return win;
}

/// Headless variant of `init`: opens no OS window and renders to an offscreen
/// `RenderTarget` of `w`x`h`. Used by the Robot / deterministic-test path  E/// input is injected synthetically (no OS callbacks) and `snapshotPixels` reads
/// back the RT. See `framework/doc/robot.md`「�EチE��レスサーフェス、E
pub fn initHeadless(
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

    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);

    var rt = try awt.RenderTarget.create(device.*, iw, ih);
    errdefer rt.deinit();

    var win = Window{
        .container = Container.init(allocator),
        .awt_window = null,
        .swapchain = null,
        .render_target = rt,
        .context = context,
        .device = device,
        .app = app_ptr,
        .event_queue = event_queue,
        .menu_bar = null,
        .overlays = OverlayManager.init(allocator),
        .title = title_dup,
        .background = awt.Graphics.Color.rgb(0.94, 0.94, 0.94),
        .fb_w = iw,
        .fb_h = ih,
        .win_pos = .{ .x = 0, .y = 0 },
        .win_size = .{ .width = iw, .height = ih },
        .cursor_x = 0,
        .cursor_y = 0,
        .current_cursor = .arrow,
        .paint_dirty = true,
        .layout_dirty = true,
        .headless = true,
        .headless_close = false,
        .in_redraw = false,
        .mouse_capture = null,
        .focus_owner = null,
        .initial_focus_done = false,
        .input_blocked = false,
        .drag_armed = null,
        .drag_start = .{ .x = 0, .y = 0 },
        .dragging = false,
        .drag_source_c = null,
        .drag_transfer = undefined,
        .drag_target = null,
        .drag_accepted = false,
        .allocator = allocator,
        .dirty_notify = undefined,
        .focus_controller = undefined,
    };
    win.container.component.vtable = &vtable;
    win.container.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    win.container.layout = BorderLayout.get();
    return win;
}

pub fn deinit(self: *Window) void {
    // Caller-owned modal overlays (PopupMenu / ComboBox / Menu) can outlive the
    // window. Dismiss them before dropping the overlay list so their owners
    // clear `open`; later owner `destroy()` / `hide()` then becomes a no-op
    // instead of walking freed overlay entries. Keep the non-empty guard:
    // early init-failure paths may not have wired dirty_notify yet, and
    // dismissAll marks dirty at the end.
    if (self.overlays.entries.items.len != 0) self.overlays.dismissAll();
    // Overlays are not owned (Menu/PopupMenu owners hold them)  Ejust drop the list.
    // menu_bar is owned by Frame, not Window  Edo not destroy.
    self.overlays.deinit();
    self.container.deinit(); // drops children + container component
    if (self.swapchain) |*sc| sc.deinit();
    if (self.awt_window) |*aw| aw.deinit();
    if (self.render_target) |*rt| rt.deinit();
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
    errdefer self.allocator.free(new_title);
    if (self.awt_window) |*aw| aw.setTitle(new_title);
    self.allocator.free(self.title);
    self.title = new_title;
}

pub fn getTitle(self: Window) []const u8 {
    return self.title;
}

/// Move the window's top-left to (`x`, `y`) in logical screen units. The
/// move is applied to the OS at the next event-loop tail by Application's
/// geometry sync  E`getPos` reflects the requested value immediately.
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
    return if (self.awt_window) |aw| aw.shouldClose() else self.headless_close;
}

pub fn dispose(self: *Window) void {
    // Raise the OS close flag; Application's loop tail will see
    // `shouldClose()` and run the normal close-collection path. Headless
    // windows have no OS flag  Eset the framework-side close request.
    if (self.awt_window) |*aw| aw.setShouldClose(true) else {
        self.headless_close = true;
    }
}

/// Render one frame and clear paint_dirty. Called by Application.run().
pub fn redraw(self: *Window) void {
    // While `in_redraw` is true, child `markLayoutDirty` / `repaint` skip the
    // wake-up call: we're already in the middle of a frame, so queued empty
    // events would just no-op. Real external triggers (timers, input handlers)
    // run with this false and still wake.
    self.in_redraw = true;
    defer self.in_redraw = false;

    if (self.layout_dirty) {
        const win_size = self.win_size;
        const win_w: f32 = @floatFromInt(win_size.width);
        const win_h: f32 = @floatFromInt(win_size.height);
        const bar_h: f32 = if (self.menu_bar) |bar| bar.min_size.height else 0;

        if (self.menu_bar) |bar| {
            bar.setBounds(.{ .x = 0, .y = 0, .width = win_w, .height = bar_h });
        }
        // `Container.setBounds` no longer auto-runs `doLayout` (was a footgun
        // for `LayoutManager` authors  Esee `Container.setBounds` comment).
        // Drive the layout cascade explicitly here, the one legitimate place.
        self.container.component.setBounds(.{
            .x = 0,
            .y = bar_h,
            .width = win_w,
            .height = @max(0, win_h - bar_h),
        });
        self.container.doLayout();
        self.layout_dirty = false;
    }

    // Initial focus: on the first frame, the first focusable in traversal
    // order takes focus (standard dialog behavior). One-shot  Eonce the user
    // clears focus by clicking empty space, we don't re-assert it.
    if (!self.initial_focus_done) {
        self.initial_focus_done = true;
        if (self.focus_owner == null) {
            var list: std.ArrayList(*Component) = .empty;
            defer list.deinit(self.allocator);
            if (collectFocusables(&self.container.component, &list, self.allocator)) {
                if (list.items.len > 0) self.requestFocusFor(list.items[0]);
            } else |_| {}
        }
    }

    const cb = awt.CommandBuffer.acquire(self.device.*) catch return;
    defer cb.release();

    self.context.uniforms.reset();
    self.context.vertex_ring.reset();

    cb.begin();
    const target = self.render_target orelse self.swapchain.?.getTarget();
    cb.bindRenderTarget(target);
    cb.clearColor(self.background.r, self.background.g, self.background.b, self.background.a);
    cb.clearStencil(0);

    const win_size = self.win_size;
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
    self.overlays.paintAll(&g);

    cb.end();
    cb.submit(self.device.*);
    // Real windows sync via swapchain present; headless has none, so wait for
    // the GPU before the next frame / readback / teardown touches the RT.
    if (self.swapchain) |*sc| sc.present() else self.device.waitIdle();

    self.paint_dirty = false;
}

// ── menu_bar / overlays management ───────────────────────────────────────

/// Set or clear the top-strip menu bar. The component is **not owned** by
/// Window  Ecaller (Frame) handles lifetime. Pass null to remove.
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

// Overlay registration / removal / dismissal live on `self.overlays`
// (OverlayManager): `self.overlays.add(...)` / `.addPassthrough(...)` /
// `.remove(...)` / `.dismissAll()`. See `OverlayManager` / `overlay.md`.

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

/// Move focus to the next focusable in traversal order (Tab). Wraps at the
/// end; no-op when the window has no focusable. See `framework/doc/keybinding.md`.
pub fn focusNext(self: *Window) void {
    self.stepFocus(true);
}

/// Move focus to the previous focusable (Shift+Tab). Exact reverse of
/// `focusNext`, wrapping at the start.
pub fn focusPrev(self: *Window) void {
    self.stepFocus(false);
}

/// The single focusable enumeration shared by focusNext / focusPrev and the
/// initial-focus rule: preorder DFS over the container tree in child add
/// order, filtered by `isFocusEligible`. Keep it the only DFS  Ea future
/// explicit tab-order value plugs in here and nowhere else (see
/// `narrative/keybinding.md`「�E挙�E一本化、E.
fn collectFocusables(
    c: *Component,
    list: *std.ArrayList(*Component),
    allocator: std.mem.Allocator,
) !void {
    if (c.isFocusEligible()) try list.append(allocator, c);
    if (c.container) |cont| {
        for (cont.children.items) |elem| {
            try collectFocusables(elem.component, list, allocator);
        }
    }
}

fn stepFocus(self: *Window, forward: bool) void {
    var list: std.ArrayList(*Component) = .empty;
    defer list.deinit(self.allocator);
    collectFocusables(&self.container.component, &list, self.allocator) catch return;
    const n = list.items.len;
    if (n == 0) return;

    // Current owner's position in the cycle. An owner living outside the
    // container tree (List cell editor) is not in the list  Etreat as "no
    // position" and restart from an end.
    var idx: ?usize = null;
    if (self.focus_owner) |fo| {
        for (list.items, 0..) |c, i| {
            if (c == fo) {
                idx = i;
                break;
            }
        }
    }
    const target_idx: usize = if (idx) |i|
        (if (forward) (i + 1) % n else (i + n - 1) % n)
    else
        (if (forward) 0 else n - 1);

    const target = list.items[target_idx];
    self.requestFocusFor(target);
    // Keep the newly-focused widget visible inside an enclosing ScrollPane.
    // Only here (Tab-driven moves): click focus is visible by definition and
    // programmatic requestFocus must not fight caller-controlled scrolling.
    target.scrollIntoView();
}

// ── dirty notify wiring ──────────────────────────────────────────────────

fn notifyPaint(user_data: *anyopaque) void {
    const win: *Window = @ptrCast(@alignCast(user_data));
    win.paint_dirty = true;
    // Skip the wake-up if we're already inside `redraw`  Ethe cascade is what
    // triggered this and the loop will just no-op those queued events.
    if (!win.in_redraw) awt.postEmptyEvent();
}

fn notifyLayout(user_data: *anyopaque) void {
    const win: *Window = @ptrCast(@alignCast(user_data));
    win.layout_dirty = true;
    win.paint_dirty = true;
    // See notifyPaint above: redraw-internal triggers don't need a wake-up.
    if (!win.in_redraw) awt.postEmptyEvent();
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
        .paint = notifyPaint,
        .layout = notifyLayout,
    };
    try self.putProperty(@typeName(Component.DirtyNotify), @ptrCast(&win.dirty_notify), null);

    // Focus controller  Elets descendants call `c.requestFocus()` and have
    // it bubble back to this Window via property lookup.
    win.focus_controller = .{
        .user_data = @ptrCast(win),
        .request_focus_for = focusControllerCallback,
        .current_owner = focusControllerCurrentOwner,
    };
    try self.putProperty(@typeName(Component.FocusController), @ptrCast(&win.focus_controller), null);

    // Hand the overlay manager the notify / controller it wires onto modal
    // overlays and uses to mark the window dirty.
    win.overlays.wire(&win.dirty_notify, &win.focus_controller);

    // Wire OS-level input callbacks into our dispatcher. Headless windows have
    // no OS window  Einput arrives only via synthetic `postInput` injection.
    if (win.awt_window) |*aw| {
        aw.setResizeCallback(onResize, @ptrCast(win));
        aw.setRefreshCallback(onRefresh, @ptrCast(win));
        aw.setMoveCallback(onWindowPos, @ptrCast(win));
        aw.setMouseButtonCallback(onMouseButton, @ptrCast(win));
        aw.setCursorPosCallback(onCursorPos, @ptrCast(win));
        aw.setScrollCallback(onScroll, @ptrCast(win));
        aw.setKeyCallback(onKey, @ptrCast(win));
        aw.setCharCallback(onChar, @ptrCast(win));
        aw.setCompositionCallback(onComposition, @ptrCast(win));
    }
}

fn focusControllerCallback(user_data: *anyopaque, c: ?*Component) void {
    const win: *Window = @ptrCast(@alignCast(user_data));
    win.requestFocusFor(c);
}

fn focusControllerCurrentOwner(user_data: *anyopaque) ?*Component {
    const win: *Window = @ptrCast(@alignCast(user_data));
    return win.focus_owner;
}

fn uninstall(self: *Component) void {
    self.container = null;
}

fn lookPaint(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookMeasureMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = 0 };
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
                    if (self.beginDrag(m.x, m.y)) return; // started ↁEconsume this move
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
                self.updateCursorFromHover();
                return;
            }

            // 2. Overlays (top-down). Only when a modal popup is open; the
            //    drag ghost / tooltips are passthrough and never gate input.
            if (self.overlays.topModalIndex() != null) {
                var hit_overlay = false;
                const entries = self.overlays.entries.items;
                var i: usize = entries.len;
                while (i > 0) {
                    i -= 1;
                    const entry = entries[i];
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
                        self.overlays.dismissAll();
                    }
                    // Hover/scroll outside overlay is also swallowed while
                    // popup is open (typical menu modal feel).
                    return;
                }
                // If consumed, we're done. Otherwise still don't bubble below
                // overlays  Eoverlays are modal.
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
            if (m.action == .move) self.updateCursorFromHover();
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
                // matters for focus targets the child-walk cannot reach  Ee.g.
                // a List materializes its cells outside the container tree, so
                // its in-cell editor field is invisible to findFocusableAt.
                if (self.focus_owner == focus_before) {
                    if (self.findFocusableAt(m.x, m.y)) |w| self.requestFocusFor(w) else self.requestFocusFor(null);
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
        .key => |k| {
            // Fixed pre-stages (structural "ancestor must win" behaviors  E            // see `narrative/keybinding.md`「却下桁E キャプチャ段、E:
            // ESC cancels an active drag; all keys are swallowed while dragging.
            if (self.dragging) {
                if (k.code == .escape and k.action == .press) self.cancelDrag();
                return;
            }
            // Modal overlay gets first shot. ESC closes one level (staged:
            // submenu before parent popup); Tab is treated like an outside
            // click  Edismiss everything (cancel), then move focus on; an
            // accelerator chord closes the popup and performs the action
            // (the user's intent is the action, not the menu).
            if (self.overlays.topModalIndex()) |ti| {
                const top = self.overlays.entries.items[ti];
                top.component.vtable.processEvent(top.component, ev);
                if (ev.isConsumed()) return;
                if (k.action == .press or k.action == .repeat) {
                    if (k.code == .escape and k.action == .press) {
                        self.overlays.dismissTop();
                        return;
                    }
                    if (k.code == .tab) {
                        self.overlays.dismissAll();
                        if (k.modifiers.shift) self.focusPrev() else self.focusNext();
                        return;
                    }
                    if (k.modifiers.ctrl or k.modifiers.meta) {
                        if (self.findAcceleratorTarget(k)) |mi| {
                            // Close first, then fire: a handler that opens a
                            // dialog must not leave the menu hanging behind it.
                            self.overlays.dismissAll();
                            mi.doClick();
                            return;
                        }
                    }
                }
                return; // modal: don't propagate
            }

            // Stage 1: the focus owner  Ethe only component that receives the
            // raw `.key` through processEvent.
            if (self.focus_owner) |fo| {
                fo.vtable.processEvent(fo, ev);
                if (ev.isConsumed()) return;
            }

            if (k.action != .press and k.action != .repeat) return;

            // Tab traversal, after the focus owner declined (leaves room for
            // a future TextArea that consumes Tab as a character).
            if (k.code == .tab) {
                if (k.modifiers.shift) self.focusPrev() else self.focusNext();
                ev.consume();
                return;
            }

            // Stages 2-4: key_bindings walked from the focus owner up to the
            // root. Including the focus owner itself is the WHEN_FOCUSED scope
            // (a binding installed on the focused widget fires after its own
            // processEvent declined, before any ancestor's)  Emore specific
            // wins. Ancestors are the WHEN_ANCESTOR / window-wide scopes
            // (default button, dialog ESC). No focus owner -> starts at root.
            var node: ?*Component = self.focus_owner orelse &self.container.component;
            while (node) |cur| : (node = cur.parent) {
                if (cur.key_bindings) |kb| {
                    if (kb.lookup(k.code, k.modifiers)) |h| {
                        h.invoke(h.ctx);
                        ev.consume();
                        return;
                    }
                }
            }

            // Stage 4: accelerator scan over the menu tree (no registration  E            // see `narrative/keybinding.md`「root 登録と走査の線引き、E.
            if (self.findAcceleratorTarget(k)) |mi| {
                mi.doClick();
                ev.consume();
                return;
            }

            // Stage 5: mnemonic scan (Alt+letter only).
            if (k.modifiers.alt and !k.modifiers.ctrl and !k.modifiers.meta) {
                if (self.mnemonicScan(k)) {
                    ev.consume();
                    return;
                }
            }
        },
        .char => {
            if (self.overlays.topModalIndex()) |ti| {
                const top = self.overlays.entries.items[ti];
                top.component.vtable.processEvent(top.component, ev);
                return; // modal
            }
            if (self.focus_owner) |fo| {
                fo.vtable.processEvent(fo, ev);
                return; // text input only goes to focused widget
            }
            // No focus owner: drop on the floor (nothing to type into).
        },
        .focus => {
            // Focus events are dispatched synchronously by requestFocusFor
            // (B-2) directly to the gaining/losing component  Ethey should
            // not normally arrive here via the event queue. No-op as a safety net.
        },
        .composition => {
            if (self.focus_owner) |fo| {
                fo.vtable.processEvent(fo, ev);
                return;
            }
        },
    }
}

/// Thunk for EventQueue.postEvent so awt can store a type-erased pointer.
fn dispatchInputThunk(target: *anyopaque, ev: *awt.Event) void {
    const win: *Window = @ptrCast(@alignCast(target));
    win.dispatchInput(ev);
}

/// Inject a synthetic input event: enqueue it on the Application event queue
/// targeting this window's dispatcher, exactly like an OS input callback would.
/// Dispatch happens on the next `EventQueue.drain` (i.e. the next `tickOnce` /
/// `Robot.pump`). Used by the Robot. `postEvent` is thread-safe.
pub fn postInput(self: *Window, ev: awt.Event) !void {
    try self.event_queue.postEvent(ev, @ptrCast(self), dispatchInputThunk);
}

/// True for events that count as the user deliberately trying to interact
/// with a window (mouse button press, key press)  Eused to decide whether
/// poking a modal-blocked window should flash the modal. Excludes passive
/// move / scroll / release so the modal does not flash on mere hover.
fn isAttentionPoke(ev: *const awt.Event) bool {
    return switch (ev.payload) {
        .mouse => |m| m.action == .press,
        .key => |k| k.action == .press,
        else => false,
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
    // Eligibility, not just the static flag: clicking a disabled widget must
    // not move focus onto it.
    return if (c.isFocusEligible()) c else null;
}
pub fn resolveCursorFromHover(root: *Component, capture: ?*Component, x: f32, y: f32) awt.Window.CursorShape {
    if (capture) |cap| {
        if (cap.cursor_query) |q| {
            if (q.at(cap, x, y)) |shape| return shape;
        }
        return .arrow;
    }

    var node: *Component = root;
    while (node.container) |cont| {
        node = cont.last_hovered orelse break;
    }

    var cur: ?*Component = node;
    while (cur) |comp| : (cur = comp.parent) {
        if (comp.cursor_query) |q| {
            if (q.at(comp, x, y)) |shape| return shape;
        }
    }
    return .arrow;
}

fn updateCursorFromHover(self: *Window) void {
    const shape = resolveCursorFromHover(&self.container.component, self.mouse_capture, self.cursor_x, self.cursor_y);
    if (shape == self.current_cursor) return;
    if (self.awt_window) |aw| aw.setCursor(shape);
    self.current_cursor = shape;
}

// ── keystroke scan stages (accelerator / mnemonic) ──────────────────────
// Component-attached key semantics are resolved by walking the live tree at
// dispatch time instead of registering at the root  Eno ordering or lifetime
// traps, negligible cost on the key-press cold path. See
// `narrative/keybinding.md`「root 登録と走査の線引き、E

/// Walk the menu tree looking for an enabled MenuItem whose accelerator
/// matches the key event. Find-only (no side effects): the caller decides
/// what to do around the activation  Estage 4 just fires; the open-menu path
/// dismisses the popup first.
fn findAcceleratorTarget(self: *Window, k: awt.Event.KeyEvent) ?*MenuItem {
    const bar_c = self.menu_bar orelse return null;
    if (bar_c.vtable != &MenuBar.vtable) return null;
    const bar: *MenuBar = @fieldParentPtr("component", bar_c);
    for (bar.menus.items) |menu| {
        if (findMenuAccelerator(menu, k)) |mi| return mi;
    }
    return null;
}

fn findMenuAccelerator(menu: *Menu, k: awt.Event.KeyEvent) ?*MenuItem {
    for (menu.items.items) |item| {
        if (item.vtable == &Menu.vtable) {
            const sub: *Menu = @fieldParentPtr("component", item);
            if (findMenuAccelerator(sub, k)) |mi| return mi;
        } else if (item.vtable == &MenuItem.vtable) {
            const mi: *MenuItem = @fieldParentPtr("component", item);
            if (mi.accelerator) |acc| {
                if (mi.model.enabled and acc.satisfies(k.code, k.modifiers)) return mi;
            }
        }
    }
    return null;
}

/// Stage 5: Alt+letter. Menu-bar menus first (Alt+F opening the File menu is
/// the canonical use), then the component tree in DFS order, first match
/// wins. Disabled targets don't fire  E`doClick` carries that guard.
fn mnemonicScan(self: *Window, k: awt.Event.KeyEvent) bool {
    const ch = keybinding.letterOf(k.code) orelse return false;
    if (self.menu_bar) |bar_c| {
        if (bar_c.vtable == &MenuBar.vtable) {
            const bar: *MenuBar = @fieldParentPtr("component", bar_c);
            for (bar.menus.items) |menu| {
                if (menu.component.mnemonic == ch) {
                    menu.doClick();
                    bar.open_menu = if (menu.open) menu else null;
                    // Keyboard-opened menus start with the first item
                    // highlighted (mouse-opened ones don't)  EWindows style.
                    if (menu.open) menu.highlightFirst();
                    return true;
                }
            }
        }
    }
    return mnemonicScanTree(&self.container.component, ch);
}

fn mnemonicScanTree(c: *Component, ch: u8) bool {
    if (c.mnemonic) |m| {
        if (m == ch) {
            activateByMnemonic(c);
            return true;
        }
    }
    if (c.container) |cont| {
        for (cont.children.items) |elem| {
            if (mnemonicScanTree(elem.component, ch)) return true;
        }
    }
    return false;
}

/// Mnemonic targets are widgets exposing `setMnemonic` (Button / Menu /
/// MenuItem in v1; MenuItem mnemonics are menu-local and never reach this
/// scan). Dispatch by vtable identity  Ethe type-erased Component cannot
/// carry a doClick function pointer without growing VTable.
fn activateByMnemonic(c: *Component) void {
    if (c.vtable == &Button.vtable) {
        const b: *Button = @fieldParentPtr("component", c);
        b.doClick();
    }
}

/// Window-wide Enter -> `btn.doClick()`, registered on the root container's
/// key_bindings (the focus chain's terminal stage, so a focused widget that
/// eats Enter  Ea Button, a future multiline editor  Estill wins). Pass null
/// to remove.
///
/// Lifetime contract: a root-registered binding references `btn` without
/// owning it. If `btn` is removed from the live window before the window
/// itself is torn down, call `setDefaultButton(null)` first  Eotherwise the
/// stale binding dangles.
pub fn setDefaultButton(self: *Window, btn: ?*Button) !void {
    const root = &self.container.component;
    if (btn) |b| {
        try root.bindKey(keybinding.KeyStroke.of(.enter), keybinding.Handler.typed(Button, Button.doClick, b));
    } else {
        root.unbindKey(keybinding.KeyStroke.of(.enter));
    }
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
// `framework/doc/dnd.md`「ドラチE��の司令塔、E

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
/// switching is deferred  Esee `dnd.md`).
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
/// point to a row)  Esee `dnd.md`「List の行並べ替え、E
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
    win.swapchain.?.resize(@intCast(fb_w), @intCast(fb_h)) catch |err|
        log.warn("window", "swapchain.resize ({d}x{d}) failed: {s}", .{ fb_w, fb_h, @errorName(err) });
    win.fb_w = @intCast(fb_w);
    win.fb_h = @intCast(fb_h);
    // Track the realized logical size in our geometry model and mark it as
    // already synced with the OS, so Application's loop-tail diff does not
    // push this size back (which would fight a live user resize). See
    // `application.md`「OS との同期、E
    win.win_size = win.awt_window.?.size();
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
    // `application.md`「OS との同期、E
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
    // GLFW delivers cursor positions in framebuffer pixels on DPI-aware
    // platforms. Widgets and bounds are in logical points, so divide by
    // content scale at the boundary.
    const scale: f64 = @floatCast(win.awt_window.?.contentScale());
    const inv: f64 = if (scale > 0) 1.0 / scale else 1.0;
    win.cursor_x = @floatCast(x * inv);
    win.cursor_y = @floatCast(y * inv);
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

test "dispatchInput routes composition to focus owner" {
    const Sink = struct {
        component: Component,
        seen: bool = false,
        text: []const u8 = "",
        target_start: usize = 0,
        target_end: usize = 0,

        fn install(_: *Component) !void {}
        fn uninstall(_: *Component) void {}
        fn destroy(_: *Component, _: std.mem.Allocator) void {}
        fn processEvent(c: *Component, ev: *Component.Event) void {
            const self: *@This() = @fieldParentPtr("component", c);
            switch (ev.payload) {
                .composition => |comp| {
                    self.seen = true;
                    self.text = comp.text;
                    self.target_start = comp.target_start;
                    self.target_end = comp.target_end;
                },
                else => {},
            }
        }

        const vtable = Component.VTable{
            .install = @This().install,
            .uninstall = @This().uninstall,
            .processEvent = @This().processEvent,
            .destroy = @This().destroy,
        };
    };

    var sink = Sink{ .component = Component.init(std.testing.allocator, &Sink.vtable) };
    var win: Window = undefined;
    win.input_blocked = false;
    win.focus_owner = &sink.component;

    var ev = awt.Event{ .payload = .{ .composition = .{
        .text = "kana",
        .target_start = 1,
        .target_end = 3,
    } } };
    win.dispatchInput(&ev);

    try std.testing.expect(sink.seen);
    try std.testing.expectEqualStrings("kana", sink.text);
    try std.testing.expectEqual(@as(usize, 1), sink.target_start);
    try std.testing.expectEqual(@as(usize, 3), sink.target_end);
}

test "cursor shape resolves from deepest hover split pane divider capture and dedups" {
    const CursorLeaf = struct {
        component: Component,

        fn create(allocator: std.mem.Allocator) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .component = Component.init(allocator, &@This().vtable) };
            self.component.role = .text_area;
            self.component.cursor_query = .{ .at = cursorAt };
            self.component.setMinSize(.{ .width = 80, .height = 0 });
            return self;
        }

        fn cursorAt(_: *const Component, _: f32, _: f32) ?Component.CursorShape {
            return .ibeam;
        }

        fn install(_: *Component) !void {}
        fn uninstall(_: *Component) void {}
        fn processEvent(_: *Component, _: *Component.Event) void {}
        fn destroy(c: *Component, allocator: std.mem.Allocator) void {
            c.deinit();
            const self: *@This() = @fieldParentPtr("component", c);
            allocator.destroy(self);
        }

        const vtable = Component.VTable{
            .install = @This().install,
            .uninstall = @This().uninstall,
            .processEvent = @This().processEvent,
            .destroy = @This().destroy,
        };
    };

    const a = std.testing.allocator;
    var root = Container.init(a);
    root.component.container = &root;
    defer root.children.deinit(a);

    const text = try CursorLeaf.create(a);
    errdefer text.component.vtable.destroy(&text.component, a);
    const plain = try @import("Panel.zig").create(a);
    errdefer plain.container.component.vtable.destroy(&plain.container.component, a);
    const sp = try @import("SplitPane.zig").create(a, .horizontal, &text.component, &plain.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    try root.add(sp.asComponent());
    root.component.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 100 });
    sp.container.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 100 });
    sp.container.doLayout();

    var win: Window = undefined;
    win.container = root;
    win.awt_window = null;
    win.mouse_capture = null;
    win.current_cursor = .arrow;

    var move_text = awt.Event{ .payload = .{ .mouse = .{ .x = 10, .y = 50, .action = .move } } };
    root.component.vtable.processEvent(&root.component, &move_text);
    win.cursor_x = 10;
    win.cursor_y = 50;
    win.updateCursorFromHover();
    try std.testing.expectEqual(awt.Window.CursorShape.ibeam, win.current_cursor);

    win.updateCursorFromHover();
    try std.testing.expectEqual(awt.Window.CursorShape.ibeam, win.current_cursor);

    var move_divider = awt.Event{ .payload = .{ .mouse = .{ .x = 82, .y = 50, .action = .move } } };
    root.component.vtable.processEvent(&root.component, &move_divider);
    win.cursor_x = 82;
    win.cursor_y = 50;
    win.updateCursorFromHover();
    try std.testing.expectEqual(awt.Window.CursorShape.hresize, win.current_cursor);

    var move_plain = awt.Event{ .payload = .{ .mouse = .{ .x = 100, .y = 50, .action = .move } } };
    root.component.vtable.processEvent(&root.component, &move_plain);
    win.cursor_x = 100;
    win.cursor_y = 50;
    win.updateCursorFromHover();
    try std.testing.expectEqual(awt.Window.CursorShape.arrow, win.current_cursor);

    var press = awt.Event{ .payload = .{ .mouse = .{ .x = 82, .y = 50, .action = .press, .button = .left } } };
    sp.asComponent().vtable.processEvent(sp.asComponent(), &press);
    try std.testing.expect(press.capture_target != null);
    win.mouse_capture = @ptrCast(@alignCast(press.capture_target.?));

    var drag_move = awt.Event{ .payload = .{ .mouse = .{ .x = 200, .y = 50, .action = .move } } };
    win.mouse_capture.?.vtable.processEvent(win.mouse_capture.?, &drag_move);
    win.cursor_x = 200;
    win.cursor_y = 50;
    win.updateCursorFromHover();
    try std.testing.expectEqual(awt.Window.CursorShape.hresize, win.current_cursor);
}
