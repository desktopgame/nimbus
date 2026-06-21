const std = @import("std");
const awt = @import("awt");
const Button = @import("../Button.zig");
const CheckBox = @import("../CheckBox.zig");
const ComboBox = @import("../ComboBox.zig");
const Component = @import("../Component.zig");
const RadioButton = @import("../RadioButton.zig");
const ScrollBar = @import("../ScrollBar.zig");
const Slider = @import("../Slider.zig");
const laf = @import("../laf.zig");

const Color = awt.Graphics.Color;

const PADDING_X: f32 = 14;
const PADDING_Y: f32 = 7;
const ICON_TEXT_GAP: f32 = 6;
const FLAT_PADDING: f32 = 4;
const CB_BOX_SIZE: f32 = 16;
const CB_BOX_GAP: f32 = 6;
const CB_PADDING_X: f32 = 4;
const CB_PADDING_Y: f32 = 4;
const RB_CIRCLE_SIZE: f32 = 16;
const RB_CIRCLE_GAP: f32 = 6;
const RB_PADDING_X: f32 = 4;
const RB_PADDING_Y: f32 = 4;
const COMBO_PADDING_X: f32 = 8;
const COMBO_PADDING_Y: f32 = 4;
const COMBO_CHEVRON_W: f32 = 18;
const COMBO_ITEM_PADDING_Y: f32 = 4;
const BORDER_WIDTH: f32 = 1;
const SLIDER_THUMB_RADIUS: f32 = 8;
const SLIDER_TRACK_THICKNESS: f32 = 6;
const SCROLLBAR_MIN_THUMB: f32 = 20;
const SCROLLBAR_THUMB_INSET: f32 = 2;

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
    well_bg: Color,
    well_disabled: Color,
    indicator_border: Color,
    indicator_mark: Color,
    indicator_mark_disabled: Color,
    select_bg: Color,
    select_text: Color,
    track_groove: Color,
    scroll_track: Color,
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
    .well_bg = Color.bytes(255, 255, 255, 255),
    .well_disabled = Color.bytes(224, 225, 228, 255),
    .indicator_border = Color.bytes(122, 138, 153, 255),
    .indicator_mark = Color.bytes(51, 51, 51, 255),
    .indicator_mark_disabled = Color.bytes(153, 153, 153, 255),
    .select_bg = Color.bytes(99, 130, 191, 255),
    .select_text = Color.bytes(255, 255, 255, 255),
    .track_groove = Color.bytes(198, 206, 216, 255),
    .scroll_track = Color.bytes(224, 225, 229, 255),
};

pub const metal_button_look = Component.LookVTable{
    .paint = paint,
    .paintOver = paintOver,
    .measureMinSize = measureMinSize,
};

pub const metal_checkbox_look = Component.LookVTable{
    .paint = paintCheckBox,
    .paintOver = paintOver,
    .measureMinSize = measureCheckBoxMinSize,
};

pub const metal_radio_look = Component.LookVTable{
    .paint = paintRadioButton,
    .paintOver = paintOver,
    .measureMinSize = measureRadioButtonMinSize,
};

pub const metal_combobox_look = Component.LookVTable{
    .paint = paintComboBox,
    .paintOver = paintOver,
    .measureMinSize = measureComboBoxMinSize,
};

pub const metal_combobox_popup_look = Component.LookVTable{
    .paint = paintComboBoxPopup,
    .paintOver = paintOver,
    .measureMinSize = measureComboBoxPopupMinSize,
};

pub const metal_slider_look = Component.LookVTable{
    .paint = paintSlider,
    .paintOver = paintOver,
    .measureMinSize = measureSliderMinSize,
};

pub const metal_scrollbar_look = Component.LookVTable{
    .paint = paintScrollBar,
    .paintOver = paintOver,
    .measureMinSize = measureScrollBarMinSize,
};

