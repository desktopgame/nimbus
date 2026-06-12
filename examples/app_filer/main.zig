//! app_filer: dogfooding file manager (M3 — file operations).
//!
//! A real (if minimal) app built only on nimbus public APIs, to surface
//! missing pieces and rough edges. Current state:
//!   - left pane: places (Home + drives on Windows, / elsewhere); a single
//!     click navigates the right pane there
//!   - right pane: entries of the current directory (folders first, then
//!     files, case-insensitively sorted), each row = icon + name
//!   - double-click / Enter opens a folder; on a file it just reports in the
//!     status line for now
//!   - right-click a row for the context menu: Open / Rename / Delete
//!   - F2 (or the menu) renames in place — the row swaps to a text field,
//!     Enter commits (performs the actual rename on disk), Escape cancels
//!   - Delete (or the menu) asks in a modal dialog, then deletes the file /
//!     empty folder; non-empty folders are refused (no recursive delete)
//!   - F5 reloads; the toolbar's up-arrow button (or Backspace) goes to the
//!     parent; the divider between the panes drags
//!
//! Usage:
//!     zig build run-app_filer

const std = @import("std");
const builtin = @import("builtin");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const ActionEvent = nimbus.ActionEvent;
const ChangeEvent = nimbus.ChangeEvent;

const ROW_HEIGHT: f32 = 24;
const ICON: f32 = 16;
const PATH_BUF = 4096;
const NAME_BUF = 512;
const SIDEBAR_WIDTH: f32 = 180;

/// One directory entry. Owned by Filer (`entries`); the ListModel borrows it.
const Entry = struct {
    name:   []u8,
    is_dir: bool,
};

/// One sidebar destination. Owned by Filer (`places`); the ListModel borrows it.
const Place = struct {
    name: []u8,
    path: []u8,
    kind: Kind,

    const Kind = enum { home, drive };
};

