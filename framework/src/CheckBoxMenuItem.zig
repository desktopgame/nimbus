//! Menu item with a toggleable checked state. See `framework/doc/checkbox_menu_item.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const ToggleButtonModel = @import("ToggleButtonModel.zig");
const MenuItem = @import("MenuItem.zig");

const CheckBoxMenuItem = @This();

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
    .processEvent = processEvent,
    .destroy = destroy,
};

pub const look_vtable = Component.LookVTable{
    .paint = lookPaint,
    .paintOver = lookPaintOver,
    .measureMinSize = lookMeasureMinSize,
};

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBoxMenuItem {
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
) !*CheckBoxMenuItem {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    owns_model: bool,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBoxMenuItem {
    const item = try allocator.create(CheckBoxMenuItem);
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
    item.component.role = .checkbox_menu_item;
    item.component.a11y = .{ .name = a11yName };
    item.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    item.applyMetrics();
    try CheckBoxMenuItem.vtable.install(&item.component);
    return item;
}

fn applyMetrics(self: *CheckBoxMenuItem) void {
    const ui = self.component.ui;
    const min = ui.vtable.measureMinSize(&self.component, ui.ctx);
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    const m = item.font.measureString(item.text);
    return .{
        .width = MenuItem.ICON_SLOT_WIDTH + m.width + MenuItem.ACCEL_SLOT_WIDTH + MenuItem.PADDING_X * 2,
        .height = m.height + MenuItem.PADDING_Y * 2,
    };
}

pub fn getText(self: CheckBoxMenuItem) []const u8 {
    return self.text;
}

pub fn setText(self: *CheckBoxMenuItem, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
}

pub fn isChecked(self: CheckBoxMenuItem) bool {
    return self.model.isSelected();
}

pub fn setChecked(self: *CheckBoxMenuItem, v: bool) void {
    self.model.setSelected(v);
}

pub fn getModel(self: CheckBoxMenuItem) *ToggleButtonModel {
    return self.model;
}

/// Programmatic activation: toggle + fire (the owning Menu's auto-dismiss
/// listener closes the popup). Entry point for menu-local mnemonics.
/// No-op while disabled.
pub fn doClick(self: *CheckBoxMenuItem) void {
    if (!self.model.button.enabled) return;
    self.model.setSelected(!self.model.isSelected());
    self.model.fireAction();
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn a11yName(c: *const Component) ?[]const u8 {
    const item: *const CheckBoxMenuItem = @fieldParentPtr("component", c);
    if (item.text.len == 0) return null;
    return item.text;
}

fn install(self: *Component) !void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    try item.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    item.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;
    const btn = &item.model.button;

    // Background by state.
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

    // Checkmark in icon slot.
    if (item.model.isSelected()) {
        const check_color = if (armed_pressed)
            t.text_on_accent
        else if (!btn.enabled)
            t.text_disabled
        else
            t.accent;
        drawCheckmark(g, MenuItem.PADDING_X, sz.height, check_color);
    }

    // Label.
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

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

/// Checkmark: two diagonal strokes approximated by small filled squares
/// along each diagonal. Origin x is left of the icon slot; vertically
/// centered in the row height.
fn drawCheckmark(g: *awt.Graphics, x0: f32, row_h: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    const size: f32 = 12;
    const cx = x0 + (MenuItem.ICON_SLOT_WIDTH - size) / 2;
    const cy = (row_h - size) / 2;
    const dot: f32 = 2;
    // Short stroke (down-right): 5 dots from lower-left to mid-bottom.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        g.fillRect(.{ .x = cx + 1 + f, .y = cy + 5 + f, .width = dot, .height = dot });
    }
    // Long stroke (up-right): 7 dots from mid-bottom to upper-right.
    i = 0;
    while (i < 7) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        g.fillRect(.{ .x = cx + 5 + f, .y = cy + 9 - f, .width = dot, .height = dot });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
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
                        if (was_armed and inside) {
                            item.model.setSelected(!item.model.isSelected());
                            item.model.fireAction();
                        }
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
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    self.deinit();
    allocator.free(item.text);
    if (item.owns_model) {
        item.model.deinit();
        allocator.destroy(item.model);
    }
    allocator.destroy(item);
}
