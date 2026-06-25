//! app_texteditor: dogfooding text editor shell (stage 1).
//!
//! Usage:
//!     zig build run-app_texteditor

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const ActionEvent = nimbus.ActionEvent;

const ICON_SIZE = nimbus.Component.Size{ .width = 18, .height = 18 };

const Handler = *const fn (*Editor) void;
const DISCARD_RESULT: nimbus.Dialog.Result = @enumFromInt(3);

pub const Eol = enum { lf, crlf };

pub const FileIo = struct {
    vtable: *const VTable,
    user_data: *anyopaque,

    pub const VTable = struct {
        readAll: *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
        writeAll: *const fn (user_data: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
    };

    pub fn readAll(self: FileIo, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.vtable.readAll(self.user_data, allocator, path);
    }

    pub fn writeAll(self: FileIo, path: []const u8, bytes: []const u8) !void {
        try self.vtable.writeAll(self.user_data, path, bytes);
    }
};

pub const OsFileIoState = struct {
    io: std.Io,
};

pub fn osFileIo(state: *OsFileIoState) FileIo {
    return .{ .vtable = &os_file_io_vtable, .user_data = state };
}

const os_file_io_vtable = FileIo.VTable{
    .readAll = osReadAll,
    .writeAll = osWriteAll,
};

fn osReadAll(user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const state: *OsFileIoState = @ptrCast(@alignCast(user_data));
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(state.io, dir_path, .{});
    defer dir.close(state.io);
    return try dir.readFileAlloc(state.io, base, allocator, .unlimited);
}

fn osWriteAll(user_data: *anyopaque, path: []const u8, bytes: []const u8) !void {
    const state: *OsFileIoState = @ptrCast(@alignCast(user_data));
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(state.io, dir_path, .{});
    defer dir.close(state.io);
    try dir.writeFile(state.io, .{ .sub_path = base, .data = bytes });
}

pub fn detectEol(bytes: []const u8) Eol {
    if (std.mem.indexOf(u8, bytes, "\r\n") != null) return .crlf;
    return .lf;
}

pub fn expandForEol(allocator: std.mem.Allocator, text: []const u8, eol: Eol) ![]u8 {
    if (eol == .lf) return try allocator.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len + std.mem.count(u8, text, "\n"));
    for (text) |b| {
        if (b == '\n') {
            out.appendAssumeCapacity('\r');
            out.appendAssumeCapacity('\n');
        } else {
            out.appendAssumeCapacity(b);
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn isDirty(current: []const u8, baseline: []const u8) bool {
    return !std.mem.eql(u8, current, baseline);
}

pub const BuildOptions = struct {
    io: std.Io,
    file_io: ?FileIo = null,
    chooser_source: ?nimbus.FileChooserDirSource = null,
};

const Action = struct {
    editor: *Editor,
    handler: Handler,
    enabled: bool = true,
    name: []const u8,
    icon: ?nimbus.lucide.Icon = null,
    accelerator: ?nimbus.KeyStroke = null,
    item: ?*nimbus.MenuItem = null,
    check_item: ?*nimbus.CheckBoxMenuItem = null,
    button: ?*nimbus.Button = null,

    fn init(editor: *Editor, name: []const u8, icon: ?nimbus.lucide.Icon, accelerator: ?nimbus.KeyStroke, handler: Handler) Action {
        return .{
            .editor = editor,
            .handler = handler,
            .name = name,
            .icon = icon,
            .accelerator = accelerator,
        };
    }

    fn bindMenuItem(self: *Action, app: *nimbus.Application, menu: *nimbus.Menu) !void {
        const item = try app.menuItem(self.name);
        if (self.icon) |icon| item.setIcon(try app.icon(icon));
        if (self.accelerator) |accel| item.setAccelerator(accel);
        try item.getModel().addActionListener(Action, Action.onAction, self);
        try menu.add(&item.component);
        self.item = item;
        self.setEnabled(self.enabled);
    }

    fn bindCheckBoxMenuItem(self: *Action, app: *nimbus.Application, menu: *nimbus.Menu) !void {
        const item = try app.checkBoxMenuItem(self.name);
        try item.getModel().addActionListener(Action, Action.onAction, self);
        try menu.add(&item.component);
        self.check_item = item;
        self.setEnabled(self.enabled);
    }

    fn bindToolButton(self: *Action, app: *nimbus.Application, toolbar: *nimbus.Panel) !void {
        const button = try app.button("");
        if (self.icon) |icon| button.setIcon(try app.icon(icon));
        button.setIconSize(ICON_SIZE);
        try button.getModel().addActionListener(Action, Action.onAction, self);
        try toolbar.asContainer().add(&button.component);
        self.button = button;
        self.setEnabled(self.enabled);
    }

    fn setEnabled(self: *Action, enabled: bool) void {
        self.enabled = enabled;
        if (self.item) |item| item.getModel().setEnabled(enabled);
        if (self.check_item) |item| item.getModel().button.setEnabled(enabled);
        if (self.button) |button| button.getModel().setEnabled(enabled);
    }

    fn onAction(self: *Action, _: *const ActionEvent) void {
        if (!self.enabled) return;
        self.handler(self.editor);
    }
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    app: *nimbus.Application,
    frame: *nimbus.Frame,
    file_io_state: OsFileIoState,
    file_io: FileIo,
    chooser: *nimbus.FileChooser = undefined,
    unsaved_dialog: *nimbus.Dialog = undefined,
    unsaved_message: *nimbus.Label = undefined,
    path: ?[]u8 = null,
    baseline: []u8 = &.{},
    eol: Eol = .lf,
    dirty: bool = false,
    toolbar: *nimbus.Panel = undefined,
    text_area: *nimbus.TextArea = undefined,
    scroll_pane: *nimbus.ScrollPane = undefined,
    status: *nimbus.Panel = undefined,
    status_line_col: *nimbus.Label = undefined,
    status_name: *nimbus.Label = undefined,
    status_encoding: *nimbus.Label = undefined,
    status_eol: *nimbus.Label = undefined,
    new_action: Action = undefined,
    open_action: Action = undefined,
    save_action: Action = undefined,
    save_as_action: Action = undefined,
    exit_action: Action = undefined,
    undo_action: Action = undefined,
    redo_action: Action = undefined,
    cut_action: Action = undefined,
    copy_action: Action = undefined,
    paste_action: Action = undefined,
    select_all_action: Action = undefined,
    word_wrap_action: Action = undefined,

    pub fn deinitModel(self: *Editor, gpa: std.mem.Allocator) void {
        if (self.path) |p| self.allocator.free(p);
        self.allocator.free(self.baseline);
        gpa.destroy(self);
    }

    pub fn deinitUi(self: *Editor) void {
        self.chooser.destroy();
        self.unsaved_dialog.destroy();
    }

    fn initActions(self: *Editor) void {
        self.new_action = Action.init(self, "New", .file_plus, nimbus.KeyStroke.cmd(.n), onNew);
        self.open_action = Action.init(self, "Open", .folder_open, nimbus.KeyStroke.cmd(.o), onOpen);
        self.save_action = Action.init(self, "Save", .save, nimbus.KeyStroke.cmd(.s), onSave);
        self.save_as_action = Action.init(self, "Save As", null, nimbus.KeyStroke.cmdShift(.s), onSaveAs);
        self.exit_action = Action.init(self, "Exit", null, null, onExit);
        self.undo_action = Action.init(self, "Undo", .undo, nimbus.KeyStroke.cmd(.z), onUndo);
        self.redo_action = Action.init(self, "Redo", .redo, nimbus.KeyStroke.cmd(.y), onRedo);
        self.cut_action = Action.init(self, "Cut", null, nimbus.KeyStroke.cmd(.x), onCut);
        self.copy_action = Action.init(self, "Copy", null, nimbus.KeyStroke.cmd(.c), onCopy);
        self.paste_action = Action.init(self, "Paste", null, nimbus.KeyStroke.cmd(.v), onPaste);
        self.select_all_action = Action.init(self, "Select All", null, nimbus.KeyStroke.cmd(.a), onSelectAll);
        self.word_wrap_action = Action.init(self, "Word Wrap", null, null, onWordWrap);
    }

    fn setPath(self: *Editor, path: ?[]const u8) !void {
        if (self.path) |old| self.allocator.free(old);
        self.path = if (path) |p| try self.allocator.dupe(u8, p) else null;
    }

    fn replaceBaseline(self: *Editor, text: []const u8) !void {
        const next = try self.allocator.dupe(u8, text);
        self.allocator.free(self.baseline);
        self.baseline = next;
        self.recomputeDirty();
    }

    fn recomputeDirty(self: *Editor) void {
        self.dirty = isDirty(self.text_area.getText(), self.baseline);
        self.updateTitle();
    }

    fn updateTitle(self: *Editor) void {
        const marker: []const u8 = if (self.dirty) "*" else "";
        const name = if (self.path) |p| std.fs.path.basename(p) else "untitled";
        var buf: [512]u8 = undefined;
        const title = std.fmt.bufPrint(&buf, "{s}{s} - nimbus text editor", .{ marker, name }) catch return;
        self.frame.window.setTitle(title) catch {};
    }

    fn resetDocument(self: *Editor) void {
        self.text_area.setText("") catch return;
        self.setPath(null) catch return;
        self.eol = .lf;
        self.replaceBaseline("") catch return;
        self.dirty = false;
        self.updateTitle();
    }

    fn openPath(self: *Editor, path: []const u8) bool {
        const bytes = self.file_io.readAll(self.allocator, path) catch return false;
        defer self.allocator.free(bytes);
        const next_eol = detectEol(bytes);
        self.text_area.setText(bytes) catch return false;
        self.setPath(path) catch return false;
        self.eol = next_eol;
        self.replaceBaseline(self.text_area.getText()) catch return false;
        self.dirty = false;
        self.updateTitle();
        return true;
    }

    fn saveToPath(self: *Editor, path: []const u8) bool {
        const expanded = expandForEol(self.allocator, self.text_area.getText(), self.eol) catch return false;
        defer self.allocator.free(expanded);
        self.file_io.writeAll(path, expanded) catch return false;
        self.setPath(path) catch return false;
        self.replaceBaseline(self.text_area.getText()) catch return false;
        self.dirty = false;
        self.updateTitle();
        return true;
    }

    fn saveCurrent(self: *Editor) bool {
        if (self.path) |p| return self.saveToPath(p);
        return self.saveAs();
    }

    fn saveAs(self: *Editor) bool {
        if (self.chooser.showSaveDialog() != .ok) return false;
        const selected = self.chooser.getSelectedPath() orelse return false;
        return self.saveToPath(selected);
    }

    fn openFromChooser(self: *Editor) void {
        if (!self.confirmDiscardIfDirty()) return;
        if (self.chooser.showOpenDialog() != .ok) return;
        const selected = self.chooser.getSelectedPath() orelse return;
        _ = self.openPath(selected);
    }

    fn confirmDiscardIfDirty(self: *Editor) bool {
        if (!self.dirty) return true;
        const result = self.unsaved_dialog.showModal();
        return self.continueAfterUnsavedResult(result);
    }

    fn continueAfterUnsavedResult(self: *Editor, result: nimbus.Dialog.Result) bool {
        if (result == .ok) return self.saveCurrent();
        if (result == DISCARD_RESULT) return true;
        return false;
    }

    pub fn newDocumentForTest(self: *Editor) void {
        self.resetDocument();
    }

    pub fn openPathForTest(self: *Editor, path: []const u8) bool {
        return self.openPath(path);
    }

    pub fn saveToPathForTest(self: *Editor, path: []const u8) bool {
        return self.saveToPath(path);
    }

    pub fn newDocumentWithUnsavedResultForTest(self: *Editor, result: nimbus.Dialog.Result) void {
        if (self.dirty and !self.continueAfterUnsavedResult(result)) return;
        self.resetDocument();
    }

    pub fn dirtyForTest(self: *const Editor) bool {
        return self.dirty;
    }

    pub fn pathForTest(self: *const Editor) ?[]const u8 {
        return self.path;
    }

    pub fn eolForTest(self: *const Editor) Eol {
        return self.eol;
    }

    fn onTextChanged(self: *Editor, _: *const nimbus.ChangeEvent) void {
        self.recomputeDirty();
    }

    fn onNew(self: *Editor) void {
        if (!self.confirmDiscardIfDirty()) return;
        self.resetDocument();
    }

    fn onOpen(self: *Editor) void {
        self.openFromChooser();
    }

    fn onSave(self: *Editor) void {
        _ = self.saveCurrent();
    }

    fn onSaveAs(self: *Editor) void {
        _ = self.saveAs();
    }

    fn onExit(self: *Editor) void {
        if (!self.confirmDiscardIfDirty()) return;
        self.frame.window.dispose();
    }

    fn onUndo(self: *Editor) void {
        self.text_area.undo();
    }

    fn onRedo(self: *Editor) void {
        self.text_area.redo();
    }

    fn onCut(self: *Editor) void {
        self.text_area.cut();
    }

    fn onCopy(self: *Editor) void {
        self.text_area.copy();
    }

    fn onPaste(self: *Editor) void {
        self.text_area.paste();
    }

    fn onSelectAll(self: *Editor) void {
        self.text_area.selectAll();
    }

    fn onWordWrap(_: *Editor) void {}
};

pub fn build(app: *nimbus.Application, frame: *nimbus.Frame, gpa: std.mem.Allocator) !*Editor {
    return buildWithOptions(app, frame, gpa, .{ .io = app.event_queue.io });
}

pub fn buildWithOptions(app: *nimbus.Application, frame: *nimbus.Frame, gpa: std.mem.Allocator, options: BuildOptions) !*Editor {
    const editor = try gpa.create(Editor);
    editor.* = .{
        .allocator = gpa,
        .app = app,
        .frame = frame,
        .file_io_state = .{ .io = options.io },
        .file_io = undefined,
    };
    editor.file_io = options.file_io orelse osFileIo(&editor.file_io_state);
    editor.baseline = try gpa.dupe(u8, "");
    editor.initActions();

    frame.window.container.setLayout(nimbus.BorderLayout.get());

    const menu_bar = try app.menuBar();
    try buildMenus(app, editor, menu_bar);
    try frame.setMenuBar(menu_bar);

    const toolbar_outer = try app.panel();
    toolbar_outer.setBackground(app.theme.surface_window);
    toolbar_outer.padding = .{ .left = 6, .right = 6, .top = 4, .bottom = 4 };
    toolbar_outer.asContainer().setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 6));
    toolbar_outer.asComponent().min_size = .{ .width = 0, .height = 36 };
    toolbar_outer.asComponent().max_size = .{ .width = std.math.inf(f32), .height = 36 };
    editor.toolbar = toolbar_outer;
    try editor.new_action.bindToolButton(app, toolbar_outer);
    try editor.open_action.bindToolButton(app, toolbar_outer);
    try editor.save_action.bindToolButton(app, toolbar_outer);
    try toolbar_outer.asContainer().add(&(try app.label("|")).component);
    try editor.undo_action.bindToolButton(app, toolbar_outer);
    try editor.redo_action.bindToolButton(app, toolbar_outer);
    try nimbus.BorderLayout.add(&frame.window.container, .north, toolbar_outer.asComponent());

    const text_area = try app.textArea("");
    editor.text_area = text_area;
    try text_area.addChangeListener(Editor, Editor.onTextChanged, editor);
    const scroll_pane = try app.scrollPane(&text_area.component);
    editor.scroll_pane = scroll_pane;
    try nimbus.BorderLayout.add(&frame.window.container, .center, scroll_pane.asComponent());

    const status = try app.panel();
    status.setBackground(app.theme.surface_window);
    status.padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 };
    status.asContainer().setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 8));
    status.asComponent().min_size = .{ .width = 0, .height = 28 };
    status.asComponent().max_size = .{ .width = std.math.inf(f32), .height = 28 };
    editor.status = status;
    editor.status_line_col = try app.label("Ln 1, Col 1");
    editor.status_name = try app.label("untitled");
    editor.status_encoding = try app.label("UTF-8");
    editor.status_eol = try app.label("LF");
    try status.asContainer().add(&editor.status_line_col.component);
    try status.asContainer().add(&(try app.label("|")).component);
    try status.asContainer().add(&editor.status_name.component);
    try status.asContainer().add(&(try app.label("|")).component);
    try status.asContainer().add(&editor.status_encoding.component);
    try status.asContainer().add(&editor.status_eol.component);
    try nimbus.BorderLayout.add(&frame.window.container, .south, status.asComponent());

    editor.chooser = if (options.chooser_source) |source|
        try nimbus.FileChooser.createWithSource(app, &frame.window, source)
    else
        try app.fileChooser(&frame.window);
    editor.unsaved_dialog = try app.dialog(&frame.window, "Unsaved changes", 360, 150);
    editor.unsaved_message = try app.label("Save changes before continuing?");
    try buildUnsavedDialog(app, editor.unsaved_dialog, editor.unsaved_message);
    editor.updateTitle();

    return editor;
}

