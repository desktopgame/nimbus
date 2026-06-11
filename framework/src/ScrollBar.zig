//! Scroll bar widget. See `framework/doc/scroll_bar.md`.
//!
//! Track + a thumb whose length is proportional to the visible amount
//! (`model.extent`). Drag the thumb, click the track to page, or wheel to
//! step. Like `Slider` it is an ordinary leaf widget backed by a
//! `BoundedRangeModel` — no overlay / special dispatch.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const listener = @import("listener.zig");
const ChangeEvent = listener.ChangeEvent;
const BoundedRangeModel = @import("BoundedRangeModel.zig");

const ScrollBar = @This();

pub const Orientation = enum { horizontal, vertical };

pub const THICKNESS: f32 = 14;
const MIN_THUMB: f32 = 20;

// Colors come from `component.theme`: scrollbar_track / scrollbar_thumb /
// scrollbar_thumb_hover (see `framework/doc/theme.md`).

component:       Component,
model:           *BoundedRangeModel,
owns_model:      bool,
orientation:     Orientation,
unit_increment:  i32,
block_increment: i32,
dragging:        bool,
rollover:        bool,
/// Distance from the thumb's leading edge to the cursor at grab time (px).
drag_grab:       f32,
allocator:       std.mem.Allocator,

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
) !*ScrollBar {
    const model = try allocator.create(BoundedRangeModel);
    errdefer allocator.destroy(model);
    model.* = BoundedRangeModel.init(allocator, min, value, max);
    errdefer model.deinit();
    return createInternal(allocator, orientation, model, true);
}

pub fn createWithModel(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    model: *BoundedRangeModel,
) !*ScrollBar {
    return createInternal(allocator, orientation, model, false);
}

fn createInternal(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    model: *BoundedRangeModel,
    owns_model: bool,
) !*ScrollBar {
    const sb = try allocator.create(ScrollBar);
    errdefer allocator.destroy(sb);

    sb.* = .{
        .component       = Component.init(allocator, &vtable),
        .model           = model,
        .owns_model      = owns_model,
        .orientation     = orientation,
        .unit_increment  = 16,
        .block_increment = 0, // 0 → page by extent
        .dragging        = false,
        .rollover        = false,
        .drag_grab       = 0,
        .allocator       = allocator,
    };
    sb.component.role = .scroll_bar;
    sb.applyDefaultLayoutAttrs();
    try ScrollBar.vtable.install(&sb.component);
    return sb;
}

