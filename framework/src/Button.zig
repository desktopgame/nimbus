//! Button widget. See `framework/doc/button.md`.
//!
//! Visual modes (auto-detected from text / icon):
//!   - text only        ↁErounded rect with border, bg by state (standard)
//!   - icon only        ↁE"flat" mode: no border; gray bg only on hover
//!   - text + icon      ↁEstandard rounded rect with icon left of text

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const ButtonModel = @import("ButtonModel.zig");

const Button = @This();

const PADDING_X: f32 = 12;
const PADDING_Y: f32 = 4;
const CORNER_RADIUS: f32 = 6;
const ICON_TEXT_GAP: f32 = 6;
const FLAT_PADDING: f32 = 4;
const disabled_icon_alpha: f32 = 0.38;

component: Component,
model: *ButtonModel,
owns_model: bool,
text: []const u8,
a11y_name: ?[]const u8,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
icon: ?awt.Image,
icon_size: ?Component.Size, // null = natural size; non-null = scaled
/// True while this button is the window's focus owner (tracked via
/// FocusEvent); drives the focus-ring paint.
focused: bool,
/// Byte index into `text` of the mnemonic character (underline paint),
/// or null. Matching itself uses `component.mnemonic`.
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

pub fn iconTint(enabled: bool) awt.Graphics.Color {
    return awt.Graphics.Color.rgba(1, 1, 1, if (enabled) 1 else disabled_icon_alpha);
}

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Button {
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
) !*Button {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
    owns_model: bool,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Button {
    const b = try allocator.create(Button);
    errdefer allocator.destroy(b);

    const text_dup = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dup);

    b.* = .{
        .component = Component.init(allocator, &vtable),
        .model = model,
        .owns_model = owns_model,
        .text = text_dup,
        .a11y_name = null,
        .font = font,
        .color = color,
        .icon = null,
        .icon_size = null,
        .focused = false,
        .mnemonic_index = null,
        .allocator = allocator,
    };
    b.component.role = .button;
    b.component.a11y = .{ .name = a11yName };
    b.component.setFocusable(true);
    b.component.focus_query = .{ .isEligible = focusEligible };
    b.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    b.updateMinSizeFromLook();
    try Button.vtable.install(&b.component);
    return b;
}

fn iconDrawSize(self: *const Button) Component.Size {
    if (self.icon_size) |s| return s;
    if (self.icon) |img| return .{
        .width = @floatFromInt(img.width),
        .height = @floatFromInt(img.height),
    };
    return .{ .width = 0, .height = 0 };
}

fn updateMinSizeFromLook(self: *Button) void {
    const ui = self.component.ui;
    self.component.min_size = ui.vtable.measureMinSize(&self.component, ui.ctx);
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const button: *Button = @fieldParentPtr("component", self);
    const has_text = button.text.len > 0;
    const has_icon = button.icon != null;
    const icon_sz = button.iconDrawSize();
    const text_m = if (has_text) button.font.measureString(button.text) else awt.Font.TextSize{ .width = 0, .height = 0 };

    var w: f32 = 0;
    var h: f32 = 0;
    if (has_icon and has_text) {
        w = icon_sz.width + ICON_TEXT_GAP + text_m.width + PADDING_X * 2;
        h = @max(icon_sz.height, text_m.height) + PADDING_Y * 2;
    } else if (has_icon) {
        // flat mode: tighter padding
        w = icon_sz.width + FLAT_PADDING * 2;
        h = icon_sz.height + FLAT_PADDING * 2;
    } else {
        // text only
        w = text_m.width + PADDING_X * 2;
        h = text_m.height + PADDING_Y * 2;
    }
    return .{ .width = w, .height = h };
}

pub fn getText(self: Button) []const u8 {
    return self.text;
}

