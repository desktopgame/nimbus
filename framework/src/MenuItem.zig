//! Menu item (leaf, clickable). See `framework/doc/menu_item.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const ButtonModel = @import("ButtonModel.zig");
const keybinding = @import("keybinding.zig");
const menu_paint = @import("menu_paint.zig");

const MenuItem = @This();

pub const ICON_SLOT_WIDTH: f32 = 24;
pub const PADDING_X: f32 = 8;
pub const PADDING_Y: f32 = 6;
const ACCEL_GAP: f32 = 32;
const ACCEL_BUF_LEN: usize = 32;

component: Component,
text: []const u8,
icon: ?awt.Image,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
model: *ButtonModel,
owns_model: bool,
/// Window-wide accelerator (e.g. Cmd/Ctrl+S). Stored only  Ethe Window's
/// accelerator scan stage walks the menu tree and matches at dispatch time;
/// nothing is registered anywhere. Fires even while the menu is closed.
accelerator: ?keybinding.KeyStroke,
/// Byte index into `text` of the mnemonic character (underline paint).
/// Matching uses `component.mnemonic`  Emenu-local only (plain letter while
/// the parent menu is open), never the window-wide Alt+letter scan.
mnemonic_index: ?usize,
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
        .accelerator = null,
        .mnemonic_index = null,
        .allocator = allocator,
    };
    item.component.role = .menu_item;
    item.component.a11y = .{ .name = a11yName };
    item.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    item.applyMetrics();
    try MenuItem.vtable.install(&item.component);
    return item;
}

fn applyMetrics(self: *MenuItem) void {
    const ui = self.component.ui;
    const min = ui.vtable.measureMinSize(&self.component, ui.ctx);
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const item: *MenuItem = @fieldParentPtr("component", self);
    const m = item.font.measureString(item.text);
    return .{
        .width = measureRowWidth(m.width, acceleratorTermWidth(item.font, item.accelerator)),
        .height = m.height + PADDING_Y * 2,
    };
}

fn acceleratorTermWidth(font: awt.Graphics.TextFont, stroke: ?keybinding.KeyStroke) f32 {
    var buf: [ACCEL_BUF_LEN]u8 = undefined;
    const label = keybinding.formatAccelerator(stroke, &buf);
    if (label.len == 0) return 0;
    return acceleratorTermWidthFromLabelWidth(font.measureString(label).width);
}

fn acceleratorTermWidthFromLabelWidth(label_width: f32) f32 {
    return if (label_width == 0) 0 else ACCEL_GAP + label_width;
}

fn measureRowWidth(label_width: f32, accelerator_term_width: f32) f32 {
    return ICON_SLOT_WIDTH + label_width + accelerator_term_width + PADDING_X * 2;
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

/// Programmatic activation: fire the action (the owning Menu's auto-dismiss
/// listener closes the popup if one is open). The single entry point shared
/// by accelerators and menu-local mnemonics. No-op while disabled.
pub fn doClick(self: *MenuItem) void {
    if (!self.model.enabled) return;
    self.model.fireAction();
}

/// Window-wide accelerator (`KeyStroke.cmd(.s)` etc.). Pass null to clear.
/// Stores only; matched by the Window's accelerator scan at dispatch time,
/// so call order vs. menu attachment does not matter.
pub fn setAccelerator(self: *MenuItem, stroke: ?keybinding.KeyStroke) void {
    self.accelerator = stroke;
    self.applyMetrics();
    self.component.repaint();
}

/// Menu-local mnemonic: while the parent menu is open, the plain letter
/// `ch` activates this item (no Alt). The matching label letter is underlined.
pub fn setMnemonic(self: *MenuItem, ch: u8) void {
    self.component.mnemonic = std.ascii.toLower(ch);
    self.mnemonic_index = std.ascii.indexOfIgnoreCase(self.text, &[1]u8{ch});
    self.component.repaint();
}

/// Menu-local mnemonic with an explicit underline byte index into `text`.
pub fn setMnemonicAt(self: *MenuItem, ch: u8, index: usize) void {
    self.component.mnemonic = std.ascii.toLower(ch);
    self.mnemonic_index = index;
    self.component.repaint();
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn a11yName(c: *const Component) ?[]const u8 {
    const item: *const MenuItem = @fieldParentPtr("component", c);
    if (item.text.len == 0) return null;
    return item.text;
}

fn install(self: *Component) !void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    try item.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    item.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const item: *MenuItem = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;

    // Background by state.
    if (item.model.enabled) {
        if (item.model.armed and item.model.pressed) {
            g.setColor(t.accent);
            g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
        } else if (item.model.rollover) {
            g.setColor(t.accent_soft);
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
        if (!item.model.enabled) break :blk t.text_disabled;
        if (item.model.armed and item.model.pressed) break :blk t.text_on_accent;
        break :blk item.color;
    };
    g.setFont(item.font);
    g.setColor(text_color);
    const tx = PADDING_X + ICON_SLOT_WIDTH;
    const ty = (sz.height - m.height) / 2;
    g.drawString(item.text, tx, ty);

    menu_paint.drawMnemonicUnderline(g, item.font, item.text, item.mnemonic_index, tx, ty, m.height);

    var accel_buf: [ACCEL_BUF_LEN]u8 = undefined;
    const accel = keybinding.formatAccelerator(item.accelerator, &accel_buf);
    if (accel.len != 0) {
        const accel_w = item.font.measureString(accel).width;
        g.drawString(accel, sz.width - PADDING_X - accel_w, ty);
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

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
        .key, .char, .focus, .composition => {},
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

test "menu item accelerator width contributes to measured row width" {
    const label_width: f32 = 48;
    const no_accel = measureRowWidth(label_width, acceleratorTermWidthFromLabelWidth(0));
    const with_accel = measureRowWidth(label_width, acceleratorTermWidthFromLabelWidth(72));

    try std.testing.expectEqual(ICON_SLOT_WIDTH + label_width + PADDING_X * 2, no_accel);
    try std.testing.expectEqual(no_accel + ACCEL_GAP + 72, with_accel);
    try std.testing.expect(with_accel > no_accel);
}
