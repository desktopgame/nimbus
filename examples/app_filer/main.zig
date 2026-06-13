//! app_filer: dogfooding file manager (M5 — list / details views).
//!
//! A real (if minimal) app built only on nimbus public APIs, to surface
//! missing pieces and rough edges. Current state:
//!   - left pane: places (Home + drives on Windows, / elsewhere); a single
//!     click navigates the right pane there
//!   - right pane: two views over ONE shared model (demonstrating
//!     Model = List.ListModel): a "list" view (icon + name, with inline
//!     rename and drag-to-move) and a "details" view (a Table with Name /
//!     Size / Modified columns, sortable headers, draggable column widths).
//!     The toolbar's view button toggles between them; the inactive view is
//!     zero-sized by a small CardLayout (both stay owned by the holder).
//!   - double-click / Enter opens a folder; on a file it reports in status
//!   - right-click a row for the context menu: Open / Rename / Delete
//!   - F2 (or the menu) renames in place in BOTH views (the Table's Name
//!     column carries a CellEdit). Delete asks in a modal, then removes the
//!     file / empty folder. F5 reloads; up-arrow / Backspace goes to parent.
//!
//! Known gap (Table is v1): the details view has no drag-to-move yet (DnD is
//! wired to the list view only — moving DnD onto the Table needs a public
//! row-from-y accessor, since the header offset is internal: framework#16).
//!
//! Usage:
//!     zig build run-app_filer

const std = @import("std");
const builtin = @import("builtin");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const dnd = nimbus.dnd;
const ActionEvent = nimbus.ActionEvent;
const ChangeEvent = nimbus.ChangeEvent;
const Model = nimbus.List.ListModel;

const ROW_HEIGHT: f32 = 24;
const ICON: f32 = 16;
const PATH_BUF = 4096;
const NAME_BUF = 512;
const SIDEBAR_WIDTH: f32 = 180;

const ViewMode = enum { list, details };

/// One directory entry. Owned by Filer (`entries`); the model borrows it.
const Entry = struct {
    name:   []u8,
    is_dir: bool,
    size:   u64 = 0,
    mtime:  i64 = 0, // seconds since epoch (UTC), 0 = unknown
};

/// One sidebar destination. Owned by Filer (`places`); the model borrows it.
const Place = struct {
    name: []u8,
    path: []u8,
    kind: Kind,

    const Kind = enum { home, drive };
};

/// Card-stack layout: the `active` child fills the container; every other
/// child is collapsed to zero size (kept owned by the container, just hidden).
/// nimbus has no built-in CardLayout; this is the few-line custom-LayoutManager
/// recipe (a dogfooding finding worth a backlog note).
const CardLayout = struct {
    base:   nimbus.LayoutManager,
    active: ?*nimbus.Component = null,

    const vt = nimbus.LayoutManager.VTable{
        .doLayout = doLayout,
        .computeMinSize = minSize,
        .computeMaxSize = maxSize,
    };

    fn doLayout(lm: *nimbus.LayoutManager, c: *nimbus.Container) void {
        const self: *CardLayout = @fieldParentPtr("base", lm);
        for (c.children.items) |elem| {
            const show = self.active != null and elem.component == self.active.?;
            elem.component.setBounds(if (show)
                .{ .x = 0, .y = 0, .width = c.component.size.width, .height = c.component.size.height }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 });
        }
    }
    fn minSize(_: *nimbus.LayoutManager, _: *const nimbus.Container) nimbus.Component.Size {
        return .{ .width = 0, .height = 0 };
    }
    fn maxSize(_: *nimbus.LayoutManager, _: *const nimbus.Container) nimbus.Component.Size {
        return .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
    }
};

const SortCtx = struct { col: usize, dir: nimbus.Table.SortDirection };