pub fn setText(self: *Button, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    // Re-locate the mnemonic underline in the new label.
    if (self.component.mnemonic) |m| {
        self.mnemonic_index = std.ascii.indexOfIgnoreCase(new_text, &[1]u8{m});
    }
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

pub fn setA11yName(self: *Button, name: ?[]const u8) !void {
    if (self.a11y_name) |old| self.allocator.free(old);
    self.a11y_name = null;
    if (name) |n| {
        self.a11y_name = try self.allocator.dupe(u8, n);
    }
}

pub fn getFont(self: Button) awt.Graphics.TextFont {
    return self.font;
}
pub fn setFont(self: *Button, font: awt.Graphics.TextFont) void {
    self.font = font;
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

pub fn getColor(self: Button) awt.Graphics.Color {
    return self.color;
}
pub fn setColor(self: *Button, color: awt.Graphics.Color) void {
    self.color = color;
    self.component.repaint();
}

pub fn getIcon(self: Button) ?awt.Image {
    return self.icon;
}
pub fn setIcon(self: *Button, icon: ?awt.Image) void {
    self.icon = icon;
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

pub fn getIconSize(self: Button) ?Component.Size {
    return self.icon_size;
}
pub fn setIconSize(self: *Button, size: ?Component.Size) void {
    self.icon_size = size;
    self.updateMinSizeFromLook();
    self.component.markLayoutDirty();
}

pub fn getModel(self: Button) *ButtonModel {
    return self.model;
}

/// Programmatic activation: the single entry point shared by Space/Enter,
/// mnemonics and the default-button binding (mouse keeps its own
/// press/armed gesture). No-op while disabled  Ethis is the one guard that
/// covers every activation path.
pub fn doClick(self: *Button) void {
    if (!self.model.enabled) return;
    self.model.setArmed(true);
    self.model.setPressed(true);
    self.model.setPressed(false);
    self.model.setArmed(false);
    self.model.fireAction();
}

/// Assign the mnemonic character (`Alt+ch` activates this button window-wide;
/// the matching letter in the label is underlined). ASCII letter / digit.
/// Stores only  Eresolution happens in the Window's mnemonic scan stage.
pub fn setMnemonic(self: *Button, ch: u8) void {
    self.component.mnemonic = std.ascii.toLower(ch);
    self.mnemonic_index = std.ascii.indexOfIgnoreCase(self.text, &[1]u8{ch});
    self.component.repaint();
}

fn focusEligible(c: *const Component) bool {
    const b: *const Button = @fieldParentPtr("component", c);
    return b.model.enabled;
}

fn a11yName(c: *const Component) ?[]const u8 {
    const b: *const Button = @fieldParentPtr("component", c);
    if (b.a11y_name) |name| return name;
    if (b.text.len == 0) return null;
    return b.text;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const button: *Button = @fieldParentPtr("component", self);
    try button.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const button: *Button = @fieldParentPtr("component", self);
    // Focus goes to null when its owner is torn down (keybinding.md).
    if (button.focused) self.releaseFocus();
    button.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const button: *Button = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;

    const has_text = button.text.len > 0;
    const has_icon = button.icon != null;
    const flat = has_icon and !has_text;
    const armed_pressed = button.model.armed and button.model.pressed;

    if (flat) {
        // Flat: bg only on hover / armed. No border.
        if (button.model.enabled) {
            if (armed_pressed) {
                g.setColor(t.button_flat_armed);
                g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
            } else if (button.model.rollover) {
                g.setColor(t.button_flat_hover);
                g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
            }
        }
    } else {
        // Standard rounded-rect background.
        var bg = t.button_bg;
        if (!button.model.enabled) {
            bg = t.button_bg_disabled;
        } else if (armed_pressed) {
            bg = t.button_bg_armed;
        } else if (button.model.rollover) {
            bg = t.button_bg_hover;
        }
        g.setColor(bg);
        g.fillRoundRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height }, CORNER_RADIUS);
    }

    // Focus ring (keyboard focus indicator).
    if (button.focused) {
        g.setColor(t.focus_ring);
        const ring = Component.Rect{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 };
        if (flat) g.drawRect(ring) else g.drawRoundRect(ring, CORNER_RADIUS);
    }

    // Content layout.
    const icon_sz = button.iconDrawSize();
    const text_m = if (has_text) button.font.measureString(button.text) else awt.Font.TextSize{ .width = 0, .height = 0 };

    var content_w: f32 = 0;
    if (has_icon) content_w += icon_sz.width;
    if (has_icon and has_text) content_w += ICON_TEXT_GAP;
    if (has_text) content_w += text_m.width;

    var x = (sz.width - content_w) / 2;
    if (has_icon) {
        const iy = (sz.height - icon_sz.height) / 2;
        if (button.icon) |img| {
            g.drawImageScaledTinted(img, x, iy, icon_sz.width, icon_sz.height, iconTint(button.model.enabled));
        }
        x += icon_sz.width;
        if (has_text) x += ICON_TEXT_GAP;
    }
    if (has_text) {
        const ty = (sz.height - text_m.height) / 2;
        const text_color = if (button.model.enabled) button.color else t.text_disabled;
        g.setFont(button.font);
        g.setColor(text_color);
        g.drawString(button.text, x, ty);
        // Mnemonic underline (always shown in v1; Alt-reveal is deferred).
        if (button.mnemonic_index) |mi| {
            if (mi < button.text.len) {
                const prefix_w = button.font.measureString(button.text[0..mi]).width;
                const ch_w = button.font.measureString(button.text[mi .. mi + 1]).width;
                g.fillRect(.{
                    .x = x + prefix_w,
                    .y = ty + text_m.height - 1,
                    .width = ch_w,
                    .height = 1,
                });
            }
        }
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const button: *Button = @fieldParentPtr("component", self);

    switch (ev.payload) {
        .mouse => |m| {
            if (!button.model.enabled) return;
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const inside = lx >= 0 and lx < self.size.width and ly >= 0 and ly < self.size.height;

            switch (m.action) {
                .press => {
                    if (m.button == .left and inside) {
                        button.model.setPressed(true);
                        button.model.setArmed(true);
                        ev.requestCapture(@ptrCast(self));
                        ev.consume();
                    }
                },
                .release => {
                    if (m.button == .left and button.model.isPressed()) {
                        const was_armed = button.model.isArmed();
                        button.model.setPressed(false);
                        button.model.setArmed(false);
                        if (was_armed and inside) {
                            button.model.fireAction();
                        }
                        ev.consume();
                    }
                },
                .move => {
                    if (button.model.isPressed()) {
                        button.model.setArmed(inside);
                    }
                    button.model.setRollover(inside);
                },
                .scroll => {},
            }
        },
        .key => |k| {
            if (!button.model.enabled) return;
            // Space / Enter activate the focused button (raw `.key` only ever
            // arrives here while this button is the focus owner). Press only  E            // auto-repeat firing a button is not a thing on any platform.
            if (k.action == .press and (k.code == .space or k.code == .enter)) {
                button.doClick();
                ev.consume();
            }
        },
        .focus => |f| {
            button.focused = f.gained;
        },
        .char, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const button: *Button = @fieldParentPtr("component", self);
    self.deinit(); // uninstall + property cleanup
    allocator.free(button.text);
    if (button.a11y_name) |name| allocator.free(name);
    if (button.owns_model) {
        button.model.deinit();
        allocator.destroy(button.model);
    }
    allocator.destroy(button);
}

test "button a11y name override falls back to text when cleared" {
    var button = Button{
        .component = Component.init(std.testing.allocator, &vtable),
        .model = undefined,
        .owns_model = false,
        .text = "Fallback",
        .a11y_name = null,
        .font = undefined,
        .color = undefined,
        .icon = null,
        .icon_size = null,
        .focused = false,
        .mnemonic_index = null,
        .allocator = std.testing.allocator,
    };
    defer if (button.a11y_name) |name| std.testing.allocator.free(name);

    try std.testing.expectEqualStrings("Fallback", a11yName(&button.component).?);
    try button.setA11yName("Override");
    try std.testing.expectEqualStrings("Override", a11yName(&button.component).?);
    try button.setA11yName(null);
    try std.testing.expectEqualStrings("Fallback", a11yName(&button.component).?);
}
