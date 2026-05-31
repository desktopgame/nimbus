//! Numeric bounds assertions for BoxLayout. GPU-free: built from
//! fixed-size Panels (so each test can run without awt.init / a font).
//! Visual snapshot of the same layouts will live in a separate
//! framework/tests/snapshot_test.zig once the snapshot harness lands.

const std = @import("std");
const nimbus = @import("nimbus");

const Container = nimbus.Container;
const Panel = nimbus.Panel;
const Component = nimbus.Component;
const BoxLayout = nimbus.BoxLayout;

/// Build a Panel with min == max == (w, h). Acts as a fixed-size leaf
/// for layout tests so we never need a real widget (which would drag in
/// fonts / GPU). The cross-axis alignment defaults to `.stretch`, but
/// because min == max, the layout cannot actually stretch beyond `h`.
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

test "horizontal: 3 fixed-size children pack from the left" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.horizontal());

    const l1 = try leaf(a, 50, 30);
    const l2 = try leaf(a, 80, 40);
    const l3 = try leaf(a, 60, 25);
    try root.add(&l1.container.component);
    try root.add(&l2.container.component);
    try root.add(&l3.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 100 });
    root.doLayout();

    // Each child takes its min/max width on the main axis. Cross axis
    // collapses to max=h (stretch clamped). Pack-left → x cumulates.
    try expectBounds(&l1.container.component,   0, 0, 50, 30);
    try expectBounds(&l2.container.component,  50, 0, 80, 40);
    try expectBounds(&l3.container.component, 130, 0, 60, 25);
}

test "horizontal: single grow child eats leftover space" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.horizontal());

    const left = try leaf(a, 40, 30);
    // Middle: min width 20, but allow it to grow (relax the max we get
    // from `leaf` so distributable space isn't clamped away).
    const mid = try leaf(a, 20, 30);
    mid.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = 30 });
    mid.container.component.setGrowX(1);
    const right = try leaf(a, 40, 30);

    try root.add(&left.container.component);
    try root.add(&mid.container.component);
    try root.add(&right.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 300, .height = 50 });
    root.doLayout();

    // sum_min = 40 + 20 + 40 = 100, excess = 200 → all goes to `mid`.
    try expectBounds(&left.container.component,   0, 0,  40, 30);
    try expectBounds(&mid.container.component,   40, 0, 220, 30);
    try expectBounds(&right.container.component, 260, 0,  40, 30);
}

test "horizontal: grow split by weight" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.horizontal());

    // Two growable children with weights 1 and 3.
    const c1 = try leaf(a, 0, 20);
    c1.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = 20 });
    c1.container.component.setGrowX(1);
    const c2 = try leaf(a, 0, 20);
    c2.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = 20 });
    c2.container.component.setGrowX(3);

    try root.add(&c1.container.component);
    try root.add(&c2.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 50 });
    root.doLayout();

    // sum_min = 0, distributable = 400. Split 1:3 → 100 / 300.
    try expectBounds(&c1.container.component,   0, 0, 100, 20);
    try expectBounds(&c2.container.component, 100, 0, 300, 20);
}

test "horizontal: max_size caps grown width" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.horizontal());

    // grow=1 but max_size.width=80 → can't exceed 80 even with leftover.
    const capped = try leaf(a, 20, 25);
    capped.container.component.setMaxSize(.{ .width = 80, .height = 25 });
    capped.container.component.setGrowX(1);
    try root.add(&capped.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 500, .height = 40 });
    root.doLayout();

    try expectBounds(&capped.container.component, 0, 0, 80, 25);
}

test "vertical: 3 fixed-size children pack from the top" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.vertical());

    const l1 = try leaf(a, 100, 20);
    const l2 = try leaf(a,  80, 30);
    const l3 = try leaf(a,  60, 15);
    try root.add(&l1.container.component);
    try root.add(&l2.container.component);
    try root.add(&l3.container.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 200, .height = 300 });
    root.doLayout();

    try expectBounds(&l1.container.component, 0,  0, 100, 20);
    try expectBounds(&l2.container.component, 0, 20,  80, 30);
    try expectBounds(&l3.container.component, 0, 50,  60, 15);
}

test "vertical: cross-axis alignment (start / center / end / stretch)" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.vertical());

    // 4 children, width 40, height 20. Cross axis is x.
    const inline_children = .{
        .{ Component.Alignment.start,   0.0,   },
        .{ Component.Alignment.center,  80.0,  }, // (200-40)/2 = 80
        .{ Component.Alignment.end,     160.0, }, // 200-40
        .{ Component.Alignment.stretch, 0.0,   }, // expands to full width
    };

    var added: [4]*Panel = undefined;
    inline for (inline_children, 0..) |entry, i| {
        const child = try leaf(a, 40, 20);
        // `leaf` pins both min and max — but stretch needs max>=container.
        if (entry[0] == .stretch) {
            child.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = 20 });
        }
        child.container.component.setAlignX(entry[0]);
        try root.add(&child.container.component);
        added[i] = child;
    }

    root.setBounds(.{ .x = 0, .y = 0, .width = 200, .height = 100 });
    root.doLayout();

    // start:   x=0,   width=40
    // center:  x=80,  width=40
    // end:     x=160, width=40
    // stretch: x=0,   width=200
    try expectBounds(&added[0].container.component,   0,  0,  40, 20);
    try expectBounds(&added[1].container.component,  80, 20,  40, 20);
    try expectBounds(&added[2].container.component, 160, 40,  40, 20);
    try expectBounds(&added[3].container.component,   0, 60, 200, 20);
}

test "nested: vertical box with a horizontal row reports correct min size" {
    // This is the regression test for the bug that the empty-Panel-as-margin
    // demo exposed: a nested Container used to report min_size=0, so an
    // outer BoxLayout would collapse it to zero height. With effectiveMinSize
    // wiring the inner row's computed size should now propagate.
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(BoxLayout.vertical());

    const row = try Container.create(a);
    row.setLayout(BoxLayout.horizontal());
    // Don't seed min/max manually — we want effectiveMinSize to do it.
    try row.add(&(try leaf(a, 30, 25)).container.component);
    try row.add(&(try leaf(a, 50, 25)).container.component);
    try root.add(&row.component);

    root.setBounds(.{ .x = 0, .y = 0, .width = 200, .height = 100 });
    root.doLayout();

    // Inner row should be sized as 80 (sum of child widths) × 25 (max
    // child height). Cross axis stretches up to row.effectiveMaxSize().width
    // = sum of child max widths = 30+50 = 80, so the row collapses to 80.
    try expectBounds(&row.component, 0, 0, 80, 25);
}
