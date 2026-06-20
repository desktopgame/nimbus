//! Single-line text label, optionally with an icon left of the text
//! (Swing `JLabel` parity). See `framework/doc/label.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");

const Label = @This();

const ICON_TEXT_GAP: f32 = 6;

component: Component,
text: []const u8, // Label owns (allocator.dupe'd)
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
icon: ?awt.Image, // borrowed (e.g. Application's icon cache)
icon_size: ?Component.Size, // null = natural size; non-null = scaled
allocator: std.mem.Allocator,

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

pub fn init(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !Label {
    var l = Label{
        .component = Component.init(allocator, &vtable),
        .text = try allocator.dupe(u8, text),
        .font = font,
        .color = color,
        .icon = null,
        .icon_size = null,
        .allocator = allocator,
    };
    l.component.role = .label;
    l.component.a11y = .{ .name = a11yName };
    l.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    l.component.min_size = lookMeasureMinSize(&l.component, &Component.default_look_context);
    return l;
}

pub fn deinit(self: *Label) void {
    self.component.deinit(); // uninstall + property cleanup
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
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

pub fn getText(self: Label) []const u8 {
    return self.text;
}

pub fn setFont(self: *Label, font: awt.Graphics.TextFont) void {
    self.font = font;
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
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

pub fn getIcon(self: Label) ?awt.Image {
    return self.icon;
}

/// The icon is borrowed; the caller keeps it alive for the Label's lifetime
/// (Application's built-in icon cache satisfies this). Pass null to clear.
pub fn setIcon(self: *Label, icon: ?awt.Image) void {
    self.icon = icon;
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

pub fn getIconSize(self: Label) ?Component.Size {
    return self.icon_size;
}

pub fn setIconSize(self: *Label, size: ?Component.Size) void {
    self.icon_size = size;
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

fn iconDrawSize(self: *const Label) Component.Size {
    if (self.icon == null) return .{ .width = 0, .height = 0 };
    if (self.icon_size) |s| return s;
    const img = self.icon.?;
    return .{ .width = @floatFromInt(img.width), .height = @floatFromInt(img.height) };
}

fn contentMinSize(self: *const Label) Component.Size {
    const m = self.font.measureString(self.text);
    const icon_sz = self.iconDrawSize();
    if (self.icon == null) return .{ .width = m.width, .height = m.height };
    const gap: f32 = if (self.text.len > 0) ICON_TEXT_GAP else 0;
    return .{
        .width = icon_sz.width + gap + m.width,
        .height = @max(icon_sz.height, m.height),
    };
}

fn updateMinSizeFromLook(self: *Label) void {
    const ui = self.component.ui.?;
    self.component.min_size = ui.vtable.measureMinSize(&self.component, ui.ctx);
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const label: *Label = @fieldParentPtr("component", self);
    return label.contentMinSize();
}

fn a11yName(c: *const Component) ?[]const u8 {
    const l: *const Label = @fieldParentPtr("component", c);
    if (l.text.len == 0) return null;
    return l.text;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    _ = self;
}

fn uninstall(self: *Component) void {
    _ = self;
}

fn paint(self: *Component, g: *awt.Graphics) void {
    lookPaint(self, &Component.default_look_context, g);
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const label: *Label = @fieldParentPtr("component", self);
    // Text-only path is unchanged from the icon-less Label (top-left), so
    // existing layouts / snapshots are unaffected.
    if (label.icon == null) {
        g.setFont(label.font);
        g.setColor(label.color);
        g.drawString(label.text, 0, 0);
        return;
    }
    // With an icon, both icon and text center vertically in the assigned box
    // (rows are usually taller than the text; top-aligning looks broken).
    const icon_sz = label.iconDrawSize();
    var x: f32 = 0;
    if (label.icon) |img| {
        const iy = (self.size.height - icon_sz.height) / 2;
        g.drawImageScaled(img, x, iy, icon_sz.width, icon_sz.height);
        x += icon_sz.width;
    }
    if (label.text.len > 0) {
        x += ICON_TEXT_GAP;
        const m = label.font.measureString(label.text);
        const ty = (self.size.height - m.height) / 2;
        g.setFont(label.font);
        g.setColor(label.color);
        g.drawString(label.text, x, ty);
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn processEvent(self: *Component, ev: *Component.Event) void {
    _ = self;
    _ = ev;
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const label: *Label = @fieldParentPtr("component", self);
    label.deinit();
    allocator.destroy(label);
}
