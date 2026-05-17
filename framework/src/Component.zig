//! Base widget type. See `framework/doc/component.md`.

const std = @import("std");
const awt = @import("awt");

const Component = @This();

pub const Point = struct { x: f32, y: f32 };
pub const Size = struct { width: f32, height: f32 };
/// Alias to awt.Graphics.Rect so Component / Graphics share the same Rect type
/// and `g.clip(comp.getBounds())` type-checks without conversion.
pub const Rect = awt.Graphics.Rect;

/// Event placeholder. v1 has no event dispatch; this is reserved so the
/// vtable shape is stable for v2 onward.
pub const Event = struct {};

pub const VTable = struct {
    install:      *const fn (self: *Component) void,
    uninstall:    *const fn (self: *Component) void,
    paint:        *const fn (self: *Component, g: *awt.Graphics) void,
    processEvent: *const fn (self: *Component, ev: *const Event) bool,
    /// Free the concrete widget's memory (sizeof Label / Button / ... not sizeof Component).
    /// Called by Container.deinit after `uninstall` + property cleanup. The implementation
    /// is expected to `@fieldParentPtr` back to the outer type and call `allocator.destroy`.
    destroy:      *const fn (self: *Component, allocator: std.mem.Allocator) void,
};

pub const Property = struct {
    value:   *anyopaque,
    destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
};

// Forward declaration so `container` field can reference Container.
const Container = @import("Container.zig");

vtable:     *const VTable,
position:   Point,
size:       Size,
parent:     ?*Component,
container:  ?*Container,
name:       ?[]const u8,
properties: ?std.StringHashMap(Property),
allocator:  std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) Component {
    return .{
        .vtable     = vtable,
        .position   = .{ .x = 0, .y = 0 },
        .size       = .{ .width = 0, .height = 0 },
        .parent     = null,
        .container  = null,
        .name       = null,
        .properties = null,
        .allocator  = allocator,
    };
}

/// Run vtable.uninstall and free property values. Does NOT free the outer
/// widget's memory — vtable.destroy is responsible for that.
pub fn deinit(self: *Component) void {
    self.vtable.uninstall(self);
    if (self.properties) |*props| {
        var it = props.iterator();
        while (it.next()) |entry| {
            const prop = entry.value_ptr.*;
            if (prop.destroy) |destroy| destroy(prop.value, self.allocator);
        }
        props.deinit();
        self.properties = null;
    }
}

pub fn getBounds(self: Component) Rect {
    return .{
        .x = self.position.x,
        .y = self.position.y,
        .width = self.size.width,
        .height = self.size.height,
    };
}

pub fn setBounds(self: *Component, r: Rect) void {
    self.position = .{ .x = r.x, .y = r.y };
    self.size = .{ .width = r.width, .height = r.height };
    self.repaint();
}

pub fn setName(self: *Component, name: ?[]const u8) void {
    self.name = name;
}

pub fn getName(self: Component) ?[]const u8 {
    return self.name;
}

/// Swap to a new vtable. uninstall the old, swap, install the new — atomic.
pub fn setVTable(self: *Component, new_vt: *const VTable) void {
    self.vtable.uninstall(self);
    self.vtable = new_vt;
    self.vtable.install(self);
}

/// Mark dirty for repaint. v1: walks up to find Frame and sets dirty rect.
/// Frame is not implemented yet, so this is a stub.
pub fn repaint(self: *Component) void {
    _ = self;
}

pub fn repaintRect(self: *Component, r: Rect) void {
    _ = self;
    _ = r;
}

/// Helper: build a child Graphics clipped to self.getBounds and dispatch
/// vtable.paint. Used by Container to paint children and by the root caller
/// (hello / Frame) to paint the root component without manual clip plumbing.
pub fn paintAt(self: *Component, parent_g: *awt.Graphics) void {
    var g = parent_g.clip(self.getBounds());
    self.vtable.paint(self, &g);
}

// ── client properties (Swing JComponent.putClientProperty 相当) ───────────

pub fn putProperty(
    self: *Component,
    key: []const u8,
    value: *anyopaque,
    destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void {
    if (self.properties == null) {
        self.properties = std.StringHashMap(Property).init(self.allocator);
    }
    try self.properties.?.put(key, .{ .value = value, .destroy = destroy });
}

pub fn getProperty(self: Component, key: []const u8) ?*anyopaque {
    const props = self.properties orelse return null;
    const prop = props.get(key) orelse return null;
    return prop.value;
}

pub fn removeProperty(self: *Component, key: []const u8) void {
    if (self.properties) |*props| {
        if (props.fetchRemove(key)) |entry| {
            if (entry.value.destroy) |destroy| destroy(entry.value.value, self.allocator);
        }
    }
}

pub fn putTyped(self: *Component, comptime T: type, value: *T) !void {
    const dtor = struct {
        fn d(p: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*T, @ptrCast(@alignCast(p))));
        }
    }.d;
    try self.putProperty(@typeName(T), @ptrCast(value), dtor);
}

pub fn getTyped(self: Component, comptime T: type) ?*T {
    const ptr = self.getProperty(@typeName(T)) orelse return null;
    return @ptrCast(@alignCast(ptr));
}
