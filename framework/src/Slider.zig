//! Slider widget. See `framework/doc/slider.md`.
//!
//! Visual: rounded-rect track + circular thumb at the value position.
//! Drag interaction: press inside track or thumb starts drag, move updates
//! the model value, release ends drag.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeEvent = @import("listener.zig").ChangeEvent;
const BoundedRangeModel = @import("BoundedRangeModel.zig");

const Slider = @This();

pub const Orientation = enum { horizontal, vertical };

const TRACK_THICKNESS: f32 = 4;
const THUMB_RADIUS: f32 = 8;

component:   Component,
model:       *BoundedRangeModel,
owns_model:  bool,
orientation: Orientation,
allocator:   std.mem.Allocator,
dragging:    bool = false,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn create(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*Slider {
    const model = try allocator.create(BoundedRangeModel);
    errdefer allocator.destroy(model);
    model.* = BoundedRangeModel.init(allocator, min, value, max);
    errdefer model.deinit();

    const s = try createInternal(allocator, orientation, model, true);
    return s;
}

pub fn createWithModel(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    model: *BoundedRangeModel,
) !*Slider {
    return try createInternal(allocator, orientation, model, false);
}

fn createInternal(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    model: *BoundedRangeModel,
    owns_model: bool,
) !*Slider {
    const s = try allocator.create(Slider);
    errdefer allocator.destroy(s);

    s.* = .{
        .component = Component.init(allocator, &vtable),
        .model = model,
        .owns_model = owns_model,
        .orientation = orientation,
        .allocator = allocator,
    };
    s.applyDefaultLayoutAttrs();
    try Slider.vtable.install(&s.component);
    return s;
}

fn applyDefaultLayoutAttrs(self: *Slider) void {
    const long_min: f32 = THUMB_RADIUS * 4;
    const cross_size: f32 = THUMB_RADIUS * 2 + 4;
    switch (self.orientation) {
        .horizontal => {
            self.component.min_size = .{ .width = long_min, .height = cross_size };
            self.component.max_size = .{ .width = std.math.inf(f32), .height = cross_size };
            self.component.grow_x = 1;
            self.component.grow_y = 0;
        },
        .vertical => {
            self.component.min_size = .{ .width = cross_size, .height = long_min };
            self.component.max_size = .{ .width = cross_size, .height = std.math.inf(f32) };
            self.component.grow_x = 0;
            self.component.grow_y = 1;
        },
    }
}

pub fn getOrientation(self: Slider) Orientation {
    return self.orientation;
}

pub fn setOrientation(self: *Slider, o: Orientation) void {
    if (self.orientation == o) return;
    self.orientation = o;
    self.applyDefaultLayoutAttrs();
    self.component.markLayoutDirty();
}

pub fn getModel(self: Slider) *BoundedRangeModel {
    return self.model;
}

// ── geometry helpers ─────────────────────────────────────────────────────

fn valueToPos(self: *const Slider) f32 {
    const sz = self.component.size;
    const range: f32 = @floatFromInt(self.model.max - self.model.min);
    if (range <= 0) return 0;
    const t: f32 = @as(f32, @floatFromInt(self.model.value - self.model.min)) / range;
    return switch (self.orientation) {
        .horizontal => THUMB_RADIUS + t * (sz.width - 2 * THUMB_RADIUS),
        .vertical   => THUMB_RADIUS + t * (sz.height - 2 * THUMB_RADIUS),
    };
}

fn posToValue(self: *const Slider, local_x: f32, local_y: f32) i32 {
    const sz = self.component.size;
    const main: f32 = switch (self.orientation) {
        .horizontal => local_x - THUMB_RADIUS,
        .vertical   => local_y - THUMB_RADIUS,
    };
    const total: f32 = switch (self.orientation) {
        .horizontal => sz.width - 2 * THUMB_RADIUS,
        .vertical   => sz.height - 2 * THUMB_RADIUS,
    };
    const t: f32 = if (total > 0) std.math.clamp(main / total, 0, 1) else 0;
    const range: f32 = @floatFromInt(self.model.max - self.model.min);
    return self.model.min + @as(i32, @intFromFloat(@round(t * range)));
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const slider: *Slider = @fieldParentPtr("component", self);
    try slider.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const slider: *Slider = @fieldParentPtr("component", self);
    slider.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const slider: *Slider = @fieldParentPtr("component", self);
    const sz = self.size;

    // Track (centered).
    const track_color = awt.Graphics.Color.rgb(0.7, 0.7, 0.75);
    g.setColor(track_color);
    switch (slider.orientation) {
        .horizontal => {
            const cy = sz.height / 2 - TRACK_THICKNESS / 2;
            g.fillRoundRect(
                .{ .x = THUMB_RADIUS, .y = cy, .width = sz.width - 2 * THUMB_RADIUS, .height = TRACK_THICKNESS },
                TRACK_THICKNESS / 2,
            );
        },
        .vertical => {
            const cx = sz.width / 2 - TRACK_THICKNESS / 2;
            g.fillRoundRect(
                .{ .x = cx, .y = THUMB_RADIUS, .width = TRACK_THICKNESS, .height = sz.height - 2 * THUMB_RADIUS },
                TRACK_THICKNESS / 2,
            );
        },
    }

    // Thumb (circle centered on value position).
    const pos = slider.valueToPos();
    const thumb_color = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);
    g.setColor(thumb_color);
    switch (slider.orientation) {
        .horizontal => {
            const cx = pos;
            const cy = sz.height / 2;
            g.fillCircle(.{
                .x = cx - THUMB_RADIUS,
                .y = cy - THUMB_RADIUS,
                .width = THUMB_RADIUS * 2,
                .height = THUMB_RADIUS * 2,
            });
        },
        .vertical => {
            const cx = sz.width / 2;
            const cy = pos;
            g.fillCircle(.{
                .x = cx - THUMB_RADIUS,
                .y = cy - THUMB_RADIUS,
                .width = THUMB_RADIUS * 2,
                .height = THUMB_RADIUS * 2,
            });
        },
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const slider: *Slider = @fieldParentPtr("component", self);
    switch (ev.payload) {
        .mouse => |m| {
            // Mouse coords arriving here are window-local; convert to
            // component-local via parent-chain offset.
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            switch (m.action) {
                .press => {
                    if (m.button == .left) {
                        slider.dragging = true;
                        slider.model.setValue(slider.posToValue(lx, ly));
                        ev.requestCapture(@ptrCast(self));
                        ev.consume();
                    }
                },
                .release => {
                    if (m.button == .left and slider.dragging) {
                        slider.dragging = false;
                        ev.consume();
                    }
                },
                .move => {
                    if (slider.dragging) {
                        slider.model.setValue(slider.posToValue(lx, ly));
                        ev.consume();
                    }
                },
                .scroll => {},
            }
        },
        .key, .char, .focus, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const slider: *Slider = @fieldParentPtr("component", self);
    self.deinit(); // uninstall + property cleanup
    if (slider.owns_model) {
        slider.model.deinit();
        allocator.destroy(slider.model);
    }
    allocator.destroy(slider);
}