const Filer = struct {
    allocator:   std.mem.Allocator,
    io:          std.Io,
    app:         *nimbus.Application,
    icon_folder: awt.Image,
    icon_file:   awt.Image,
    icon_home:   awt.Image,
    icon_drive:  awt.Image,
    list:        *nimbus.List = undefined,         // right pane (files)
    places_list: *nimbus.List = undefined,         // left pane (places)
    sp:          *nimbus.ScrollPane = undefined,   // right pane's scroll pane
    path_label:  *nimbus.Label = undefined,
    status:      *nimbus.Label = undefined,
    window:      *nimbus.Window = undefined,       // for PopupMenu.show
    popup:       *nimbus.PopupMenu = undefined,    // row context menu
    confirm:     *nimbus.Dialog = undefined,       // delete confirmation
    confirm_msg: *nimbus.Label = undefined,
    entries:     std.ArrayList(*Entry) = .empty,
    places:      std.ArrayList(*Place) = .empty,
    cur:         [PATH_BUF]u8 = undefined,
    cur_len:     usize = 0,
    status_buf:  [512]u8 = undefined,
    /// Name to select after the next loadDir (set by rename so the renamed
    /// row stays selected through the reload).
    pending:     [NAME_BUF]u8 = undefined,
    pending_len: usize = 0,

    fn curPath(self: *const Filer) []const u8 {
        return self.cur[0..self.cur_len];
    }

    fn setStatus(self: *Filer, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_buf, fmt, args) catch return;
        self.status.setText(text) catch {};
    }

    fn clearEntries(self: *Filer) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.destroy(e);
        }
        self.entries.clearRetainingCapacity();
    }

    fn clearPlaces(self: *Filer) void {
        for (self.places.items) |p| {
            self.allocator.free(p.name);
            self.allocator.free(p.path);
            self.allocator.destroy(p);
        }
        self.places.clearRetainingCapacity();
    }

    fn addPlace(self: *Filer, name: []const u8, path: []const u8, kind: Place.Kind) void {
        const p = self.allocator.create(Place) catch return;
        p.* = .{
            .name = self.allocator.dupe(u8, name) catch {
                self.allocator.destroy(p);
                return;
            },
            .path = self.allocator.dupe(u8, path) catch {
                self.allocator.free(p.name);
                self.allocator.destroy(p);
                return;
            },
            .kind = kind,
        };
        self.places.append(self.allocator, p) catch {
            self.allocator.free(p.name);
            self.allocator.free(p.path);
            self.allocator.destroy(p);
        };
    }

    /// Populate the sidebar: Home (`home`, from the caller's environ map),
    /// then the drives that exist (Windows) or the filesystem root (elsewhere).
    fn buildPlaces(self: *Filer, home: ?[]const u8) void {
        if (home) |h| self.addPlace("Home", h, .home);
        if (builtin.os.tag == .windows) {
            var letter: u8 = 'A';
            while (letter <= 'Z') : (letter += 1) {
                const drive = [3]u8{ letter, ':', std.fs.path.sep };
                std.Io.Dir.accessAbsolute(self.io, &drive, .{}) catch continue;
                self.addPlace(&drive, &drive, .drive);
            }
        } else {
            self.addPlace("/", "/", .drive);
        }
        for (self.places.items) |p| self.places_list.model.add(@ptrCast(p)) catch break;
    }

    fn entryLess(_: void, a: *Entry, b: *Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir; // folders first
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// Load `path` (absolute) into the right pane. On open failure the
    /// current directory and listing stay; only the status line reports.
    fn loadDir(self: *Filer, path: []const u8) void {
        if (path.len > PATH_BUF) return;
        var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        defer dir.close(self.io);

        const same_dir = std.mem.eql(u8, path, self.curPath());

        // Unbind all rows before freeing the entries they borrow.
        self.list.model.clear();
        self.clearEntries();

        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            const e = self.allocator.create(Entry) catch break;
            e.* = .{
                .name = self.allocator.dupe(u8, ent.name) catch {
                    self.allocator.destroy(e);
                    break;
                },
                .is_dir = ent.kind == .directory,
            };
            self.entries.append(self.allocator, e) catch {
                self.allocator.free(e.name);
                self.allocator.destroy(e);
                break;
            };
        }
        std.sort.pdq(*Entry, self.entries.items, {}, entryLess);
        for (self.entries.items) |e| self.list.model.add(@ptrCast(e)) catch break;

        // `path` may alias `cur` (goUp passes a prefix slice of it) — the
        // prefix is already in place then, so only copy from foreign buffers.
        if (path.ptr != @as([*]const u8, @ptrCast(&self.cur))) {
            @memcpy(self.cur[0..path.len], path);
        }
        self.cur_len = path.len;

        self.path_label.setText(self.curPath()) catch {};

        // Selection: a pending name (post-rename) wins; otherwise first row.
        var sel: ?usize = if (self.entries.items.len > 0) 0 else null;
        if (self.pending_len > 0) {
            const want = self.pending[0..self.pending_len];
            for (self.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, want)) {
                    sel = i;
                    break;
                }
            }
            self.pending_len = 0;
        }
        self.list.setSelected(sel);

        if (!same_dir) self.sp.setScrollY(0);
        self.setStatus("{d} items", .{self.entries.items.len});
    }

    fn requestSelectName(self: *Filer, name: []const u8) void {
        const n = @min(name.len, self.pending.len);
        @memcpy(self.pending[0..n], name[0..n]);
        self.pending_len = n;
    }

    fn reloadTask(ud: *anyopaque) void {
        const self: *Filer = @ptrCast(@alignCast(ud));
        self.loadDir(self.curPath());
    }

    /// Reload at the end of the current event-loop iteration. Used where a
    /// synchronous reload would reenter List machinery (e.g. from inside a
    /// CellEdit.commit, which List is still unwinding).
    fn scheduleReload(self: *Filer) void {
        self.app.event_queue.invokeLater(reloadTask, @ptrCast(self)) catch {};
    }

    fn selectedEntry(self: *Filer) ?*Entry {
        const idx = self.list.getSelected() orelse return null;
        if (idx >= self.entries.items.len) return null;
        return self.entries.items[idx];
    }

    fn openSelected(self: *Filer) void {
        const e = self.selectedEntry() orelse return;
        if (e.is_dir) {
            const joined = std.fs.path.join(self.allocator, &.{ self.curPath(), e.name }) catch return;
            defer self.allocator.free(joined);
            self.loadDir(joined);
        } else {
            self.setStatus("file: {s} (opening comes in a later milestone)", .{e.name});
        }
    }

    fn goUp(self: *Filer) void {
        const parent = std.fs.path.dirname(self.curPath()) orelse {
            self.setStatus("already at the root", .{});
            return;
        };
        self.loadDir(parent);
    }

    fn renameSelected(self: *Filer) void {
        if (self.list.getSelected()) |s| self.list.edit(s);
    }

    /// Modal confirmation, then delete the file / empty directory. The
    /// listing reloads with the selection kept near the deleted row.
    fn confirmDelete(self: *Filer) void {
        const idx = self.list.getSelected() orelse return;
        const e = self.selectedEntry() orelse return;

        // Keep the name past the reload (e is freed by it).
        var name_buf: [NAME_BUF]u8 = undefined;
        const n = @min(e.name.len, name_buf.len);
        @memcpy(name_buf[0..n], e.name[0..n]);
        const name = name_buf[0..n];
        const was_dir = e.is_dir;

        var msg_buf: [NAME_BUF + 32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Delete \"{s}\"?", .{name}) catch return;
        self.confirm_msg.setText(msg) catch {};
        if (self.confirm.showModal() != .ok) return;

        var d = std.Io.Dir.openDirAbsolute(self.io, self.curPath(), .{}) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ self.curPath(), @errorName(err) });
            return;
        };
        defer d.close(self.io);
        const res = if (was_dir) d.deleteDir(self.io, name) else d.deleteFile(self.io, name);
        res catch |err| {
            self.setStatus("delete failed: {s} ({s})", .{ name, @errorName(err) });
            return;
        };

        self.loadDir(self.curPath());
        self.list.setSelected(if (self.entries.items.len == 0)
            null
        else
            @min(idx, self.entries.items.len - 1));
        self.setStatus("deleted {s}", .{name});
    }

    /// Called by the editing cell after it performed the on-disk rename.
    fn renamed(self: *Filer, new_name: []const u8) void {
        self.setStatus("renamed to {s}", .{new_name});
        self.requestSelectName(new_name);
        self.scheduleReload();
    }

    // ── listeners ────────────────────────────────────────────────────────

    fn onActivate(self: *Filer, _: *const ActionEvent) void {
        self.openSelected();
    }

    fn onContextMenu(self: *Filer, e: *const nimbus.List.ContextMenuEvent) void {
        if (e.row == null) return; // no background menu yet
        self.popup.show(self.window, e.x, e.y) catch {};
    }

    fn onMenuOpen(self: *Filer, _: *const ActionEvent) void {
        self.openSelected();
    }

    fn onMenuRename(self: *Filer, _: *const ActionEvent) void {
        self.renameSelected();
    }

    fn onMenuDelete(self: *Filer, _: *const ActionEvent) void {
        self.confirmDelete();
    }

    fn onUpButton(self: *Filer, _: *const ActionEvent) void {
        self.goUp();
    }

    fn onBackspace(self: *Filer) void {
        self.goUp();
    }

    fn onRenameKey(self: *Filer) void {
        self.renameSelected();
    }

    fn onDeleteKey(self: *Filer) void {
        self.confirmDelete();
    }

    fn onReloadKey(self: *Filer) void {
        self.loadDir(self.curPath());
    }

    /// Sidebar selection = navigation (single click, like a places sidebar).
    fn onPlaceSelected(self: *Filer, _: *const ChangeEvent) void {
        const idx = self.places_list.getSelected() orelse return;
        if (idx >= self.places.items.len) return;
        self.loadDir(self.places.items[idx].path);
    }
};