const Filer = struct {
    allocator:   std.mem.Allocator,
    io:          std.Io,
    app:         *nimbus.Application,
    icon_folder: awt.Image,
    icon_file:   awt.Image,
    icon_home:   awt.Image,
    icon_drive:  awt.Image,
    model:       *Model,                  // shared by both right-pane views
    list:        *nimbus.List = undefined,
    list_sp:     *nimbus.ScrollPane = undefined,
    table:       *nimbus.Table = undefined,
    table_sp:    *nimbus.ScrollPane = undefined,
    right_center:*nimbus.Container = undefined,
    card:        *CardLayout = undefined,
    view_mode:   ViewMode = .list,
    view_button: *nimbus.Button = undefined,
    places_list: *nimbus.List = undefined,
    path_label:  *nimbus.Label = undefined,
    status:      *nimbus.Label = undefined,
    window:      *nimbus.Window = undefined,
    popup:       *nimbus.PopupMenu = undefined,
    confirm:     *nimbus.Dialog = undefined,
    confirm_msg: *nimbus.Label = undefined,
    entries:     std.ArrayList(*Entry) = .empty,
    places:      std.ArrayList(*Place) = .empty,
    cur:         [PATH_BUF]u8 = undefined,
    cur_len:     usize = 0,
    status_buf:  [512]u8 = undefined,
    sort_col:    usize = 0,
    sort_dir:    nimbus.Table.SortDirection = .ascending,
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

    fn sortLess(ctx: SortCtx, a: *Entry, b: *Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir; // folders first, regardless of dir
        const eq = switch (ctx.col) {
            1 => a.size == b.size,
            2 => a.mtime == b.mtime,
            else => std.ascii.eqlIgnoreCase(a.name, b.name),
        };
        if (eq) return std.ascii.lessThanIgnoreCase(a.name, b.name); // stable tie-break
        const less = switch (ctx.col) {
            1 => a.size < b.size,
            2 => a.mtime < b.mtime,
            else => std.ascii.lessThanIgnoreCase(a.name, b.name),
        };
        return if (ctx.dir == .ascending) less else !less;
    }

    /// Reorder entries by the current sort key and republish into the shared
    /// model (both views observe the change).
    fn applySort(self: *Filer) void {
        std.sort.pdq(*Entry, self.entries.items, SortCtx{ .col = self.sort_col, .dir = self.sort_dir }, sortLess);
        self.model.clear();
        for (self.entries.items) |e| self.model.add(@ptrCast(e)) catch break;
    }

    /// Load `path` (absolute) into the shared model. On open failure the
    /// current directory and listing stay; only the status line reports.
    fn loadDir(self: *Filer, path: []const u8) void {
        if (path.len > PATH_BUF) return;
        var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        defer dir.close(self.io);

        const same_dir = std.mem.eql(u8, path, self.curPath());

        self.model.clear();
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
            if (dir.statFile(self.io, ent.name, .{}) catch null) |st| {
                e.size = st.size;
                e.mtime = @intCast(@divFloor(st.mtime.nanoseconds, 1_000_000_000));
            }
            self.entries.append(self.allocator, e) catch {
                self.allocator.free(e.name);
                self.allocator.destroy(e);
                break;
            };
        }
        self.applySort();

        if (path.ptr != @as([*]const u8, @ptrCast(&self.cur))) {
            @memcpy(self.cur[0..path.len], path);
        }
        self.cur_len = path.len;
        self.path_label.setText(self.curPath()) catch {};

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
        self.setActiveSelected(sel);

        if (!same_dir) {
            self.list_sp.setScrollY(0);
            self.table_sp.setScrollY(0);
        }
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

    fn scheduleReload(self: *Filer) void {
        self.app.event_queue.invokeLater(reloadTask, @ptrCast(self)) catch {};
    }

    // ── active-view helpers (selection lives per view) ─────────────────────

    fn selectedIndex(self: *Filer) ?usize {
        return switch (self.view_mode) {
            .list => self.list.getSelected(),
            .details => self.table.getSelected(),
        };
    }

    fn setActiveSelected(self: *Filer, idx: ?usize) void {
        switch (self.view_mode) {
            .list => self.list.setSelected(idx),
            .details => self.table.setSelected(idx),
        }
    }

    fn setViewMode(self: *Filer, mode: ViewMode) void {
        if (self.view_mode == mode) return;
        const carry = self.selectedIndex();
        self.view_mode = mode;
        self.card.active = switch (mode) {
            .list => self.list_sp.asComponent(),
            .details => self.table_sp.asComponent(),
        };
        self.setActiveSelected(carry); // carry selection across the switch
        self.view_button.setText(switch (mode) {
            .list => "Details",
            .details => "List",
        }) catch {};
        self.right_center.component.markLayoutDirty();
        self.right_center.component.repaint();
    }

    fn selectedEntry(self: *Filer) ?*Entry {
        const idx = self.selectedIndex() orelse return null;
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
        // Both views edit in place now: the list cell and the Table's Name
        // column (col 0) each carry a CellEdit.
        switch (self.view_mode) {
            .list => if (self.list.getSelected()) |s| self.list.edit(s),
            .details => if (self.table.getSelected()) |s| self.table.edit(s, 0),
        }
    }

    /// Shared rename: validate, rename on disk, schedule a reload that keeps
    /// the renamed row selected. Called by both views' edit cells on commit.
    fn performRename(self: *Filer, entry: *Entry, new_name: []const u8) void {
        if (new_name.len == 0 or std.mem.eql(u8, new_name, entry.name)) return;
        if (std.mem.indexOfAny(u8, new_name, "/\\") != null) {
            self.setStatus("invalid name: {s}", .{new_name});
            return;
        }
        var d = std.Io.Dir.openDirAbsolute(self.io, self.curPath(), .{}) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ self.curPath(), @errorName(err) });
            return;
        };
        defer d.close(self.io);
        d.rename(entry.name, d, new_name, self.io) catch |err| {
            self.setStatus("rename failed: {s} ({s})", .{ entry.name, @errorName(err) });
            return;
        };
        self.renamed(new_name);
    }

    fn confirmDelete(self: *Filer) void {
        const idx = self.selectedIndex() orelse return;
        const e = self.selectedEntry() orelse return;

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
        self.setActiveSelected(if (self.entries.items.len == 0)
            null
        else
            @min(idx, self.entries.items.len - 1));
        self.setStatus("deleted {s}", .{name});
    }

    fn renamed(self: *Filer, new_name: []const u8) void {
        self.setStatus("renamed to {s}", .{new_name});
        self.requestSelectName(new_name);
        self.scheduleReload();
    }

    /// Move `entry` (in the current directory) into `dest_dir` (absolute).
    fn moveEntryTo(self: *Filer, entry: *Entry, dest_dir: []const u8) void {
        const old_p = std.fs.path.join(self.allocator, &.{ self.curPath(), entry.name }) catch return;
        defer self.allocator.free(old_p);
        const new_p = std.fs.path.join(self.allocator, &.{ dest_dir, entry.name }) catch return;
        defer self.allocator.free(new_p);
        std.Io.Dir.renameAbsolute(old_p, new_p, self.io) catch |err| {
            self.setStatus("move failed: {s} ({s})", .{ entry.name, @errorName(err) });
            return;
        };
        self.setStatus("moved {s} -> {s}", .{ entry.name, dest_dir });
        self.scheduleReload();
    }

    // ── listeners ────────────────────────────────────────────────────────

    fn onActivate(self: *Filer, _: *const ActionEvent) void {
        self.openSelected();
    }

    fn onListContextMenu(self: *Filer, e: *const nimbus.List.ContextMenuEvent) void {
        if (e.row == null) return;
        self.popup.show(self.window, e.x, e.y) catch {};
    }

    fn onTableContextMenu(self: *Filer, e: *const nimbus.Table.ContextMenuEvent) void {
        if (e.row == null) return;
        self.popup.show(self.window, e.x, e.y) catch {};
    }

    fn onSort(self: *Filer, e: *const nimbus.Table.SortEvent) void {
        self.sort_col = e.column;
        self.sort_dir = e.direction;
        const keep = self.selectedEntry();
        self.applySort();
        // Keep the same entry selected across the reorder.
        if (keep) |k| for (self.entries.items, 0..) |it, i| {
            if (it == k) {
                self.setActiveSelected(i);
                break;
            }
        };
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
    fn onViewButton(self: *Filer, _: *const ActionEvent) void {
        self.setViewMode(switch (self.view_mode) {
            .list => .details,
            .details => .list,
        });
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

    fn onPlaceSelected(self: *Filer, _: *const ChangeEvent) void {
        const idx = self.places_list.getSelected() orelse return;
        if (idx >= self.places.items.len) return;
        self.loadDir(self.places.items[idx].path);
    }
};

// ── formatting helpers ─────────────────────────────────────────────────────

fn fmtSize(buf: []u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "";
    const kb = n / 1024;
    if (kb < 1024) return std.fmt.bufPrint(buf, "{d} KB", .{kb}) catch "";
    const mb = kb / 1024;
    if (mb < 1024) return std.fmt.bufPrint(buf, "{d} MB", .{mb}) catch "";
    return std.fmt.bufPrint(buf, "{d} GB", .{mb / 1024}) catch "";
}

fn fmtDate(buf: []u8, secs: i64) []const u8 {
    if (secs <= 0) return "";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch "";
}

// ── list-view cell (icon + name; inline rename via CellEditor) ──────────────

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

    fn start(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.cur_entry = e;
        self.field.setText(e.name) catch {};
        self.swapTo(true);
        self.field.component.requestFocus();
    }

    fn commit(ud: *anyopaque) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        self.swapTo(false);
        if (self.cur_entry) |e| self.filer.performRename(e, self.field.getText());
    }

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
        self.root.doLayout();
    }

    fn onSubmit(self: *FileCell, _: *const ActionEvent) void {
        self.filer.list.commitEdit();
    }
    fn onCancel(self: *FileCell, _: *const ActionEvent) void {
        self.filer.list.cancelEdit();
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        self.root.remove(&self.label.component);
        self.root.remove(&self.field.component);
        const rc = &self.root.component;
        rc.vtable.destroy(rc, allocator);
        self.label.component.vtable.destroy(&self.label.component, allocator);
        self.field.component.vtable.destroy(&self.field.component, allocator);
        allocator.destroy(self);
    }
};

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

    const root = try app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BorderLayout.get());

    const margin = try app.container();
    margin.component.setMinSize(.{ .width = 6, .height = 0 });
    try nimbus.BorderLayout.add(root, .west, &margin.component);

    const label = try app.label("");
    label.setIconSize(.{ .width = ICON, .height = ICON });
    const field = try app.textField("");
    try nimbus.BorderLayout.add(root, .center, &label.component);

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

    const margin = try app.container();
    margin.component.setMinSize(.{ .width = 6, .height = 0 });
    margin.component.setMaxSize(.{ .width = 6, .height = std.math.inf(f32) });
    try root.add(&margin.component);

    const label = try app.label("");
    label.setIconSize(.{ .width = ICON, .height = ICON });
    try root.add(&label.component);

    pc.* = .{ .root = root, .label = label, .icon_home = filer.icon_home, .icon_drive = filer.icon_drive };
    return .{
        .component = &root.component,
        .update    = PlaceCell.update,
        .destroy   = PlaceCell.destroyCell,
        .user_data = pc,
    };
}

