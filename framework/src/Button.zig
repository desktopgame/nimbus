//! Button widget. See `framework/doc/button.md`.
//!
//! Visual: rounded rectangle with centered text. The fill color reflects
//! ButtonModel state (pressed → darker, rollover → lighter, disabled → gray).

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ButtonModel = @import("ButtonModel.zig");

const Button = @This();

const PADDING_X: f32 = 12;
const PADDING_Y: f32 = 8;
const CORNER_RADIUS: f32 = 6;

component:  Component,
model:      *ButtonModel,
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
        .allocator = allocator,
    };
    b.component.min_size = textMinSize(b.font, b.text);
    Button.vtable.install(&b.component);
    return b;
}

fn textMinSize(font: awt.Graphics.TextFont, text: []const u8) Component.Size {
    const m = font.measureString(text);
    return .{ .width = m.width + PADDING_X * 2, .height = m.height + PADDING_Y * 2 };
}

pub fn getText(self: Button) []const u8 {
    return self.text;
}

pub fn setText(self: *Button, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.component.setMinSize(textMinSize(self.font, self.text));
}

pub fn getFont(self: Button) awt.Graphics.TextFont { return self.font; }
pub fn setFont(self: *Button, font: awt.Graphics.TextFont) void {
    self.font = font;
    self.component.setMinSize(textMinSize(self.font, self.text));
}

pub fn getColor(self: Button) awt.Graphics.Color { return self.color; }
pub fn setColor(self: *Button, color: awt.Graphics.Color) void {
    self.color = color;
    self.component.repaint();
}

pub fn getModel(self: Button) *ButtonModel { return self.model; }

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) void {
    const button: *Button = @fieldParentPtr("component", self);
    button.model.addChangeListener(onModelChange, self) catch {};
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

    // Background color picks based on model state.
    var bg = awt.Graphics.Color.rgb(0.85, 0.85, 0.90);
    if (!button.model.enabled) {
        bg = awt.Graphics.Color.rgb(0.75, 0.75, 0.78);
    } else if (button.model.armed and button.model.pressed) {
        bg = awt.Graphics.Color.rgb(0.55, 0.65, 0.85); // pressed = darker
    } else if (button.model.rollover) {
        bg = awt.Graphics.Color.rgb(0.92, 0.92, 0.97); // hover = lighter
    }

    g.setColor(bg);
    g.fillRoundRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height }, CORNER_RADIUS);

    // Text centered.
    const m = button.font.measureString(button.text);
    const tx = (sz.width - m.width) / 2;
    const ty = (sz.height - m.height) / 2;
    const text_color = if (button.model.enabled) button.color else awt.Graphics.Color.rgb(0.5, 0.5, 0.5);
    g.setFont(button.font);
    g.setColor(text_color);
    g.drawString(button.text, tx, ty);
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
                    // Update armed (drag in/out toggles armed while pressed).
                    if (button.model.isPressed()) {
                        button.model.setArmed(inside);
                    }
                    // Update rollover.
                    button.model.setRollover(inside);
                },
                .scroll => {},
            }
        },
        .key => {},
    }
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
