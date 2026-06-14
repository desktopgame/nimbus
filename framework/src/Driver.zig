//! Semantic UI driver layered on top of Robot. See `framework/doc/robot.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const Robot = @import("Robot.zig");
const Application = @import("Application.zig");

pub const QueryError = error{ NotFound, Ambiguous, OutOfMemory };

pub const Query = struct {
    role: ?Component.Role = null,
    text: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

robot: *Robot,

pub fn find(self: *@This(), q: Query) QueryError!*Component {
    var roots: std.ArrayList(*Component) = .empty;
    defer roots.deinit(self.robot.window.allocator);
    try Robot.automationRoots(self.robot.window, &roots);
    return findFromRoots(roots.items, q);
}

fn findFromRoot(root: *Component, q: Query) QueryError!*Component {
    return findFromRoots(&.{root}, q);
}

fn findFromRoots(roots: []const *Component, q: Query) QueryError!*Component {
    var found: ?*Component = null;
    for (roots) |root| {
        _ = try findInSubtree(root, q, &found);
    }
    return found orelse error.NotFound;
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

    const child_count = c.automationChildCount();
    var i: usize = 0;
    while (i < child_count) : (i += 1) {
        _ = try findInSubtree(c.automationChildAt(i), q, found);
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

test "headless driver: clickOn reaches popup menu item by role and text" {
    const gpa = std.testing.allocator;
    const ActionEvent = @import("listener.zig").ActionEvent;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 240, 160);
    frame.window.container.setLayout(null);

    const Ctx = struct { copied: bool = false };
    var ctx: Ctx = .{};
    const popup = try app.popupMenu();
    defer popup.destroy();
    const copy = try app.menuItem("Copy");
    try copy.getModel().addActionListener(Ctx, struct {
        fn f(c: *Ctx, _: *const ActionEvent) void {
            c.copied = true;
        }
    }.f, &ctx);
    try popup.add(&copy.component);
    try popup.show(&frame.window, 20, 20);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try std.testing.expect(!ctx.copied);
    try driver.clickOn(.{ .role = .menu_item, .text = "Copy" });
    robot.pump();
    try std.testing.expect(ctx.copied);
}

test "headless driver: clickOn reaches menu bar popup item" {
    const gpa = std.testing.allocator;
    const ActionEvent = @import("listener.zig").ActionEvent;

    awt.setLogCallback(Robot.QuietLog.cb, null);
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 260, 160);
    frame.window.container.setLayout(null);

    const Ctx = struct { opened: bool = false };
    var ctx: Ctx = .{};
    const bar = try app.menuBar();
    const file = try app.menu("File");
    const open = try app.menuItem("Open");
    try open.getModel().addActionListener(Ctx, struct {
        fn f(c: *Ctx, _: *const ActionEvent) void {
            c.opened = true;
        }
    }.f, &ctx);
    try file.add(&open.component);
    try bar.add(file);
    try frame.setMenuBar(bar);

    var robot = Robot.init(app, &frame.window);
    var driver = @This(){ .robot = &robot };
    robot.pump();

    try std.testing.expectEqual(&bar.component, try driver.find(.{ .role = .menu_bar }));
    try driver.clickOn(.{ .role = .menu, .text = "File" });
    robot.pump();
    try driver.clickOn(.{ .role = .menu_item, .text = "Open" });
    robot.pump();
    try std.testing.expect(ctx.opened);
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

const plain_vtable = Component.VTable{
    .install = plainInstall,
    .uninstall = plainUninstall,
    .paint = plainPaint,
    .processEvent = plainProcessEvent,
    .destroy = plainDestroy,
};

fn plainInstall(_: *Component) !void {}
fn plainUninstall(_: *Component) void {}
fn plainPaint(_: *Component, _: *awt.Graphics) void {}
fn plainProcessEvent(_: *Component, _: *Component.Event) void {}
fn plainDestroy(_: *Component, _: std.mem.Allocator) void {}

const PlainTreeNode = struct {
    component: Component,
    children: []const *Component,

    fn init(allocator: std.mem.Allocator, role: Component.Role, name: ?[]const u8, children: []const *Component) PlainTreeNode {
        var node = PlainTreeNode{
            .component = Component.init(allocator, &plain_vtable),
            .children = children,
        };
        node.component.role = role;
        node.component.name = name;
        node.component.tree_children = .{ .count = treeChildCount, .at = treeChildAt };
        return node;
    }

    fn treeChildCount(c: *const Component) usize {
        const node: *const PlainTreeNode = @fieldParentPtr("component", c);
        return node.children.len;
    }

    fn treeChildAt(c: *const Component, index: usize) *Component {
        const node: *const PlainTreeNode = @fieldParentPtr("component", c);
        return node.children[index];
    }
};

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

test "driver query core: tree_children facet is traversed without GPU" {
    const gpa = std.testing.allocator;

    var leaf = PlainTreeNode.init(gpa, .menu_item, "copy", &.{});
    const children = [_]*Component{&leaf.component};
    var root = PlainTreeNode.init(gpa, .popup_menu, "popup", &children);

    try std.testing.expectEqual(@as(usize, 1), root.component.automationChildCount());
    try std.testing.expectEqual(&leaf.component, root.component.automationChildAt(0));
    try std.testing.expectEqual(&leaf.component, try findFromRoot(&root.component, .{ .role = .menu_item, .name = "copy" }));
}

test "driver query core: multiple roots aggregate matches without GPU" {
    const gpa = std.testing.allocator;

    var first = PlainTreeNode.init(gpa, .button, "dup", &.{});
    var second = PlainTreeNode.init(gpa, .button, "dup", &.{});
    var unique = PlainTreeNode.init(gpa, .label, "only", &.{});
    const roots = [_]*Component{ &first.component, &second.component, &unique.component };

    try std.testing.expectEqual(&unique.component, try findFromRoots(&roots, .{ .role = .label, .name = "only" }));
    try std.testing.expectError(error.Ambiguous, findFromRoots(&roots, .{ .role = .button, .name = "dup" }));
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
