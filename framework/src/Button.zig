//! Button widget. See `framework/doc/button.md`.
//!
//! Visual modes (auto-detected from text / icon):
//!   - text only        → rounded rect with border, bg by state (standard)
//!   - icon only        → "flat" mode: no border; gray bg only on hover
//!   - text + icon      → standard rounded rect with icon left of text

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ButtonModel = @import("ButtonModel.zig");

const Button = @This();

const PADDING_X: f32 = 12;
const PADDING_Y: f32 = 8;
const CORNER_RADIUS: f32 = 6;
const ICON_TEXT_GAP: f32 = 6;
const FLAT_PADDING: f32 = 4;

component:  Component,
model:      *ButtonModel,
owns_model: bool,
text:       []const u8,
font:       awt.Graphics.TextFont,
color:      awt.Graphics.Color,
icon:       ?awt.Image,
icon_size:  ?Component.Size,           // null = natural size; non-null = scaled
allocator:  std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
    .mouseExited  = mouseExited,
};

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
        .font = font,
        .color = color,
        .icon = null,
        .icon_size = null,
        .allocator = allocator,
    };
    b.applyMetrics();
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

fn applyMetrics(self: *Button) void {
    const has_text = self.text.len > 0;
    const has_icon = self.icon != null;
    const icon_sz = self.iconDrawSize();
    const text_m = if (has_text) self.font.measureString(self.text)
                   else awt.Font.TextSize{ .width = 0, .height = 0 };

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
    self.component.min_size = .{ .width = w, .height = h };
}

pub fn getText(self: Button) []const u8 {
    return self.text;
}

pub fn setText(self: *Button, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
    self.component.markLayoutDirty();
}

pub fn getFont(self: Button) awt.Graphics.TextFont { return self.font; }
pub fn setFont(self: *Button, font: awt.Graphics.TextFont) void {
    self.font = font;
    self.applyMetrics();
    self.component.markLayoutDirty();
}

pub fn getColor(self: Button) awt.Graphics.Color { return self.color; }
pub fn setColor(self: *Button, color: awt.Graphics.Color) void {
    self.color = color;
    self.component.repaint();
}

pub fn getIcon(self: Button) ?awt.Image { return self.icon; }
pub fn setIcon(self: *Button, icon: ?awt.Image) void {
    self.icon = icon;
    self.applyMetrics();
    self.component.markLayoutDirty();
}

pub fn getIconSize(self: Button) ?Component.Size { return self.icon_size; }
pub fn setIconSize(self: *Button, size: ?Component.Size) void {
    self.icon_size = size;
    self.applyMetrics();
    self.component.markLayoutDirty();
}

pub fn getModel(self: Button) *ButtonModel { return self.model; }

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const button: *Button = @fieldParentPtr("component", self);
    try button.model.addChangeListener(onModelChange, self);
}

fn uninstall(self: *Component) void {
    const button: *Button = @fieldParentPtr("component", self);
    button.model.removeChangeListener(onModelChange, self);
}

fn onModelChange(user_data: *anyopaque) void {
    const comp: *Component = @ptrCast(@alignCast(user_data));
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const button: *Button = @fieldParentPtr("component", self);
    const sz = self.size;

    const has_text = button.text.len > 0;
    const has_icon = button.icon != null;
    const flat = has_icon and !has_text;
    const armed_pressed = button.model.armed and button.model.pressed;

    if (flat) {
        // Flat: bg only on hover / armed. No border.
        if (button.model.enabled) {
            if (armed_pressed) {
                g.setColor(awt.Graphics.Color.rgb(0.78, 0.82, 0.92));
                g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
            } else if (button.model.rollover) {
                g.setColor(awt.Graphics.Color.rgb(0.88, 0.88, 0.92));
                g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
            }
        }
    } else {
        // Standard rounded-rect background.
        var bg = awt.Graphics.Color.rgb(0.85, 0.85, 0.90);
        if (!button.model.enabled) {
            bg = awt.Graphics.Color.rgb(0.75, 0.75, 0.78);
        } else if (armed_pressed) {
            bg = awt.Graphics.Color.rgb(0.55, 0.65, 0.85);
        } else if (button.model.rollover) {
            bg = awt.Graphics.Color.rgb(0.92, 0.92, 0.97);
        }
        g.setColor(bg);
        g.fillRoundRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height }, CORNER_RADIUS);
    }

    // Content layout.
    const icon_sz = button.iconDrawSize();
    const text_m = if (has_text) button.font.measureString(button.text)
                   else awt.Font.TextSize{ .width = 0, .height = 0 };

    var content_w: f32 = 0;
    if (has_icon) content_w += icon_sz.width;
    if (has_icon and has_text) content_w += ICON_TEXT_GAP;
    if (has_text) content_w += text_m.width;

    var x = (sz.width - content_w) / 2;
    if (has_icon) {
        const iy = (sz.height - icon_sz.height) / 2;
        if (button.icon) |img| {
            g.drawImageScaled(img, x, iy, icon_sz.width, icon_sz.height);
        }
        x += icon_sz.width;
        if (has_text) x += ICON_TEXT_GAP;
    }
    if (has_text) {
        const ty = (sz.height - text_m.height) / 2;
        const text_color = if (button.model.enabled) button.color
                          else awt.Graphics.Color.rgb(0.5, 0.5, 0.5);
        g.setFont(button.font);
        g.setColor(text_color);
        g.drawString(button.text, x, ty);
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const button: *Button = @fieldParentPtr("component", self);
    if (!button.model.enabled) return;

    switch (ev.payload) {
        .mouse => |m| {
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
        .key, .char, .focus, .composition => {},
    }
}

fn mouseExited(self: *Component) void {
    const button: *Button = @fieldParentPtr("component", self);
    // Pointer left the button: drop the hover affordance. (Armed is only set
    // while pressed/captured, a path that bypasses this hook, so leave it.)
    button.model.setRollover(false);
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const button: *Button = @fieldParentPtr("component", self);
    self.deinit(); // uninstall + property cleanup
    allocator.free(button.text);
    if (button.owns_model) {
        button.model.deinit();
        allocator.destroy(button.model);
    }
    allocator.destroy(button);
}
