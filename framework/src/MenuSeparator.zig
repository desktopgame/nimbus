//! Menu separator (horizontal divider). See `framework/doc/menu_separator.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");

const MenuSeparator = @This();

const LINE_THICKNESS: f32 = 1;
const PADDING_Y: f32 = 4;

component: Component,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn create(allocator: std.mem.Allocator) !*MenuSeparator {
    const s = try allocator.create(MenuSeparator);
    errdefer allocator.destroy(s);
    s.* = .{
        .component = Component.init(allocator, &vtable),
        .allocator = allocator,
    };
    const h = LINE_THICKNESS + PADDING_Y * 2;
    s.component.min_size = .{ .width = 0, .height = h };
    s.component.max_size = .{ .width = std.math.inf(f32), .height = h };
    return s;
}

fn install(_: *Component) !void {}
fn uninstall(_: *Component) void {}

fn paint(self: *Component, g: *awt.Graphics) void {
    const w = self.size.width;
    g.setColor(awt.Graphics.Color.rgb(0.75, 0.75, 0.78));
    g.fillRect(.{
        .x = 0,
        .y = PADDING_Y,
        .width = w,
        .height = LINE_THICKNESS,
    });
}

fn processEvent(_: *Component, _: *Component.Event) void {
    // Separators don't consume input.
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const sep: *MenuSeparator = @fieldParentPtr("component", self);
    self.deinit();
    allocator.destroy(sep);
}
