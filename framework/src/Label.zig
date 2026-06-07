//! Single-line text label. See `framework/doc/label.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");

const Label = @This();

component: Component,
text:      []const u8,         // Label owns (allocator.dupe'd)
font:      awt.Graphics.TextFont,
color:     awt.Graphics.Color,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn init(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !Label {
    var l = Label{
        .component = Component.init(allocator, &vtable),
        .text      = try allocator.dupe(u8, text),
        .font      = font,
        .color     = color,
        .allocator = allocator,
    };
    l.component.role = .label;
    l.component.min_size = textMinSize(font, l.text);
    return l;
}

pub fn deinit(self: *Label) void {
    self.component.deinit();                 // uninstall + property cleanup
    self.allocator.free(self.text);
}

/// Heap-allocate + init + install. Caller frees via `vtable.destroy` (or
/// indirectly when added to a Container that owns this widget).
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Label {
    const label = try allocator.create(Label);
    errdefer allocator.destroy(label);
    label.* = try Label.init(allocator, text, font, color);
    try Label.vtable.install(&label.component);
    return label;
}

pub fn setText(self: *Label, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.component.setMinSize(textMinSize(self.font, self.text));
}

pub fn getText(self: Label) []const u8 {
    return self.text;
}

pub fn setFont(self: *Label, font: awt.Graphics.TextFont) void {
    self.font = font;
    self.component.setMinSize(textMinSize(self.font, self.text));
}

pub fn getFont(self: Label) awt.Graphics.TextFont {
    return self.font;
}

pub fn setColor(self: *Label, color: awt.Graphics.Color) void {
    self.color = color;
    self.component.repaint();
}

pub fn getColor(self: Label) awt.Graphics.Color {
    return self.color;
}

fn textMinSize(font: awt.Graphics.TextFont, text: []const u8) Component.Size {
    const m = font.measureString(text);
    return .{ .width = m.width, .height = m.height };
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    _ = self;
}

fn uninstall(self: *Component) void {
    _ = self;
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const label: *Label = @fieldParentPtr("component", self);
    g.setFont(label.font);
    g.setColor(label.color);
    g.drawString(label.text, 0, 0);
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    _ = self;
    _ = ev;
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const label: *Label = @fieldParentPtr("component", self);
    label.deinit();
    allocator.destroy(label);
}
