//! Container that owns child Components. See `framework/doc/container.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const LayoutManager = @import("LayoutManager.zig");

const Container = @This();

pub const LayoutElement = struct {
    component: *Component,
    hint: ?*anyopaque = null,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
};

component: Component,
children: std.ArrayList(LayoutElement),
layout: ?*LayoutManager,
allocator: std.mem.Allocator,
/// Memoized layout-computed min/max size (the result of the layout manager's
/// `computeMinSize`/`computeMaxSize`, which walks the whole subtree). Null when
/// stale. Invalidated by `Component.markDirty` on every container along the
/// path from a changed node up to the root — i.e. exactly the containers whose
/// subtree measurement could have changed. See `doc/internal/optimize.md`.
min_cache: ?Component.Size = null,
max_cache: ?Component.Size = null,
/// Child the pointer is currently over, tracked so we can synthesize a
/// `mouseExited` to it when the hovered child changes (nimbus has no OS
/// enter/leave). Null = pointer is over no child. See `Component.mouseExited`.
last_hovered: ?*Component = null,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub const look_vtable = Component.LookVTable{
    .paint = lookPaint,
    .paintOver = lookPaintOver,
    .measureMinSize = lookMeasureMinSize,
};

pub fn init(allocator: std.mem.Allocator) Container {
    var container = Container{
        .component = Component.init(allocator, &vtable),
        .children = .empty,
        .layout = null,
        .allocator = allocator,
    };
    container.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    return container;
}

pub fn deinit(self: *Container) void {
    for (self.children.items) |elem| {
        if (elem.hint_destroy) |destroy_hint| destroy_hint(elem.hint.?, self.allocator);
        // vtable.destroy is responsible for its own deinit chain
        // (widget.deinit → component.deinit → uninstall + property cleanup).
        elem.component.vtable.destroy(elem.component, self.allocator);
    }
    self.children.deinit(self.allocator);
    self.deinitLayout();
    self.component.deinit();
}

pub fn create(allocator: std.mem.Allocator) !*Container {
    const cont = try allocator.create(Container);
    errdefer allocator.destroy(cont);
    cont.* = Container.init(allocator);
    try Container.vtable.install(&cont.component);
    return cont;
}

pub fn add(self: *Container, child: *Component) !void {
    try self.children.append(self.allocator, .{ .component = child });
    child.parent = &self.component;
    self.component.markLayoutDirty();
}

