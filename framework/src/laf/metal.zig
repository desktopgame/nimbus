const awt = @import("awt");
const Button = @import("../Button.zig");
const Component = @import("../Component.zig");
const laf = @import("../laf.zig");

const Color = awt.Graphics.Color;

const PADDING_X: f32 = 14;
const PADDING_Y: f32 = 7;
const ICON_TEXT_GAP: f32 = 6;
const FLAT_PADDING: f32 = 4;

pub const MetalPalette = struct {
    body_enabled_top: Color,
    body_enabled_bottom: Color,
    body_rollover_top: Color,
    body_rollover_bottom: Color,
    body_pressed_top: Color,
    body_pressed_bottom: Color,
    body_disabled_top: Color,
    body_disabled_bottom: Color,
    border: Color,
    bevel_light: Color,
    bevel_dark: Color,
    border_disabled: Color,
    text_disabled: Color,
    focus_ring: Color,
    flat_hover: Color,
    flat_armed: Color,
};

pub var metal_palette = MetalPalette{
    .body_enabled_top = Color.bytes(248, 250, 252, 255),
    .body_enabled_bottom = Color.bytes(199, 212, 227, 255),
    .body_rollover_top = Color.bytes(255, 255, 255, 255),
    .body_rollover_bottom = Color.bytes(214, 226, 240, 255),
    .body_pressed_top = Color.bytes(158, 173, 194, 255),
    .body_pressed_bottom = Color.bytes(196, 209, 224, 255),
    .body_disabled_top = Color.bytes(232, 233, 236, 255),
    .body_disabled_bottom = Color.bytes(214, 215, 219, 255),
    .border = Color.bytes(122, 138, 153, 255),
    .bevel_light = Color.bytes(255, 255, 255, 255),
    .bevel_dark = Color.bytes(132, 148, 168, 255),
    .border_disabled = Color.bytes(180, 186, 194, 255),
    .text_disabled = Color.bytes(153, 153, 153, 255),
    .focus_ring = Color.bytes(99, 130, 191, 255),
    .flat_hover = Color.bytes(214, 226, 240, 255),
    .flat_armed = Color.bytes(190, 205, 224, 255),
};

pub const metal_button_look = Component.LookVTable{
    .paint = paint,
    .paintOver = paintOver,
    .measureMinSize = measureMinSize,
};

const button_table = [_]laf.RemapEntry{
    .{
        .from = &Button.look_vtable,
        .to = .{ .vtable = &metal_button_look, .ctx = &metal_palette },
    },
};

pub fn buttonTable() laf.LookTable {
    return &button_table;
}

fn paint(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const button: *Button = @fieldParentPtr("component", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;

    const has_text = button.text.len > 0;
    const has_icon = button.icon != null;
    const flat = has_icon and !has_text;
    const enabled = button.model.enabled;
    const armed_pressed = button.model.armed and button.model.pressed;

    if (flat) {
        if (enabled) {
            if (armed_pressed) {
                g.setColor(palette.flat_armed);
                g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
            } else if (button.model.rollover) {
                g.setColor(palette.flat_hover);
                g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
            }
        }
    } else {
        const border = if (enabled) palette.border else palette.border_disabled;
        g.setColor(border);
        g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

        const body = bodyGradient(palette, enabled, button.model.rollover, armed_pressed);
        g.fillGradientRect(
            .{ .x = 2, .y = 2, .width = sz.width - 4, .height = sz.height - 4 },
            body.top,
            body.bottom,
        );

        if (enabled) {
            const top_left = if (armed_pressed) palette.bevel_dark else palette.bevel_light;
            const bottom_right = if (armed_pressed) palette.bevel_light else palette.bevel_dark;
            drawBevel(g, sz, top_left, bottom_right);
        }

        if (button.focused) {
            g.setColor(palette.focus_ring);
            g.drawRect(.{ .x = 3, .y = 3, .width = sz.width - 6, .height = sz.height - 6 });
        }
    }

    paintContent(button, self, palette, enabled, g);
}

fn paintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn measureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const button: *Button = @fieldParentPtr("component", self);
    const has_text = button.text.len > 0;
    const has_icon = button.icon != null;
    const icon_sz = iconDrawSize(button);
    const text_m = if (has_text) button.font.measureString(button.text) else awt.Font.TextSize{ .width = 0, .height = 0 };

    if (has_icon and has_text) {
        return .{
            .width = icon_sz.width + ICON_TEXT_GAP + text_m.width + PADDING_X * 2,
            .height = @max(icon_sz.height, text_m.height) + PADDING_Y * 2,
        };
    }
    if (has_icon) {
        return .{
            .width = icon_sz.width + FLAT_PADDING * 2,
            .height = icon_sz.height + FLAT_PADDING * 2,
        };
    }
    return .{
        .width = text_m.width + PADDING_X * 2,
        .height = text_m.height + PADDING_Y * 2,
    };
}

fn bodyGradient(
    palette: *const MetalPalette,
    enabled: bool,
    rollover: bool,
    armed_pressed: bool,
) struct { top: Color, bottom: Color } {
    if (!enabled) {
        return .{ .top = palette.body_disabled_top, .bottom = palette.body_disabled_bottom };
    }
    if (armed_pressed) {
        return .{ .top = palette.body_pressed_top, .bottom = palette.body_pressed_bottom };
    }
    if (rollover) {
        return .{ .top = palette.body_rollover_top, .bottom = palette.body_rollover_bottom };
    }
    return .{ .top = palette.body_enabled_top, .bottom = palette.body_enabled_bottom };
}

fn drawBevel(g: *awt.Graphics, sz: Component.Size, top_left: Color, bottom_right: Color) void {
    g.setColor(top_left);
    g.fillRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = 1 });
    g.fillRect(.{ .x = 1, .y = 1, .width = 1, .height = sz.height - 2 });

    g.setColor(bottom_right);
    g.fillRect(.{ .x = 1, .y = sz.height - 2, .width = sz.width - 2, .height = 1 });
    g.fillRect(.{ .x = sz.width - 2, .y = 1, .width = 1, .height = sz.height - 2 });
}

fn paintContent(
    button: *Button,
    component: *Component,
    palette: *const MetalPalette,
    enabled: bool,
    g: *awt.Graphics,
) void {
    const has_text = button.text.len > 0;
    const has_icon = button.icon != null;
    const icon_sz = iconDrawSize(button);
    const text_m = if (has_text) button.font.measureString(button.text) else awt.Font.TextSize{ .width = 0, .height = 0 };

    var content_w: f32 = 0;
    if (has_icon) content_w += icon_sz.width;
    if (has_icon and has_text) content_w += ICON_TEXT_GAP;
    if (has_text) content_w += text_m.width;

    var x = (component.size.width - content_w) / 2;
    if (has_icon) {
        const iy = (component.size.height - icon_sz.height) / 2;
        if (button.icon) |img| {
            g.drawImageScaled(img, x, iy, icon_sz.width, icon_sz.height);
        }
        x += icon_sz.width;
        if (has_text) x += ICON_TEXT_GAP;
    }
    if (has_text) {
        const ty = (component.size.height - text_m.height) / 2;
        const text_color = if (enabled) button.color else palette.text_disabled;
        g.setFont(button.font);
        g.setColor(text_color);
        g.drawString(button.text, x, ty);
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

fn iconDrawSize(button: *const Button) Component.Size {
    if (button.icon_size) |s| return s;
    if (button.icon) |img| return .{
        .width = @floatFromInt(img.width),
        .height = @floatFromInt(img.height),
    };
    return .{ .width = 0, .height = 0 };
}
