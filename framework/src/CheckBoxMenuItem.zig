//! Menu item with a toggleable checked state. See `framework/doc/checkbox_menu_item.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ButtonModel = @import("ButtonModel.zig");
const MenuItem = @import("MenuItem.zig");

const CheckBoxMenuItem = @This();

component:  Component,
text:       []const u8,
font:       awt.Graphics.TextFont,
color:      awt.Graphics.Color,
model:      *ButtonModel,
owns_model: bool,
allocator:  std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBoxMenuItem {
    const model = try allocator.create(ButtonModel);
    errdefer allocator.destroy(model);
    model.* = ButtonModel.init(allocator);
    errdefer model.deinit();
    return createInternal(allocator, model, true, text, font, color);
}

pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBoxMenuItem {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
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
    item.applyMetrics();
    CheckBoxMenuItem.vtable.install(&item.component);
    return item;
}

fn applyMetrics(self: *CheckBoxMenuItem) void {
    const m = self.font.measureString(self.text);
    const min = Component.Size{
        .width = MenuItem.ICON_SLOT_WIDTH + m.width + MenuItem.ACCEL_SLOT_WIDTH + MenuItem.PADDING_X * 2,
        .height = m.height + MenuItem.PADDING_Y * 2,
    };
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
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

pub fn getModel(self: CheckBoxMenuItem) *ButtonModel {
    return self.model;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    item.model.addChangeListener(onModelChange, self) catch {};
}

fn uninstall(self: *Component) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    item.model.removeChangeListener(onModelChange, self);
}

fn onModelChange(user_data: *anyopaque) void {
    const comp: *Component = @ptrCast(@alignCast(user_data));
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    const sz = self.size;

    // Background by state.
    const armed_pressed = item.model.armed and item.model.pressed;
    if (item.model.enabled) {
        if (armed_pressed) {
            g.setColor(awt.Graphics.Color.rgb(0.30, 0.55, 0.95));
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        } else if (item.model.rollover) {
            g.setColor(awt.Graphics.Color.rgb(0.90, 0.93, 0.99));
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        }
    }

    // Checkmark in icon slot.
    if (item.model.isSelected()) {
        const check_color = if (armed_pressed)
            awt.Graphics.Color.rgb(1, 1, 1)
        else if (!item.model.enabled)
            awt.Graphics.Color.rgb(0.55, 0.55, 0.55)
        else
            awt.Graphics.Color.rgb(0.20, 0.50, 0.90);
        drawCheckmark(g, MenuItem.PADDING_X, sz.height, check_color);
    }

    // Label.
    const m = item.font.measureString(item.text);
    const text_color = blk: {
        if (!item.model.enabled) break :blk awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
        if (armed_pressed) break :blk awt.Graphics.Color.rgb(1, 1, 1);
        break :blk item.color;
    };
    g.setFont(item.font);
    g.setColor(text_color);
    const tx = MenuItem.PADDING_X + MenuItem.ICON_SLOT_WIDTH;
    const ty = (sz.height - m.height) / 2;
    g.drawString(item.text, tx, ty);
}

/// Simple checkmark: two diagonal strokes drawn as small filled rects.
/// Origin x is left of the icon slot; vertically centered in the row height.
fn drawCheckmark(g: *awt.Graphics, x0: f32, row_h: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    const size: f32 = 10;
    const cx = x0 + (MenuItem.ICON_SLOT_WIDTH - size) / 2;
    const cy = (row_h - size) / 2;
    // Short stroke (lower-left to middle-bottom)
    const t: f32 = 2;
    g.fillRect(.{ .x = cx,         .y = cy + size * 0.55, .width = size * 0.35, .height = t });
    // Long stroke (middle-bottom to upper-right)
    g.fillRect(.{ .x = cx + size * 0.30, .y = cy + size * 0.40, .width = size * 0.65, .height = t });
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const item: *CheckBoxMenuItem = @fieldParentPtr("component", self);
    if (!item.model.enabled) return;

    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const inside = lx >= 0 and lx < self.size.width and ly >= 0 and ly < self.size.height;

            switch (m.action) {
                .press => {
                    if (m.button == .left and inside) {
                        item.model.setPressed(true);
                        item.model.setArmed(true);
                        ev.requestCapture(@ptrCast(self));
                        ev.consume();
                    }
                },
                .release => {
                    if (m.button == .left and item.model.isPressed()) {
                        const was_armed = item.model.isArmed();
                        item.model.setPressed(false);
                        item.model.setArmed(false);
                        if (was_armed and inside) {
                            item.model.setSelected(!item.model.isSelected());
                            item.model.fireAction();
                        }
                        ev.consume();
                    }
                },
                .move => {
                    if (item.model.isPressed()) item.model.setArmed(inside);
                    item.model.setRollover(inside);
                },
                .scroll => {},
            }
        },
        .key => {},
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