// ── cells ────────────────────────────────────────────────────────────────

/// One recycled file row. Display mode: [6px margin | icon+name label].
/// Edit mode (rename): the label swaps to a TextField; Enter commits (does
/// the on-disk rename), Escape cancels. Same swap mechanics as
/// `widget_listedit`'s EditCell.
const FileCell = struct {
    root:      *nimbus.Container,
    label:     *nimbus.Label,
    field:     *nimbus.TextField,
    filer:     *Filer,
    cur_entry: ?*Entry = null,
    in_edit:   bool = false,

    fn update(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.cur_entry = e;
        self.label.setText(e.name) catch {};
        self.label.setIcon(if (e.is_dir) self.filer.icon_folder else self.filer.icon_file);
    }

    // CellEdit.start — swap to the text field seeded with the current name.
    fn start(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.cur_entry = e;
        self.field.setText(e.name) catch {};
        self.swapTo(true);
        self.field.component.requestFocus();
    }

    // CellEdit.commit — perform the rename on disk; the listing reloads at
    // the end of this event-loop pass (invokeLater) since List is still
    // unwinding its edit machinery here.
    fn commit(ud: *anyopaque) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        self.swapTo(false);
        const filer = self.filer;
        const e = self.cur_entry orelse return;
        const new_name = self.field.getText();
        if (new_name.len == 0 or std.mem.eql(u8, new_name, e.name)) return;
        if (std.mem.indexOfAny(u8, new_name, "/\\") != null) {
            filer.setStatus("invalid name: {s}", .{new_name});
            return;
        }
        var d = std.Io.Dir.openDirAbsolute(filer.io, filer.curPath(), .{}) catch |err| {
            filer.setStatus("cannot open {s}: {s}", .{ filer.curPath(), @errorName(err) });
            return;
        };
        defer d.close(filer.io);
        d.rename(e.name, d, new_name, filer.io) catch |err| {
            filer.setStatus("rename failed: {s} ({s})", .{ e.name, @errorName(err) });
            return;
        };
        filer.renamed(new_name);
    }

    // CellEdit.cancel — back to display mode, nothing touched.
    fn cancel(ud: *anyopaque) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        self.swapTo(false);
    }

    fn swapTo(self: *FileCell, edit_mode: bool) void {
        if (edit_mode == self.in_edit) return;
        if (edit_mode) {
            self.root.remove(&self.label.component);
            nimbus.BorderLayout.add(self.root, .center, &self.field.component) catch {};
        } else {
            self.root.remove(&self.field.component);
            nimbus.BorderLayout.add(self.root, .center, &self.label.component) catch {};
        }
        self.in_edit = edit_mode;
        self.root.doLayout(); // size the newly-shown child to fill the cell
    }

    // Wired to the field's Enter / Escape via submit / cancel listeners.
    fn onSubmit(self: *FileCell, _: *const ActionEvent) void {
        self.filer.list.commitEdit();
    }
    fn onCancel(self: *FileCell, _: *const ActionEvent) void {
        self.filer.list.cancelEdit();
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        // Detach both swappable children (remove is a no-op if not added) so
        // the container destroys neither; the cell owns both.
        self.root.remove(&self.label.component);
        self.root.remove(&self.field.component);
        const rc = &self.root.component;
        rc.vtable.destroy(rc, allocator); // frees root + margin
        self.label.component.vtable.destroy(&self.label.component, allocator);
        self.field.component.vtable.destroy(&self.field.component, allocator);
        allocator.destroy(self);
    }
};

