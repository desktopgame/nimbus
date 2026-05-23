//! Numeric bounds assertions for BorderLayout.
//! See `box_layout_test.zig` for the GPU-free Panel-leaf pattern.

const std = @import("std");
const nimbus = @import("nimbus");

const Container = nimbus.Container;
const Panel = nimbus.Panel;
const Component = nimbus.Component;
const BorderLayout = nimbus.BorderLayout;

fn leaf(allocator: std.mem.Allocator, w: f32, h: f32) !*Panel {
    const p = try Panel.create(allocator);
    p.container.component.setMinSize(.{ .width = w, .height = h });
    p.container.component.setMaxSize(.{ .width = w, .height = h });
    return p;
}

fn expectBounds(c: *const Component, x: f32, y: f32, w: f32, h: f32) !void {
    const b = c.getBounds();
    try std.testing.expectApproxEqAbs(x, b.x, 0.001);
    try std.testing.expectApproxEqAbs(y, b.y, 0.001);
    try std.testing.expectApproxEqAbs(w, b.width, 0.001);
    try std.testing.expectApproxEqAbs(h, b.height, 0.001);
}

test "center only fills the entire container" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BorderLayout.get());

    const center = try leaf(a, 50, 30);
    try BorderLayout.add(root, .center, &center.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 200 });

    // With no edge regions, the center takes the full container.
    try expectBounds(&center.container.component, 0, 0, 400, 200);
}

test "north + south + center: edges keep min size, center fills the rest" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BorderLayout.get());

    const north = try leaf(a, 50, 24);
    const south = try leaf(a, 50, 32);
    const center = try leaf(a, 50, 50);

    try BorderLayout.add(root, .north,  &north.container.component);
    try BorderLayout.add(root, .south,  &south.container.component);
    try BorderLayout.add(root, .center, &center.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 300, .height = 200 });

    // north: full width, height = north.min.height = 24
    // south: full width, height = south.min.height = 32, y = H - sh
    // center: full width, sits between north and south
    try expectBounds(&north.container.component,  0,   0, 300, 24);
    try expectBounds(&south.container.component,  0, 168, 300, 32);
    try expectBounds(&center.container.component, 0,  24, 300, 144);
}

test "all 5 regions partition correctly" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BorderLayout.get());

    const north  = try leaf(a, 50, 20);
    const south  = try leaf(a, 50, 30);
    const west   = try leaf(a, 40, 50);
    const east   = try leaf(a, 60, 50);
    const center = try leaf(a, 50, 50);

    try BorderLayout.add(root, .north,  &north.container.component);
    try BorderLayout.add(root, .south,  &south.container.component);
    try BorderLayout.add(root, .west,   &west.container.component);
    try BorderLayout.add(root, .east,   &east.container.component);
    try BorderLayout.add(root, .center, &center.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 300 });

    // nh=20, sh=30, ww=40, ew=60
    // mid_h = 300 - 20 - 30 = 250
    // mid_w = 400 - 40 - 60 = 300
    try expectBounds(&north.container.component,    0,   0, 400,  20);
    try expectBounds(&south.container.component,    0, 270, 400,  30);
    try expectBounds(&west.container.component,     0,  20,  40, 250);
    try expectBounds(&east.container.component,   340,  20,  60, 250);
    try expectBounds(&center.container.component,  40,  20, 300, 250);
}

test "edges with nested Container report size via effectiveMinSize" {
    // Regression for the same wire-up as in box_layout_test.zig: a nested
    // Container without an explicit setMinSize must still occupy the
    // space its children require.
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BorderLayout.get());

    const north_row = try Container.create(a);
    north_row.setLayout(nimbus.BoxLayout.horizontal());
    try north_row.add(&(try leaf(a, 30, 24)).container.component);
    try north_row.add(&(try leaf(a, 70, 24)).container.component);
    try BorderLayout.add(root, .north, &north_row.component);

    const center = try leaf(a, 0, 0);
    center.container.component.setMaxSize(.{
        .width = std.math.inf(f32),
        .height = std.math.inf(f32),
    });
    try BorderLayout.add(root, .center, &center.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 300, .height = 100 });

    // north_row.effectiveMinSize.height = max(24, 24) = 24, so the north
    // strip should be 24 tall — *not* 0 (which is what `north.min_size.height`
    // alone would have returned before the effectiveMinSize wiring).
    try expectBounds(&north_row.component, 0,  0, 300,  24);
    try expectBounds(&center.container.component, 0, 24, 300, 76);
}
