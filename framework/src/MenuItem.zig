//! Menu item (leaf, clickable). See `framework/doc/menu_item.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ButtonModel = @import("ButtonModel.zig");

const MenuItem = @This();

pub const ICON_SLOT_WIDTH: f32 = 24;
pub const ACCEL_SLOT_WIDTH: f32 = 0;        // v1: not rendered
pub const PADDING_X: f32 = 8;
pub const PADDING_Y: f32 = 6;

component:  Component,
text:       []const u8,
icon:       ?awt.Image,
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
) !*MenuItem {
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
) !*MenuItem {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
    owns_model: bool,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*MenuItem {
    const item = try allocator.create(MenuItem);
    errdefer allocator.destroy(item);

    const text_dup = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dup);

    item.* = .{
        .component = Component.init(allocator, &vtable),
        .text = text_dup,
        .icon = null,
        .font = font,
        .color = color,
        .model = model,
        .owns_model = owns_model,
        .allocator = allocator,
    };
    item.applyMetrics();
    MenuItem.vtable.install(&item.component);
    return item;
}

fn applyMetrics(self: *MenuItem) void {
    const m = self.font.measureString(self.text);
    const min = Component.Size{
        .width = ICON_SLOT_WIDTH + m.width + ACCEL_SLOT_WIDTH + PADDING_X * 2,
        .height = m.height + PADDING_Y * 2,
    };
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

pub fn getText(self: MenuItem) []const u8 {
    return self.text;
}

pub fn setText(self: *MenuItem, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
}

pub fn getIcon(self: MenuItem) ?awt.Image {
    return self.icon;
}

pub fn setIcon(self: *MenuItem, icon: ?awt.Image) void {
    self.icon = icon;
    self.component.repaint();
}

pub fn getModel(self: MenuItem) *ButtonModel {
    return self.model;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    item.model.addChangeListener(onModelChange, self) catch {};
}

fn uninstall(self: *Component) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    item.model.removeChangeListener(onModelChange, self);
}

fn onModelChange(user_data: *anyopaque) void {
    const comp: *Component = @ptrCast(@alignCast(user_data));
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    const sz = self.size;

    // Background by state.
    if (item.model.enabled) {
        if (item.model.armed and item.model.pressed) {
            g.setColor(awt.Graphics.Color.rgb(0.30, 0.55, 0.95));
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        } else if (item.model.rollover) {
            g.setColor(awt.Graphics.Color.rgb(0.90, 0.93, 0.99));
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        }
    }

    // Icon slot (left): always scaled to 16x16, centered in the slot.
    if (item.icon) |img| {
        const draw_size: f32 = 16;
        const ix = PADDING_X + (ICON_SLOT_WIDTH - draw_size) / 2;
        const iy = (sz.height - draw_size) / 2;
        g.drawImageScaled(img, ix, iy, draw_size, draw_size);
    }

    // Label.
    const m = item.font.measureString(item.text);
    const text_color = blk: {
        if (!item.model.enabled) break :blk awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
        if (item.model.armed and item.model.pressed) break :blk awt.Graphics.Color.rgb(1, 1, 1);
        break :blk item.color;
    };
    g.setFont(item.font);
    g.setColor(text_color);
    const tx = PADDING_X + ICON_SLOT_WIDTH;
    const ty = (sz.height - m.height) / 2;
    g.drawString(item.text, tx, ty);
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
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
                            item.model.fireAction();
                        }
                        ev.consume();
                    }
                },
                .move => {
                    if (item.model.isPressed()) {
                        item.model.setArmed(inside);
                    }
                    item.model.setRollover(inside);
                },
                .scroll => {},
            }
        },
        .key => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    self.deinit();
    allocator.free(item.text);
    if (item.owns_model) {
        item.model.deinit();
        allocator.destroy(item.model);
    }
    allocator.destroy(item);
}