const metal_table = [_]laf.RemapEntry{
    .{
        .from = &Button.look_vtable,
        .to = .{ .vtable = &metal_button_look, .ctx = &metal_palette },
    },
    .{
        .from = &CheckBox.look_vtable,
        .to = .{ .vtable = &metal_checkbox_look, .ctx = &metal_palette },
    },
    .{
        .from = &RadioButton.look_vtable,
        .to = .{ .vtable = &metal_radio_look, .ctx = &metal_palette },
    },
    .{
        .from = &ComboBox.look_vtable,
        .to = .{ .vtable = &metal_combobox_look, .ctx = &metal_palette },
    },
    .{
        .from = &ComboBox.popup_look_vtable,
        .to = .{ .vtable = &metal_combobox_popup_look, .ctx = &metal_palette },
    },
    .{
        .from = &Slider.look_vtable,
        .to = .{ .vtable = &metal_slider_look, .ctx = &metal_palette },
    },
    .{
        .from = &ScrollBar.look_vtable,
        .to = .{ .vtable = &metal_scrollbar_look, .ctx = &metal_palette },
    },
};

pub fn metalTable() laf.LookTable {
    return &metal_table;
}

pub fn buttonTable() laf.LookTable {
    return metal_table[0..1];
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

fn paintCheckBox(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const cb: *CheckBox = @fieldParentPtr("component", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;
    const btn = &cb.model.button;
    const selected = cb.model.isSelected();
    const enabled = btn.enabled;

    const box_x = CB_PADDING_X;
    const box_y = (sz.height - CB_BOX_SIZE) / 2;
    g.setColor(if (enabled) palette.well_bg else palette.well_disabled);
    g.fillRect(.{ .x = box_x, .y = box_y, .width = CB_BOX_SIZE, .height = CB_BOX_SIZE });
    drawInsetBevel(g, box_x, box_y, CB_BOX_SIZE, CB_BOX_SIZE, palette);
    drawRectBorder(g, box_x, box_y, CB_BOX_SIZE, CB_BOX_SIZE, if (enabled) palette.indicator_border else palette.border_disabled);

    if (selected) {
        drawCheck(g, box_x, box_y, CB_BOX_SIZE, if (enabled) palette.indicator_mark else palette.indicator_mark_disabled);
    }

    const text_color = if (enabled) cb.color else palette.text_disabled;
    const m = cb.font.measureString(cb.text);
    const text_x = box_x + CB_BOX_SIZE + CB_BOX_GAP;
    const text_y = (sz.height - m.height) / 2;
    g.setFont(cb.font);
    g.setColor(text_color);
    g.drawString(cb.text, text_x, text_y);

    if (cb.focused) {
        g.setColor(palette.focus_ring);
        g.drawRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 });
    }
}

fn measureCheckBoxMinSize(self: *Component, _: *anyopaque) Component.Size {
    const cb: *CheckBox = @fieldParentPtr("component", self);
    const m = cb.font.measureString(cb.text);
    return .{
        .width = CB_BOX_SIZE + CB_BOX_GAP + m.width + CB_PADDING_X * 2,
        .height = @max(CB_BOX_SIZE, m.height) + CB_PADDING_Y * 2,
    };
}

fn paintRadioButton(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;
    const enabled = rb.model.button.enabled;
    const selected = rb.model.isSelected();
    const circle_x = RB_PADDING_X;
    const circle_y = (sz.height - RB_CIRCLE_SIZE) / 2;

    g.setColor(if (enabled) palette.well_bg else palette.well_disabled);
    g.fillCircle(.{ .x = circle_x, .y = circle_y, .width = RB_CIRCLE_SIZE, .height = RB_CIRCLE_SIZE });
    g.setColor(if (enabled) palette.indicator_border else palette.border_disabled);
    g.drawCircle(.{ .x = circle_x, .y = circle_y, .width = RB_CIRCLE_SIZE, .height = RB_CIRCLE_SIZE });

    if (selected) {
        const dot_inset: f32 = 4;
        g.setColor(if (enabled) palette.indicator_mark else palette.indicator_mark_disabled);
        g.fillCircle(.{
            .x = circle_x + dot_inset,
            .y = circle_y + dot_inset,
            .width = RB_CIRCLE_SIZE - dot_inset * 2,
            .height = RB_CIRCLE_SIZE - dot_inset * 2,
        });
    }

    const text_color = if (enabled) rb.color else palette.text_disabled;
    const m = rb.font.measureString(rb.text);
    const text_x = circle_x + RB_CIRCLE_SIZE + RB_CIRCLE_GAP;
    const text_y = (sz.height - m.height) / 2;
    g.setFont(rb.font);
    g.setColor(text_color);
    g.drawString(rb.text, text_x, text_y);

    if (rb.focused) {
        g.setColor(palette.focus_ring);
        g.drawRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 });
    }
}

