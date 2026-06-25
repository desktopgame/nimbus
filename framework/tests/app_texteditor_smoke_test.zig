//! app_texteditor smoke tests over the real app tree.

const std = @import("std");
const nimbus = @import("nimbus");
const app_texteditor = @import("app_texteditor");
const awt = nimbus.awt;

fn quietLog(level: awt.LogLevel, category: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level < awt.c.nmLogLevelWarn) return;
    const tag: []const u8 = if (level == awt.c.nmLogLevelWarn) "WARN" else "ERROR";
    const cat: [*:0]const u8 = category;
    const msg: [*:0]const u8 = message;
    std.debug.print("[{s}] [{s}] {s}\n", .{ tag, std.mem.span(cat), std.mem.span(msg) });
}

fn newApp() !*nimbus.Application {
    awt.setLogCallback(quietLog, null);
    return nimbus.Application.initHeadless(std.testing.allocator, std.testing.io) catch
        return error.SkipZigTest;
}

fn hasRole(node: nimbus.Robot.NodeSnapshot, role: nimbus.Component.Role) bool {
    if (node.role == role) return true;
    for (node.children) |ch| {
        if (hasRole(ch, role)) return true;
    }
    return false;
}

fn hasRoleText(node: nimbus.Robot.NodeSnapshot, role: nimbus.Component.Role, text: []const u8) bool {
    if (node.role == role) {
        if (node.text) |got| {
            if (std.mem.eql(u8, got, text)) return true;
        }
    }
    for (node.children) |ch| {
        if (hasRoleText(ch, role, text)) return true;
    }
    return false;
}

fn containsRect(node: nimbus.Robot.NodeSnapshot, rect: nimbus.Component.Rect, role: nimbus.Component.Role) bool {
    if (node.role == role and
        node.rect.x == rect.x and
        node.rect.y == rect.y and
        node.rect.width == rect.width and
        node.rect.height == rect.height)
    {
        return true;
    }
    for (node.children) |ch| {
        if (containsRect(ch, rect, role)) return true;
    }
    return false;
}

fn absoluteRect(component: *const nimbus.Component) nimbus.Component.Rect {
    const bounds = component.getBounds();
    const origin = component.absoluteOriginInWindow();
    return .{
        .x = origin.x,
        .y = origin.y,
        .width = bounds.width,
        .height = bounds.height,
    };
}

test "app_texteditor smoke: shell regions appear and File menu opens" {
    const gpa = std.testing.allocator;
    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.build(app, frame, gpa);
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    var driver = nimbus.Driver{ .robot = &robot };
    robot.pump();

    const tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, tree);
    try std.testing.expect(hasRole(tree, .menu_bar));
    try std.testing.expect(containsRect(tree, absoluteRect(editor.toolbar.asComponent()), .panel));
    try std.testing.expect(hasRole(tree, .scroll_pane));
    try std.testing.expect(hasRole(tree, .text_area));
    try std.testing.expect(containsRect(tree, absoluteRect(editor.status.asComponent()), .panel));
    try std.testing.expect(hasRoleText(tree, .label, "Ln 1, Col 1"));
    try std.testing.expect(hasRoleText(tree, .label, "untitled"));
    try std.testing.expect(hasRoleText(tree, .label, "UTF-8"));
    try std.testing.expect(hasRoleText(tree, .label, "LF"));

    try driver.clickOn(.{ .role = .menu, .text = "File" });
    robot.pump();

    const menu_tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, menu_tree);
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "New"));
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Open"));
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Save"));
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Save As"));
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Exit"));
}

test "app_texteditor smoke: View menu exposes Word Wrap checkbox" {
    const gpa = std.testing.allocator;
    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.build(app, frame, gpa);
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    var driver = nimbus.Driver{ .robot = &robot };
    robot.pump();

    try driver.clickOn(.{ .role = .menu, .text = "View" });
    robot.pump();

    const tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, tree);
    try std.testing.expect(hasRoleText(tree, .checkbox_menu_item, "Word Wrap"));
}
