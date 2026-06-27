//! app_texteditor smoke tests over the real app tree.

const std = @import("std");
const builtin = @import("builtin");
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

fn commandMods() awt.Event.Modifiers {
    var mods = awt.Event.Modifiers{};
    if (builtin.os.tag == .macos) {
        mods.meta = true;
    } else {
        mods.ctrl = true;
    }
    return mods;
}

fn pressKey(robot: *nimbus.Robot, code: awt.Event.KeyCode, mods: awt.Event.Modifiers) void {
    robot.keyDown(code, mods);
    robot.keyUp(code, mods);
}

fn expectMenuMnemonic(menu: *nimbus.Menu, mnemonic: u8, index: usize) !void {
    try std.testing.expectEqual(mnemonic, menu.component.mnemonic.?);
    try std.testing.expectEqual(index, menu.mnemonic_index.?);
}

fn expectItemMnemonic(item: *nimbus.MenuItem, mnemonic: u8, index: usize) !void {
    try std.testing.expectEqual(mnemonic, item.component.mnemonic.?);
    try std.testing.expectEqual(index, item.mnemonic_index.?);
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
    try std.testing.expect(hasRoleText(tree, .button, "New"));
    try std.testing.expect(hasRoleText(tree, .button, "Open"));
    try std.testing.expect(hasRoleText(tree, .button, "Save"));
    try std.testing.expect(hasRoleText(tree, .button, "Undo"));
    try std.testing.expect(hasRoleText(tree, .button, "Redo"));

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

test "app_texteditor mnemonics: menu bar and items are wired" {
    const gpa = std.testing.allocator;
    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.build(app, frame, gpa);
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    const menu_bar = frame.getMenuBar().?;
    const file = menu_bar.at(0).?;
    const edit = menu_bar.at(1).?;
    const view = menu_bar.at(2).?;

    try expectMenuMnemonic(file, 'f', 0);
    try expectMenuMnemonic(edit, 'e', 0);
    try expectMenuMnemonic(view, 'v', 0);

    try expectItemMnemonic(editor.new_action.item.?, 'n', 0);
    try expectItemMnemonic(editor.open_action.item.?, 'o', 0);
    try expectItemMnemonic(editor.save_action.item.?, 's', 0);
    try expectItemMnemonic(editor.save_as_action.item.?, 'a', 1);
    try expectItemMnemonic(editor.exit_action.item.?, 'x', 1);

    try expectItemMnemonic(editor.undo_action.item.?, 'u', 0);
    try expectItemMnemonic(editor.redo_action.item.?, 'r', 0);
    try expectItemMnemonic(editor.cut_action.item.?, 't', 2);
    try expectItemMnemonic(editor.copy_action.item.?, 'c', 0);
    try expectItemMnemonic(editor.paste_action.item.?, 'p', 0);
    try expectItemMnemonic(editor.select_all_action.item.?, 'a', 7);

    try std.testing.expectEqual('w', editor.word_wrap_action.check_item.?.component.mnemonic.?);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();
    robot.keyDown(.f, .{ .alt = true });
    robot.pump();

    try std.testing.expect(file.open);
    try std.testing.expect(editor.new_action.item.?.getModel().isRollover());
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

test "app_texteditor stage3: status wrap and dynamic action state update" {
    const gpa = std.testing.allocator;
    var mem = MemoryFileIo.init(gpa);
    defer mem.deinit();
    try mem.put("/docs/crlf.txt", "one\r\ntwo");

    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.buildWithOptions(app, frame, gpa, .{ .io = std.testing.io, .file_io = mem.io() });
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    var driver = nimbus.Driver{ .robot = &robot };
    robot.pump();

    try std.testing.expect(!editor.actionMenuEnabledForTest(.undo));
    try std.testing.expectEqual(false, editor.actionButtonEnabledForTest(.undo).?);
    try std.testing.expect(!editor.actionMenuEnabledForTest(.cut));
    try std.testing.expect(!editor.actionMenuEnabledForTest(.copy));
    try std.testing.expect(editor.actionMenuEnabledForTest(.paste));

    try std.testing.expect(editor.openPathForTest("/docs/crlf.txt"));
    try std.testing.expectEqualStrings("crlf.txt", editor.status_name.getText());
    try std.testing.expectEqualStrings("CRLF", editor.status_eol.getText());
    try std.testing.expectEqualStrings("UTF-8", editor.status_encoding.getText());
    try std.testing.expectEqualStrings("Ln 2, Col 4", editor.status_line_col.getText());

    robot.click(20, 50, .left);
    robot.pump();
    try std.testing.expectEqualStrings("Ln 1, Col 1", editor.status_line_col.getText());

    try std.testing.expect(!editor.text_area.getLineWrap());
    try std.testing.expect(!editor.wordWrapCheckedForTest());
    try driver.clickOn(.{ .role = .menu, .text = "View" });
    robot.pump();
    try driver.clickOn(.{ .role = .checkbox_menu_item, .text = "Word Wrap" });
    robot.pump();
    try std.testing.expect(editor.text_area.getLineWrap());
    try std.testing.expect(editor.wordWrapCheckedForTest());

    robot.click(200, 70, .left);
    robot.typeText("abc");
    robot.pump();
    try std.testing.expect(editor.actionMenuEnabledForTest(.undo));
    try std.testing.expectEqual(true, editor.actionButtonEnabledForTest(.undo).?);
    try std.testing.expect(!editor.actionMenuEnabledForTest(.cut));
    try std.testing.expect(!editor.actionMenuEnabledForTest(.copy));

    editor.text_area.selectAll();
    try std.testing.expect(editor.actionMenuEnabledForTest(.cut));
    try std.testing.expect(editor.actionMenuEnabledForTest(.copy));
}

test "app_texteditor stage4: eol edge cases and multibyte status" {
    const gpa = std.testing.allocator;
    var mem = MemoryFileIo.init(gpa);
    defer mem.deinit();
    try mem.put("/docs/empty.txt", "");
    try mem.put("/docs/lf.txt", "one\ntwo");
    try mem.put("/docs/noeol.txt", "tail");
    try mem.put("/docs/crlf.txt", "a\r\nb");

    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.buildWithOptions(app, frame, gpa, .{ .io = std.testing.io, .file_io = mem.io() });
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    try std.testing.expect(editor.openPathForTest("/docs/lf.txt"));
    try std.testing.expectEqualStrings("LF", editor.status_eol.getText());
    try std.testing.expectEqualStrings("lf.txt", editor.status_name.getText());
    try std.testing.expect(!editor.dirtyForTest());

    editor.newDocumentForTest();
    try std.testing.expectEqualStrings("LF", editor.status_eol.getText());
    try std.testing.expectEqualStrings("untitled", editor.status_name.getText());
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expect(editor.pathForTest() == null);
    try editor.text_area.setText("untitled body");
    try std.testing.expect(editor.dirtyForTest());
    try std.testing.expect(editor.saveToPathForTest("/docs/untitled.txt"));
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expectEqualStrings("/docs/untitled.txt", editor.pathForTest() orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("untitled body", mem.get("/docs/untitled.txt") orelse return error.TestUnexpectedResult);

    try std.testing.expect(editor.openPathForTest("/docs/empty.txt"));
    try std.testing.expectEqualStrings("", editor.text_area.getText());
    try std.testing.expectEqualStrings("LF", editor.status_eol.getText());
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expect(editor.saveToPathForTest("/docs/empty_saved.txt"));
    try std.testing.expectEqualStrings("", mem.get("/docs/empty_saved.txt") orelse return error.TestUnexpectedResult);

    try std.testing.expect(editor.openPathForTest("/docs/noeol.txt"));
    try std.testing.expectEqualStrings("tail", editor.text_area.getText());
    try std.testing.expect(editor.saveToPathForTest("/docs/noeol_saved.txt"));
    try std.testing.expectEqualStrings("tail", mem.get("/docs/noeol_saved.txt") orelse return error.TestUnexpectedResult);

    try std.testing.expect(editor.openPathForTest("/docs/crlf.txt"));
    try std.testing.expect(editor.saveToPathForTest("/docs/crlf_saved.txt"));
    try std.testing.expectEqualStrings("a\r\nb", mem.get("/docs/crlf_saved.txt") orelse return error.TestUnexpectedResult);

    try editor.text_area.setText("x\n\u{3042}\u{1F44D}z");
    try std.testing.expectEqualStrings("Ln 2, Col 4", editor.status_line_col.getText());
}

test "app_texteditor stage4: accelerators route without duplicate edit actions" {
    const gpa = std.testing.allocator;
    var mem = MemoryFileIo.init(gpa);
    defer mem.deinit();
    try mem.put("/docs/shortcut.txt", "base");

    const app = try newApp();
    const frame = try app.frameHeadless("texteditor", 760, 520);
    const editor = try app_texteditor.buildWithOptions(app, frame, gpa, .{ .io = std.testing.io, .file_io = mem.io() });
    defer editor.deinitModel(gpa);
    defer app.deinit();
    defer editor.deinitUi();

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    robot.click(200, 70, .left);
    robot.typeText("a");
    robot.pump();
    pressKey(&robot, .arrow_left, .{});
    pressKey(&robot, .arrow_right, .{});
    robot.typeText("b");
    robot.pump();
    try std.testing.expectEqualStrings("ab", editor.text_area.getText());

    const cmd = commandMods();
    pressKey(&robot, .z, cmd);
    robot.pump();
    try std.testing.expectEqualStrings("a", editor.text_area.getText());
    try std.testing.expect(editor.actionMenuEnabledForTest(.redo));
    try std.testing.expectEqual(true, editor.actionButtonEnabledForTest(.redo).?);

    pressKey(&robot, .y, cmd);
    robot.pump();
    try std.testing.expectEqualStrings("ab", editor.text_area.getText());
    try std.testing.expect(!editor.actionMenuEnabledForTest(.redo));
    try std.testing.expectEqual(false, editor.actionButtonEnabledForTest(.redo).?);

    try std.testing.expect(editor.openPathForTest("/docs/shortcut.txt"));
    robot.click(200, 70, .left);
    robot.typeText("!");
    robot.pump();
    try std.testing.expect(editor.dirtyForTest());
    pressKey(&robot, .s, cmd);
    robot.pump();
    try std.testing.expect(!editor.dirtyForTest());
    try std.testing.expectEqualStrings("base!", mem.get("/docs/shortcut.txt") orelse return error.TestUnexpectedResult);
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
