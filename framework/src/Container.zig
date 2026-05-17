//! Container that owns child Components. See `framework/doc/container.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");

const Container = @This();

/// LayoutManager placeholder. v2 で本格化、それまで `?*LayoutManager` は常に null。
pub const LayoutManager = opaque {};

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
        elem.component.deinit();                                       // uninstall + properties cleanup
        elem.component.vtable.destroy(elem.component, self.allocator); // free outer widget memory
    }
    self.children.deinit(self.allocator);
    self.component.deinit();
}

pub fn add(self: *Container, child: *Component) !void {
    try self.children.append(self.allocator, .{ .component = child });
    child.parent = &self.component;
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
}

pub fn asComponent(self: *Container) *Component {
    return &self.component;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) void {
    // Mark this component as a Container for tree-walk identification.
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

fn processEvent(self: *Component, ev: *const Component.Event) bool {
    _ = self;
    _ = ev;
    return false;
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const container: *Container = @fieldParentPtr("component", self);
    allocator.destroy(container);
}
