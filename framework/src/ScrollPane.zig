//! Scroll pane. See `framework/doc/scrollpane.md`.
//!
//! Shows one owned `view` through a smaller viewport, scrolling the overflow.
//! Built by composition: it embeds a `Container` (whose children are the
//! viewport + two `ScrollBar`s) and overrides that container's vtable so it
//! can intercept the wheel. The viewport is itself a plain `Container` holding
//! the view at a negative offset  Eclipping (via `paintAt`) and event gating
//! (via `containsWindowPoint`) then fall out of the existing machinery, so no
//! bespoke clip / hit-test code is needed.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const ScrollBar = @import("ScrollBar.zig");
const BoundedRangeModel = @import("BoundedRangeModel.zig");
const LayoutManager = @import("LayoutManager.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;

const ScrollPane = @This();

pub const Policy = enum { as_needed, always, never };
pub const Corner = enum { upper_left, upper_right, lower_left, lower_right };

const DEFAULT_UNIT_INCREMENT: f32 = 40;
/// Modest floor so the pane is usable in a layout without demanding the
/// content's full size; callers grow it via setGrowX/Y or BorderLayout.center.
const DEFAULT_MIN: f32 = 48;

// `container` MUST be the first field: the public Component is
// `container.component`, and methods recover `*ScrollPane` via
// `@fieldParentPtr("container", ...)`.
container: Container,
layout: ScrollLayout,
view: *Component, // owned (lives inside `viewport`)
viewport: *Container, // child of `container`; owns `view`
column_header_view: ?*Component,
column_header_port: ?*Container,
row_header_view: ?*Component,
row_header_port: ?*Container,
corners: [4]?*Component,
hbar: *ScrollBar, // child of `container`; borrows `h_model`
vbar: *ScrollBar, // child of `container`; borrows `v_model`
/// Scroll state. Owned here (not by the bars) so teardown order is safe: the
/// bars are destroyed first by `container.deinit`, then these are deinited.
h_model: BoundedRangeModel,
v_model: BoundedRangeModel,
h_policy: Policy,
v_policy: Policy,
unit_increment: f32,
/// Installed as a property on `viewport.component` so the scrolled view can
/// request `scrollRectToVisible` (e.g. TextArea caret follow). See Component.
scroll_controller: Component.ScrollController,
allocator: std.mem.Allocator,

const ScrollLayout = struct {
    base: LayoutManager,
};

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

const scroll_layout_vtable = LayoutManager.VTable{
    .doLayout = layoutDoLayout,
    .computeMinSize = layoutComputeMinSize,
    .computeMaxSize = layoutComputeMaxSize,
};

pub fn create(allocator: std.mem.Allocator, view: *Component) !*ScrollPane {
    const sp = try allocator.create(ScrollPane);
    errdefer allocator.destroy(sp);

    sp.* = .{
        .container = Container.init(allocator),
        .layout = .{ .base = .{ .vtable = &scroll_layout_vtable } },
        .view = view,
        .viewport = undefined,
        .column_header_view = null,
        .column_header_port = null,
        .row_header_view = null,
        .row_header_port = null,
        .corners = .{ null, null, null, null },
        .hbar = undefined,
        .vbar = undefined,
        .h_model = BoundedRangeModel.init(allocator, 0, 0, 0),
        .v_model = BoundedRangeModel.init(allocator, 0, 0, 0),
        .h_policy = .as_needed,
        .v_policy = .as_needed,
        .unit_increment = DEFAULT_UNIT_INCREMENT,
        .scroll_controller = .{ .user_data = undefined, .scroll_rect_to_visible = scrollRectToVisibleImpl },
        .allocator = allocator,
    };
    sp.scroll_controller.user_data = @ptrCast(sp);
    errdefer {
        sp.v_model.deinit();
        sp.h_model.deinit();
    }
    // Wire the embedded container to behave as the ScrollPane component.
    sp.container.component.vtable = &vtable;
    sp.container.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    sp.container.component.role = .scroll_pane;
    sp.container.component.container = &sp.container;
    sp.container.layout = &sp.layout.base;

    // Reserve capacity up front so the appends below are infallible  Ethis
    // keeps the errdefers simple (all fallible work happens before anything is
    // handed to `container`, which owns it on success).
    try sp.container.children.ensureTotalCapacity(allocator, 3);

    sp.viewport = try Container.create(allocator);
    errdefer sp.viewport.component.vtable.destroy(&sp.viewport.component, allocator);
    try sp.viewport.children.ensureTotalCapacity(allocator, 1);
    // Let the view reach us for caret follow / scrollRectToVisible. Stored on
    // the viewport (the view's parent), found via enclosingScrollController.
    try sp.viewport.component.putProperty(
        @typeName(Component.ScrollController),
        @ptrCast(&sp.scroll_controller),
        null,
    );

    sp.hbar = try ScrollBar.createWithModel(allocator, .horizontal, &sp.h_model);
    errdefer sp.hbar.component.vtable.destroy(&sp.hbar.component, allocator);
    sp.vbar = try ScrollBar.createWithModel(allocator, .vertical, &sp.v_model);
    errdefer sp.vbar.component.vtable.destroy(&sp.vbar.component, allocator);

    // Room for both listeners on each model (the bar added its own in
    // createWithModel; ScrollPane adds one more).
    try sp.h_model.change_listeners.items.ensureTotalCapacity(allocator, 2);
    try sp.v_model.change_listeners.items.ensureTotalCapacity(allocator, 2);

    // ── commit: no failures past this point ──────────────────────────────
    sp.viewport.add(view) catch unreachable;
    sp.container.add(&sp.viewport.component) catch unreachable;
    sp.container.add(&sp.hbar.component) catch unreachable;
    sp.container.add(&sp.vbar.component) catch unreachable;
    sp.h_model.addChangeListener(ScrollPane, onScrollChange, sp) catch unreachable;
    sp.v_model.addChangeListener(ScrollPane, onScrollChange, sp) catch unreachable;

    return sp;
}

// ── public API ───────────────────────────────────────────────────────────

/// The public Component (for `setGrowX/Y`, adding to a parent, etc.). The
/// ScrollPane embeds a Container, so this is `&self.container.component`.
pub fn asComponent(self: *ScrollPane) *Component {
    return &self.container.component;
}

pub fn getView(self: ScrollPane) *Component {
    return self.view;
}

pub fn setView(self: *ScrollPane, view: *Component) void {
    self.viewport.remove(self.view); // detach (no destroy)
    self.view.vtable.destroy(self.view, self.allocator);
    self.view = view;
    self.viewport.add(view) catch {}; // capacity retained from the removed slot
    self.h_model.setValue(0);
    self.v_model.setValue(0);
    self.container.component.markLayoutDirty();
}

pub fn getColumnHeaderView(self: ScrollPane) ?*Component {
    return self.column_header_view;
}

pub fn getRowHeaderView(self: ScrollPane) ?*Component {
    return self.row_header_view;
}

pub fn getCorner(self: ScrollPane, which: Corner) ?*Component {
    return self.corners[@intFromEnum(which)];
}

pub fn setColumnHeaderView(self: *ScrollPane, view: *Component) !void {
    if (self.column_header_view == view) return;
    const port = try self.ensureColumnHeaderPort();
    try port.children.ensureTotalCapacity(self.allocator, 1);
    if (self.column_header_view) |old| {
        port.remove(old);
        old.vtable.destroy(old, self.allocator);
    }
    self.column_header_view = view;
    port.add(view) catch unreachable;
    self.container.component.markLayoutDirty();
}

pub fn setRowHeaderView(self: *ScrollPane, view: *Component) !void {
    if (self.row_header_view == view) return;
    const port = try self.ensureRowHeaderPort();
    try port.children.ensureTotalCapacity(self.allocator, 1);
    if (self.row_header_view) |old| {
        port.remove(old);
        old.vtable.destroy(old, self.allocator);
    }
    self.row_header_view = view;
    port.add(view) catch unreachable;
    self.container.component.markLayoutDirty();
}

pub fn setCorner(self: *ScrollPane, which: Corner, view: *Component) !void {
    try self.container.children.ensureUnusedCapacity(self.allocator, 1);
    const idx = @intFromEnum(which);
    if (self.corners[idx] == view) return;
    if (self.corners[idx]) |old| {
        self.container.remove(old);
        old.vtable.destroy(old, self.allocator);
    }
    self.corners[idx] = view;
    self.container.add(view) catch unreachable;
    self.container.component.markLayoutDirty();
}

pub fn getScrollX(self: ScrollPane) f32 {
    return @floatFromInt(self.h_model.value);
}

pub fn getScrollY(self: ScrollPane) f32 {
    return @floatFromInt(self.v_model.value);
}

pub fn setScrollX(self: *ScrollPane, px: f32) void {
    self.h_model.setValue(toI32(px));
}

pub fn setScrollY(self: *ScrollPane, px: f32) void {
    self.v_model.setValue(toI32(px));
}

pub fn setHorizontalPolicy(self: *ScrollPane, policy: Policy) void {
    self.h_policy = policy;
    self.container.component.markLayoutDirty();
}

pub fn setVerticalPolicy(self: *ScrollPane, policy: Policy) void {
    self.v_policy = policy;
    self.container.component.markLayoutDirty();
}

pub fn setUnitIncrement(self: *ScrollPane, px: f32) void {
    self.unit_increment = px;
}

/// Scroll the minimum amount so that `rect`  Eexpressed in the view's local
/// coordinates (0 = view top-left)  Elies within the viewport. Used by views
/// like TextArea to keep the caret visible. Over-large rects pin to the
/// leading edge.
pub fn scrollRectToVisible(self: *ScrollPane, rect: Component.Rect) void {
    const vp_w = self.viewport.component.size.width;
    const vp_h = self.viewport.component.size.height;
    var sx = self.getScrollX();
    var sy = self.getScrollY();

    if (rect.x < sx) {
        sx = rect.x;
    } else if (rect.x + rect.width > sx + vp_w) {
        sx = rect.x + rect.width - vp_w;
    }
    if (rect.y < sy) {
        sy = rect.y;
    } else if (rect.y + rect.height > sy + vp_h) {
        sy = rect.y + rect.height - vp_h;
    }

    // setScrollX/Y clamp against the model's valid range.
    self.setScrollX(sx);
    self.setScrollY(sy);
}

fn scrollRectToVisibleImpl(user_data: *anyopaque, rect: Component.Rect) void {
    const self: *ScrollPane = @ptrCast(@alignCast(user_data));
    self.scrollRectToVisible(rect);
}

/// Fires when either axis's scroll position changes.
pub fn addChangeListener(
    self: *ScrollPane,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void {
    try self.h_model.addChangeListener(T, f, user_data);
    errdefer self.h_model.removeChangeListener(T, f, user_data);
    try self.v_model.addChangeListener(T, f, user_data);
}

pub fn removeChangeListener(
    self: *ScrollPane,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void {
    self.h_model.removeChangeListener(T, f, user_data);
    self.v_model.removeChangeListener(T, f, user_data);
}

// ── internal ─────────────────────────────────────────────────────────────

fn toI32(f: f32) i32 {
    return @intFromFloat(@max(0, @round(f)));
}

fn fromComponent(self: *Component) *ScrollPane {
    const c: *Container = @fieldParentPtr("component", self);
    return @fieldParentPtr("container", c);
}

fn ensureColumnHeaderPort(self: *ScrollPane) !*Container {
    if (self.column_header_port) |port| return port;
    try self.container.children.ensureUnusedCapacity(self.allocator, 1);
    const port = try Container.create(self.allocator);
    errdefer port.component.vtable.destroy(&port.component, self.allocator);
    self.column_header_port = port;
    self.container.add(&port.component) catch unreachable;
    return port;
}

fn ensureRowHeaderPort(self: *ScrollPane) !*Container {
    if (self.row_header_port) |port| return port;
    try self.container.children.ensureUnusedCapacity(self.allocator, 1);
    const port = try Container.create(self.allocator);
    errdefer port.component.vtable.destroy(&port.component, self.allocator);
    self.row_header_port = port;
    self.container.add(&port.component) catch unreachable;
    return port;
}

/// Measure the view's laid-out size given the available viewport. Honors the
/// view's optional `scrollable` hint: a tracked axis is forced to the viewport
/// size; an untracked axis uses `max(natural, viewport)` so small content fills
/// the viewport and large content scrolls. When the view is width-tracking AND
/// exposes a `SizeQuery`, the height is asked via `minHeightForWidth(w)`  Ea
/// pure query that does not mutate the view (replaces the old reshape-based
/// "set bounds then re-read effectiveMinSize" round trip).
fn measureView(self: *ScrollPane, vp_w: f32, vp_h: f32) Component.Size {
    const sc = self.view.scrollable orelse Component.Scrollable{};
    const nat = self.view.effectiveMinSize();
    const w: f32 = if (sc.tracks_viewport_width) vp_w else @max(nat.width, vp_w);
    var h: f32 = if (sc.tracks_viewport_height) vp_h else @max(nat.height, vp_h);
    if (sc.tracks_viewport_width) {
        if (self.view.size_query) |sq| {
            h = @max(sq.minHeightForWidth(self.view, w), vp_h);
        }
    }
    // No width-for-height equivalent in v1 (no widget defines it); the
    // untracked-height branch above already supplies `nat.width`, which is
    // what the previous reshape-based path also fell back to.
    return .{ .width = w, .height = h };
}

// ── layout (ScrollLayout vtable) ───────────────────────────────────────────

fn layoutDoLayout(_: *LayoutManager, container: *Container) void {
    const self: *ScrollPane = @fieldParentPtr("container", container);
    const W = container.component.size.width;
    const H = container.component.size.height;
    const T = ScrollBar.THICKNESS;
    const left: f32 = if (self.row_header_view) |v| v.effectiveMinSize().width else 0;
    const top: f32 = if (self.column_header_view) |v| v.effectiveMinSize().height else 0;

    // Decide bar visibility. The vertical bar steals width (and vice-versa),
    // which can change the other axis's need  Esettle with a couple passes.
    var show_v = self.v_policy == .always;
    var show_h = self.h_policy == .always;
    var iter: u8 = 0;
    while (iter < 2) : (iter += 1) {
        const vp_w = @max(0, W - left - (if (show_v) T else 0));
        const vp_h = @max(0, H - top - (if (show_h) T else 0));
        const sz = self.measureView(vp_w, vp_h);
        if (self.v_policy == .as_needed) show_v = sz.height > vp_h;
        if (self.h_policy == .as_needed) show_h = sz.width > vp_w;
        if (self.v_policy == .never) show_v = false;
        if (self.h_policy == .never) show_h = false;
    }

    const right: f32 = if (show_v) T else 0;
    const bottom: f32 = if (show_h) T else 0;
    const center_w = @max(0, W - left - right);
    const center_h = @max(0, H - top - bottom);
    const view_size = self.measureView(center_w, center_h);

    // Scroll state: range = content size, extent = viewport size. Atomic
    // update so a stale `value` (left over from when the content was larger,
    // e.g. user scrolled down then deleted lines) is clamped down to the new
    // valid range  Eotherwise `setRange` would leave `value` past the new max
    // and `setExtent` would collapse the extent to compensate.
    self.v_model.setRangeProperties(0, self.v_model.value, toI32(view_size.height), toI32(center_h));
    self.h_model.setRangeProperties(0, self.h_model.value, toI32(view_size.width), toI32(center_w));

    // View at its measured size, offset by the (clamped) scroll value.
    const ox: f32 = @floatFromInt(self.h_model.value);
    const oy: f32 = @floatFromInt(self.v_model.value);
    self.view.setBounds(.{ .x = -ox, .y = -oy, .width = view_size.width, .height = view_size.height });
    if (self.column_header_view) |header| {
        header.setBounds(.{ .x = -ox, .y = 0, .width = view_size.width, .height = top });
    }
    if (self.row_header_view) |header| {
        header.setBounds(.{ .x = 0, .y = -oy, .width = left, .height = view_size.height });
    }

    // Viewport + bars in disjoint rects (Component.setBounds: the outer
    // doLayout recursion handles the viewport's own child layout).
    self.viewport.component.setBounds(.{ .x = left, .y = top, .width = center_w, .height = center_h });
    if (self.column_header_port) |port| {
        port.component.setBounds(.{ .x = left, .y = 0, .width = center_w, .height = top });
    }
    if (self.row_header_port) |port| {
        port.component.setBounds(.{ .x = 0, .y = top, .width = left, .height = center_h });
    }
    self.vbar.component.setBounds(if (show_v)
        .{ .x = left + center_w, .y = top, .width = T, .height = center_h }
    else
        .{ .x = 0, .y = 0, .width = 0, .height = 0 });
    self.hbar.component.setBounds(if (show_h)
        .{ .x = left, .y = top + center_h, .width = center_w, .height = T }
    else
        .{ .x = 0, .y = 0, .width = 0, .height = 0 });
    setCornerBounds(self.corners[@intFromEnum(Corner.upper_left)], 0, 0, left, top);
    setCornerBounds(self.corners[@intFromEnum(Corner.upper_right)], left + center_w, 0, right, top);
    setCornerBounds(self.corners[@intFromEnum(Corner.lower_left)], 0, top + center_h, left, bottom);
    setCornerBounds(self.corners[@intFromEnum(Corner.lower_right)], left + center_w, top + center_h, right, bottom);
}

fn setCornerBounds(corner: ?*Component, x: f32, y: f32, w: f32, h: f32) void {
    if (corner) |c| {
        if (w > 0 and h > 0) {
            c.setBounds(.{ .x = x, .y = y, .width = w, .height = h });
        } else {
            c.setBounds(.{ .x = x, .y = y, .width = 0, .height = 0 });
        }
    }
}

fn layoutComputeMinSize(_: *LayoutManager, _: *const Container) Component.Size {
    return .{ .width = DEFAULT_MIN, .height = DEFAULT_MIN };
}

fn layoutComputeMaxSize(_: *LayoutManager, _: *const Container) Component.Size {
    return .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
}

// ── scroll wiring ──────────────────────────────────────────────────────────

fn onScrollChange(self: *ScrollPane, _: *const ChangeEvent) void {
    // Cheap update: just move the view; no relayout needed.
    self.view.position = .{
        .x = -@as(f32, @floatFromInt(self.h_model.value)),
        .y = -@as(f32, @floatFromInt(self.v_model.value)),
    };
    if (self.column_header_view) |header| {
        header.position = .{ .x = -@as(f32, @floatFromInt(self.h_model.value)), .y = 0 };
    }
    if (self.row_header_view) |header| {
        header.position = .{ .x = 0, .y = -@as(f32, @floatFromInt(self.v_model.value)) };
    }
    self.container.component.repaint();
}

fn handleWheel(self: *ScrollPane, m: awt.Event.MouseEvent) void {
    const step = toI32(self.unit_increment);
    const delta: i32 = if (m.wheel > 0) -step else step;
    if (m.modifiers.shift) {
        self.h_model.setValue(self.h_model.value + delta);
    } else {
        self.v_model.setValue(self.v_model.value + delta);
    }
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const c: *Container = @fieldParentPtr("component", self);
    self.container = c;
}

fn uninstall(self: *Component) void {
    const sp = fromComponent(self);
    // Remove our scroll listeners while the models are still alive (the bars
    // are torn down earlier by container.deinit; the models outlive them).
    sp.h_model.removeChangeListener(ScrollPane, onScrollChange, sp);
    sp.v_model.removeChangeListener(ScrollPane, onScrollChange, sp);
}

fn lookPaint(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookMeasureMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = 0 };
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    // Let children (bars, then viewport ↁEview) handle it first.
    Container.vtable.processEvent(self, ev);
    if (ev.isConsumed()) return;
    // An unconsumed wheel over the content scrolls the pane.
    switch (ev.payload) {
        .mouse => |m| {
            if (m.action == .scroll) {
                fromComponent(self).handleWheel(m);
                ev.consume();
            }
        },
        else => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const c: *Container = @fieldParentPtr("component", self);
    const sp: *ScrollPane = @fieldParentPtr("container", c);
    // container.deinit destroys children (viewport ↁEview, hbar, vbar) and
    // runs component.deinit ↁEuninstall (which unsubscribes from the models
    // while they are still alive). Then free the models we own.
    c.deinit();
    sp.v_model.deinit();
    sp.h_model.deinit();
    allocator.destroy(sp);
}

const Panel = @import("Panel.zig");

fn testPanel(a: std.mem.Allocator, w: f32, h: f32) !*Panel {
    const p = try Panel.create(a);
    p.asComponent().setMinSizeDerived(.{ .width = w, .height = h });
    return p;
}

fn layoutTestPane(sp: *ScrollPane, w: f32, h: f32) void {
    sp.asComponent().setBounds(.{ .x = 0, .y = 0, .width = w, .height = h });
    sp.container.doLayout();
}

test "scrollpane: vertical bar starts below column header" {
    const a = std.testing.allocator;
    const view = try testPanel(a, 80, 300);
    const sp = try create(a, view.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);
    const header = try testPanel(a, 80, 26);
    try sp.setColumnHeaderView(header.asComponent());

    layoutTestPane(sp, 100, 100);

    const top: f32 = 26;
    const center_h = 100 - top;
    try std.testing.expectApproxEqAbs(top, sp.vbar.component.position.y, 0.001);
    try std.testing.expectApproxEqAbs(center_h, sp.vbar.component.size.height, 0.001);
}

test "scrollpane: horizontal bar starts after row header" {
    const a = std.testing.allocator;
    const view = try testPanel(a, 300, 80);
    const sp = try create(a, view.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);
    const row_header = try testPanel(a, 32, 80);
    try sp.setRowHeaderView(row_header.asComponent());

    layoutTestPane(sp, 100, 100);

    try std.testing.expectApproxEqAbs(@as(f32, 32), sp.hbar.component.position.x, 0.001);
}

test "scrollpane: header and viewport offsets follow their axes" {
    const a = std.testing.allocator;
    const view = try testPanel(a, 300, 300);
    const sp = try create(a, view.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);
    const col_header = try testPanel(a, 300, 26);
    const row_header = try testPanel(a, 32, 300);
    try sp.setColumnHeaderView(col_header.asComponent());
    try sp.setRowHeaderView(row_header.asComponent());

    layoutTestPane(sp, 100, 100);
    sp.setScrollX(40);
    sp.setScrollY(30);

    try std.testing.expectApproxEqAbs(@as(f32, -40), col_header.asComponent().position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), col_header.asComponent().position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), row_header.asComponent().position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -30), row_header.asComponent().position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -40), view.asComponent().position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -30), view.asComponent().position.y, 0.001);
}