fn measureRadioButtonMinSize(self: *Component, _: *anyopaque) Component.Size {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    const m = rb.font.measureString(rb.text);
    return .{
        .width = RB_CIRCLE_SIZE + RB_CIRCLE_GAP + m.width + RB_PADDING_X * 2,
        .height = @max(RB_CIRCLE_SIZE, m.height) + RB_PADDING_Y * 2,
    };
}

fn paintComboBox(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;
    const enabled = cb.enabled;

    g.setColor(if (enabled) palette.well_bg else palette.well_disabled);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
    drawRectBorder(g, 0, 0, sz.width, sz.height, palette.indicator_border);

    if (cb.getSelectedItem()) |s| {
        const m = cb.font.measureString(s);
        const text_y = (sz.height - m.height) / 2;
        g.setFont(cb.font);
        g.setColor(if (enabled) cb.color else palette.text_disabled);
        g.drawString(s, COMBO_PADDING_X, text_y);
    }

    const arrow_x = sz.width - COMBO_CHEVRON_W;
    const body = bodyGradient(palette, enabled, false, false);
    g.fillGradientRect(
        .{ .x = arrow_x, .y = 1, .width = COMBO_CHEVRON_W - 1, .height = sz.height - 2 },
        body.top,
        body.bottom,
    );
    if (enabled) {
        drawBevelAt(g, arrow_x, 0, COMBO_CHEVRON_W, sz.height, palette.bevel_light, palette.bevel_dark);
    }
    g.setColor(palette.indicator_border);
    g.fillRect(.{ .x = arrow_x, .y = 0, .width = BORDER_WIDTH, .height = sz.height });
    drawChevron(g, arrow_x, 0, COMBO_CHEVRON_W, sz.height, if (enabled) palette.indicator_mark else palette.indicator_mark_disabled);

    if (cb.has_focus) {
        g.setColor(palette.focus_ring);
        g.drawRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 });
    }
}

fn measureComboBoxMinSize(self: *Component, _: *anyopaque) Component.Size {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    var max_w: f32 = 0;
    for (cb.items.items) |s| {
        const m = cb.font.measureString(s);
        if (m.width > max_w) max_w = m.width;
    }
    const line_h = cb.font.face.metrics().line_height;
    return .{
        .width = max_w + COMBO_PADDING_X * 2 + COMBO_CHEVRON_W,
        .height = line_h + COMBO_PADDING_Y * 2,
    };
}

fn paintComboBoxPopup(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const cb: *ComboBox = @fieldParentPtr("popup_root", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;
    const item_h = cb.font.face.metrics().line_height + COMBO_ITEM_PADDING_Y * 2;

    g.setColor(palette.well_bg);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    g.setFont(cb.font);
    for (cb.items.items, 0..) |s, idx| {
        const y_top: f32 = @as(f32, @floatFromInt(idx)) * item_h;
        const is_hover = cb.hovered_index == idx;
        if (is_hover) {
            g.setColor(palette.select_bg);
            g.fillRect(.{ .x = 0, .y = y_top, .width = sz.width, .height = item_h });
        }
        g.setColor(if (is_hover) palette.select_text else cb.color);
        g.drawString(s, COMBO_PADDING_X, y_top + COMBO_ITEM_PADDING_Y);
    }

    drawRectBorder(g, 0, 0, sz.width, sz.height, palette.indicator_border);
}

fn measureComboBoxPopupMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = 0 };
}

