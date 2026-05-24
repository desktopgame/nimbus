//! Five-region border layout. See `framework/doc/border_layout.md`.
//!
//! North / south get full container width at the min height of their child.
//! West / east get the remaining vertical space at the min width of their
//! child. Center fills whatever rectangle is left.

const std = @import("std");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const LayoutManager = @import("LayoutManager.zig");

const BorderLayout = @This();

pub const Region = enum(u8) { north, south, east, west, center };

base: LayoutManager,

pub const vtable = LayoutManager.VTable{
    .doLayout       = doLayout,
    .computeMinSize = computeMinSize,
    .computeMaxSize = computeMaxSize,
};

// Singleton. BorderLayout has no per-instance state.
var singleton: BorderLayout = .{ .base = .{ .vtable = &vtable } };

pub fn get() *LayoutManager {
    return &singleton.base;
}

// ── hint plumbing ────────────────────────────────────────────────────────

/// One byte per region, used purely so each region gets a distinct stable
/// address that can serve as the hint pointer. The byte's value is never
/// read.
var markers = [_]u8{ 0, 0, 0, 0, 0 };

fn marker(r: Region) *anyopaque {
    return @ptrCast(&markers[@intFromEnum(r)]);
}

fn regionFromHint(h: ?*anyopaque) ?Region {
    const p = h orelse return null;
    const base_addr = @intFromPtr(&markers[0]);
    const addr = @intFromPtr(p);
    if (addr < base_addr) return null;
    const offset = addr - base_addr;
    if (offset >= markers.len) return null;
    return @enumFromInt(@as(u8, @intCast(offset)));
}

/// Add `child` to `container` with the given region. Equivalent to
/// `container.addWithHint(child, BorderLayout.marker(region), null)`
/// but reads better at call sites.
pub fn add(container: *Container, region: Region, child: *Component) !void {
    try container.addWithHint(child, marker(region), null);
}

// ── vtable impl ──────────────────────────────────────────────────────────

const Slots = struct {
    north:  ?*Component = null,
    south:  ?*Component = null,
    east:   ?*Component = null,
    west:   ?*Component = null,
    center: ?*Component = null,
};

fn collect(container: *const Container) Slots {
    var slots = Slots{};
    for (container.children.items) |elem| {
        const region = regionFromHint(elem.hint) orelse continue;
        switch (region) {
            .north  => slots.north  = elem.component,
            .south  => slots.south  = elem.component,
            .east   => slots.east   = elem.component,
            .west   => slots.west   = elem.component,
            .center => slots.center = elem.component,
        }
    }
    return slots;
}

fn setChildBounds(child: *Component, bounds: Component.Rect) void {
    // Always Component.setBounds, never Container.setBounds: the latter would
    // eagerly re-layout the child, which Container.doLayout's trailing
    // recursion then repeats (2^depth re-layouts). Container.doLayout owns the
    // single recursion. See `framework/doc/optimize.md`.
    child.setBounds(bounds);
}

fn doLayout(self: *LayoutManager, container: *Container) void {
    _ = self;
    const slots = collect(container);
    const cb = container.component.size;
    const W = cb.width;
    const H = cb.height;

    // Use effectiveMinSize so that nested Containers report a size
    // derived from their own children, not the default 0.
    const nh: f32 = if (slots.north)  |c| c.effectiveMinSize().height else 0;
    const sh: f32 = if (slots.south)  |c| c.effectiveMinSize().height else 0;
    const ww: f32 = if (slots.west)   |c| c.effectiveMinSize().width  else 0;
    const ew: f32 = if (slots.east)   |c| c.effectiveMinSize().width  else 0;

    const mid_h = @max(0, H - nh - sh);
    const mid_w = @max(0, W - ww - ew);

    if (slots.north)  |c| setChildBounds(c, .{ .x = 0,      .y = 0,      .width = W,      .height = nh });
    if (slots.south)  |c| setChildBounds(c, .{ .x = 0,      .y = H - sh, .width = W,      .height = sh });
    if (slots.west)   |c| setChildBounds(c, .{ .x = 0,      .y = nh,     .width = ww,     .height = mid_h });
    if (slots.east)   |c| setChildBounds(c, .{ .x = W - ew, .y = nh,     .width = ew,     .height = mid_h });
    if (slots.center) |c| setChildBounds(c, .{ .x = ww,     .y = nh,     .width = mid_w,  .height = mid_h });
}

fn computeMinSize(self: *LayoutManager, container: *const Container) Component.Size {
    _ = self;
    const slots = collect(container);

    const nw: f32 = if (slots.north)  |c| c.effectiveMinSize().width  else 0;
    const sw: f32 = if (slots.south)  |c| c.effectiveMinSize().width  else 0;
    const ww: f32 = if (slots.west)   |c| c.effectiveMinSize().width  else 0;
    const ew: f32 = if (slots.east)   |c| c.effectiveMinSize().width  else 0;
    const cw: f32 = if (slots.center) |c| c.effectiveMinSize().width  else 0;

    const nh: f32 = if (slots.north)  |c| c.effectiveMinSize().height else 0;
    const sh: f32 = if (slots.south)  |c| c.effectiveMinSize().height else 0;
    const wh: f32 = if (slots.west)   |c| c.effectiveMinSize().height else 0;
    const eh: f32 = if (slots.east)   |c| c.effectiveMinSize().height else 0;
    const ch: f32 = if (slots.center) |c| c.effectiveMinSize().height else 0;

    const mid_w = ww + cw + ew;
    const min_w = @max(@max(nw, sw), mid_w);
    const mid_h = @max(@max(wh, ch), eh);
    const min_h = nh + mid_h + sh;
    return .{ .width = min_w, .height = min_h };
}

fn computeMaxSize(self: *LayoutManager, container: *const Container) Component.Size {
    _ = self;
    _ = container;
    return .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
}