fn buildUnsavedDialog(app: *nimbus.Application, dialog: *nimbus.Dialog, msg: *nimbus.Label) !void {
    dialog.window.container.setLayout(try nimbus.PaddingLayout.create(app.allocator, nimbus.Insets.all(12)));
    const body = try app.container();
    body.setLayout(try nimbus.BoxLayout.verticalSpaced(app.allocator, 10));
    msg.component.setAlignX(.center);
    const row = try app.container();
    row.setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 8));
    const save = try app.button("Save");
    const discard = try app.button("Discard");
    const cancel = try app.button("Cancel");
    try save.getModel().addActionListener(nimbus.Dialog, onUnsavedSave, dialog);
    try discard.getModel().addActionListener(nimbus.Dialog, onUnsavedDiscard, dialog);
    try cancel.getModel().addActionListener(nimbus.Dialog, onUnsavedCancel, dialog);
    try row.add(&save.component);
    try row.add(&discard.component);
    try row.add(&cancel.component);
    try body.add(&msg.component);
    try body.add(&row.component);
    try dialog.window.add(&body.component);
}

fn onUnsavedSave(dialog: *nimbus.Dialog, _: *const ActionEvent) void {
    dialog.close(.ok);
}

fn onUnsavedDiscard(dialog: *nimbus.Dialog, _: *const ActionEvent) void {
    dialog.close(DISCARD_RESULT);
}