fn paintSlider(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const slider: *Slider = @fieldParentPtr("component", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;
    const enabled = true;

    switch (slider.orientation) {
        .horizontal => {
            const y = sz.height / 2 - SLIDER_TRACK_THICKNESS / 2;
            g.setColor(palette.track_groove);
            g.fillRect(.{
                .x = SLIDER_THUMB_RADIUS,
                .y = y,
                .width = sz.width - 2 * SLIDER_THUMB_RADIUS,
                .height = SLIDER_TRACK_THICKNESS,
            });
            drawInsetBevel(g, SLIDER_THUMB_RADIUS, y, sz.width - 2 * SLIDER_THUMB_RADIUS, SLIDER_TRACK_THICKNESS, palette);
        },
        .vertical => {
            const x = sz.width / 2 - SLIDER_TRACK_THICKNESS / 2;
            g.setColor(palette.track_groove);
            g.fillRect(.{
                .x = x,
                .y = SLIDER_THUMB_RADIUS,
                .width = SLIDER_TRACK_THICKNESS,
                .height = sz.height - 2 * SLIDER_THUMB_RADIUS,
            });
            drawInsetBevel(g, x, SLIDER_THUMB_RADIUS, SLIDER_TRACK_THICKNESS, sz.height - 2 * SLIDER_THUMB_RADIUS, palette);
        },
    }

    const pos = sliderPos(slider);
    const thumb = switch (slider.orientation) {
        .horizontal => awt.Graphics.Rect{
            .x = pos - SLIDER_THUMB_RADIUS,
            .y = sz.height / 2 - SLIDER_THUMB_RADIUS,
            .width = SLIDER_THUMB_RADIUS * 2,
            .height = SLIDER_THUMB_RADIUS * 2,
        },
        .vertical => awt.Graphics.Rect{
            .x = sz.width / 2 - SLIDER_THUMB_RADIUS,
            .y = pos - SLIDER_THUMB_RADIUS,
            .width = SLIDER_THUMB_RADIUS * 2,
            .height = SLIDER_THUMB_RADIUS * 2,
        },
    };
    paintSteelThumb(g, palette, thumb, enabled, false);

    if (slider.focused) {
        g.setColor(palette.focus_ring);
        g.drawRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 });
    }
}

fn measureSliderMinSize(self: *Component, _: *anyopaque) Component.Size {
    const slider: *Slider = @fieldParentPtr("component", self);
    const long_min: f32 = SLIDER_THUMB_RADIUS * 4;
    const cross_size: f32 = SLIDER_THUMB_RADIUS * 2 + 4;
    return switch (slider.orientation) {
        .horizontal => .{ .width = long_min, .height = cross_size },
        .vertical => .{ .width = cross_size, .height = long_min },
    };
}

fn paintScrollBar(self: *Component, ctx: *anyopaque, g: *awt.Graphics) void {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    const palette: *MetalPalette = @ptrCast(@alignCast(ctx));
    const sz = self.size;
    if (sz.width <= 0 or sz.height <= 0) return;

    g.setColor(palette.scroll_track);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
    drawRectBorder(g, 0, 0, sz.width, sz.height, palette.border_disabled);

    const len = scrollBarThumbLen(sb);
    const start = scrollBarThumbStart(sb, len);
    const thumb = switch (sb.orientation) {
        .horizontal => awt.Graphics.Rect{
            .x = start,
            .y = SCROLLBAR_THUMB_INSET,
            .width = len,
            .height = sz.height - SCROLLBAR_THUMB_INSET * 2,
        },
        .vertical => awt.Graphics.Rect{
            .x = SCROLLBAR_THUMB_INSET,
            .y = start,
            .width = sz.width - SCROLLBAR_THUMB_INSET * 2,
            .height = len,
        },
    };
    paintSteelThumb(g, palette, thumb, true, sb.dragging or sb.rollover);
}

fn measureScrollBarMinSize(self: *Component, _: *anyopaque) Component.Size {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    return switch (sb.orientation) {
        .horizontal => .{ .width = SCROLLBAR_MIN_THUMB * 2, .height = ScrollBar.THICKNESS },
        .vertical => .{ .width = ScrollBar.THICKNESS, .height = SCROLLBAR_MIN_THUMB * 2 },
    };
}

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

fn paintSteelThumb(
    g: *awt.Graphics,
    palette: *const MetalPalette,
    rect: awt.Graphics.Rect,
    enabled: bool,
    rollover: bool,
) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    drawRectBorder(g, rect.x, rect.y, rect.width, rect.height, if (enabled) palette.border else palette.border_disabled);
    const body = bodyGradient(palette, enabled, rollover, false);
    g.fillGradientRect(
        .{ .x = rect.x + 2, .y = rect.y + 2, .width = rect.width - 4, .height = rect.height - 4 },
        body.top,
        body.bottom,
    );
    if (enabled) {
        drawBevelAt(g, rect.x, rect.y, rect.width, rect.height, palette.bevel_light, palette.bevel_dark);
    }
}

