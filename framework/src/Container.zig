//! Container that owns child Components. See `framework/doc/container.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const LayoutManager = @import("LayoutManager.zig");

const Container = @This();

pub const LayoutElement = struct {
    component:    *Component,
    hint:         ?*anyopaque = null,
    hint_destroy: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
};

component: Component,
children:  std.ArrayList(LayoutElement),
layout:    ?*LayoutManager,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn init(allocator: std.mem.Allocator) Container {
    return .{
        .component = Component.init(allocator, &vtable),
        .children  = .empty,
        .layout    = null,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Container) void {
    for (self.children.items) |elem| {
        if (elem.hint_destroy) |destroy_hint| destroy_hint(elem.hint.?, self.allocator);
        // vtable.destroy is responsible for its own deinit chain
        // (widget.deinit → component.deinit → uninstall + property cleanup).
        elem.component.vtable.destroy(elem.component, self.allocator);
    }
    self.children.deinit(self.allocator);
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
        .component    = child,
        .hint         = hint,
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
    self.layout = layout;
    self.doLayout();
    self.component.markLayoutDirty();
}

pub fn getMinSize(self: *const Container) Component.Size {
    const lm_min: Component.Size = if (self.layout) |lm|
        lm.vtable.computeMinSize(lm, self)
    else
        .{ .width = 0, .height = 0 };
    return .{
        .width  = @max(self.component.min_size.width, lm_min.width),
        .height = @max(self.component.min_size.height, lm_min.height),
    };
}

pub fn getMaxSize(self: *const Container) Component.Size {
    const lm_max: Component.Size = if (self.layout) |lm|
        lm.vtable.computeMaxSize(lm, self)
    else
        .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
    // Symmetric with `getMinSize`: combine the explicit field with the
    // layout-computed value. For max we take the *smaller* of the two
    // ("both bounds must hold"), so an explicit `setMaxSize` actually
    // caps the layout's contribution.
    return .{
        .width  = @min(self.component.max_size.width, lm_max.width),
        .height = @min(self.component.max_size.height, lm_max.height),
    };
}

pub fn setBounds(self: *Container, bounds: Component.Rect) void {
    self.component.setBounds(bounds);
    self.doLayout();
}

/// Run the layout manager on direct children, then recurse into any child
/// that is itself a Container.
pub fn doLayout(self: *Container) void {
    if (self.layout) |lm| lm.vtable.doLayout(lm, self);
    for (self.children.items) |elem| {
        if (elem.component.container) |child_c| child_c.doLayout();
    }
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

fn processEvent(self: *Component, ev: *Component.Event) void {
    const container = self.container orelse return;
    switch (ev.payload) {
        .mouse => |m| {
            // Hit-test in reverse so top-most child (added last) gets first shot.
            var i: usize = container.children.items.len;
            while (i > 0) {
                i -= 1;
                const child = container.children.items[i].component;
                if (child.containsWindowPoint(m.x, m.y)) {
                    child.vtable.processEvent(child, ev);
                    if (ev.isConsumed()) return;
                }
            }
        },
        .key, .char => {
            // Key / text-input events: fan out to all children. Focus-aware
            // routing (B-2: focus_owner) bypasses this path when set; this
            // fan-out is the fallback when no component has focus.
            for (container.children.items) |elem| {
                elem.component.vtable.processEvent(elem.component, ev);
                if (ev.isConsumed()) return;
            }
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