fn onUnsavedCancel(dialog: *nimbus.Dialog, _: *const ActionEvent) void {
    dialog.close(.cancel);
}

fn buildMenus(app: *nimbus.Application, editor: *Editor, menu_bar: *nimbus.MenuBar) !void {
    const file = try app.menu("File");
    try editor.new_action.bindMenuItem(app, file);
    try editor.open_action.bindMenuItem(app, file);
    try editor.save_action.bindMenuItem(app, file);
    try editor.save_as_action.bindMenuItem(app, file);
    try file.addSeparator();
    try editor.exit_action.bindMenuItem(app, file);
    try menu_bar.add(file);

    const edit = try app.menu("Edit");
    try editor.undo_action.bindMenuItem(app, edit);
    try editor.redo_action.bindMenuItem(app, edit);
    try edit.addSeparator();
    try editor.cut_action.bindMenuItem(app, edit);
    try editor.copy_action.bindMenuItem(app, edit);
    try editor.paste_action.bindMenuItem(app, edit);
    try edit.addSeparator();
    try editor.select_all_action.bindMenuItem(app, edit);
    try menu_bar.add(edit);

    const view = try app.menu("View");
    try editor.word_wrap_action.bindCheckBoxMenuItem(app, view);
    try menu_bar.add(view);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    const frame = try app.frame("nimbus text editor", 760, 520);
    const editor = try build(app, frame, init.gpa);
    defer editor.deinitModel(init.gpa);
    defer app.deinit();
    defer editor.deinitUi();

    std.debug.print(
        \\text editor stage 1: shell, menu, toolbar, text area, and status bar.
        \\
    , .{});
    try app.run();
}