fn sliderPos(slider: *const Slider) f32 {
    const sz = slider.component.size;
    const range: f32 = @floatFromInt(slider.model.max - slider.model.min);
    if (range <= 0) return SLIDER_THUMB_RADIUS;
    const t: f32 = @as(f32, @floatFromInt(slider.model.value - slider.model.min)) / range;
    return switch (slider.orientation) {
        .horizontal => SLIDER_THUMB_RADIUS + t * (sz.width - 2 * SLIDER_THUMB_RADIUS),
        .vertical => SLIDER_THUMB_RADIUS + t * (sz.height - 2 * SLIDER_THUMB_RADIUS),
    };
}

fn scrollBarTrackLen(sb: *const ScrollBar) f32 {
    return switch (sb.orientation) {
        .horizontal => sb.component.size.width,
        .vertical => sb.component.size.height,
    };
}

fn scrollBarThumbLen(sb: *const ScrollBar) f32 {
    const track = scrollBarTrackLen(sb);
    if (track <= SCROLLBAR_MIN_THUMB) return track;
    const range: f32 = @floatFromInt(sb.model.max - sb.model.min);
    if (range <= 0) return track;
    const ext: f32 = @floatFromInt(sb.model.extent);
    const len = ext / range * track;
    return std.math.clamp(len, SCROLLBAR_MIN_THUMB, track);
}

fn scrollBarThumbStart(sb: *const ScrollBar, len: f32) f32 {
    const travel = scrollBarTrackLen(sb) - len;
    if (travel <= 0) return 0;
    const span: f32 = @floatFromInt((sb.model.max - sb.model.min) - sb.model.extent);
    if (span <= 0) return 0;
    const v: f32 = @floatFromInt(sb.model.value - sb.model.min);
    return std.math.clamp(v / span, 0, 1) * travel;
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
    drawBevelAt(g, 0, 0, sz.width, sz.height, top_left, bottom_right);
}

fn drawBevelAt(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, top_left: Color, bottom_right: Color) void {
    g.setColor(top_left);
    g.fillRect(.{ .x = x + 1, .y = y + 1, .width = w - 2, .height = 1 });
    g.fillRect(.{ .x = x + 1, .y = y + 1, .width = 1, .height = h - 2 });

    g.setColor(bottom_right);
    g.fillRect(.{ .x = x + 1, .y = y + h - 2, .width = w - 2, .height = 1 });
    g.fillRect(.{ .x = x + w - 2, .y = y + 1, .width = 1, .height = h - 2 });
}

fn drawInsetBevel(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, palette: *const MetalPalette) void {
    drawBevelAt(g, x, y, w, h, palette.bevel_dark, palette.bevel_light);
}

fn drawRectBorder(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    g.setColor(color);
    g.fillRect(.{ .x = x, .y = y, .width = w, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = x, .y = y + h - BORDER_WIDTH, .width = w, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = x, .y = y, .width = BORDER_WIDTH, .height = h });
    g.fillRect(.{ .x = x + w - BORDER_WIDTH, .y = y, .width = BORDER_WIDTH, .height = h });
}

fn drawCheck(g: *awt.Graphics, box_x: f32, box_y: f32, box_size: f32, color: Color) void {
    g.setColor(color);
    const inset: f32 = 3;
    const cx = box_x + inset;
    const cy = box_y + inset;
    const span = box_size - inset * 2;
    const dot: f32 = 2;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        g.fillRect(.{ .x = cx + f, .y = cy + span * 0.5 + f, .width = dot, .height = dot });
    }
    i = 0;
    while (i < 6) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        g.fillRect(.{ .x = cx + 3 + f, .y = cy + span - 1 - f, .width = dot, .height = dot });
    }
}

fn drawChevron(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    g.setColor(color);
    const center_x = x + w / 2;
    const triangle_h: f32 = 5;
    const triangle_w: f32 = 8;
    const top_y = y + (h - triangle_h) / 2;
    var row: i32 = 0;
    while (row < @as(i32, @intFromFloat(triangle_h))) : (row += 1) {
        const rf: f32 = @floatFromInt(row);
        const strip_w = triangle_w - rf * 2;
        if (strip_w <= 0) break;
        g.fillRect(.{
            .x = center_x - strip_w / 2,
            .y = top_y + rf,
            .width = strip_w,
            .height = 1,
        });
    }
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