// ── details-view (Table) cells: one typed cell per column ───────────────────

// Table Name-column cell: like the list FileCell (icon + name, with inline
// rename via CellEdit — label / field swap).
const NameCell = struct {
    root:      *nimbus.Container,
    label:     *nimbus.Label,
    field:     *nimbus.TextField,
    filer:     *Filer,
    cur_entry: ?*Entry = null,
    in_edit:   bool = false,

    fn update(ud: *anyopaque, ctx: nimbus.Table.CellContext) void {
        const self: *NameCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.cur_entry = e;
        self.label.setText(e.name) catch {};
        self.label.setIcon(if (e.is_dir) self.filer.icon_folder else self.filer.icon_file);
    }
    fn start(ud: *anyopaque, ctx: nimbus.Table.CellContext) void {
        const self: *NameCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.cur_entry = e;
        self.field.setText(e.name) catch {};
        self.swapTo(true);
        self.field.component.requestFocus();
    }
    fn commit(ud: *anyopaque) void {
        const self: *NameCell = @ptrCast(@alignCast(ud));
        self.swapTo(false);
        if (self.cur_entry) |e| self.filer.performRename(e, self.field.getText());
    }
    fn cancel(ud: *anyopaque) void {
        const self: *NameCell = @ptrCast(@alignCast(ud));
        self.swapTo(false);
    }
    fn swapTo(self: *NameCell, edit_mode: bool) void {
        if (edit_mode == self.in_edit) return;
        if (edit_mode) {
            self.root.remove(&self.label.component);
            nimbus.BorderLayout.add(self.root, .center, &self.field.component) catch {};
        } else {
            self.root.remove(&self.field.component);
            nimbus.BorderLayout.add(self.root, .center, &self.label.component) catch {};
        }
        self.in_edit = edit_mode;
        self.root.doLayout();
    }
    fn onSubmit(self: *NameCell, _: *const ActionEvent) void {
        self.filer.table.commitEdit();
    }
    fn onCancel(self: *NameCell, _: *const ActionEvent) void {
        self.filer.table.cancelEdit();
    }
    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *NameCell = @ptrCast(@alignCast(ud));
        self.root.remove(&self.label.component);
        self.root.remove(&self.field.component);
        const c = &self.root.component;
        c.vtable.destroy(c, allocator);
        self.label.component.vtable.destroy(&self.label.component, allocator);
        self.field.component.vtable.destroy(&self.field.component, allocator);
        allocator.destroy(self);
    }
};