/// One recycled places row: [6px margin | icon+name label], read-only.
const PlaceCell = struct {
    root:       *nimbus.Container,
    label:      *nimbus.Label,
    icon_home:  awt.Image,
    icon_drive: awt.Image,

    fn update(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *PlaceCell = @ptrCast(@alignCast(ud));
        const p: *Place = @ptrCast(@alignCast(ctx.value));
        self.label.setText(p.name) catch {};
        self.label.setIcon(switch (p.kind) {
            .home => self.icon_home,
            .drive => self.icon_drive,
        });
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *PlaceCell = @ptrCast(@alignCast(ud));
        const comp = &self.root.component;
        comp.vtable.destroy(comp, allocator);
        allocator.destroy(self);
    }
};

fn createFileCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const app = filer.app;

    const fc = try allocator.create(FileCell);
    errdefer allocator.destroy(fc);

    // BorderLayout so the label/field swap is a center-region exchange.
    const root = try app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BorderLayout.get());

    const margin = try app.container();
    margin.component.setMinSize(.{ .width = 6, .height = 0 });
    try nimbus.BorderLayout.add(root, .west, &margin.component);

    const label = try app.label("");
    label.setIconSize(.{ .width = ICON, .height = ICON });
    const field = try app.textField("");
    try nimbus.BorderLayout.add(root, .center, &label.component); // start in display mode

    fc.* = .{ .root = root, .label = label, .field = field, .filer = filer };
    try field.addSubmitListener(FileCell, FileCell.onSubmit, fc);
    try field.addCancelListener(FileCell, FileCell.onCancel, fc);

    return .{
        .component = &root.component,
        .update    = FileCell.update,
        .destroy   = FileCell.destroyCell,
        .edit      = .{ .start = FileCell.start, .commit = FileCell.commit, .cancel = FileCell.cancel },
        .user_data = fc,
    };
}

