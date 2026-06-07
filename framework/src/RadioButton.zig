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
const CIRCLE_GAP: f32  = 6;
const PADDING_X: f32   = 4;
const PADDING_Y: f32   = 4;

const CIRCLE_BG_NORMAL   = awt.Graphics.Color.rgb(1.00, 1.00, 1.00);
const CIRCLE_BG_DISABLED = awt.Graphics.Color.rgb(0.93, 0.93, 0.93);
const CIRCLE_BORDER      = awt.Graphics.Color.rgb(0.50, 0.50, 0.50);
const CIRCLE_BORDER_HOV  = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);
const DOT_COLOR          = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);
const DOT_COLOR_DISABLED = awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
const TEXT_DISABLED      = awt.Graphics.Color.rgb(0.55, 0.55, 0.55);

component:  Component,
model:      *ToggleButtonModel,
owns_model: bool,
text:       []const u8,
font:       awt.Graphics.TextFont,
color:      awt.Graphics.Color,
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
        .allocator = allocator,
    };
    rb.component.role = .radio_button;
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

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *RadioButton) void {
    const m = self.font.measureString(self.text);
    const content_h = @max(CIRCLE_SIZE, m.height);
    const min = Component.Size{
        .width = CIRCLE_SIZE + CIRCLE_GAP + m.width + PADDING_X * 2,
        .height = content_h + PADDING_Y * 2,
    };
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    const rb: *RadioButton = @fieldParentPtr("component", self);
    try rb.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    rb.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const rb: *RadioButton = @fieldParentPtr("component", self);
    const sz = self.size;
    const btn = &rb.model.button;
    const selected = rb.model.isSelected();
    const enabled = btn.enabled;

    const circle_x = PADDING_X;
    const circle_y = (sz.height - CIRCLE_SIZE) / 2;

    // Background fill (round shape via fillCircle on the bounding rect).
    const bg = if (!enabled) CIRCLE_BG_DISABLED else CIRCLE_BG_NORMAL;
    g.setColor(bg);
    g.fillCircle(.{ .x = circle_x, .y = circle_y, .width = CIRCLE_SIZE, .height = CIRCLE_SIZE });

    // Border (drawCircle).
    const border = if (btn.rollover and enabled) CIRCLE_BORDER_HOV else CIRCLE_BORDER;
    g.setColor(border);
    g.drawCircle(.{ .x = circle_x, .y = circle_y, .width = CIRCLE_SIZE, .height = CIRCLE_SIZE });

    // Inner dot when selected.
    if (selected) {
        const dot_inset: f32 = 4;
        const dot_color = if (enabled) DOT_COLOR else DOT_COLOR_DISABLED;
        g.setColor(dot_color);
        g.fillCircle(.{
            .x = circle_x + dot_inset,
            .y = circle_y + dot_inset,
            .width = CIRCLE_SIZE - dot_inset * 2,
            .height = CIRCLE_SIZE - dot_inset * 2,
        });
    }

    // Label.
    const text_color = if (enabled) rb.color else TEXT_DISABLED;
    const m = rb.font.measureString(rb.text);
    const text_x = circle_x + CIRCLE_SIZE + CIRCLE_GAP;
    const text_y = (sz.height - m.height) / 2;
    g.setFont(rb.font);
    g.setColor(text_color);
    g.drawString(rb.text, text_x, text_y);
}

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
                if (!rb.model.isSelected()) rb.model.setSelected(true);
                rb.model.fireAction();
                ev.consume();
            }
        },
        .char, .focus, .composition => {},
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