const TextKind = enum { size, date };

const TextCell = struct {
    label: *nimbus.Label,
    kind:  TextKind,
    buf:   [40]u8 = undefined,
    fn update(ud: *anyopaque, ctx: nimbus.Table.CellContext) void {
        const self: *TextCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        const text = switch (self.kind) {
            .size => if (e.is_dir) "" else fmtSize(&self.buf, e.size),
            .date => fmtDate(&self.buf, e.mtime),
        };
        self.label.setText(text) catch {};
    }
    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TextCell = @ptrCast(@alignCast(ud));
        self.label.component.vtable.destroy(&self.label.component, allocator);
        allocator.destroy(self);
    }
};

fn createNameCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.Table.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const app = filer.app;
    const nc = try allocator.create(NameCell);
    errdefer allocator.destroy(nc);
    const root = try app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BorderLayout.get());
    const margin = try app.container();
    margin.component.setMinSize(.{ .width = 6, .height = 0 });
    try nimbus.BorderLayout.add(root, .west, &margin.component);
    const label = try app.label("");
    label.setIconSize(.{ .width = ICON, .height = ICON });
    const field = try app.textField("");
    try nimbus.BorderLayout.add(root, .center, &label.component);
    nc.* = .{ .root = root, .label = label, .field = field, .filer = filer };
    try field.addSubmitListener(NameCell, NameCell.onSubmit, nc);
    try field.addCancelListener(NameCell, NameCell.onCancel, nc);
    return .{
        .component = &root.component,
        .update    = NameCell.update,
        .destroy   = NameCell.destroyCell,
        .edit      = .{ .start = NameCell.start, .commit = NameCell.commit, .cancel = NameCell.cancel },
        .user_data = nc,
    };
}

