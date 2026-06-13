//! Menu item with radio-style selected state. See
//! `framework/doc/radio_button_menu_item.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const ToggleButtonModel = @import("ToggleButtonModel.zig");
const MenuItem = @import("MenuItem.zig");
const ButtonGroup = @import("ButtonGroup.zig");
const Application = @import("Application.zig");

const RadioButtonMenuItem = @This();

component: Component,
text: []const u8,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
model: *ToggleButtonModel,
owns_model: bool,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButtonMenuItem {
    const model = try allocator.create(ToggleButtonModel);
    errdefer allocator.destroy(model);
    model.* = ToggleButtonModel.init(allocator);
    errdefer model.deinit();
    return createInternal(allocator, model, true, text, font, color);
}

pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButtonMenuItem {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    owns_model: bool,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButtonMenuItem {
    const item = try allocator.create(RadioButtonMenuItem);
    errdefer allocator.destroy(item);

    const text_dup = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dup);

    item.* = .{
        .component = Component.init(allocator, &vtable),
        .text = text_dup,
        .font = font,
        .color = color,
        .model = model,
        .owns_model = owns_model,
        .allocator = allocator,
    };
    item.component.role = .radio_button_menu_item;
    item.applyMetrics();
    try RadioButtonMenuItem.vtable.install(&item.component);
    return item;
}

fn applyMetrics(self: *RadioButtonMenuItem) void {
    const m = self.font.measureString(self.text);
    const min = Component.Size{
        .width = MenuItem.ICON_SLOT_WIDTH + m.width + MenuItem.ACCEL_SLOT_WIDTH + MenuItem.PADDING_X * 2,
        .height = m.height + MenuItem.PADDING_Y * 2,
    };
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

pub fn getText(self: RadioButtonMenuItem) []const u8 {
    return self.text;
}

pub fn setText(self: *RadioButtonMenuItem, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
}

pub fn isSelected(self: RadioButtonMenuItem) bool {
    return self.model.isSelected();
}

pub fn setSelected(self: *RadioButtonMenuItem, v: bool) void {
    self.model.setSelected(v);
}

pub fn getModel(self: RadioButtonMenuItem) *ToggleButtonModel {
    return self.model;
}

/// Programmatic activation: select + fire. Unlike CheckBoxMenuItem this never
/// toggles off; mutual exclusion is handled by ButtonGroup when present.
/// No-op while disabled.
pub fn doClick(self: *RadioButtonMenuItem) void {
    if (!self.model.button.enabled) return;
    if (!self.model.isSelected()) self.model.setSelected(true);
    self.model.fireAction();
}

// ── vtable impl ─────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const item: *RadioButtonMenuItem = @fieldParentPtr("component", self);
    try item.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const item: *RadioButtonMenuItem = @fieldParentPtr("component", self);
    item.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const item: *RadioButtonMenuItem = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;
    const btn = &item.model.button;

    const armed_pressed = btn.armed and btn.pressed;
    if (btn.enabled) {
        if (armed_pressed) {
            g.setColor(t.accent);
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        } else if (btn.rollover) {
            g.setColor(t.accent_soft);
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        }
    }

    if (item.model.isSelected()) {
        const dot_color = if (armed_pressed)
            t.text_on_accent
        else if (!btn.enabled)
            t.text_disabled
        else
            t.accent;
        drawRadioDot(g, MenuItem.PADDING_X, sz.height, dot_color);
    }

    const m = item.font.measureString(item.text);
    const text_color = blk: {
        if (!btn.enabled) break :blk t.text_disabled;
        if (armed_pressed) break :blk t.text_on_accent;
        break :blk item.color;
    };
    g.setFont(item.font);
    g.setColor(text_color);
    const tx = MenuItem.PADDING_X + MenuItem.ICON_SLOT_WIDTH;
    const ty = (sz.height - m.height) / 2;
    g.drawString(item.text, tx, ty);
}

fn drawRadioDot(g: *awt.Graphics, x0: f32, row_h: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    const size: f32 = 8;
    const cx = x0 + (MenuItem.ICON_SLOT_WIDTH - size) / 2;
    const cy = (row_h - size) / 2;
    g.fillCircle(.{ .x = cx, .y = cy, .width = size, .height = size });
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const item: *RadioButtonMenuItem = @fieldParentPtr("component", self);
    const btn = &item.model.button;
    if (!btn.enabled) return;

    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const inside = lx >= 0 and lx < self.size.width and ly >= 0 and ly < self.size.height;

            switch (m.action) {
                .press => {
                    if (m.button == .left and inside) {
                        btn.setPressed(true);
                        btn.setArmed(true);
                        ev.requestCapture(@ptrCast(self));
                        ev.consume();
                    }
                },
                .release => {
                    if (m.button == .left and btn.isPressed()) {
                        const was_armed = btn.isArmed();
                        btn.setPressed(false);
                        btn.setArmed(false);
                        if (was_armed and inside) item.doClick();
                        ev.consume();
                    }
                },
                .move => {
                    if (btn.isPressed()) btn.setArmed(inside);
                    btn.setRollover(inside);
                },
                .scroll => {},
            }
        },
        .key, .char, .focus, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const item: *RadioButtonMenuItem = @fieldParentPtr("component", self);
    self.deinit();
    allocator.free(item.text);
    if (item.owns_model) {
        item.model.deinit();
        allocator.destroy(item.model);
    }
    allocator.destroy(item);
}

const QuietLog = struct {
    fn cb(level: awt.LogLevel, category: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        if (level < awt.c.nmLogLevelWarn) return;
        const tag: []const u8 = if (level == awt.c.nmLogLevelWarn) "WARN" else "ERROR";
        const cat: [*:0]const u8 = category;
        const msg: [*:0]const u8 = message;
        std.debug.print("[{s}] [{s}] {s}\n", .{ tag, std.mem.span(cat), std.mem.span(msg) });
    }
};

fn newApp() !*Application {
    awt.setLogCallback(QuietLog.cb, null);
    return Application.initHeadless(std.testing.allocator, std.testing.io) catch
        return error.SkipZigTest;
}

test "radio menu item click selects and does not toggle off" {
    const app = try newApp();
    defer app.deinit();

    const item = try app.radioButtonMenuItem("List");
    defer item.component.vtable.destroy(&item.component, std.testing.allocator);

    try std.testing.expect(!item.isSelected());
    item.doClick();
    try std.testing.expect(item.isSelected());
    item.doClick();
    try std.testing.expect(item.isSelected());
}

test "radio menu item works with ButtonGroup exclusion" {
    const app = try newApp();
    defer app.deinit();

    const list = try app.radioButtonMenuItem("List");
    defer list.component.vtable.destroy(&list.component, std.testing.allocator);
    const details = try app.radioButtonMenuItem("Details");
    defer details.component.vtable.destroy(&details.component, std.testing.allocator);

    var group = ButtonGroup.init(std.testing.allocator);
    defer group.deinit();

    try group.add(list.getModel());
    try group.add(details.getModel());

    list.doClick();
    try std.testing.expect(list.isSelected());
    try std.testing.expect(!details.isSelected());
    try std.testing.expectEqual(@as(?*ToggleButtonModel, list.getModel()), group.getSelected());

    details.doClick();
    try std.testing.expect(!list.isSelected());
    try std.testing.expect(details.isSelected());
    try std.testing.expectEqual(@as(?*ToggleButtonModel, details.getModel()), group.getSelected());
}
