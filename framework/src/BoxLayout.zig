//! Horizontal / vertical box layout. See `framework/doc/box_layout.md`.
//!
//! Algorithm: 1-pass clamp. Sum mins, distribute excess by grow weight,
//! clamp at max, leave any leftover as gap at the end. Cross-axis stretches
//! to container size (clamped by child min/max).

const std = @import("std");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const LayoutManager = @import("LayoutManager.zig");

const BoxLayout = @This();

pub const Orientation = enum { horizontal, vertical };

base:        LayoutManager,
orientation: Orientation,

pub const vtable = LayoutManager.VTable{
    .doLayout       = doLayout,
    .computeMinSize = computeMinSize,
    .computeMaxSize = computeMaxSize,
};

// Singletons. Mutable static instances since LayoutManager API takes
// non-const pointers; we never actually mutate them.
var horizontal_singleton: BoxLayout = .{
    .base = .{ .vtable = &vtable },
    .orientation = .horizontal,
};
var vertical_singleton: BoxLayout = .{
    .base = .{ .vtable = &vtable },
    .orientation = .vertical,
};

pub fn horizontal() *LayoutManager {
    return &horizontal_singleton.base;
}

pub fn vertical() *LayoutManager {
    return &vertical_singleton.base;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn mainOf(o: Orientation, s: Component.Size) f32 {
    return switch (o) {
        .horizontal => s.width,
        .vertical   => s.height,
    };
}

fn crossOf(o: Orientation, s: Component.Size) f32 {
    return switch (o) {
        .horizontal => s.height,
        .vertical   => s.width,
    };
}

fn growMain(o: Orientation, c: *const Component) f32 {
    return switch (o) {
        .horizontal => c.grow_x,
        .vertical   => c.grow_y,
    };
}

/// Cross-axis alignment for `c` in a box of orientation `o`.
/// In a horizontal box the cross axis is y → read align_y; vertical → align_x.
fn crossAlign(o: Orientation, c: *const Component) Component.Alignment {
    return switch (o) {
        .horizontal => c.align_y,
        .vertical   => c.align_x,
    };
}

fn doLayout(self: *LayoutManager, container: *Container) void {
    const this: *BoxLayout = @fieldParentPtr("base", self);
    const ori = this.orientation;

    const cb = container.component.size;
    const main_size = mainOf(ori, cb);
    const cross_size = crossOf(ori, cb);

    // Pass 1: collect mins + growth sum. Use effectiveMinSize so a child
    // that is itself a Container reports a size computed from its own
    // children (instead of the default 0 on `component.min_size`).
    var sum_min: f32 = 0;
    var sum_grow: f32 = 0;
    for (container.children.items) |elem| {
        sum_min += mainOf(ori, elem.component.effectiveMinSize());
        sum_grow += growMain(ori, elem.component);
    }

    const excess = main_size - sum_min;
    const distributable = if (excess > 0) excess else 0;

    // Pass 2: assign main-axis sizes (1-pass clamp; no redistribution).
    var pos: f32 = 0;
    for (container.children.items) |elem| {
        const child = elem.component;
        const child_min_size = child.effectiveMinSize();
        const child_max_size = child.effectiveMaxSize();
        const child_min = mainOf(ori, child_min_size);
        const child_max = mainOf(ori, child_max_size);
        const child_grow = growMain(ori, child);

        var main: f32 = child_min;
        if (sum_grow > 0 and distributable > 0) {
            main += distributable * (child_grow / sum_grow);
        }
        if (main > child_max) main = child_max;

        // Cross axis sizing + alignment.
        const child_cmin = crossOf(ori, child_min_size);
        const child_cmax = crossOf(ori, child_max_size);
        const align_v = crossAlign(ori, child);
        var cross: f32 = switch (align_v) {
            .stretch => cross_size,
            else     => child_cmin,    // start / center / end use min size
        };
        if (cross > child_cmax) cross = child_cmax;
        if (cross < child_cmin) cross = child_cmin;

        const cross_pos: f32 = switch (align_v) {
            .stretch, .start => 0,
            .center          => (cross_size - cross) / 2,
            .end             => cross_size - cross,
        };

        const bounds: Component.Rect = switch (ori) {
            .horizontal => .{ .x = pos, .y = cross_pos, .width = main, .height = cross },
            .vertical   => .{ .x = cross_pos, .y = pos, .width = cross, .height = main },
        };

        if (child.container) |child_container| {
            child_container.setBounds(bounds);
        } else {
            child.setBounds(bounds);
        }
        pos += main;
    }
}

fn computeMinSize(self: *LayoutManager, container: *const Container) Component.Size {
    const this: *BoxLayout = @fieldParentPtr("base", self);
    const ori = this.orientation;

    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    for (container.children.items) |elem| {
        const child_min = elem.component.effectiveMinSize();
        main_total += mainOf(ori, child_min);
        const c = crossOf(ori, child_min);
        if (c > cross_max) cross_max = c;
    }
    return switch (ori) {
        .horizontal => .{ .width = main_total, .height = cross_max },
        .vertical   => .{ .width = cross_max,  .height = main_total },
    };
}

fn computeMaxSize(self: *LayoutManager, container: *const Container) Component.Size {
    const this: *BoxLayout = @fieldParentPtr("base", self);
    const ori = this.orientation;

    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    for (container.children.items) |elem| {
        const child_max = elem.component.effectiveMaxSize();
        main_total += mainOf(ori, child_max);
        const c = crossOf(ori, child_max);
        if (c > cross_max) cross_max = c;
    }
    return switch (ori) {
        .horizontal => .{ .width = main_total, .height = cross_max },
        .vertical   => .{ .width = cross_max,  .height = main_total },
    };
}