fn createSizeCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.Table.Cell {
    return createTextCell(ud, allocator, .size);
}
fn createDateCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.Table.Cell {
    return createTextCell(ud, allocator, .date);
}
fn createTextCell(ud: *anyopaque, allocator: std.mem.Allocator, kind: TextKind) anyerror!nimbus.Table.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const tc = try allocator.create(TextCell);
    errdefer allocator.destroy(tc);
    const label = try filer.app.label("");
    tc.* = .{ .label = label, .kind = kind };
    return .{ .component = &label.component, .update = TextCell.update, .destroy = TextCell.destroyCell, .user_data = tc };
}

// ── drag & drop move (list view only) ──────────────────────────────────────

const entry_tag = dnd.tagOf(Entry);

const Mover = struct {
    filer: *Filer,
    ghost: *nimbus.Label,
    files_highlight:  ?usize = null,
    places_highlight: ?usize = null,

    fn dragEntry(e: *const dnd.DragEvent) ?*Entry {
        if (e.transfer.flavor != .object or e.transfer.type_tag != entry_tag) return null;
        return @ptrCast(@alignCast(e.transfer.object()));
    }
    fn rowAt(list: *nimbus.List, y: f32) ?usize {
        const h = list.getRowHeight();
        if (h <= 0 or y < 0) return null;
        return @intFromFloat(y / h);
    }

    fn onDragStart(ud: *anyopaque, x: f32, y: f32) ?dnd.Transfer {
        _ = x;
        const self: *Mover = @ptrCast(@alignCast(ud));
        const filer = self.filer;
        const row = rowAt(filer.list, y) orelse return null;
        if (row >= filer.entries.items.len) return null;
        const entry = filer.entries.items[row];
        self.ghost.setText(entry.name) catch {};
        self.ghost.setIcon(if (entry.is_dir) filer.icon_folder else filer.icon_file);
        filer.window.overlays.addPassthrough(&self.ghost.component) catch {};
        return .{ .flavor = .object, .ctx = entry, .type_tag = entry_tag, .source = filer.list.asComponent() };
    }
    fn onDrag(ud: *anyopaque, x: f32, y: f32) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        self.ghost.component.position = .{ .x = x + 12, .y = y + 12 };
    }
    fn onDragDone(ud: *anyopaque, performed: ?dnd.Action) void {
        _ = performed;
        const self: *Mover = @ptrCast(@alignCast(ud));
        self.filer.window.overlays.remove(@ptrCast(&self.ghost.component));
    }

    fn filesOnOver(ud: *anyopaque, e: *const dnd.DragEvent) bool {
        const self: *Mover = @ptrCast(@alignCast(ud));
        const filer = self.filer;
        const entry = dragEntry(e) orelse return false;
        var hl: ?usize = null;
        if (rowAt(filer.list, e.y)) |row| {
            if (row < filer.entries.items.len) {
                const target = filer.entries.items[row];
                if (target.is_dir and target != entry) hl = row;
            }
        }
        self.files_highlight = hl;
        filer.list.asComponent().repaint();
        return hl != null;
    }
    fn filesOnLeave(ud: *anyopaque) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        self.files_highlight = null;
        self.filer.list.asComponent().repaint();
    }
    fn filesOnDrop(ud: *anyopaque, e: *const dnd.DragEvent) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        const filer = self.filer;
        self.files_highlight = null;
        const entry = dragEntry(e) orelse return;
        const row = rowAt(filer.list, e.y) orelse return;
        if (row >= filer.entries.items.len) return;
        const target = filer.entries.items[row];
        if (!target.is_dir or target == entry) return;
        const dest = std.fs.path.join(filer.allocator, &.{ filer.curPath(), target.name }) catch return;
        defer filer.allocator.free(dest);
        filer.moveEntryTo(entry, dest);
    }

    fn placesOnOver(ud: *anyopaque, e: *const dnd.DragEvent) bool {
        const self: *Mover = @ptrCast(@alignCast(ud));
        const filer = self.filer;
        var hl: ?usize = null;
        if (dragEntry(e) != null) {
            if (rowAt(filer.places_list, e.y)) |row| {
                if (row < filer.places.items.len) {
                    const place = filer.places.items[row];
                    if (!std.mem.eql(u8, place.path, filer.curPath())) hl = row;
                }
            }
        }
        self.places_highlight = hl;
        filer.places_list.asComponent().repaint();
        return hl != null;
    }
    fn placesOnLeave(ud: *anyopaque) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        self.places_highlight = null;
        self.filer.places_list.asComponent().repaint();
    }
    fn placesOnDrop(ud: *anyopaque, e: *const dnd.DragEvent) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        const filer = self.filer;
        self.places_highlight = null;
        const entry = dragEntry(e) orelse return;
        const row = rowAt(filer.places_list, e.y) orelse return;
        if (row >= filer.places.items.len) return;
        const place = filer.places.items[row];
        if (std.mem.eql(u8, place.path, filer.curPath())) return;
        filer.moveEntryTo(entry, place.path);
    }
};

