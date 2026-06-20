//! Radio button. Visually a circle with a filled dot when selected;
//! semantically identical to CheckBox but typically used inside a
//! `ButtonGroup` so only one radio in the group is selected at a time.
//! See `framework/doc/radio_button.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const ToggleButtonModel = @import("ToggleButtonModel.zig");

const RadioButton = @This();

const CIRCLE_SIZE: f32 = 16;
const CIRCLE_GAP: f32 = 6;
const PADDING_X: f32 = 4;
const PADDING_Y: f32 = 4;

// Colors come from `component.theme` (see `framework/doc/theme.md`):
// circle bg = surface_input / surface_disabled, frame = indicator_border
// (accent on hover), inner dot = accent (text_disabled when disabled).

component: Component,
model: *ToggleButtonModel,
owns_model: bool,
text: []const u8,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
/// True while this radio is the window's focus owner (FocusEvent-driven);
/// drives the focus-ring paint.
focused: bool,
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

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButton {
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
) !*RadioButton {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    owns_model: bool,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*RadioButton {
    const rb = try allocator.create(RadioButton);
    errdefer allocator.destroy(rb);

    const text_dup = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dup);

    rb.* = .{
        .component = Component.init(allocator, &vtable),
        .model = model,
        .owns_model = owns_model,
        .text = text_dup,
        .font = font,
        .color = color,
        .focused = false,
        .allocator = allocator,
    };
    rb.component.role = .radio_button;
    rb.component.a11y = .{ .name = a11yName };
    rb.component.focus_query = .{ .isEligible = focusEligible };
    rb.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    rb.applyMetrics();
    try RadioButton.vtable.install(&rb.component);
    return rb;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getText(self: RadioButton) []const u8 {
    return self.text;
}

pub fn setText(self: *RadioButton, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
    self.component.repaint();
}

pub fn isSelected(self: RadioButton) bool {
    return self.model.isSelected();
}

pub fn setSelected(self: *RadioButton, v: bool) void {
    self.model.setSelected(v);
}

pub fn getModel(self: RadioButton) *ToggleButtonModel {
    return self.model;
}

/// Programmatic activation: select (idempotent — the ButtonGroup turns the
/// previous one off) + fire. Shared by Space and any future mnemonic.
/// No-op while disabled.
pub fn doClick(self: *RadioButton) void {
    if (!self.model.button.enabled) return;
    if (!self.model.isSelected()) self.model.setSelected(true);
    self.model.fireAction();
}

fn focusEligible(c: *const Component) bool {
    const rb: *const RadioButton = @fieldParentPtr("component", c);
    return rb.model.button.enabled;
}

fn a11yName(c: *const Component) ?[]const u8 {
    const rb: *const RadioButton = @fieldParentPtr("component", c);
    if (rb.text.len == 0) return null;
    return rb.text;
}

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *RadioButton) void {
    const ui = self.component.ui.?;
    const min = ui.vtable.measureMinSize(&self.component, ui.ctx);
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    const m = rb.font.measureString(rb.text);
    const content_h = @max(CIRCLE_SIZE, m.height);
    return .{
        .width = CIRCLE_SIZE + CIRCLE_GAP + m.width + PADDING_X * 2,
        .height = content_h + PADDING_Y * 2,
    };
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    const rb: *RadioButton = @fieldParentPtr("component", self);
    try rb.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    // Focus goes to null when its owner is torn down (keybinding.md).
    if (rb.focused) self.releaseFocus();
    rb.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    lookPaint(self, &Component.default_look_context, g);
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;
    const btn = &rb.model.button;
    const selected = rb.model.isSelected();
    const enabled = btn.enabled;

    const circle_x = PADDING_X;
    const circle_y = (sz.height - CIRCLE_SIZE) / 2;

    // Background fill (round shape via fillCircle on the bounding rect).
    const bg = if (!enabled) t.surface_disabled else t.surface_input;
    g.setColor(bg);
    g.fillCircle(.{ .x = circle_x, .y = circle_y, .width = CIRCLE_SIZE, .height = CIRCLE_SIZE });

    // Border (drawCircle).
    const border = if (btn.rollover and enabled) t.accent else t.indicator_border;
    g.setColor(border);
    g.drawCircle(.{ .x = circle_x, .y = circle_y, .width = CIRCLE_SIZE, .height = CIRCLE_SIZE });

    // Inner dot when selected.
    if (selected) {
        const dot_inset: f32 = 4;
        const dot_color = if (enabled) t.accent else t.text_disabled;
        g.setColor(dot_color);
        g.fillCircle(.{
            .x = circle_x + dot_inset,
            .y = circle_y + dot_inset,
            .width = CIRCLE_SIZE - dot_inset * 2,
            .height = CIRCLE_SIZE - dot_inset * 2,
        });
    }

    // Label.
    const text_color = if (enabled) rb.color else t.text_disabled;
    const m = rb.font.measureString(rb.text);
    const text_x = circle_x + CIRCLE_SIZE + CIRCLE_GAP;
    const text_y = (sz.height - m.height) / 2;
    g.setFont(rb.font);
    g.setColor(text_color);
    g.drawString(rb.text, text_x, text_y);

    // Focus ring (keyboard focus indicator).
    if (rb.focused) {
        g.setColor(t.focus_ring);
        g.drawRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 });
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    const btn = &rb.model.button;
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
                        self.requestFocus();
                        ev.consume();
                    }
                },
                .release => {
                    if (m.button == .left and btn.isPressed()) {
                        const was_armed = btn.isArmed();
                        btn.setPressed(false);
                        btn.setArmed(false);
                        if (was_armed and inside) {
                            // Unlike CheckBox, RadioButton clicking always
                            // selects (idempotent if already selected). The
                            // group ensures only one stays on.
                            if (!rb.model.isSelected()) rb.model.setSelected(true);
                            rb.model.fireAction();
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
        .key => |k| {
            if (k.action == .press and k.code == .space) {
                rb.doClick();
                ev.consume();
            }
        },
        .focus => |f| {
            rb.focused = f.gained;
        },
        .char, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    self.deinit();
    allocator.free(rb.text);
    if (rb.owns_model) {
        rb.model.deinit();
        allocator.destroy(rb.model);
    }
    allocator.destroy(rb);
}
