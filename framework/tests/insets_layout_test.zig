//! Insets, PaddingLayout, and spacing ownership tests.

const std = @import("std");
const nimbus = @import("nimbus");

const Component = nimbus.Component;
const Container = nimbus.Container;
const Panel = nimbus.Panel;

fn leaf(allocator: std.mem.Allocator, w: f32, h: f32) !*Panel {
    const p = try Panel.create(allocator);
    p.asComponent().setMinSize(.{ .width = w, .height = h });
    p.asComponent().setMaxSize(.{ .width = w, .height = h });
    return p;
}

fn expectSize(size: Component.Size, w: f32, h: f32) !void {
    try std.testing.expectApproxEqAbs(w, size.width, 0.001);
    try std.testing.expectApproxEqAbs(h, size.height, 0.001);
}

fn expectBounds(c: *const Component, x: f32, y: f32, w: f32, h: f32) !void {
    const b = c.getBounds();
    try std.testing.expectApproxEqAbs(x, b.x, 0.001);
    try std.testing.expectApproxEqAbs(y, b.y, 0.001);
    try std.testing.expectApproxEqAbs(w, b.width, 0.001);
    try std.testing.expectApproxEqAbs(h, b.height, 0.001);
}

test "Insets constructors and totals" {
    try std.testing.expectEqual(nimbus.Insets.zero, nimbus.Insets{});
    try std.testing.expectEqual(nimbus.Insets{ .left = 3, .top = 3, .right = 3, .bottom = 3 }, nimbus.Insets.all(3));
    try std.testing.expectEqual(nimbus.Insets{ .left = 4, .top = 2, .right = 4, .bottom = 2 }, nimbus.Insets.symmetric(4, 2));
    try std.testing.expectEqual(@as(f32, 8), nimbus.Insets.symmetric(4, 2).horizontalTotal());
    try std.testing.expectEqual(@as(f32, 4), nimbus.Insets.symmetric(4, 2).verticalTotal());
}

test "PaddingLayout lays out one child inside insets" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(try nimbus.PaddingLayout.create(a, .{ .left = 4, .top = 5, .right = 6, .bottom = 7 }));

    const child = try leaf(a, 20, 10);
    try root.add(child.asComponent());

    root.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 80 });
    root.doLayout();

    try expectBounds(child.asComponent(), 4, 5, 90, 68);
}

test "PaddingLayout clamps negative inner size to zero" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(try nimbus.PaddingLayout.create(a, nimbus.Insets.all(20)));

    const child = try leaf(a, 20, 10);
    try root.add(child.asComponent());

    root.setBounds(.{ .x = 0, .y = 0, .width = 30, .height = 10 });
    root.doLayout();

    try expectBounds(child.asComponent(), 20, 20, 0, 0);
}

test "PaddingLayout computes min and max with insets and handles zero children" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(try nimbus.PaddingLayout.create(a, .{ .left = 1, .top = 2, .right = 3, .bottom = 4 }));

    try expectSize(root.getMinSize(), 4, 6);
    try expectSize(root.getMaxSize(), 4, 6);
    root.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 80 });
    root.doLayout();

    const child = try leaf(a, 20, 10);
    try root.add(child.asComponent());
    try expectSize(root.getMinSize(), 24, 16);
    try expectSize(root.getMaxSize(), 24, 16);
}

test "BoxLayout spacing contributes to min size and child gaps" {
    const a = std.testing.allocator;
    const root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);
    root.setLayout(try nimbus.BoxLayout.horizontalSpaced(a, 7));

    const l1 = try leaf(a, 50, 30);
    const l2 = try leaf(a, 80, 40);
    const l3 = try leaf(a, 60, 25);
    try root.add(l1.asComponent());
    try root.add(l2.asComponent());
    try root.add(l3.asComponent());

    try expectSize(root.getMinSize(), 204, 40);

    root.setBounds(.{ .x = 0, .y = 0, .width = 400, .height = 100 });
    root.doLayout();

    try expectBounds(l1.asComponent(), 0, 0, 50, 30);
    try expectBounds(l2.asComponent(), 57, 0, 80, 40);
    try expectBounds(l3.asComponent(), 144, 0, 60, 25);
}

test "Container owns allocated layouts and ignores singleton layouts" {
    const a = std.testing.allocator;
    {
        const root = try Container.create(a);
        root.setLayout(try nimbus.BoxLayout.verticalSpaced(a, 3));
        root.component.vtable.destroy(&root.component, a);
    }
    {
        const root = try Container.create(a);
        root.setLayout(try nimbus.PaddingLayout.create(a, nimbus.Insets.all(2)));
        root.component.vtable.destroy(&root.component, a);
    }
    {
        const root = try Container.create(a);
        root.setLayout(nimbus.BoxLayout.horizontal());
        root.component.vtable.destroy(&root.component, a);
    }
}

test "Panel keeps content inside border thickness" {
    const a = std.testing.allocator;
    const panel = try Panel.create(a);
    defer panel.asComponent().vtable.destroy(panel.asComponent(), a);

    panel.setBorder(.{
        .thickness = 3,
        .color = nimbus.awt.Graphics.Color.rgb(0, 0, 0),
    });
    panel.asComponent().setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 80 });
    panel.container.doLayout();

    try expectBounds(&panel.asContainer().component, 3, 3, 94, 74);
}