fn dndListPaint(self: *nimbus.Component, g: *awt.Graphics) void {
    nimbus.List.vtable.paint(self, g);
    const m = self.getTyped(Mover) orelse return;
    const is_files = self == m.filer.list.asComponent();
    const hl = if (is_files) m.files_highlight else m.places_highlight;
    if (hl) |row| {
        const list = if (is_files) m.filer.list else m.filer.places_list;
        const h = list.getRowHeight();
        const y = @as(f32, @floatFromInt(row)) * h;
        g.setColor(self.theme.focus_ring);
        g.drawRect(.{ .x = 1, .y = y + 1, .width = self.size.width - 2, .height = h - 2 });
    }
}

const dnd_list_vt = blk: {
    var vt = nimbus.List.vtable;
    vt.paint = dndListPaint;
    break :blk vt;
};

// ── confirm dialog ──────────────────────────────────────────────────────────

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

// ── ui assembly ──────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    // The shared model outlives the views (which unsubscribe on destroy in
    // app.deinit), so it is created first → its deinit runs last.
    var model = Model.init(init.gpa);
    defer model.deinit();

    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("nimbus filer", 760, 520);

    var filer = Filer{
        .allocator   = init.gpa,
        .io          = init.io,
        .app         = app,
        .icon_folder = try app.icon(.folder),
        .icon_file   = try app.icon(.file),
        .icon_home   = try app.icon(.house),
        .icon_drive  = try app.icon(.hard_drive),
        .model       = &model,
    };
    filer.window = &frame.window;
    defer {
        filer.clearEntries();
        filer.entries.deinit(init.gpa);
        filer.clearPlaces();
        filer.places.deinit(init.gpa);
    }

    // Right pane: list view (shares the model) with inline rename.
    const lst = try app.listWithModel(&model, .{ .create = createFileCell, .user_data = &filer });
    filer.list = lst;
    lst.setRowHeight(ROW_HEIGHT);
    lst.setEditTrigger(.manual);
    try lst.addActionListener(Filer, Filer.onActivate, &filer);
    try lst.addContextMenuListener(Filer, Filer.onListContextMenu, &filer);
    const lsp = try app.scrollPane(lst.asComponent());
    filer.list_sp = lsp;

    // Right pane: details view (Table over the SAME model).
    const tbl = try app.tableWithModel(&model, &.{
        .{ .title = "Name", .width = 300, .factory = .{ .create = createNameCell, .user_data = &filer } },
        .{ .title = "Size", .width = 90, .factory = .{ .create = createSizeCell, .user_data = &filer } },
        .{ .title = "Modified", .width = 150, .factory = .{ .create = createDateCell, .user_data = &filer } },
    });
    filer.table = tbl;
    tbl.setRowHeight(ROW_HEIGHT);
    tbl.setSortIndicator(0, .ascending);
    try tbl.addActionListener(Filer, Filer.onActivate, &filer);
    try tbl.addContextMenuListener(Filer, Filer.onTableContextMenu, &filer);
    try tbl.addSortListener(Filer, Filer.onSort, &filer);
    const tsp = try app.scrollPane(tbl.asComponent());
    filer.table_sp = tsp;

    // Holder with a card layout: both scroll panes are children; only the
    // active one is shown (the other collapses to zero size).
    var card = CardLayout{ .base = .{ .vtable = &CardLayout.vt } };
    filer.card = &card;
    const holder = try app.container();
    filer.right_center = holder;
    holder.setLayout(&card.base);
    try holder.add(lsp.asComponent());
    try holder.add(tsp.asComponent());
    card.active = lsp.asComponent();

    // Left pane: places.
    const places = try app.list(.{ .create = createPlaceCell, .user_data = &filer });
    filer.places_list = places;
    places.setRowHeight(ROW_HEIGHT);
    try places.addChangeListener(Filer, Filer.onPlaceSelected, &filer);
    const places_sp = try app.scrollPane(places.asComponent());

    const split = try app.splitPane(.horizontal, places_sp.asComponent(), &holder.component);
    split.setDividerLocation(SIDEBAR_WIDTH);
    split.asComponent().setGrowX(1);
    split.asComponent().setGrowY(1);
    try nimbus.BorderLayout.add(&frame.window.container, .center, split.asComponent());

    // Drag & drop move (list view only — see header note).
    const ghost = try app.label("");
    ghost.setIconSize(.{ .width = ICON, .height = ICON });
    ghost.component.size = .{ .width = 240, .height = ROW_HEIGHT };
    defer ghost.component.vtable.destroy(&ghost.component, init.gpa);
    var mover = Mover{ .filer = &filer, .ghost = ghost };
    lst.asComponent().drag_source = .{ .onDragStart = Mover.onDragStart, .onDrag = Mover.onDrag, .onDragDone = Mover.onDragDone, .user_data = &mover };
    lst.asComponent().drop_target = .{ .onOver = Mover.filesOnOver, .onLeave = Mover.filesOnLeave, .onDrop = Mover.filesOnDrop, .user_data = &mover };
    places.asComponent().drop_target = .{ .onOver = Mover.placesOnOver, .onLeave = Mover.placesOnLeave, .onDrop = Mover.placesOnDrop, .user_data = &mover };
    lst.asComponent().vtable = &dnd_list_vt;
    places.asComponent().vtable = &dnd_list_vt;
    try lst.asComponent().putProperty(@typeName(Mover), &mover, null);
    try places.asComponent().putProperty(@typeName(Mover), &mover, null);

    // Row context menu (caller-owned, reused).
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

    // Delete confirmation (caller-owned).
    const confirm = try app.dialog(&frame.window, "Confirm", 320, 120);
    defer confirm.destroy();
    filer.confirm = confirm;
    const confirm_msg = try app.label("");
    filer.confirm_msg = confirm_msg;
    try buildConfirmDialog(app, confirm, confirm_msg);

    // Toolbar (north): [up] [view] path
    const bar = try app.container();
    bar.setLayout(nimbus.BoxLayout.horizontal());
    const up = try app.button("");
    up.setIcon(try app.icon(.arrow_up));
    up.setIconSize(.{ .width = ICON, .height = ICON });
    try up.getModel().addActionListener(Filer, Filer.onUpButton, &filer);
    const view_btn = try app.button("Details");
    filer.view_button = view_btn;
    try view_btn.getModel().addActionListener(Filer, Filer.onViewButton, &filer);
    const gap = try app.container();
    gap.component.setMinSize(.{ .width = 6, .height = 0 });
    gap.component.setMaxSize(.{ .width = 6, .height = std.math.inf(f32) });
    const path_label = try app.label("");
    filer.path_label = path_label;
    path_label.component.setAlignY(.center);
    try bar.add(&up.component);
    try bar.add(&view_btn.component);
    try bar.add(&gap.component);
    try bar.add(&path_label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .north, &bar.component);

    // Status line (south).
    const status = try app.label("");
    filer.status = status;
    try nimbus.BorderLayout.add(&frame.window.container, .south, &status.component);

    // Keys: Backspace / F5 anywhere; F2 / Delete on whichever view is focused.
    try frame.window.container.component.bindKey(nimbus.KeyStroke.of(.backspace), nimbus.KeyHandler.typed(Filer, Filer.onBackspace, &filer));
    try frame.window.container.component.bindKey(nimbus.KeyStroke.of(.f5), nimbus.KeyHandler.typed(Filer, Filer.onReloadKey, &filer));
    for ([_]*nimbus.Component{ lst.asComponent(), tbl.asComponent() }) |c| {
        try c.bindKey(nimbus.KeyStroke.of(.f2), nimbus.KeyHandler.typed(Filer, Filer.onRenameKey, &filer));
        try c.bindKey(nimbus.KeyStroke.of(.delete), nimbus.KeyHandler.typed(Filer, Filer.onDeleteKey, &filer));
    }

    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    filer.buildPlaces(init.environ_map.get(home_var));

    var buf: [PATH_BUF]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(init.io, &buf);
    filer.loadDir(buf[0..n]);

    std.debug.print(
        \\filer M5 — toolbar "Details"/"List" toggles the right-pane view.
        \\Details view: click a header to sort, drag a column boundary to resize.
        \\Double-click/Enter opens, right-click for the menu, F2 renames, Delete removes, F5 reloads.
        \\
    , .{});
    try app.run();
}
