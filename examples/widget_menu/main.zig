//! Menu widget demo: MenuBar with sub-menus, CheckBoxMenuItem, and a
//! right-click PopupMenu on the content area. Verifies open /
//! hover-switch / submenu / action-fires-dismiss / outside-click-dismiss
//! behaviour interactively.
//!
//! Usage:
//!     zig build run-widget_menu

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

const lucide = nimbus.lucide;

const State = struct {
    label:   *nimbus.Label,
    buf:     [256]u8 = undefined,
    counter: u32 = 0,
};

fn setStatus(state: *State, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&state.buf, fmt, args) catch return;
    state.label.setText(text) catch {};
}

fn onFileNew(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    s.counter += 1;
    setStatus(s, "File > New ({d} click(s))", .{s.counter});
}

fn onFileOpen(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "File > Open clicked", .{});
}

fn onFileSave(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "File > Save clicked", .{});
}

fn onFileQuit(_: *anyopaque) void {
    std.debug.print("File > Quit — bye!\n", .{});
}

fn onEditCut(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "Edit > Cut clicked", .{});
}

fn onEditCopy(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "Edit > Copy clicked", .{});
}

fn onEditPaste(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "Edit > Paste clicked", .{});
}

fn onFindOne(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "Edit > Find > Find...", .{});
}

fn onFindNext(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "Edit > Find > Next", .{});
}

fn onViewGrid(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "View > Show Grid toggled", .{});
}

fn onViewRuler(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "View > Show Ruler toggled", .{});
}

// ── right-click PopupMenu on content area ────────────────────────────────

const ContextPanel = struct {
    panel:     *nimbus.Panel,
    popup:     *nimbus.PopupMenu,
    state:     *State,
    window:    *nimbus.Window,
    saved_vt:  *const nimbus.Component.VTable,

    var instance: ContextPanel = undefined;
};

pub const ctx_vtable = nimbus.Component.VTable{
    .install      = ctxInstall,
    .uninstall    = ctxUninstall,
    .paint        = ctxPaint,
    .processEvent = ctxProcessEvent,
    .destroy      = ctxDestroy,
};

fn ctxInstall(self: *nimbus.Component) void {
    ContextPanel.instance.saved_vt.install(self);
}

fn ctxUninstall(self: *nimbus.Component) void {
    ContextPanel.instance.saved_vt.uninstall(self);
}

fn ctxPaint(self: *nimbus.Component, g: *awt.Graphics) void {
    ContextPanel.instance.saved_vt.paint(self, g);
}

fn ctxDestroy(self: *nimbus.Component, allocator: std.mem.Allocator) void {
    ContextPanel.instance.saved_vt.destroy(self, allocator);
}

fn ctxProcessEvent(self: *nimbus.Component, ev: *nimbus.Component.Event) void {
    switch (ev.payload) {
        .mouse => |m| {
            if (m.action == .press and m.button == .right) {
                ContextPanel.instance.popup.show(ContextPanel.instance.window, m.x, m.y) catch {};
                ev.consume();
                return;
            }
        },
        else => {},
    }
    ContextPanel.instance.saved_vt.processEvent(self, ev);
}

fn onCtxPaste(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "PopupMenu > Paste clicked", .{});
}

fn onCtxDelete(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "PopupMenu > Delete clicked", .{});
}

fn onCtxInsertImage(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "PopupMenu > Insert > Image", .{});
}

fn onCtxInsertTable(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "PopupMenu > Insert > Table", .{});
}

fn onTbAction(user_data: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(user_data));
    setStatus(s, "Toolbar button clicked", .{});
}