fn applyDefaultLayoutAttrs(self: *ScrollBar) void {
    switch (self.orientation) {
        .horizontal => {
            self.component.min_size = .{ .width = MIN_THUMB * 2, .height = THICKNESS };
            self.component.max_size = .{ .width = std.math.inf(f32), .height = THICKNESS };
            self.component.grow_x = 1;
            self.component.grow_y = 0;
        },
        .vertical => {
            self.component.min_size = .{ .width = THICKNESS, .height = MIN_THUMB * 2 };
            self.component.max_size = .{ .width = THICKNESS, .height = std.math.inf(f32) };
            self.component.grow_x = 0;
            self.component.grow_y = 1;
        },
    }
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getModel(self: ScrollBar) *BoundedRangeModel {
    return self.model;
}

pub fn getValue(self: ScrollBar) i32 {
    return self.model.getValue();
}

pub fn setValue(self: *ScrollBar, v: i32) void {
    self.model.setValue(v);
}

pub fn getOrientation(self: ScrollBar) Orientation {
    return self.orientation;
}

pub fn setUnitIncrement(self: *ScrollBar, px: i32) void {
    self.unit_increment = px;
}

pub fn setBlockIncrement(self: *ScrollBar, px: i32) void {
    self.block_increment = px;
}

pub fn addChangeListener(
    self: *ScrollBar,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void {
    try self.model.addChangeListener(T, f, user_data);
}

pub fn removeChangeListener(
    self: *ScrollBar,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void {
    self.model.removeChangeListener(T, f, user_data);
}

// ── geometry ───────────────────────────────────────────────────────────────

fn trackLen(self: *const ScrollBar) f32 {
    return switch (self.orientation) {
        .horizontal => self.component.size.width,
        .vertical   => self.component.size.height,
    };
}

/// Thumb length in px (proportional to extent / range). When the track is
/// shorter than the minimum thumb (e.g. a hidden / zero-sized bar after the
/// content shrinks to fit), the thumb just fills the whole track — guarding
/// against `std.math.clamp`'s `lower <= upper` assertion.
fn thumbLen(self: *const ScrollBar) f32 {
    const track = self.trackLen();
    if (track <= MIN_THUMB) return track;
    const range: f32 = @floatFromInt(self.model.max - self.model.min);
    if (range <= 0) return track;
    const ext: f32 = @floatFromInt(self.model.extent);
    const len = ext / range * track;
    return std.math.clamp(len, MIN_THUMB, track);
}

/// Thumb leading-edge offset from the track start, in px.
fn thumbStart(self: *const ScrollBar) f32 {
    const travel = self.trackLen() - self.thumbLen();
    if (travel <= 0) return 0;
    const span: f32 = @floatFromInt((self.model.max - self.model.min) - self.model.extent);
    if (span <= 0) return 0;
    const v: f32 = @floatFromInt(self.model.value - self.model.min);
    return std.math.clamp(v / span, 0, 1) * travel;
}

/// True when there is room to scroll (thumb does not fill the track).
fn scrollable(self: *const ScrollBar) bool {
    return (self.model.max - self.model.min) > self.model.extent;
}

/// Map a thumb leading-edge offset (px) back to a model value.
fn offsetToValue(self: *const ScrollBar, offset: f32) i32 {
    const travel = self.trackLen() - self.thumbLen();
    if (travel <= 0) return self.model.min;
    const scrollable_span: f32 = @floatFromInt((self.model.max - self.model.min) - self.model.extent);
    const t = std.math.clamp(offset / travel, 0, 1);
    return self.model.min + @as(i32, @intFromFloat(@round(t * scrollable_span)));
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    try sb.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    sb.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    const sz = self.size;
    // Hidden / collapsed bar (e.g. content fits, so this axis needs no bar).
    if (sz.width <= 0 or sz.height <= 0) return;

    const t = self.theme;
    g.setColor(t.scrollbar_track);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    const len = sb.thumbLen();
    const start = sb.thumbStart();
    const inset: f32 = 2;
    const thumb_color = if (sb.dragging or sb.rollover) t.scrollbar_thumb_hover else t.scrollbar_thumb;
    g.setColor(thumb_color);
    switch (sb.orientation) {
        .horizontal => g.fillRoundRect(
            .{ .x = start, .y = inset, .width = len, .height = sz.height - inset * 2 },
            (sz.height - inset * 2) / 2,
        ),
        .vertical => g.fillRoundRect(
            .{ .x = inset, .y = start, .width = sz.width - inset * 2, .height = len },
            (sz.width - inset * 2) / 2,
        ),
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const main: f32 = switch (sb.orientation) {
                .horizontal => lx,
                .vertical   => ly,
            };
            switch (m.action) {
                .press => {
                    if (m.button != .left) return;
                    if (!sb.scrollable()) {
                        ev.consume();
                        return;
                    }
                    const start = sb.thumbStart();
                    const len = sb.thumbLen();
                    if (main >= start and main < start + len) {
                        // Grab the thumb.
                        sb.dragging = true;
                        sb.drag_grab = main - start;
                        ev.requestCapture(@ptrCast(self));
                    } else {
                        // Page toward the click.
                        const page: i32 = if (sb.block_increment > 0) sb.block_increment else sb.model.extent;
                        if (main < start) {
                            sb.model.setValue(sb.model.value - page);
                        } else {
                            sb.model.setValue(sb.model.value + page);
                        }
                    }
                    ev.consume();
                },
                .release => {
                    if (m.button == .left and sb.dragging) {
                        sb.dragging = false;
                        ev.consume();
                    }
                },
                .move => {
                    if (sb.dragging) {
                        sb.model.setValue(sb.offsetToValue(main - sb.drag_grab));
                        ev.consume();
                    } else {
                        const start = sb.thumbStart();
                        const len = sb.thumbLen();
                        const over = main >= start and main < start + len;
                        if (over != sb.rollover) {
                            sb.rollover = over;
                            self.repaint();
                        }
                    }
                },
                .scroll => {
                    // Wheel up (positive) scrolls toward the start.
                    const step = if (m.wheel > 0) -sb.unit_increment else sb.unit_increment;
                    sb.model.setValue(sb.model.value + step);
                    ev.consume();
                },
            }
        },
        .key, .char, .focus, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const sb: *ScrollBar = @fieldParentPtr("component", self);
    self.deinit();
    if (sb.owns_model) {
        sb.model.deinit();
        allocator.destroy(sb.model);
    }
    allocator.destroy(sb);
}