fn createPlaceCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const app = filer.app;

    const pc = try allocator.create(PlaceCell);
    errdefer allocator.destroy(pc);

    const root = try app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.horizontal());

    // Left margin via the empty-container recipe (BoxLayout has no spacing).
    const margin = try app.container();
    margin.component.setMinSize(.{ .width = 6, .height = 0 });
    margin.component.setMaxSize(.{ .width = 6, .height = std.math.inf(f32) });
    try root.add(&margin.component);

    const label = try app.label("");
    label.setIconSize(.{ .width = ICON, .height = ICON });
    try root.add(&label.component);

    pc.* = .{
        .root = root,
        .label = label,
        .icon_home = filer.icon_home,
        .icon_drive = filer.icon_drive,
    };
    return .{
        .component = &root.component,
        .update    = PlaceCell.update,
        .destroy   = PlaceCell.destroyCell,
        .user_data = pc,
    };
}

// ── ui assembly ──────────────────────────────────────────────────────────

fn buildConfirmDialog(app: *nimbus.Application, dialog: *nimbus.Dialog, msg: *nimbus.Label) !void {
    dialog.window.container.setLayout(nimbus.BoxLayout.vertical());
    msg.component.setAlignX(.center);

    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const ok = try app.button("Delete");
    const cancel = try app.button("Cancel");
    try ok.getModel().addActionListener(nimbus.Dialog, onConfirmOk, dialog);
    try cancel.getModel().addActionListener(nimbus.Dialog, onConfirmCancel, dialog);
    try row.add(&ok.component);
    try row.add(&cancel.component);

    try dialog.window.add(&msg.component);
    try dialog.window.add(&row.component);
}

fn onConfirmOk(d: *nimbus.Dialog, _: *const ActionEvent) void {
    d.close(.ok);
}