// ── main ─────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("menu demo", 640, 360);
    const font = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
    const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

    // Status label in the center.
    const label = try app.label("Click a menu, or right-click on the content area.");
    var state = State{ .label = label };

    // Decode the lucide icons we use. All Image objects must outlive the
    // widgets that reference them — defer their deinit until program exit.
    var ic_new    = try awt.Image.fromMemory(app.allocator, app.device, lucide.file_plus);
    defer ic_new.deinit();
    var ic_open   = try awt.Image.fromMemory(app.allocator, app.device, lucide.folder_open);
    defer ic_open.deinit();
    var ic_save   = try awt.Image.fromMemory(app.allocator, app.device, lucide.save);
    defer ic_save.deinit();
    var ic_quit   = try awt.Image.fromMemory(app.allocator, app.device, lucide.x);
    defer ic_quit.deinit();
    var ic_cut    = try awt.Image.fromMemory(app.allocator, app.device, lucide.scissors);
    defer ic_cut.deinit();
    var ic_copy   = try awt.Image.fromMemory(app.allocator, app.device, lucide.copy);
    defer ic_copy.deinit();
    var ic_paste  = try awt.Image.fromMemory(app.allocator, app.device, lucide.clipboard);
    defer ic_paste.deinit();
    var ic_search = try awt.Image.fromMemory(app.allocator, app.device, lucide.search);
    defer ic_search.deinit();
    var ic_undo   = try awt.Image.fromMemory(app.allocator, app.device, lucide.undo);
    defer ic_undo.deinit();
    var ic_redo   = try awt.Image.fromMemory(app.allocator, app.device, lucide.redo);
    defer ic_redo.deinit();
    var ic_trash  = try awt.Image.fromMemory(app.allocator, app.device, lucide.trash);
    defer ic_trash.deinit();

    // Content panel.
    const content = try app.panel();
    content.setBackground(awt.Graphics.Color.rgb(1, 1, 1));
    content.container.setLayout(nimbus.BoxLayout.vertical());
    label.component.setAlignX(.center);
    try content.container.add(&label.component);

    // Set up right-click context menu via vtable override on the content panel.
    const popup = try nimbus.PopupMenu.create(app.allocator);
    const paste = try nimbus.MenuItem.create(app.allocator, "Paste", font, black);
    paste.setIcon(ic_paste);
    try paste.getModel().addActionListener(onCtxPaste, @ptrCast(&state));
    try popup.add(&paste.component);

    const del = try nimbus.MenuItem.create(app.allocator, "Delete", font, black);
    del.setIcon(ic_trash);
    try del.getModel().addActionListener(onCtxDelete, @ptrCast(&state));
    try popup.add(&del.component);

    try popup.addSeparator();

    const insert = try nimbus.Menu.create(app.allocator, "Insert", font, black);
    const ins_image = try nimbus.MenuItem.create(app.allocator, "Image", font, black);
    try ins_image.getModel().addActionListener(onCtxInsertImage, @ptrCast(&state));
    try insert.add(&ins_image.component);
    const ins_table = try nimbus.MenuItem.create(app.allocator, "Table", font, black);
    try ins_table.getModel().addActionListener(onCtxInsertTable, @ptrCast(&state));
    try insert.add(&ins_table.component);
    try popup.add(&insert.component);
    defer popup.destroy();

    ContextPanel.instance = .{
        .panel    = content,
        .popup    = popup,
        .state    = &state,
        .window   = &frame.window,
        .saved_vt = content.container.component.vtable,
    };
    content.container.component.vtable = &ctx_vtable;

    try nimbus.BorderLayout.add(&frame.window.container, .center, &content.container.component);

    // Toolbar with icon-only buttons.
    const tb = try app.toolbar();
    inline for ([_]awt.Image{ ic_new, ic_open, ic_save, ic_undo, ic_redo }) |icn| {
        const tb_btn = try app.button("");
        tb_btn.setIcon(icn);
        tb_btn.setIconSize(.{ .width = 20, .height = 20 });
        try tb_btn.getModel().addActionListener(onTbAction, @ptrCast(&state));
        try tb.container.add(&tb_btn.component);
    }
    try nimbus.BorderLayout.add(&frame.window.container, .north, &tb.container.component);

    // Build menu bar.
    const bar = try nimbus.MenuBar.create(app.allocator, font, black);

    // File menu
    {
        const file = try nimbus.Menu.create(app.allocator, "File", font, black);
        const new_item = try nimbus.MenuItem.create(app.allocator, "New", font, black);
        new_item.setIcon(ic_new);
        try new_item.getModel().addActionListener(onFileNew, @ptrCast(&state));
        try file.add(&new_item.component);
        const open = try nimbus.MenuItem.create(app.allocator, "Open", font, black);
        open.setIcon(ic_open);
        try open.getModel().addActionListener(onFileOpen, @ptrCast(&state));
        try file.add(&open.component);
        const save = try nimbus.MenuItem.create(app.allocator, "Save", font, black);
        save.setIcon(ic_save);
        try save.getModel().addActionListener(onFileSave, @ptrCast(&state));
        try file.add(&save.component);
        try file.addSeparator();
        const quit = try nimbus.MenuItem.create(app.allocator, "Quit", font, black);
        quit.setIcon(ic_quit);
        try quit.getModel().addActionListener(onFileQuit, @ptrCast(&state));
        try file.add(&quit.component);
        try bar.add(file);
    }

    // Edit menu (with submenu)
    {
        const edit = try nimbus.Menu.create(app.allocator, "Edit", font, black);
        const cut = try nimbus.MenuItem.create(app.allocator, "Cut", font, black);
        cut.setIcon(ic_cut);
        try cut.getModel().addActionListener(onEditCut, @ptrCast(&state));
        try edit.add(&cut.component);
        const copy = try nimbus.MenuItem.create(app.allocator, "Copy", font, black);
        copy.setIcon(ic_copy);
        try copy.getModel().addActionListener(onEditCopy, @ptrCast(&state));
        try edit.add(&copy.component);
        const paste2 = try nimbus.MenuItem.create(app.allocator, "Paste", font, black);
        paste2.setIcon(ic_paste);
        try paste2.getModel().addActionListener(onEditPaste, @ptrCast(&state));
        try edit.add(&paste2.component);
        try edit.addSeparator();

        const find = try nimbus.Menu.create(app.allocator, "Find", font, black);
        find.setIcon(ic_search);
        const find_one = try nimbus.MenuItem.create(app.allocator, "Find...", font, black);
        try find_one.getModel().addActionListener(onFindOne, @ptrCast(&state));
        try find.add(&find_one.component);
        const find_next = try nimbus.MenuItem.create(app.allocator, "Find Next", font, black);
        try find_next.getModel().addActionListener(onFindNext, @ptrCast(&state));
        try find.add(&find_next.component);
        try edit.add(&find.component);

        try bar.add(edit);
    }

    // View menu (with CheckBoxMenuItem)
    {
        const view = try nimbus.Menu.create(app.allocator, "View", font, black);
        const grid = try nimbus.CheckBoxMenuItem.create(app.allocator, "Show Grid", font, black);
        try grid.getModel().addActionListener(onViewGrid, @ptrCast(&state));
        try view.add(&grid.component);
        const ruler = try nimbus.CheckBoxMenuItem.create(app.allocator, "Show Ruler", font, black);
        ruler.setChecked(true);  // initial state
        try ruler.getModel().addActionListener(onViewRuler, @ptrCast(&state));
        try view.add(&ruler.component);
        try bar.add(view);
    }

    frame.setMenuBar(bar);

    std.debug.print(
        \\Try:
        \\  - Click File / Edit / View in the menu bar
        \\  - Hover from one open menu to another (switches popup)
        \\  - Edit -> Find -> hover opens the submenu
        \\  - Click a MenuItem (action fires, popup closes)
        \\  - Click outside any popup to dismiss
        \\  - Press ESC to dismiss
        \\  - Right-click on the content area for PopupMenu
        \\
    , .{});
    try app.run();
}
