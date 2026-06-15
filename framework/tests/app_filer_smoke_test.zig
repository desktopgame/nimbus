//! app_filer smoke tests over the real app tree.

const std = @import("std");
const nimbus = @import("nimbus");
const app_filer = @import("app_filer");
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

fn makeFixture() !std.testing.TmpDir {
    var td = std.testing.tmpDir(.{ .iterate = true });
    errdefer td.cleanup();
    try td.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.txt", .data = "alpha" });
    try td.dir.writeFile(std.testing.io, .{ .sub_path = "beta.txt", .data = "beta" });
    try td.dir.createDir(std.testing.io, "sub", .default_dir);
    return td;
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

fn findRoleText(node: *const nimbus.Robot.NodeSnapshot, role: nimbus.Component.Role, text: []const u8) ?*const nimbus.Robot.NodeSnapshot {
    if (node.role == role) {
        if (node.text) |got| {
            if (std.mem.eql(u8, got, text)) return node;
        }
    }
    for (node.children) |*ch| {
        if (findRoleText(ch, role, text)) |found| return found;
    }
    return null;
}

fn findWideRole(node: *const nimbus.Robot.NodeSnapshot, role: nimbus.Component.Role, min_width: f32) ?*const nimbus.Robot.NodeSnapshot {
    var best: ?*const nimbus.Robot.NodeSnapshot = null;
    if (node.role == role and node.rect.width >= min_width) best = node;
    for (node.children) |*ch| {
        if (findWideRole(ch, role, min_width)) |found| {
            if (best == null or found.rect.width > best.?.rect.width) best = found;
        }
    }
    return best;
}

test "app_filer smoke: Driver.clickOn toggles view button" {
    const gpa = std.testing.allocator;
    var td = try makeFixture();
    defer td.cleanup();

    var start_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const start_dir = start_buf[0..try td.dir.realPath(std.testing.io, &start_buf)];

    const app = try newApp();
    const frame = try app.frameHeadless("filer", 760, 520);
    const filer = try app_filer.build(app, &frame.window, gpa, std.testing.io, start_dir, null);
    defer filer.deinitModel(gpa);
    defer app.deinit();
    defer filer.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    var driver = nimbus.Driver{ .robot = &robot };
    robot.pump();

    const tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, tree);
    try std.testing.expect(hasRoleText(tree, .button, "Details"));

    try driver.clickOn(.{ .role = .button, .text = "Details" });
    robot.pump();

    const tree_after = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, tree_after);
    try std.testing.expect(hasRoleText(tree_after, .button, "List"));
}

test "app_filer smoke: open row popup then close window without keeping popup alive" {
    const gpa = std.testing.allocator;
    var td = try makeFixture();
    defer td.cleanup();

    var start_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const start_dir = start_buf[0..try td.dir.realPath(std.testing.io, &start_buf)];

    const app = try newApp();
    const frame = try app.frameHeadless("filer", 760, 520);
    const filer = try app_filer.build(app, &frame.window, gpa, std.testing.io, start_dir, null);
    defer filer.deinitModel(gpa);
    defer app.deinit();
    defer filer.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    const tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, tree);
    const list = findWideRole(&tree, .list, 300) orelse return error.TestUnexpectedResult;
    var file_index: ?usize = null;
    for (filer.entries.items, 0..) |entry, idx| {
        if (!entry.is_dir) {
            file_index = idx;
            break;
        }
    }
    const row_index = file_index orelse return error.TestUnexpectedResult;
    const row_height = filer.list.getRowHeight();
    const cx = list.rect.x + list.rect.width / 2;
    const cy = list.rect.y + (@as(f32, @floatFromInt(row_index)) + 0.5) * row_height;
    robot.click(cx, cy, .right);
    robot.pump();

    const menu_tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, menu_tree);
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Open"));
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Rename"));
    try std.testing.expect(hasRoleText(menu_tree, .menu_item, "Delete"));
    try std.testing.expect(filer.popup.open);

    frame.window.dispose();
    app.tickOnce();

    try std.testing.expect(!filer.popup.open);
}

test "app_filer smoke: background popup creates New Folder" {
    const gpa = std.testing.allocator;
    var td = try makeFixture();
    defer td.cleanup();

    var start_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const start_dir = start_buf[0..try td.dir.realPath(std.testing.io, &start_buf)];

    const app = try newApp();
    const frame = try app.frameHeadless("filer", 760, 520);
    const filer = try app_filer.build(app, &frame.window, gpa, std.testing.io, start_dir, null);
    defer filer.deinitModel(gpa);
    defer app.deinit();
    defer filer.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    var driver = nimbus.Driver{ .robot = &robot };
    robot.pump();

    const tree = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, tree);
    const list = findWideRole(&tree, .list, 300) orelse return error.TestUnexpectedResult;
    robot.click(list.rect.x + list.rect.width - 10, list.rect.y + list.rect.height - 10, .right);
    robot.pump();

    try driver.clickOn(.{ .role = .menu_item, .text = "New Folder" });
    robot.pump();
    robot.pump();

    try td.dir.access(std.testing.io, "New Folder", .{});
}
