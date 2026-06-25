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
        gpa.destroy(self);
    }

    pub fn deinitUi(_: *Editor) void {}

    fn noop(_: *Editor) void {}

    fn initActions(self: *Editor) void {
        self.new_action = Action.init(self, "New", .file_plus, nimbus.KeyStroke.cmd(.n), noop);
        self.open_action = Action.init(self, "Open", .folder_open, nimbus.KeyStroke.cmd(.o), noop);
        self.save_action = Action.init(self, "Save", .save, nimbus.KeyStroke.cmd(.s), noop);
        self.save_as_action = Action.init(self, "Save As", null, nimbus.KeyStroke.cmdShift(.s), noop);
        self.exit_action = Action.init(self, "Exit", null, null, noop);
        self.undo_action = Action.init(self, "Undo", .undo, nimbus.KeyStroke.cmd(.z), noop);
        self.redo_action = Action.init(self, "Redo", .redo, nimbus.KeyStroke.cmd(.y), noop);
        self.cut_action = Action.init(self, "Cut", null, nimbus.KeyStroke.cmd(.x), noop);
        self.copy_action = Action.init(self, "Copy", null, nimbus.KeyStroke.cmd(.c), noop);
        self.paste_action = Action.init(self, "Paste", null, nimbus.KeyStroke.cmd(.v), noop);
        self.select_all_action = Action.init(self, "Select All", null, nimbus.KeyStroke.cmd(.a), noop);
        self.word_wrap_action = Action.init(self, "Word Wrap", null, null, noop);
    }
};

pub fn build(app: *nimbus.Application, frame: *nimbus.Frame, gpa: std.mem.Allocator) !*Editor {
    const editor = try gpa.create(Editor);
    editor.* = .{
        .allocator = gpa,
        .app = app,
        .frame = frame,
    };
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

    return editor;
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
