//! Numeric bounds assertions for TabbedPane. GPU-free: built from fixed-size
//! Panels and never paints or measures tab text, so the font can be undefined.

const std = @import("std");
const nimbus = @import("nimbus");

const Component = nimbus.Component;
const Panel = nimbus.Panel;
const TabbedPane = nimbus.TabbedPane;
const ChangeEvent = nimbus.ChangeEvent;

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

fn layoutAt(tp: *TabbedPane, w: f32, h: f32) void {
    tp.container.setBounds(.{ .x = 0, .y = 0, .width = w, .height = h });
    tp.container.doLayout();
}

fn testTabbedPane(a: std.mem.Allocator) !*TabbedPane {
    return TabbedPane.create(a, .{ .face = undefined, .pixel_size = 14 });
}

test "tabbed pane: zero-tab state is allowed" {
    const a = std.testing.allocator;
    const tp = try testTabbedPane(a);
    defer tp.asComponent().vtable.destroy(tp.asComponent(), a);

    try std.testing.expectEqual(@as(usize, 0), tp.count());
    try std.testing.expectEqual(@as(?usize, null), tp.getSelectedIndex());
    layoutAt(tp, 300, 200);
}

test "tabbed pane: first tab becomes selected and selected content is laid out" {
    const a = std.testing.allocator;
    const tp = try testTabbedPane(a);
    defer tp.asComponent().vtable.destroy(tp.asComponent(), a);

    const one = try pane(a, 50, 20);
    const two = try pane(a, 60, 30);
    try tp.addTab("One", &one.container.component);
    try tp.addTab("Two", &two.container.component);

    try std.testing.expectEqual(@as(usize, 2), tp.count());
    try std.testing.expectEqual(@as(?usize, 0), tp.getSelectedIndex());
    try std.testing.expectEqualStrings("One", tp.getTitleAt(0));
    try std.testing.expect(tp.getContentAt(1) == &two.container.component);

    layoutAt(tp, 300, 200);
    try expectBounds(&one.container.component, 0, 26, 300, 174);
    try expectBounds(&two.container.component, 0, 26, 0, 0);
}

test "tabbed pane: setSelectedIndex clamps and moves content bounds" {
    const a = std.testing.allocator;
    const tp = try testTabbedPane(a);
    defer tp.asComponent().vtable.destroy(tp.asComponent(), a);

    const one = try pane(a, 50, 20);
    const two = try pane(a, 60, 30);
    try tp.addTab("One", &one.container.component);
    try tp.addTab("Two", &two.container.component);

    tp.setSelectedIndex(99);
    try std.testing.expectEqual(@as(?usize, 1), tp.getSelectedIndex());

    layoutAt(tp, 300, 200);
    try expectBounds(&one.container.component, 0, 26, 0, 0);
    try expectBounds(&two.container.component, 0, 26, 300, 174);
}

test "tabbed pane: removeTab reclamps selection to the following tab" {
    const a = std.testing.allocator;
    const tp = try testTabbedPane(a);
    defer tp.asComponent().vtable.destroy(tp.asComponent(), a);

    const one = try pane(a, 50, 20);
    const two = try pane(a, 60, 30);
    const three = try pane(a, 70, 40);
    try tp.addTab("One", &one.container.component);
    try tp.addTab("Two", &two.container.component);
    try tp.addTab("Three", &three.container.component);

    tp.setSelectedIndex(1);
    tp.removeTab(1);

    try std.testing.expectEqual(@as(usize, 2), tp.count());
    try std.testing.expectEqual(@as(?usize, 1), tp.getSelectedIndex());
    try std.testing.expectEqualStrings("Three", tp.getTitleAt(1));

    layoutAt(tp, 300, 200);
    try expectBounds(&one.container.component, 0, 26, 0, 0);
    try expectBounds(&three.container.component, 0, 26, 300, 174);
}

test "tabbed pane: removing the last tab clears selection" {
    const a = std.testing.allocator;
    const tp = try testTabbedPane(a);
    defer tp.asComponent().vtable.destroy(tp.asComponent(), a);

    const one = try pane(a, 50, 20);
    try tp.addTab("One", &one.container.component);
    tp.removeTab(0);

    try std.testing.expectEqual(@as(usize, 0), tp.count());
    try std.testing.expectEqual(@as(?usize, null), tp.getSelectedIndex());
}

test "tabbed pane: selection changes fire change listeners" {
    const a = std.testing.allocator;
    const tp = try testTabbedPane(a);
    defer tp.asComponent().vtable.destroy(tp.asComponent(), a);

    const Ctx = struct {
        fired: u32 = 0,
        fn onChange(ud: *anyopaque, _: *const ChangeEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ud));
            self.fired += 1;
        }
    };
    var ctx: Ctx = .{};
    var l = TabbedPane.ChangeListener{ .fn_ptr = Ctx.onChange, .user_data = @ptrCast(&ctx) };
    tp.addChangeListener(&l);

    const one = try pane(a, 50, 20);
    const two = try pane(a, 60, 30);
    try tp.addTab("One", &one.container.component);
    try tp.addTab("Two", &two.container.component);
    tp.setSelectedIndex(1);
    tp.removeTab(0);

    try std.testing.expectEqual(@as(u32, 3), ctx.fired);
}
