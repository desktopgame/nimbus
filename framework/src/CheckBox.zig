//! Two-state check box. See `framework/doc/checkbox.md`.
//!
//! Visual: a square indicator on the left, label to the right. When
//! selected, a check glyph is drawn inside the square. Click or Space
//! (when focused) toggles selected and fires the model's ActionListener
//! chain.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const ToggleButtonModel = @import("ToggleButtonModel.zig");

const CheckBox = @This();

const BOX_SIZE: f32 = 16;
const BOX_GAP: f32 = 6; // indicator → label gap
const PADDING_X: f32 = 4;
const PADDING_Y: f32 = 4;
const FOCUS_RING: f32 = 1;

// Colors come from `component.theme` (see `framework/doc/theme.md`):
// box bg = surface_input / surface_disabled / accent (checked), box border =
// indicator_border (accent on hover), check glyph = text_on_accent.

component: Component,
model: *ToggleButtonModel,
owns_model: bool,
text: []const u8,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
/// True while this checkbox is the window's focus owner (FocusEvent-driven);
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

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBox {
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
) !*CheckBox {
    return createInternal(allocator, model, false, text, font, color);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *ToggleButtonModel,
    owns_model: bool,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*CheckBox {
    const cb = try allocator.create(CheckBox);
    errdefer allocator.destroy(cb);

    const text_dup = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dup);

    cb.* = .{
        .component = Component.init(allocator, &vtable),
        .model = model,
        .owns_model = owns_model,
        .text = text_dup,
        .font = font,
        .color = color,
        .focused = false,
        .allocator = allocator,
    };
    cb.component.role = .checkbox;
    cb.component.focus_query = .{ .isEligible = focusEligible };
    cb.applyMetrics();
    try CheckBox.vtable.install(&cb.component);
    return cb;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getText(self: CheckBox) []const u8 {
    return self.text;
}

pub fn setText(self: *CheckBox, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
    self.component.repaint();
}

pub fn isSelected(self: CheckBox) bool {
    return self.model.isSelected();
}

pub fn setSelected(self: *CheckBox, v: bool) void {
    self.model.setSelected(v);
}

pub fn getModel(self: CheckBox) *ToggleButtonModel {
    return self.model;
}

/// Programmatic activation: toggle + fire, the path shared by Space and any
/// future mnemonic. No-op while disabled (the one guard for all entry points).
pub fn doClick(self: *CheckBox) void {
    if (!self.model.button.enabled) return;
    self.model.setSelected(!self.model.isSelected());
    self.model.fireAction();
}

fn focusEligible(c: *const Component) bool {
    const cb: *const CheckBox = @fieldParentPtr("component", c);
    return cb.model.button.enabled;
}

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *CheckBox) void {
    const m = self.font.measureString(self.text);
    const content_h = @max(BOX_SIZE, m.height);
    const min = Component.Size{
        .width = BOX_SIZE + BOX_GAP + m.width + PADDING_X * 2,
        .height = content_h + PADDING_Y * 2,
    };
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    const cb: *CheckBox = @fieldParentPtr("component", self);
    try cb.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const cb: *CheckBox = @fieldParentPtr("component", self);
    // Focus goes to null when its owner is torn down (keybinding.md).
    if (cb.focused) self.releaseFocus();
    cb.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const cb: *CheckBox = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;
    const btn = &cb.model.button;
    const selected = cb.model.isSelected();
    const enabled = btn.enabled;

    // Indicator box: vertically centered.
    const box_x = PADDING_X;
    const box_y = (sz.height - BOX_SIZE) / 2;
    const bg = if (!enabled)
        t.surface_disabled
    else if (selected)
        t.accent
    else
        t.surface_input;
    const border = if (btn.rollover and enabled) t.accent else t.indicator_border;

    g.setColor(bg);
    g.fillRect(.{ .x = box_x, .y = box_y, .width = BOX_SIZE, .height = BOX_SIZE });
    drawBoxBorder(g, box_x, box_y, BOX_SIZE, BOX_SIZE, border);

    if (selected) {
        drawCheck(g, box_x, box_y, BOX_SIZE, t.text_on_accent);
    }

    // Label.
    const text_color = if (enabled) cb.color else t.text_disabled;
    const m = cb.font.measureString(cb.text);
    const text_x = box_x + BOX_SIZE + BOX_GAP;
    const text_y = (sz.height - m.height) / 2;
    g.setFont(cb.font);
    g.setColor(text_color);
    g.drawString(cb.text, text_x, text_y);

    // Focus ring (keyboard focus indicator).
    if (cb.focused) {
        g.setColor(t.focus_ring);
        g.drawRect(.{ .x = 1, .y = 1, .width = sz.width - 2, .height = sz.height - 2 });
    }
}

/// Open border (4 strips) so the colored fill underneath shows through
/// to the user without rasterizing a separate stroke pass.
fn drawBoxBorder(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    g.fillRect(.{ .x = x, .y = y, .width = w, .height = 1 });
    g.fillRect(.{ .x = x, .y = y + h - 1, .width = w, .height = 1 });
    g.fillRect(.{ .x = x, .y = y, .width = 1, .height = h });
    g.fillRect(.{ .x = x + w - 1, .y = y, .width = 1, .height = h });
}

/// Stylized check mark, rendered as two diagonal strokes built
/// from short rectangles (no line primitive in awt — same trick as
/// CheckBoxMenuItem.drawCheckmark, sized to fit a 16-px box).
fn drawCheck(g: *awt.Graphics, box_x: f32, box_y: f32, box_size: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    const inset: f32 = 3;
    const cx = box_x + inset;
    const cy = box_y + inset;
    const span = box_size - inset * 2; // 10 when box=16
    const dot: f32 = 2;
    // Short stroke (down-right), 4 dots.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        g.fillRect(.{ .x = cx + f, .y = cy + span * 0.5 + f, .width = dot, .height = dot });
    }
    // Long stroke (up-right), 6 dots.
    i = 0;
    while (i < 6) : (i += 1) {
        const f: f32 = @floatFromInt(i);
        g.fillRect(.{ .x = cx + 3 + f, .y = cy + span - 1 - f, .width = dot, .height = dot });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const cb: *CheckBox = @fieldParentPtr("component", self);
    const btn = &cb.model.button;
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
                            cb.model.setSelected(!cb.model.isSelected());
                            cb.model.fireAction();
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
            // Space toggles when focused (Swing JCheckBox / Win32 / GTK all do this).
            if (k.action == .press and k.code == .space) {
                cb.doClick();
                ev.consume();
            }
        },
        .focus => |f| {
            cb.focused = f.gained;
        },
        .char, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cb: *CheckBox = @fieldParentPtr("component", self);
    self.deinit();
    allocator.free(cb.text);
    if (cb.owns_model) {
        cb.model.deinit();
        allocator.destroy(cb.model);
    }
    allocator.destroy(cb);
}
