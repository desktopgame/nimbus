//! Semantic UI driver layered on top of Robot. See `framework/doc/robot.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const Robot = @import("Robot.zig");
const Application = @import("Application.zig");

pub const QueryError = error{ NotFound, Ambiguous };

pub const Query = struct {
    role: ?Component.Role = null,
    text: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

robot: *Robot,

pub fn find(self: *@This(), q: Query) QueryError!*Component {
    return findFromRoot(&self.robot.window.container.component, q);
}

fn findFromRoot(root: *Component, q: Query) QueryError!*Component {
    var found: ?*Component = null;
    return (try findInSubtree(root, q, &found)) orelse error.NotFound;
}

pub fn clickOn(self: *@This(), q: Query) QueryError!void {
    const c = try self.find(q);
    const origin = c.absoluteOriginInWindow();
    const cx = origin.x + c.size.width / 2;
    const cy = origin.y + c.size.height / 2;
    self.robot.click(cx, cy, .left);
}

fn findInSubtree(c: *Component, q: Query, found: *?*Component) QueryError!?*Component {
    // Keep this traversal in lockstep with Robot.buildNode: the searched live
    // tree is exactly the snapshotTree container subtree, in child paint order.
    if (matches(c, q)) {
        if (found.* != null) return error.Ambiguous;
        found.* = c;
    }

    if (c.container) |cont| {
        for (cont.children.items) |elem| {
            _ = try findInSubtree(elem.component, q, found);
        }
    }

    return found.*;
}

fn matches(c: *const Component, q: Query) bool {
    if (q.role) |role| {
        if (c.role != role) return false;
    }
    if (q.text) |text| {
        const a = c.a11y orelse return false;
        const got = a.name(c) orelse return false;
        if (!std.mem.eql(u8, got, text)) return false;
    }
    if (q.name) |name| {
        const got = c.name orelse return false;
        if (!std.mem.eql(u8, got, name)) return false;
    }
    return true;
}

test "headless driver: clickOn button fires action by role and text" {
    const gpa = std.testing.allocator;
    const ActionEvent = @import("listener.zig").ActionEvent;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 200, 120);
    frame.window.container.setLayout(null);

    const Ctx = struct { saved: bool = false };
    var ctx: Ctx = .{};
    const btn = try app.button("Save");
    btn.component.setBounds(.{ .x = 10, .y = 10, .width = 80, .height = 30 });
    try btn.getModel().addActionListener(Ctx, struct {
        fn f(c: *Ctx, _: *const ActionEvent) void {
            c.saved = true;
        }
    }.f, &ctx);
    try frame.window.add(&btn.component);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try std.testing.expect(!ctx.saved);
    try driver.clickOn(.{ .role = .button, .text = "Save" });
    robot.pump();
    try std.testing.expect(ctx.saved);
}

test "headless driver: find button by role and text" {
    const gpa = std.testing.allocator;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 200, 120);
    frame.window.container.setLayout(null);

    const btn = try app.button("Go");
    btn.component.setBounds(.{ .x = 10, .y = 10, .width = 80, .height = 30 });
    try frame.window.add(&btn.component);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try std.testing.expectEqual(&btn.component, try driver.find(.{ .role = .button, .text = "Go" }));
}

test "headless driver: find reports NotFound" {
    const gpa = std.testing.allocator;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 200, 120);
    frame.window.container.setLayout(null);

    const btn = try app.button("Go");
    btn.component.setBounds(.{ .x = 10, .y = 10, .width = 80, .height = 30 });
    try frame.window.add(&btn.component);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try std.testing.expectError(error.NotFound, driver.find(.{ .role = .button, .text = "Missing" }));
}

test "headless driver: find reports Ambiguous" {
    const gpa = std.testing.allocator;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 200, 120);
    frame.window.container.setLayout(null);

    const first = try app.button("Go");
    first.component.setBounds(.{ .x = 10, .y = 10, .width = 80, .height = 30 });
    try frame.window.add(&first.component);

    const second = try app.button("Go");
    second.component.setBounds(.{ .x = 100, .y = 10, .width = 80, .height = 30 });
    try frame.window.add(&second.component);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try std.testing.expectError(error.Ambiguous, driver.find(.{ .role = .button, .text = "Go" }));
}

