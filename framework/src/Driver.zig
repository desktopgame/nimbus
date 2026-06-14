//! Semantic UI driver layered on top of Robot. See `framework/doc/robot.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
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
    var found: ?*Component = null;
    return (try findInSubtree(&self.robot.window.container.component, q, &found)) orelse error.NotFound;
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

/// Test-quiet log: drop debug/info chatter, keep warn/error visible.
const QuietLog = struct {
    fn cb(level: awt.LogLevel, category: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        if (level < awt.c.nmLogLevelWarn) return;
        const tag: []const u8 = if (level == awt.c.nmLogLevelWarn) "WARN" else "ERROR";
        const cat: [*:0]const u8 = category;
        const msg: [*:0]const u8 = message;
        std.debug.print("[{s}] [{s}] {s}\n", .{ tag, std.mem.span(cat), std.mem.span(msg) });
    }
};

test "headless driver: clickOn button fires action by role and text" {
    const gpa = std.testing.allocator;
    const ActionEvent = @import("listener.zig").ActionEvent;

    awt.setLogCallback(QuietLog.cb, null);
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

    awt.setLogCallback(QuietLog.cb, null);
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

    awt.setLogCallback(QuietLog.cb, null);
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

    awt.setLogCallback(QuietLog.cb, null);
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

    awt.setLogCallback(QuietLog.cb, null);
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