test "scrollpane: no headers keeps legacy viewport and bar regions" {
    const a = std.testing.allocator;
    const view = try testPanel(a, 300, 300);
    const sp = try create(a, view.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutTestPane(sp, 100, 100);

    const T = ScrollBar.THICKNESS;
    try std.testing.expectApproxEqAbs(@as(f32, 0), sp.viewport.component.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sp.viewport.component.position.y, 0.001);
    try std.testing.expectApproxEqAbs(100 - T, sp.viewport.component.size.width, 0.001);
    try std.testing.expectApproxEqAbs(100 - T, sp.viewport.component.size.height, 0.001);
    try std.testing.expectApproxEqAbs(100 - T, sp.vbar.component.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sp.vbar.component.position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sp.hbar.component.position.x, 0.001);
    try std.testing.expectApproxEqAbs(100 - T, sp.hbar.component.position.y, 0.001);
}

test "scrollpane: corners collapse when either band is zero" {
    const a = std.testing.allocator;
    const view = try testPanel(a, 80, 80);
    const sp = try create(a, view.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);
    const header = try testPanel(a, 80, 26);
    const row_header = try testPanel(a, 32, 80);
    const corner = try testPanel(a, 10, 10);
    try sp.setColumnHeaderView(header.asComponent());
    try sp.setRowHeaderView(row_header.asComponent());
    try sp.setCorner(.upper_left, corner.asComponent());

    layoutTestPane(sp, 100, 100);

    try std.testing.expectApproxEqAbs(@as(f32, 32), corner.asComponent().size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 26), corner.asComponent().size.height, 0.001);

    row_header.asComponent().setMinSizeDerived(.{ .width = 0, .height = 80 });
    layoutTestPane(sp, 100, 100);

    try std.testing.expectApproxEqAbs(@as(f32, 0), corner.asComponent().size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), corner.asComponent().size.height, 0.001);
}