fn onConfirmCancel(d: *nimbus.Dialog, _: *const ActionEvent) void {
    d.close(.cancel);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("nimbus filer", 720, 480);

    var filer = Filer{
        .allocator   = init.gpa,
        .io          = init.io,
        .app         = app,
        .icon_folder = try app.icon(.folder),
        .icon_file   = try app.icon(.file),
        .icon_home   = try app.icon(.house),
        .icon_drive  = try app.icon(.hard_drive),
    };
    filer.window = &frame.window;
    // Runs before app.deinit (LIFO): the Lists still exist but are idle, and
    // they never touch the borrowed items during teardown.
    defer {
        filer.clearEntries();
        filer.entries.deinit(init.gpa);
        filer.clearPlaces();
        filer.places.deinit(init.gpa);
    }

    // Right pane: files.
    const lst = try app.list(.{ .create = createFileCell, .user_data = &filer });
    filer.list = lst;
    lst.setRowHeight(ROW_HEIGHT);
    // Double-click / Enter must OPEN (activation), never start a rename —
    // renames begin explicitly via F2 / the context menu.
    lst.setEditTrigger(.manual);
    try lst.addActionListener(Filer, Filer.onActivate, &filer);
    try lst.addContextMenuListener(Filer, Filer.onContextMenu, &filer);
    const sp = try app.scrollPane(lst.asComponent());
    filer.sp = sp;

    // Left pane: places.
    const places = try app.list(.{ .create = createPlaceCell, .user_data = &filer });
    filer.places_list = places;
    places.setRowHeight(ROW_HEIGHT);
    try places.addChangeListener(Filer, Filer.onPlaceSelected, &filer);
    const places_sp = try app.scrollPane(places.asComponent());

    // Split: sidebar keeps its width on resize (resize_weight 0 default).
    const split = try app.splitPane(.horizontal, places_sp.asComponent(), sp.asComponent());
    split.setDividerLocation(SIDEBAR_WIDTH);
    split.asComponent().setGrowX(1);
    split.asComponent().setGrowY(1);
    try nimbus.BorderLayout.add(&frame.window.container, .center, split.asComponent());

    // Row context menu (caller-owned, reused across shows).
    const popup = try app.popupMenu();
    defer popup.destroy();
    filer.popup = popup;
    const mi_open = try app.menuItem("Open");
    mi_open.setIcon(try app.icon(.folder_open));
    try mi_open.getModel().addActionListener(Filer, Filer.onMenuOpen, &filer);
    try popup.add(&mi_open.component);
    const mi_rename = try app.menuItem("Rename");
    mi_rename.setIcon(try app.icon(.pencil));
    try mi_rename.getModel().addActionListener(Filer, Filer.onMenuRename, &filer);
    try popup.add(&mi_rename.component);
    const mi_delete = try app.menuItem("Delete");
    mi_delete.setIcon(try app.icon(.trash_2));
    try mi_delete.getModel().addActionListener(Filer, Filer.onMenuDelete, &filer);
    try popup.add(&mi_delete.component);

    // Delete confirmation (caller-owned, message label rewritten per use).
    const confirm = try app.dialog(&frame.window, "Confirm", 320, 120);
    defer confirm.destroy();
    filer.confirm = confirm;
    const confirm_msg = try app.label("");
    filer.confirm_msg = confirm_msg;
    try buildConfirmDialog(app, confirm, confirm_msg);

    // Toolbar (north): [up] path
    const bar = try app.container();
    bar.setLayout(nimbus.BoxLayout.horizontal());
    const up = try app.button("");
    up.setIcon(try app.icon(.arrow_up));
    up.setIconSize(.{ .width = ICON, .height = ICON });
    try up.getModel().addActionListener(Filer, Filer.onUpButton, &filer);
    const gap = try app.container();
    gap.component.setMinSize(.{ .width = 6, .height = 0 });
    gap.component.setMaxSize(.{ .width = 6, .height = std.math.inf(f32) });
    const path_label = try app.label("");
    filer.path_label = path_label;
    path_label.component.setAlignY(.center);
    try bar.add(&up.component);
    try bar.add(&gap.component);
    try bar.add(&path_label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .north, &bar.component);

    // Status line (south).
    const status = try app.label("");
    filer.status = status;
    try nimbus.BorderLayout.add(&frame.window.container, .south, &status.component);

    // Keys. Backspace / F5 on the window root (work regardless of focus);
    // F2 / Delete on the file list (only meaningful with the list focused —
    // and the rename TextField consumes Delete itself while editing).
    try frame.window.container.component.bindKey(
        nimbus.KeyStroke.of(.backspace),
        nimbus.KeyHandler.typed(Filer, Filer.onBackspace, &filer),
    );
    try frame.window.container.component.bindKey(
        nimbus.KeyStroke.of(.f5),
        nimbus.KeyHandler.typed(Filer, Filer.onReloadKey, &filer),
    );
    try lst.asComponent().bindKey(
        nimbus.KeyStroke.of(.f2),
        nimbus.KeyHandler.typed(Filer, Filer.onRenameKey, &filer),
    );
    try lst.asComponent().bindKey(
        nimbus.KeyStroke.of(.delete),
        nimbus.KeyHandler.typed(Filer, Filer.onDeleteKey, &filer),
    );

    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    filer.buildPlaces(init.environ_map.get(home_var));

    // Start in the working directory.
    var buf: [PATH_BUF]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(init.io, &buf);
    filer.loadDir(buf[0..n]);

    std.debug.print(
        \\filer M3 — right-click a row for Open / Rename / Delete.
        \\F2 renames in place (Enter commits, Escape cancels), Delete asks then deletes,
        \\F5 reloads, Backspace goes up.
        \\
    , .{});
    try app.run();
}
