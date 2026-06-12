//! Numeric bounds assertions for SplitPane. GPU-free: built from
//! fixed-size Panels (no awt.init / fonts needed), same harness style as
//! box_layout_test.zig. Covers initial placement, clamping, resize_weight
//! distribution and the divider drag (synthesized mouse events).

const std = @import("std");
const nimbus = @import("nimbus");

const Component = nimbus.Component;
const Panel = nimbus.Panel;
const SplitPane = nimbus.SplitPane;

/// Panel with min size (w, h); max stays unbounded so the SplitPane can
/// stretch it on the cross axis.
fn pane(allocator: std.mem.Allocator, w: f32, h: f32) !*Panel {
    const p = try Panel.create(allocator);
    p.container.component.setMinSize(.{ .width = w, .height = h });
    return p;
}

fn expectBounds(c: *const Component, x: f32, y: f32, w: f32, h: f32) !void {
    const b = c.getBounds();
    try std.testing.expectApproxEqAbs(x, b.x, 0.001);
    try std.testing.expectApproxEqAbs(y, b.y, 0.001);
    try std.testing.expectApproxEqAbs(w, b.width, 0.001);
    try std.testing.expectApproxEqAbs(h, b.height, 0.001);
}

fn layoutAt(sp: *SplitPane, w: f32, h: f32) void {
    sp.container.setBounds(.{ .x = 0, .y = 0, .width = w, .height = h });
    sp.container.doLayout();
}

test "horizontal: first opens at its min width, second takes the rest" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutAt(sp, 400, 100);

    // divider_size default 6: first = min(50), divider [50,56), second = rest.
    try expectBounds(sp.getFirst(), 0, 0, 50, 100);
    try expectBounds(sp.getSecond(), 56, 0, 344, 100);
    try std.testing.expectEqual(@as(?f32, 50), sp.getDividerLocation());
}

test "vertical: first opens at its min height, second takes the rest" {
    const a = std.testing.allocator;
    const top = try pane(a, 0, 30);
    const bottom = try pane(a, 0, 20);
    const sp = try SplitPane.create(a, .vertical, &top.container.component, &bottom.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutAt(sp, 200, 300);

    try expectBounds(sp.getFirst(), 0, 0, 200, 30);
    try expectBounds(sp.getSecond(), 0, 36, 200, 264);
}

test "setDividerLocation before first layout is kept and applied" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    sp.setDividerLocation(120); // no size yet → stored raw
    layoutAt(sp, 400, 100);

    try expectBounds(sp.getFirst(), 0, 0, 120, 100);
    try expectBounds(sp.getSecond(), 126, 0, 274, 100);
}

test "setDividerLocation clamps to both panes' min sizes" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutAt(sp, 400, 100);

    // avail = 400 - 6 = 394; valid range = [50, 354].
    sp.setDividerLocation(10);
    try std.testing.expectEqual(@as(?f32, 50), sp.getDividerLocation());
    sp.setDividerLocation(380);
    try std.testing.expectEqual(@as(?f32, 354), sp.getDividerLocation());
}

test "range collapse: first wins its min, second takes the leftover" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 60, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    // avail = 80 - 6 = 74 < 50 + 60: both mins can't hold.
    layoutAt(sp, 80, 100);

    try expectBounds(sp.getFirst(), 0, 0, 50, 100);
    try expectBounds(sp.getSecond(), 56, 0, 24, 100);
}

test "resize_weight 0 (default): first keeps its px size across a resize" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutAt(sp, 400, 100);
    sp.setDividerLocation(120);
    layoutAt(sp, 500, 100); // grow by 100

    try expectBounds(sp.getFirst(), 0, 0, 120, 100);
    try expectBounds(sp.getSecond(), 126, 0, 374, 100);
}

test "resize_weight 1: first absorbs the whole resize delta" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    sp.setResizeWeight(1);
    layoutAt(sp, 400, 100);
    sp.setDividerLocation(120);
    layoutAt(sp, 500, 100);

    try expectBounds(sp.getFirst(), 0, 0, 220, 100);
    try expectBounds(sp.getSecond(), 226, 0, 274, 100);
}

test "resize_weight 0.5: resize delta splits evenly" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    sp.setResizeWeight(0.5);
    layoutAt(sp, 400, 100);
    sp.setDividerLocation(120);
    layoutAt(sp, 500, 100);

    try expectBounds(sp.getFirst(), 0, 0, 170, 100);
    try expectBounds(sp.getSecond(), 176, 0, 324, 100);
}

test "min size: main = first + divider + second, cross = max of both" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 80);
    const right = try pane(a, 40, 120);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    const min = sp.asComponent().effectiveMinSize();
    try std.testing.expectApproxEqAbs(@as(f32, 96), min.width, 0.001); // 50+6+40
    try std.testing.expectApproxEqAbs(@as(f32, 120), min.height, 0.001);
}

test "divider drag: press on the divider, move, release" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutAt(sp, 400, 100);
    const comp = sp.asComponent();

    // Press 2px into the divider strip [50, 56).
    var press = Component.Event{ .payload = .{ .mouse = .{ .x = 52, .y = 50, .action = .press, .button = .left } } };
    comp.vtable.processEvent(comp, &press);
    try std.testing.expect(press.isConsumed());
    try std.testing.expect(press.capture_target != null);

    // Drag right: grab offset 2 → divider leading edge lands at 200 - 2 = 198.
    var move = Component.Event{ .payload = .{ .mouse = .{ .x = 200, .y = 50, .action = .move } } };
    comp.vtable.processEvent(comp, &move);
    try std.testing.expect(move.isConsumed());
    try std.testing.expectEqual(@as(?f32, 198), sp.getDividerLocation());

    var release = Component.Event{ .payload = .{ .mouse = .{ .x = 200, .y = 50, .action = .release, .button = .left } } };
    comp.vtable.processEvent(comp, &release);
    try std.testing.expect(release.isConsumed());

    // After the gesture, a relayout applies the dragged location.
    sp.container.doLayout();
    try expectBounds(sp.getFirst(), 0, 0, 198, 100);
    try expectBounds(sp.getSecond(), 204, 0, 196, 100);
}

test "press outside the divider is not consumed by the split pane" {
    const a = std.testing.allocator;
    const left = try pane(a, 50, 0);
    const right = try pane(a, 40, 0);
    const sp = try SplitPane.create(a, .horizontal, &left.container.component, &right.container.component);
    defer sp.asComponent().vtable.destroy(sp.asComponent(), a);

    layoutAt(sp, 400, 100);
    const comp = sp.asComponent();

    // Panels don't consume presses, so it should pass through unconsumed.
    var press = Component.Event{ .payload = .{ .mouse = .{ .x = 20, .y = 50, .action = .press, .button = .left } } };
    comp.vtable.processEvent(comp, &press);
    try std.testing.expect(!press.isConsumed());
    try std.testing.expect(sp.drag == null);
}
