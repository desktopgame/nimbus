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

const MemoryFileIo = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,

    const File = struct {
        path: []u8,
        data: []u8,
    };

    fn init(allocator: std.mem.Allocator) MemoryFileIo {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MemoryFileIo) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.data);
        }
        self.files.deinit(self.allocator);
    }

    fn io(self: *MemoryFileIo) app_texteditor.FileIo {
        return .{ .vtable = &vtable, .user_data = self };
    }

    fn put(self: *MemoryFileIo, path: []const u8, data: []const u8) !void {
        try writeAll(self, path, data);
    }

    fn get(self: *MemoryFileIo, path: []const u8) ?[]const u8 {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) return file.data;
        }
        return null;
    }

    fn readAll(user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *MemoryFileIo = @ptrCast(@alignCast(user_data));
        const data = self.get(path) orelse return error.FileNotFound;
        return try allocator.dupe(u8, data);
    }

    fn writeAll(user_data: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *MemoryFileIo = @ptrCast(@alignCast(user_data));
        for (self.files.items) |*file| {
            if (std.mem.eql(u8, file.path, path)) {
                const next = try self.allocator.dupe(u8, bytes);
                self.allocator.free(file.data);
                file.data = next;
                return;
            }
        }
        try self.files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .data = try self.allocator.dupe(u8, bytes),
        });
    }

    const vtable = app_texteditor.FileIo.VTable{
        .readAll = readAll,
        .writeAll = writeAll,
    };
};

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

test "app_texteditor logic: eol expansion and dirty comparison" {
    try std.testing.expectEqual(app_texteditor.Eol.lf, app_texteditor.detectEol("abc"));
    try std.testing.expectEqual(app_texteditor.Eol.lf, app_texteditor.detectEol("a\nb"));
    try std.testing.expectEqual(app_texteditor.Eol.crlf, app_texteditor.detectEol("a\r\nb"));
    try std.testing.expectEqual(app_texteditor.Eol.crlf, app_texteditor.detectEol("a\r\nb\nc"));

    const lf = try app_texteditor.expandForEol(std.testing.allocator, "a\nb", .lf);
    defer std.testing.allocator.free(lf);
    try std.testing.expectEqualStrings("a\nb", lf);

    const crlf = try app_texteditor.expandForEol(std.testing.allocator, "a\nb\n", .crlf);
    defer std.testing.allocator.free(crlf);
    try std.testing.expectEqualStrings("a\r\nb\r\n", crlf);

    try std.testing.expect(!app_texteditor.isDirty("same", "same"));
    try std.testing.expect(app_texteditor.isDirty("changed", "same"));
}

test "app_texteditor file io: edit save open and dirty baseline" {
    const gpa = std.testing.allocator;
    var mem = MemoryFileIo.init(gpa);
    defer mem.deinit();
    try mem.put("/docs/existing.txt", "one\r\ntwo");

    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.buildWithOptions(app, frame, gpa, .{ .io = std.testing.io, .file_io = mem.io() });
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    try std.testing.expect(editor.openPathForTest("/docs/existing.txt"));
    try std.testing.expectEqualStrings("one\ntwo", editor.text_area.getText());
    try std.testing.expectEqual(app_texteditor.Eol.crlf, editor.eolForTest());
    try std.testing.expect(!editor.dirtyForTest());

    robot.click(200, 70, .left);
    robot.typeText("!");
    robot.pump();
    try std.testing.expect(editor.dirtyForTest());

    editor.text_area.undo();
    try std.testing.expect(!editor.dirtyForTest());

    robot.typeText("?");
    robot.pump();
    try std.testing.expect(editor.dirtyForTest());
    try std.testing.expect(editor.saveToPathForTest("/docs/saved.txt"));
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expectEqualStrings("one?\r\ntwo", mem.get("/docs/saved.txt") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("/docs/saved.txt", editor.pathForTest() orelse return error.TestUnexpectedResult);

    editor.newDocumentForTest();
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expectEqual(app_texteditor.Eol.lf, editor.eolForTest());
    try std.testing.expectEqualStrings("", editor.text_area.getText());
}

test "app_texteditor edit menu: cut and undo use TextArea public actions" {
    const gpa = std.testing.allocator;
    var mem = MemoryFileIo.init(gpa);
    defer mem.deinit();

    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.buildWithOptions(app, frame, gpa, .{ .io = std.testing.io, .file_io = mem.io() });
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    var driver = nimbus.Driver{ .robot = &robot };
    robot.pump();

    robot.click(200, 70, .left);
    robot.typeText("abc");
    robot.pump();
    editor.text_area.selectAll();

    try driver.clickOn(.{ .role = .menu, .text = "Edit" });
    robot.pump();
    try driver.clickOn(.{ .role = .menu_item, .text = "Cut" });
    robot.pump();
    try std.testing.expectEqualStrings("", editor.text_area.getText());

    try driver.clickOn(.{ .role = .menu, .text = "Edit" });
    robot.pump();
    try driver.clickOn(.{ .role = .menu_item, .text = "Undo" });
    robot.pump();
    try std.testing.expectEqualStrings("abc", editor.text_area.getText());
}

test "app_texteditor unsaved prompt: discard cancel and save branches" {
    const gpa = std.testing.allocator;
    var mem = MemoryFileIo.init(gpa);
    defer mem.deinit();
    try mem.put("/docs/current.txt", "old");

    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.buildWithOptions(app, frame, gpa, .{ .io = std.testing.io, .file_io = mem.io() });
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    try std.testing.expect(editor.openPathForTest("/docs/current.txt"));
    try editor.text_area.setText("old dirty");
    try std.testing.expect(editor.dirtyForTest());

    editor.newDocumentWithUnsavedResultForTest(.cancel);
    try std.testing.expect(editor.dirtyForTest());
    try std.testing.expectEqualStrings("old dirty", editor.text_area.getText());

    editor.newDocumentWithUnsavedResultForTest(@enumFromInt(3));
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expectEqualStrings("", editor.text_area.getText());

    try std.testing.expect(editor.openPathForTest("/docs/current.txt"));
    try editor.text_area.setText("old saved");
    editor.newDocumentWithUnsavedResultForTest(.ok);
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expectEqualStrings("old saved", mem.get("/docs/current.txt") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("", editor.text_area.getText());
}