test "headless driver: text field content can be found after typing" {
    const gpa = std.testing.allocator;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 320, 120);
    frame.window.container.setLayout(null);

    const field = try app.textField("");
    field.component.setBounds(.{ .x = 10, .y = 10, .width = 200, .height = 30 });
    try frame.window.add(&field.component);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try driver.clickOn(.{ .role = .text_field, .text = "" });
    robot.typeText("hello");
    robot.pump();

    try std.testing.expectEqual(&field.component, try driver.find(.{ .role = .text_field, .text = "hello" }));
}

fn createTestNode(allocator: std.mem.Allocator, role: Component.Role, name: ?[]const u8) !*Container {
    const node = try Container.create(allocator);
    node.component.role = role;
    if (name) |n| {
        node.component.name = try allocator.dupe(u8, n);
    }
    return node;
}

test "driver query core: matches role and name predicates without GPU" {
    const gpa = std.testing.allocator;
    const node = try createTestNode(gpa, .button, "save");
    defer node.component.vtable.destroy(&node.component, gpa);

    try std.testing.expect(matches(&node.component, .{ .role = .button }));
    try std.testing.expect(matches(&node.component, .{ .name = "save" }));
    try std.testing.expect(matches(&node.component, .{ .role = .button, .name = "save" }));
    try std.testing.expect(!matches(&node.component, .{ .role = .label }));
    try std.testing.expect(!matches(&node.component, .{ .name = "cancel" }));
}

test "driver query core: findInSubtree returns exactly one match without GPU" {
    const gpa = std.testing.allocator;
    const root = try createTestNode(gpa, .panel, "root");
    defer root.component.vtable.destroy(&root.component, gpa);

    const first = try createTestNode(gpa, .button, "save");
    try root.add(&first.component);
    const second = try createTestNode(gpa, .label, "status");
    try root.add(&second.component);

    try std.testing.expectEqual(&first.component, try findFromRoot(&root.component, .{ .role = .button, .name = "save" }));
}

test "driver query core: findInSubtree reports NotFound without GPU" {
    const gpa = std.testing.allocator;
    const root = try createTestNode(gpa, .panel, "root");
    defer root.component.vtable.destroy(&root.component, gpa);

    const child = try createTestNode(gpa, .button, "save");
    try root.add(&child.component);

    try std.testing.expectError(error.NotFound, findFromRoot(&root.component, .{ .role = .button, .name = "missing" }));
}

test "driver query core: findInSubtree reports Ambiguous for two and three matches without GPU" {
    const gpa = std.testing.allocator;
    const root = try createTestNode(gpa, .panel, "root");
    defer root.component.vtable.destroy(&root.component, gpa);

    const first = try createTestNode(gpa, .button, "dup");
    try root.add(&first.component);
    const second = try createTestNode(gpa, .button, "dup");
    try root.add(&second.component);

    try std.testing.expectError(error.Ambiguous, findFromRoot(&root.component, .{ .role = .button, .name = "dup" }));

    const third = try createTestNode(gpa, .button, "dup");
    try root.add(&third.component);

    try std.testing.expectError(error.Ambiguous, findFromRoot(&root.component, .{ .role = .button, .name = "dup" }));
}

test "driver query core: empty query is ambiguous with multiple nodes without GPU" {
    const gpa = std.testing.allocator;
    const root = try createTestNode(gpa, .panel, "root");
    defer root.component.vtable.destroy(&root.component, gpa);

    const first = try createTestNode(gpa, .button, "first");
    try root.add(&first.component);
    const second = try createTestNode(gpa, .button, "second");
    try root.add(&second.component);

    try std.testing.expectError(error.Ambiguous, findFromRoot(&root.component, .{}));
}