pub fn addWithHint(
    self: *Container,
    child: *Component,
    hint: *anyopaque,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void {
    try self.children.append(self.allocator, .{
        .component = child,
        .hint = hint,
        .hint_destroy = hint_destroy,
    });
    child.parent = &self.component;
    self.component.markLayoutDirty();
}

pub fn remove(self: *Container, child: *Component) void {
    var i: usize = 0;
    while (i < self.children.items.len) : (i += 1) {
        const elem = self.children.items[i];
        if (elem.component == child) {
            if (elem.hint_destroy) |dh| dh(elem.hint.?, self.allocator);
            if (self.last_hovered == child) self.last_hovered = null;
            _ = self.children.orderedRemove(i);
            child.parent = null;
            self.component.markLayoutDirty();
            return;
        }
    }
}

pub fn asComponent(self: *Container) *Component {
    return &self.component;
}

// ── layout integration ───────────────────────────────────────────────────

pub fn getLayout(self: *const Container) ?*LayoutManager {
    return self.layout;
}

pub fn setLayout(self: *Container, layout: ?*LayoutManager) void {
    if (self.layout != layout) self.deinitLayout();
    self.layout = layout;
    // The cached size belongs to the previous layout manager; drop it before
    // the doLayout below reads getMinSize.
    self.invalidateSizeCache();
    self.doLayout();
    self.component.markLayoutDirty();
}

fn deinitLayout(self: *Container) void {
    if (self.layout) |layout| {
        if (layout.vtable.deinit) |layout_deinit| layout_deinit(layout, self.allocator);
        self.layout = null;
    }
}

pub fn getMinSize(self: *const Container) Component.Size {
    const lm_min: Component.Size = if (self.layout) |lm| blk: {
        if (self.min_cache) |c| break :blk c;
        const m = lm.vtable.computeMinSize(lm, self);
        // Logically const: the memo is a pure function of the (unchanged)
        // subtree. The Container instance is genuinely mutable; only this
        // pointer is const, so @constCast is safe here.
        @constCast(self).min_cache = m;
        break :blk m;
    } else .{ .width = 0, .height = 0 };
    return .{
        .width = @max(self.component.min_size.width, lm_min.width),
        .height = @max(self.component.min_size.height, lm_min.height),
    };
}

/// Drop the memoized min/max sizes. Called from `Component.markDirty` for every
/// container on the path to the root whenever something layout-affecting
/// changes below it.
pub fn invalidateSizeCache(self: *Container) void {
    self.min_cache = null;
    self.max_cache = null;
}

pub fn getMaxSize(self: *const Container) Component.Size {
    const lm_max: Component.Size = if (self.layout) |lm| blk: {
        if (self.max_cache) |c| break :blk c;
        const m = lm.vtable.computeMaxSize(lm, self);
        @constCast(self).max_cache = m;
        break :blk m;
    } else .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
    // Symmetric with `getMinSize`: combine the explicit field with the
    // layout-computed value. For max we take the *smaller* of the two
    // ("both bounds must hold"), so an explicit `setMaxSize` actually
    // caps the layout's contribution.
    return .{
        .width = @min(self.component.max_size.width, lm_max.width),
        .height = @min(self.component.max_size.height, lm_max.height),
    };
}

pub fn setBounds(self: *Container, bounds: Component.Rect) void {
    self.component.setBounds(bounds);
    // doLayout is NOT called here. Triggering layout from inside `setBounds`
    // creates a footgun: when a `LayoutManager` writes children's bounds via
    // `Container.setBounds`, each call recurses into the child's own doLayout,
    // and combined with the outer cascade you get 2^k layouts at depth k.
    // Instead, `Window.redraw` calls `container.doLayout()` explicitly after
    // setting the root's bounds, and `Container.doLayout` recurses into child
    // containers. `Component.setBounds` is fine to use from a LayoutManager
    // (and so is `Container.setBounds` now, since it's equivalent).
}

/// Run the layout manager on direct children, then recurse into any child
/// that is itself a Container.
pub fn doLayout(self: *Container) void {
    if (self.layout) |lm| lm.vtable.doLayout(lm, self);
    for (self.children.items) |elem| {
        if (elem.component.container) |child_c| child_c.doLayout();
    }
}

// ── hover tracking ─────────────────────────────────────────────────────────

/// Update the hovered child. When it changes, the previously-hovered child is
/// sent a synthesized `.move` at the current (now-outside) pointer position so
/// it re-evaluates and drops its hover state (e.g. `rollover`). If that child
/// is itself a container, its own `.move` handling propagates the same to its
/// hovered descendant — so leave needs no dedicated vtable hook. Shared by
/// Panel, which embeds a Container and routes mouse events the same way.
///
/// nimbus has no OS enter/leave; "enter" needs nothing because the ordinary
/// `.move` already reaches the newly-hovered child.
pub fn updateHover(self: *Container, target: ?*Component, x: f32, y: f32) void {
    if (self.last_hovered == target) return;
    if (self.last_hovered) |old| {
        var ev = Component.Event{ .payload = .{ .mouse = .{ .x = x, .y = y, .action = .move } } };
        old.vtable.processEvent(old, &ev);
    }
    self.last_hovered = target;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const container: *Container = @fieldParentPtr("component", self);
    self.container = container;
}

fn uninstall(self: *Component) void {
    self.container = null;
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const container = self.container orelse return;
    for (container.children.items) |elem| {
        elem.component.paintAt(g);
    }
}

fn lookPaint(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookMeasureMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = 0 };
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const container = self.container orelse return;
    switch (ev.payload) {
        .mouse => |m| {
            // Hit-test in reverse so top-most child (added last) gets first shot.
            var hovered: ?*Component = null;
            var i: usize = container.children.items.len;
            while (i > 0) {
                i -= 1;
                const child = container.children.items[i].component;
                if (child.containsWindowPoint(m.x, m.y)) {
                    if (hovered == null) hovered = child;
                    child.vtable.processEvent(child, ev);
                    if (ev.isConsumed()) break;
                }
            }
            // Track hover on moves so the previously-hovered child re-evaluates
            // (and drops rollover) when the pointer moves off it.
            if (m.action == .move) container.updateHover(hovered, m.x, m.y);
        },
        .key, .char => {
            // No fan-out: raw key / text-input events reach a widget only as
            // the window's focus owner, dispatched directly by
            // `Window.dispatchInput`. Containers never forward them. (The old
            // broadcast-to-all-children fallback was deleted with the
            // keybinding redesign — see `narrative/keybinding.md`「削除予定:
            // フォーカス不在時の fan-out」.)
        },
        .focus, .composition => {
            // Focus events are delivered directly to the gaining/losing
            // component by Window.requestFocusFor — not through fan-out.
            // Composition events will be routed to focus_owner in a future
            // milestone; until then they fall on the floor here.
        },
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const container: *Container = @fieldParentPtr("component", self);
    container.deinit();
    allocator.destroy(container);
}
