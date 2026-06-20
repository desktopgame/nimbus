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

pub fn create(allocator: std.mem.Allocator) !*MenuSeparator {
    const s = try allocator.create(MenuSeparator);
    errdefer allocator.destroy(s);
    s.* = .{
        .component = Component.init(allocator, &vtable),
        .allocator = allocator,
    };
    s.component.role = .separator;
    s.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    const min = lookMeasureMinSize(&s.component, &Component.default_look_context);
    s.component.min_size = min;
    const h = min.height;
    s.component.max_size = .{ .width = std.math.inf(f32), .height = h };
    return s;
}

fn install(_: *Component) !void {}
fn uninstall(_: *Component) void {}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const w = self.size.width;
    g.setColor(self.theme.separator);
    g.fillRect(.{
        .x = 0,
        .y = PADDING_Y,
        .width = w,
        .height = LINE_THICKNESS,
    });
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookMeasureMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = LINE_THICKNESS + PADDING_Y * 2 };
}

fn processEvent(_: *Component, _: *Component.Event) void {
    // Separators don't consume input.
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const sep: *MenuSeparator = @fieldParentPtr("component", self);
    self.deinit();
    allocator.destroy(sep);
}
