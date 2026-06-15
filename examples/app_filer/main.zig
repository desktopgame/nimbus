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
//!   - editable path bar navigates to an absolute path on Enter
//!   - background right-click or Ctrl+Shift+N creates "New Folder" and starts rename
//!   - F2 (or the menu) renames in place in BOTH views (the Table's Name
//!     column carries a CellEdit). Delete asks in a modal, then removes the
//!     file / empty folder. F5 reloads; up-arrow / Backspace goes to parent.
//!
//! The list and details views both support drag-to-move into folders and places.
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
const SEARCH_BATCH_SIZE = 32;

const ViewMode = enum { list, details };
pub const RunnerKind = enum { threaded, manual };

pub const SearchLogic = struct {
    pub fn matches(name: []const u8, query: []const u8) bool {
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len == 0) return false;
        return std.ascii.indexOfIgnoreCase(name, q) != null;
    }
};

/// One directory entry. Owned by Filer (`entries`); the model borrows it.
const Entry = struct {
    name: []u8,
    is_dir: bool,
    size: u64 = 0,
    mtime: i64 = 0, // seconds since epoch (UTC), 0 = unknown
};

/// One sidebar destination. Owned by Filer (`places`); the model borrows it.
const Place = struct {
    name: []u8,
    path: []u8,
    kind: Kind,

    const Kind = enum { home, drive };
};

const Hit = struct {
    path: []u8,
};

const Batch = struct {
    gen: u64,
    filer: *Filer,
    paths: [][]u8,
    consumed: bool = false,
};

const Finish = struct {
    gen: u64,
    filer: *Filer,
    cancelled: bool,
};

const SearchJob = struct {
    gen: u64,
    cancelled: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    root: [PATH_BUF]u8 = undefined,
    root_len: usize = 0,
    query: [NAME_BUF]u8 = undefined,
    query_len: usize = 0,
    // std.testing.allocator and the process GPA used by the app are safe for
    // this worker usage. If a different allocator is introduced, wrap it with
    // ThreadSafeAllocator before assigning it here.
    allocator: std.mem.Allocator,
    io: std.Io,
    filer: *Filer,
    runner: RunnerKind,
    manual_stack: std.ArrayList([]u8) = .empty,
    manual_ready: bool = false,

    fn rootPath(self: *const SearchJob) []const u8 {
        return self.root[0..self.root_len];
    }

    fn queryText(self: *const SearchJob) []const u8 {
        return self.query[0..self.query_len];
    }
};

/// Card-stack layout: the `active` child fills the container; every other
/// child is collapsed to zero size (kept owned by the container, just hidden).
/// nimbus has no built-in CardLayout; this is the few-line custom-LayoutManager
/// recipe (a dogfooding finding worth a backlog note).
const CardLayout = struct {
    base: nimbus.LayoutManager,
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

pub const Filer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app: *nimbus.Application,
    icon_folder: awt.Image,
    icon_file: awt.Image,
    icon_home: awt.Image,
    icon_drive: awt.Image,
    model: Model, // shared by both right-pane views
    results_model: Model,
    list: *nimbus.List = undefined,
    list_sp: *nimbus.ScrollPane = undefined,
    results_list: *nimbus.List = undefined,
    results_sp: *nimbus.ScrollPane = undefined,
    table: *nimbus.Table = undefined,
    table_sp: *nimbus.ScrollPane = undefined,
    right_center: *nimbus.Container = undefined,
    card: CardLayout = undefined,
    view_mode: ViewMode = .list,
    view_button: *nimbus.Button = undefined,
    places_list: *nimbus.List = undefined,
    path_field: *nimbus.TextField = undefined,
    status: *nimbus.Label = undefined,
    window: *nimbus.Window = undefined,
    popup: *nimbus.PopupMenu = undefined,
    background_popup: *nimbus.PopupMenu = undefined,
    confirm: *nimbus.Dialog = undefined,
    confirm_msg: *nimbus.Label = undefined,
    mover: Mover = undefined,
    ghost: *nimbus.Label = undefined,
    entries: std.ArrayList(*Entry) = .empty,
    places: std.ArrayList(*Place) = .empty,
    cur: [PATH_BUF]u8 = undefined,
    cur_len: usize = 0,
    status_buf: [512]u8 = undefined,
    sort_col: usize = 0,
    sort_dir: nimbus.Table.SortDirection = .ascending,
    pending: [NAME_BUF]u8 = undefined,
    pending_len: usize = 0,
    pending_edit: bool = false,
    runner: RunnerKind = .threaded,
    search_gen: u64 = 0,
    search_job: ?*SearchJob = null,
    results: std.ArrayList(*Hit) = .empty,
    search_field: *nimbus.TextField = undefined,
    search_button: *nimbus.Button = undefined,
    cancel_button: *nimbus.Button = undefined,
    result_count: *nimbus.Label = undefined,
    prev_view: ?*nimbus.Component = null,
    tearing_down: bool = false,

    pub fn deinitUi(self: *Filer) void {
        self.tearing_down = true;
        self.searchStop();
        self.app.event_queue.drain();
        self.clearResults();
        self.results.deinit(self.allocator);
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.clearPlaces();
        self.places.deinit(self.allocator);
        self.popup.destroy();
        self.background_popup.destroy();
        self.confirm.destroy();
        self.ghost.component.vtable.destroy(&self.ghost.component, self.allocator);
    }

    pub fn deinitModel(self: *Filer, gpa: std.mem.Allocator) void {
        self.results_model.deinit();
        self.model.deinit();
        gpa.destroy(self);
    }

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

    fn clearResults(self: *Filer) void {
        self.results_model.clear();
        for (self.results.items) |h| {
            self.allocator.free(h.path);
            self.allocator.destroy(h);
        }
        self.results.clearRetainingCapacity();
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
    fn loadDir(self: *Filer, path: []const u8) bool {
        if (self.search_job != null) self.searchStop();
        if (path.len == 0) {
            self.setStatus("path is empty", .{});
            return false;
        }
        if (path.len > PATH_BUF) {
            self.setStatus("path too long", .{});
            return false;
        }
        var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ path, @errorName(err) });
            return false;
        };
        defer dir.close(self.io);

        var real_buf: [PATH_BUF]u8 = undefined;
        const real_path = if (dir.realPath(self.io, &real_buf)) |n| real_buf[0..n] else |_| path;
        const same_dir = std.mem.eql(u8, real_path, self.curPath());

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

        if (real_path.ptr != @as([*]const u8, @ptrCast(&self.cur))) {
            @memcpy(self.cur[0..real_path.len], real_path);
        }
        self.cur_len = real_path.len;
        self.path_field.setText(self.curPath()) catch {};

        var sel: ?usize = if (self.entries.items.len > 0) 0 else null;
        var pending_match: ?usize = null;
        if (self.pending_len > 0) {
            const want = self.pending[0..self.pending_len];
            for (self.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, want)) {
                    sel = i;
                    pending_match = i;
                    break;
                }
            }
            self.pending_len = 0;
            if (pending_match == null) self.pending_edit = false;
        }
        self.setActiveSelected(sel);
        if (pending_match) |idx| {
            if (self.pending_edit) self.startPendingEdit(idx);
        } else {
            self.pending_edit = false;
        }

        if (!same_dir) {
            self.list_sp.setScrollY(0);
            self.table_sp.setScrollY(0);
        }
        self.leaveResultsView();
        self.setStatus("{d} items", .{self.entries.items.len});
        return true;
    }

    fn showResultsView(self: *Filer) void {
        if (self.prev_view == null) self.prev_view = self.card.active;
        self.card.active = self.results_sp.asComponent();
        self.right_center.component.markLayoutDirty();
        self.right_center.component.repaint();
    }

    fn leaveResultsView(self: *Filer) void {
        if (self.prev_view) |prev| {
            self.card.active = prev;
            self.prev_view = null;
            self.right_center.component.markLayoutDirty();
            self.right_center.component.repaint();
        }
    }

    fn exitResults(self: *Filer) void {
        if (self.search_job != null) {
            self.searchStop();
            return;
        }
        self.leaveResultsView();
        self.updateSearchStatus("{d} items", .{self.entries.items.len});
    }

    fn updateSearchStatus(self: *Filer, comptime fmt: []const u8, args: anytype) void {
        self.setStatus(fmt, args);
        const text = std.fmt.bufPrint(&self.status_buf, fmt, args) catch return;
        self.result_count.setText(text) catch {};
    }

    fn appendResult(self: *Filer, path: []u8) void {
        const h = self.allocator.create(Hit) catch {
            self.allocator.free(path);
            return;
        };
        h.* = .{ .path = path };
        self.results.append(self.allocator, h) catch {
            self.allocator.free(h.path);
            self.allocator.destroy(h);
            return;
        };
        self.results_model.add(@ptrCast(h)) catch {};
    }

    fn destroyBatch(self: *Filer, b: *Batch) void {
        if (!b.consumed) for (b.paths) |p| self.allocator.free(p);
        self.allocator.free(b.paths);
        self.allocator.destroy(b);
    }

    fn destroyFinish(self: *Filer, f: *Finish) void {
        self.allocator.destroy(f);
    }

    fn destroyJob(self: *Filer, job: *SearchJob) void {
        for (job.manual_stack.items) |p| job.allocator.free(p);
        job.manual_stack.deinit(job.allocator);
        self.allocator.destroy(job);
    }

    fn makeJob(self: *Filer, root: []const u8, query: []const u8) ?*SearchJob {
        if (root.len > PATH_BUF or query.len > NAME_BUF) return null;
        const job = self.allocator.create(SearchJob) catch return null;
        job.* = .{
            .gen = self.search_gen,
            .allocator = self.allocator,
            .io = self.io,
            .filer = self,
            .runner = self.runner,
        };
        @memcpy(job.root[0..root.len], root);
        job.root_len = root.len;
        @memcpy(job.query[0..query.len], query);
        job.query_len = query.len;
        return job;
    }

    pub fn searchStart(self: *Filer, raw_query: []const u8) void {
        const query = std.mem.trim(u8, raw_query, " \t\r\n");
        self.searchStop();
        self.clearResults();
        if (query.len == 0) {
            self.leaveResultsView();
            self.updateSearchStatus("{d} items", .{self.entries.items.len});
            return;
        }
        const job = self.makeJob(self.curPath(), query) orelse {
            self.updateSearchStatus("search failed", .{});
            return;
        };
        self.search_job = job;
        self.showResultsView();
        self.updateSearchStatus("searching... {d}", .{self.results.items.len});
        if (self.runner == .threaded) {
            job.thread = std.Thread.spawn(.{}, walkThread, .{job}) catch {
                self.search_job = null;
                self.destroyJob(job);
                self.updateSearchStatus("search failed", .{});
                return;
            };
        }
    }

    pub fn searchStop(self: *Filer) void {
        const job = self.search_job orelse return;
        job.cancelled.store(true, .release);
        if (job.thread) |t| t.join();
        self.search_gen +%= 1;
        self.search_job = null;
        self.destroyJob(job);
        self.clearResults();
        self.leaveResultsView();
        if (!self.tearing_down) self.updateSearchStatus("cancelled ({d})", .{self.results.items.len});
    }

    fn finishSearch(self: *Filer, gen: u64, cancelled: bool) void {
        if (gen != self.search_gen) return;
        const job = self.search_job orelse return;
        if (job.thread) |t| t.join();
        self.search_job = null;
        self.destroyJob(job);
        if (cancelled) {
            self.updateSearchStatus("cancelled ({d})", .{self.results.items.len});
        } else if (self.results.items.len == 0) {
            self.updateSearchStatus("no matches", .{});
        } else {
            self.updateSearchStatus("done: {d} found", .{self.results.items.len});
        }
    }

    pub fn searchStepForTest(self: *Filer, max_entries: usize) void {
        const job = self.search_job orelse return;
        if (job.runner != .manual or job.cancelled.load(.acquire)) return;
        produceManual(job, max_entries);
    }

    pub fn searchResultCountForTest(self: *const Filer) usize {
        return self.results.items.len;
    }

    pub fn searchRunningForTest(self: *const Filer) bool {
        return self.search_job != null;
    }

    pub fn curPathForTest(self: *const Filer) []const u8 {
        return self.curPath();
    }

    pub fn showingResultsForTest(self: *const Filer) bool {
        return self.card.active == self.results_sp.asComponent();
    }

    pub fn cancelSearchForTest(self: *Filer) void {
        self.exitResults();
    }

    pub fn activateResultForTest(self: *Filer, idx: usize) void {
        self.activateResultIndex(idx);
    }

    fn requestSelectName(self: *Filer, name: []const u8) void {
        const n = @min(name.len, self.pending.len);
        @memcpy(self.pending[0..n], name[0..n]);
        self.pending_len = n;
    }

    fn reloadTask(ud: *anyopaque) void {
        const self: *Filer = @ptrCast(@alignCast(ud));
        if (self.tearing_down) return;
        _ = self.loadDir(self.curPath());
    }

    fn scheduleReload(self: *Filer) void {
        self.app.event_queue.invokeLater(reloadTask, @ptrCast(self)) catch {};
    }

    fn pendingEditTask(ud: *anyopaque) void {
        const self: *Filer = @ptrCast(@alignCast(ud));
        if (self.tearing_down) return;
        if (!self.pending_edit) return;
        const idx = self.selectedIndex() orelse {
            self.pending_edit = false;
            return;
        };
        self.pending_edit = false;
        self.editIndex(idx);
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

    fn focusActiveView(self: *Filer) void {
        switch (self.view_mode) {
            .list => self.list.asComponent().requestFocus(),
            .details => self.table.asComponent().requestFocus(),
        }
    }

    fn activeFilesComponent(self: *Filer) *nimbus.Component {
        return switch (self.view_mode) {
            .list => self.list.asComponent(),
            .details => self.table.asComponent(),
        };
    }

    fn activeRowAt(self: *Filer, y: f32) ?usize {
        return switch (self.view_mode) {
            .list => Mover.rowAt(self.list, y),
            .details => self.table.rowAtLocalY(y),
        };
    }

    /// Selected row indices of the active view (sorted ascending). Borrowed.
    fn selectedIndices(self: *Filer) []const usize {
        return switch (self.view_mode) {
            .list => self.list.getSelectedIndices(),
            .details => self.table.getSelectedIndices(),
        };
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
            _ = self.loadDir(joined);
        } else {
            self.setStatus("file: {s} (opening comes in a later milestone)", .{e.name});
        }
    }

    fn goUp(self: *Filer) void {
        const parent = std.fs.path.dirname(self.curPath()) orelse {
            self.setStatus("already at the root", .{});
            return;
        };
        _ = self.loadDir(parent);
    }

    fn renameSelected(self: *Filer) void {
        // Both views edit in place now: the list cell and the Table's Name
        // column (col 0) each carry a CellEdit.
        const idx = self.selectedIndex() orelse return;
        self.editIndex(idx);
    }

    fn editIndex(self: *Filer, idx: usize) void {
        switch (self.view_mode) {
            .list => self.list.edit(idx),
            .details => self.table.edit(idx, 0),
        }
    }

    fn isEditingIndex(self: *const Filer, idx: usize) bool {
        return switch (self.view_mode) {
            .list => self.list.getEditing() == idx,
            .details => if (self.table.getEditing()) |pos| pos.row == idx and pos.col == 0 else false,
        };
    }

    fn commitActiveEdit(self: *Filer) void {
        switch (self.view_mode) {
            .list => self.list.commitEdit(),
            .details => self.table.commitEdit(),
        }
    }

    fn startPendingEdit(self: *Filer, idx: usize) void {
        self.pending_edit = false;
        self.editIndex(idx);
        if (!self.isEditingIndex(idx)) {
            self.pending_edit = true;
            self.app.event_queue.invokeLater(pendingEditTask, @ptrCast(self)) catch {
                self.pending_edit = false;
            };
        }
    }

    fn createNewFolder(self: *Filer) void {
        self.commitActiveEdit();

        var d = std.Io.Dir.openDirAbsolute(self.io, self.curPath(), .{}) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ self.curPath(), @errorName(err) });
            return;
        };
        defer d.close(self.io);

        var name_buf: [NAME_BUF]u8 = undefined;
        var attempt: usize = 1;
        while (attempt < 10_000) : (attempt += 1) {
            const name = if (attempt == 1)
                "New Folder"
            else
                std.fmt.bufPrint(&name_buf, "New Folder ({d})", .{attempt}) catch return;
            d.createDir(self.io, name, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => {
                    self.setStatus("new folder failed: {s} ({s})", .{ name, @errorName(err) });
                    return;
                },
            };
            self.setStatus("created {s}", .{name});
            self.requestSelectName(name);
            self.pending_edit = true;
            self.scheduleReload();
            return;
        }
        self.setStatus("new folder failed: too many existing names", .{});
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
        const sel_live = self.selectedIndices();
        if (sel_live.len == 0) return;
        // Snapshot the indices: the live selection mutates on reload below.
        const sel = self.allocator.dupe(usize, sel_live) catch return;
        defer self.allocator.free(sel);

        var msg_buf: [NAME_BUF + 32]u8 = undefined;
        const msg = if (sel.len == 1) one: {
            const e = self.entries.items[sel[0]];
            break :one std.fmt.bufPrint(&msg_buf, "Delete \"{s}\"?", .{e.name}) catch return;
        } else std.fmt.bufPrint(&msg_buf, "Delete {d} items?", .{sel.len}) catch return;
        self.confirm_msg.setText(msg) catch {};
        if (self.confirm.showModal() != .ok) return;

        var d = std.Io.Dir.openDirAbsolute(self.io, self.curPath(), .{}) catch |err| {
            self.setStatus("cannot open {s}: {s}", .{ self.curPath(), @errorName(err) });
            return;
        };
        defer d.close(self.io);

        var ok: usize = 0;
        var failed: usize = 0;
        for (sel) |idx| {
            if (idx >= self.entries.items.len) continue;
            const e = self.entries.items[idx];
            const res = if (e.is_dir) d.deleteDir(self.io, e.name) else d.deleteFile(self.io, e.name);
            if (res) |_| {
                ok += 1;
            } else |_| {
                failed += 1;
            }
        }

        _ = self.loadDir(self.curPath());
        const keep = std.mem.min(usize, sel);
        self.setActiveSelected(if (self.entries.items.len == 0)
            null
        else
            @min(keep, self.entries.items.len - 1));
        if (failed == 0)
            self.setStatus("deleted {d}", .{ok})
        else
            self.setStatus("deleted {d}, {d} failed", .{ ok, failed });
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

    /// Move several entries (by index in the current dir) into `dest_dir`.
    fn moveEntriesTo(self: *Filer, dest_dir: []const u8, idxs: []const usize) void {
        var ok: usize = 0;
        var failed: usize = 0;
        for (idxs) |i| {
            if (i >= self.entries.items.len) continue;
            const entry = self.entries.items[i];
            const old_p = std.fs.path.join(self.allocator, &.{ self.curPath(), entry.name }) catch continue;
            defer self.allocator.free(old_p);
            const new_p = std.fs.path.join(self.allocator, &.{ dest_dir, entry.name }) catch continue;
            defer self.allocator.free(new_p);
            if (std.Io.Dir.renameAbsolute(old_p, new_p, self.io)) |_| {
                ok += 1;
            } else |_| {
                failed += 1;
            }
        }
        if (failed == 0)
            self.setStatus("moved {d} -> {s}", .{ ok, dest_dir })
        else
            self.setStatus("moved {d}, {d} failed", .{ ok, failed });
        self.scheduleReload();
    }

    /// DnD move: if the dragged entry is part of a multi-selection, move the
    /// whole selection; otherwise just the dragged entry.
    fn moveDraggedTo(self: *Filer, dragged: *Entry, dest_dir: []const u8) void {
        const sel = self.selectedIndices();
        var in_sel = false;
        for (sel) |i| {
            if (i < self.entries.items.len and self.entries.items[i] == dragged) {
                in_sel = true;
                break;
            }
        }
        if (in_sel and sel.len > 1) {
            const idxs = self.allocator.dupe(usize, sel) catch return self.moveEntryTo(dragged, dest_dir);
            defer self.allocator.free(idxs);
            self.moveEntriesTo(dest_dir, idxs);
        } else {
            self.moveEntryTo(dragged, dest_dir);
        }
    }

    // ── listeners ────────────────────────────────────────────────────────

    fn onActivate(self: *Filer, _: *const ActionEvent) void {
        self.openSelected();
    }

    fn onListContextMenu(self: *Filer, e: *const nimbus.List.ContextMenuEvent) void {
        const menu = if (e.row == null) self.background_popup else self.popup;
        menu.show(self.window, e.x, e.y) catch {};
    }

    fn onTableContextMenu(self: *Filer, e: *const nimbus.Table.ContextMenuEvent) void {
        const menu = if (e.row == null) self.background_popup else self.popup;
        menu.show(self.window, e.x, e.y) catch {};
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
    fn onMenuNewFolder(self: *Filer, _: *const ActionEvent) void {
        self.createNewFolder();
    }
    fn onSearchSubmit(self: *Filer, _: *const ActionEvent) void {
        self.searchStart(self.search_field.getText());
    }
    fn onSearchCancel(self: *Filer, _: *const ActionEvent) void {
        self.exitResults();
    }
    fn onSearchButton(self: *Filer, _: *const ActionEvent) void {
        self.searchStart(self.search_field.getText());
    }
    fn onCancelButton(self: *Filer, _: *const ActionEvent) void {
        self.exitResults();
    }
    fn onResultsEscape(self: *Filer) void {
        self.exitResults();
    }
    fn onResultActivate(self: *Filer, _: *const ActionEvent) void {
        const idx = self.results_list.getSelected() orelse return;
        self.activateResultIndex(idx);
    }
    fn activateResultIndex(self: *Filer, idx: usize) void {
        if (idx >= self.results.items.len) return;
        const path = self.results.items[idx].path;
        const dir = std.fs.path.dirname(path) orelse return;
        if (dir.len > PATH_BUF) return;
        var dir_buf: [PATH_BUF]u8 = undefined;
        @memcpy(dir_buf[0..dir.len], dir);
        const base = std.fs.path.basename(path);
        self.requestSelectName(base);
        _ = self.loadDir(dir_buf[0..dir.len]);
    }
    fn onPathSubmit(self: *Filer, _: *const ActionEvent) void {
        const path = std.mem.trim(u8, self.path_field.getText(), " \t\r\n");
        const loaded = self.loadDir(path);
        self.path_field.setText(self.curPath()) catch {};
        if (loaded) {
            self.focusActiveView();
        } else {
            self.path_field.component.requestFocus();
        }
    }
    fn onPathCancel(self: *Filer, _: *const ActionEvent) void {
        self.path_field.setText(self.curPath()) catch {};
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
        _ = self.loadDir(self.curPath());
    }
    fn onNewFolderKey(self: *Filer) void {
        self.createNewFolder();
    }

    fn onPlaceSelected(self: *Filer, _: *const ChangeEvent) void {
        const idx = self.places_list.getSelected() orelse return;
        if (idx >= self.places.items.len) return;
        _ = self.loadDir(self.places.items[idx].path);
    }
};

// ── formatting helpers ─────────────────────────────────────────────────────

fn freePathList(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    for (paths.items) |p| allocator.free(p);
    paths.deinit(allocator);
}

fn flushBatch(job: *SearchJob, paths: *std.ArrayList([]u8)) void {
    if (paths.items.len == 0) return;
    const slice = job.allocator.dupe([]u8, paths.items) catch {
        freePathList(job.allocator, paths);
        paths.* = .empty;
        return;
    };
    paths.clearRetainingCapacity();
    const batch = job.allocator.create(Batch) catch {
        for (slice) |p| job.allocator.free(p);
        job.allocator.free(slice);
        return;
    };
    batch.* = .{ .gen = job.gen, .filer = job.filer, .paths = slice };
    job.filer.app.event_queue.invokeLater(publishBatch, @ptrCast(batch)) catch {
        job.filer.destroyBatch(batch);
    };
}

fn pushHit(job: *SearchJob, paths: *std.ArrayList([]u8), full_path: []const u8) void {
    const owned = job.allocator.dupe(u8, full_path) catch return;
    paths.append(job.allocator, owned) catch {
        job.allocator.free(owned);
        return;
    };
    if (paths.items.len >= SEARCH_BATCH_SIZE) flushBatch(job, paths);
}

fn postFinish(job: *SearchJob, cancelled: bool) void {
    const finish = job.allocator.create(Finish) catch return;
    finish.* = .{ .gen = job.gen, .filer = job.filer, .cancelled = cancelled };
    job.filer.app.event_queue.invokeLater(finishTask, @ptrCast(finish)) catch {
        job.filer.destroyFinish(finish);
    };
}

fn scanDir(job: *SearchJob, dir_path: []const u8, paths: *std.ArrayList([]u8)) void {
    if (job.cancelled.load(.acquire)) return;
    var dir = std.Io.Dir.openDirAbsolute(job.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(job.io);

    var it = dir.iterate();
    while (!job.cancelled.load(.acquire)) {
        const ent = it.next(job.io) catch null orelse break;
        const full = std.fs.path.join(job.allocator, &.{ dir_path, ent.name }) catch continue;
        defer job.allocator.free(full);
        if (SearchLogic.matches(ent.name, job.queryText())) pushHit(job, paths, full);
        if (ent.kind == .directory) scanDir(job, full, paths);
    }
}

fn walkThread(job: *SearchJob) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer freePathList(job.allocator, &paths);
    scanDir(job, job.rootPath(), &paths);
    flushBatch(job, &paths);
    postFinish(job, job.cancelled.load(.acquire));
}

fn ensureManualReady(job: *SearchJob) void {
    if (job.manual_ready) return;
    collectManualPaths(job, job.rootPath());
    job.manual_ready = true;
}

fn collectManualPaths(job: *SearchJob, dir_path: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(job.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(job.io);
    var it = dir.iterate();
    while (it.next(job.io) catch null) |ent| {
        const full = std.fs.path.join(job.allocator, &.{ dir_path, ent.name }) catch continue;
        job.manual_stack.append(job.allocator, full) catch {
            job.allocator.free(full);
            continue;
        };
        if (ent.kind == .directory) collectManualPaths(job, full);
    }
}

fn produceManual(job: *SearchJob, max_entries: usize) void {
    ensureManualReady(job);
    var paths: std.ArrayList([]u8) = .empty;
    defer freePathList(job.allocator, &paths);

    var seen: usize = 0;
    while (seen < max_entries and !job.cancelled.load(.acquire)) {
        if (job.manual_stack.items.len == 0) {
            flushBatch(job, &paths);
            postFinish(job, false);
            return;
        }
        const full = job.manual_stack.orderedRemove(0);
        defer job.allocator.free(full);
        seen += 1;
        if (SearchLogic.matches(std.fs.path.basename(full), job.queryText())) pushHit(job, &paths, full);
    }
    flushBatch(job, &paths);
    if (job.cancelled.load(.acquire)) postFinish(job, true);
}

fn publishBatch(ud: *anyopaque) void {
    const batch: *Batch = @ptrCast(@alignCast(ud));
    const filer = batch.filer;
    defer filer.destroyBatch(batch);
    if (batch.gen != filer.search_gen or filer.tearing_down) return;
    for (batch.paths) |p| {
        filer.appendResult(p);
    }
    batch.consumed = true;
    filer.updateSearchStatus("searching... {d}", .{filer.results.items.len});
}

fn finishTask(ud: *anyopaque) void {
    const finish: *Finish = @ptrCast(@alignCast(ud));
    const filer = finish.filer;
    defer filer.destroyFinish(finish);
    if (finish.gen != filer.search_gen or filer.tearing_down) return;
    filer.finishSearch(finish.gen, finish.cancelled);
}

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
    root: *nimbus.Container,
    label: *nimbus.Label,
    field: *nimbus.TextField,
    filer: *Filer,
    cur_entry: ?*Entry = null,
    in_edit: bool = false,

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
    root: *nimbus.Container,
    label: *nimbus.Label,
    icon_home: awt.Image,
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
        .update = FileCell.update,
        .destroy = FileCell.destroyCell,
        .edit = .{ .start = FileCell.start, .commit = FileCell.commit, .cancel = FileCell.cancel },
        .user_data = fc,
    };
}

const ResultCell = struct {
    label: *nimbus.Label,

    fn update(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *ResultCell = @ptrCast(@alignCast(ud));
        const h: *Hit = @ptrCast(@alignCast(ctx.value));
        self.label.setText(h.path) catch {};
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ResultCell = @ptrCast(@alignCast(ud));
        self.label.component.vtable.destroy(&self.label.component, allocator);
        allocator.destroy(self);
    }
};

fn createResultCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const rc = try allocator.create(ResultCell);
    errdefer allocator.destroy(rc);
    const label = try filer.app.label("");
    label.setIcon(filer.icon_file);
    label.setIconSize(.{ .width = ICON, .height = ICON });
    rc.* = .{ .label = label };
    return .{
        .component = &label.component,
        .update = ResultCell.update,
        .destroy = ResultCell.destroyCell,
        .user_data = rc,
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
        .update = PlaceCell.update,
        .destroy = PlaceCell.destroyCell,
        .user_data = pc,
    };
}

// ── details-view (Table) cells: one typed cell per column ───────────────────

// Table Name-column cell: like the list FileCell (icon + name, with inline
// rename via CellEdit — label / field swap).
const NameCell = struct {
    root: *nimbus.Container,
    label: *nimbus.Label,
    field: *nimbus.TextField,
    filer: *Filer,
    cur_entry: ?*Entry = null,
    in_edit: bool = false,

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
    kind: TextKind,
    buf: [40]u8 = undefined,
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
        .update = NameCell.update,
        .destroy = NameCell.destroyCell,
        .edit = .{ .start = NameCell.start, .commit = NameCell.commit, .cancel = NameCell.cancel },
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

// ── drag & drop move (list/details files + places) ─────────────────────────

const entry_tag = dnd.tagOf(Entry);

const Mover = struct {
    filer: *Filer,
    ghost: *nimbus.Label,
    files_highlight: ?usize = null,
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
        const row = filer.activeRowAt(y) orelse return null;
        if (row >= filer.entries.items.len) return null;
        const entry = filer.entries.items[row];
        self.ghost.setText(entry.name) catch {};
        self.ghost.setIcon(if (entry.is_dir) filer.icon_folder else filer.icon_file);
        filer.window.overlays.addPassthrough(&self.ghost.component) catch {};
        return .{ .flavor = .object, .ctx = entry, .type_tag = entry_tag, .source = filer.activeFilesComponent() };
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
        if (filer.activeRowAt(e.y)) |row| {
            if (row < filer.entries.items.len) {
                const target = filer.entries.items[row];
                if (target.is_dir and target != entry) hl = row;
            }
        }
        self.files_highlight = hl;
        filer.activeFilesComponent().repaint();
        return hl != null;
    }
    fn filesOnLeave(ud: *anyopaque) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        self.files_highlight = null;
        self.filer.activeFilesComponent().repaint();
    }
    fn filesOnDrop(ud: *anyopaque, e: *const dnd.DragEvent) void {
        const self: *Mover = @ptrCast(@alignCast(ud));
        const filer = self.filer;
        self.files_highlight = null;
        const entry = dragEntry(e) orelse return;
        const row = filer.activeRowAt(e.y) orelse return;
        if (row >= filer.entries.items.len) return;
        const target = filer.entries.items[row];
        if (!target.is_dir or target == entry) return;
        const dest = std.fs.path.join(filer.allocator, &.{ filer.curPath(), target.name }) catch return;
        defer filer.allocator.free(dest);
        filer.moveDraggedTo(entry, dest);
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
        filer.moveDraggedTo(entry, place.path);
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

fn dndTablePaint(self: *nimbus.Component, g: *awt.Graphics) void {
    nimbus.Table.vtable.paint(self, g);
    const m = self.getTyped(Mover) orelse return;
    if (m.filer.view_mode != .details) return;
    if (m.files_highlight) |row| {
        const table = m.filer.table;
        const h = table.getRowHeight();
        const y = table.getHeaderHeight() + @as(f32, @floatFromInt(row)) * h;
        g.setColor(self.theme.focus_ring);
        g.drawRect(.{ .x = 1, .y = y + 1, .width = self.size.width - 2, .height = h - 2 });
    }
}

const dnd_table_vt = blk: {
    var vt = nimbus.Table.vtable;
    vt.paint = dndTablePaint;
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

pub fn build(
    app: *nimbus.Application,
    window: *nimbus.Window,
    gpa: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    home: ?[]const u8,
) !*Filer {
    return buildWithRunner(app, window, gpa, io, start_dir, home, .threaded);
}

pub fn buildWithRunner(
    app: *nimbus.Application,
    window: *nimbus.Window,
    gpa: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    home: ?[]const u8,
    runner: RunnerKind,
) !*Filer {
    const filer = try gpa.create(Filer);
    filer.* = .{
        .allocator = gpa,
        .io = io,
        .app = app,
        .icon_folder = try app.icon(.folder),
        .icon_file = try app.icon(.file),
        .icon_home = try app.icon(.house),
        .icon_drive = try app.icon(.hard_drive),
        .model = Model.init(gpa),
        .results_model = Model.init(gpa),
        .runner = runner,
        .card = .{ .base = .{ .vtable = &CardLayout.vt } },
    };
    filer.window = window;

    // Right pane: list view (shares the model) with inline rename.
    const lst = try app.listWithModel(&filer.model, .{ .create = createFileCell, .user_data = filer });
    filer.list = lst;
    lst.setRowHeight(ROW_HEIGHT);
    lst.setEditTrigger(.manual);
    lst.setSelectionMode(.multiple);
    try lst.addActionListener(Filer, Filer.onActivate, filer);
    try lst.addContextMenuListener(Filer, Filer.onListContextMenu, filer);
    const lsp = try app.scrollPane(lst.asComponent());
    filer.list_sp = lsp;

    const results_list = try app.listWithModel(&filer.results_model, .{ .create = createResultCell, .user_data = filer });
    filer.results_list = results_list;
    results_list.setRowHeight(ROW_HEIGHT);
    try results_list.addActionListener(Filer, Filer.onResultActivate, filer);
    try results_list.asComponent().bindKey(nimbus.KeyStroke.of(.escape), nimbus.KeyHandler.typed(Filer, Filer.onResultsEscape, filer));
    const rsp = try app.scrollPane(results_list.asComponent());
    filer.results_sp = rsp;

    // Right pane: details view (Table over the SAME model).
    const tbl = try app.tableWithModel(&filer.model, &.{
        .{ .title = "Name", .width = 300, .factory = .{ .create = createNameCell, .user_data = filer } },
        .{ .title = "Size", .width = 90, .factory = .{ .create = createSizeCell, .user_data = filer } },
        .{ .title = "Modified", .width = 150, .factory = .{ .create = createDateCell, .user_data = filer } },
    });
    filer.table = tbl;
    tbl.setRowHeight(ROW_HEIGHT);
    tbl.setSelectionMode(.multiple);
    tbl.setSortIndicator(0, .ascending);
    try tbl.addActionListener(Filer, Filer.onActivate, filer);
    try tbl.addContextMenuListener(Filer, Filer.onTableContextMenu, filer);
    try tbl.addSortListener(Filer, Filer.onSort, filer);
    const tsp = try app.scrollPane(tbl.asComponent());
    filer.table_sp = tsp;

    // Holder with a card layout: both scroll panes are children; only the
    // active one is shown (the other collapses to zero size).
    const holder = try app.container();
    filer.right_center = holder;
    holder.setLayout(&filer.card.base);
    try holder.add(lsp.asComponent());
    try holder.add(tsp.asComponent());
    try holder.add(rsp.asComponent());
    filer.card.active = lsp.asComponent();

    // Left pane: places.
    const places = try app.list(.{ .create = createPlaceCell, .user_data = filer });
    filer.places_list = places;
    places.setRowHeight(ROW_HEIGHT);
    try places.addChangeListener(Filer, Filer.onPlaceSelected, filer);
    const places_sp = try app.scrollPane(places.asComponent());

    const split = try app.splitPane(.horizontal, places_sp.asComponent(), &holder.component);
    split.setDividerLocation(SIDEBAR_WIDTH);
    split.asComponent().setGrowX(1);
    split.asComponent().setGrowY(1);
    try nimbus.BorderLayout.add(&window.container, .center, split.asComponent());

    // Drag & drop move (list/details files + places).
    const ghost = try app.label("");
    ghost.setIconSize(.{ .width = ICON, .height = ICON });
    ghost.component.size = .{ .width = 240, .height = ROW_HEIGHT };
    filer.ghost = ghost;
    filer.mover = .{ .filer = filer, .ghost = ghost };
    lst.asComponent().drag_source = .{ .onDragStart = Mover.onDragStart, .onDrag = Mover.onDrag, .onDragDone = Mover.onDragDone, .user_data = &filer.mover };
    lst.asComponent().drop_target = .{ .onOver = Mover.filesOnOver, .onLeave = Mover.filesOnLeave, .onDrop = Mover.filesOnDrop, .user_data = &filer.mover };
    tbl.asComponent().drag_source = .{ .onDragStart = Mover.onDragStart, .onDrag = Mover.onDrag, .onDragDone = Mover.onDragDone, .user_data = &filer.mover };
    tbl.asComponent().drop_target = .{ .onOver = Mover.filesOnOver, .onLeave = Mover.filesOnLeave, .onDrop = Mover.filesOnDrop, .user_data = &filer.mover };
    places.asComponent().drop_target = .{ .onOver = Mover.placesOnOver, .onLeave = Mover.placesOnLeave, .onDrop = Mover.placesOnDrop, .user_data = &filer.mover };
    lst.asComponent().vtable = &dnd_list_vt;
    tbl.asComponent().vtable = &dnd_table_vt;
    places.asComponent().vtable = &dnd_list_vt;
    try lst.asComponent().putProperty(@typeName(Mover), &filer.mover, null);
    try tbl.asComponent().putProperty(@typeName(Mover), &filer.mover, null);
    try places.asComponent().putProperty(@typeName(Mover), &filer.mover, null);

    // Row context menu (caller-owned, reused).
    const popup = try app.popupMenu();
    filer.popup = popup;
    const mi_open = try app.menuItem("Open");
    mi_open.setIcon(try app.icon(.folder_open));
    try mi_open.getModel().addActionListener(Filer, Filer.onMenuOpen, filer);
    try popup.add(&mi_open.component);
    const mi_rename = try app.menuItem("Rename");
    mi_rename.setIcon(try app.icon(.pencil));
    try mi_rename.getModel().addActionListener(Filer, Filer.onMenuRename, filer);
    try popup.add(&mi_rename.component);
    const mi_delete = try app.menuItem("Delete");
    mi_delete.setIcon(try app.icon(.trash_2));
    try mi_delete.getModel().addActionListener(Filer, Filer.onMenuDelete, filer);
    try popup.add(&mi_delete.component);

    // Background context menu (caller-owned, reused).
    const background_popup = try app.popupMenu();
    filer.background_popup = background_popup;
    const mi_new_folder = try app.menuItem("New Folder");
    mi_new_folder.setIcon(try app.icon(.folder_plus));
    try mi_new_folder.getModel().addActionListener(Filer, Filer.onMenuNewFolder, filer);
    try background_popup.add(&mi_new_folder.component);

    // Delete confirmation (caller-owned).
    const confirm = try app.dialog(window, "Confirm", 320, 120);
    filer.confirm = confirm;
    const confirm_msg = try app.label("");
    filer.confirm_msg = confirm_msg;
    try buildConfirmDialog(app, confirm, confirm_msg);

    // Toolbar (north): [up] [view] path / search row.
    const north_stack = try app.container();
    north_stack.setLayout(nimbus.BoxLayout.vertical());

    const bar = try app.container();
    bar.setLayout(nimbus.BoxLayout.horizontal());
    const up = try app.button("");
    up.setIcon(try app.icon(.arrow_up));
    up.setIconSize(.{ .width = ICON, .height = ICON });
    try up.getModel().addActionListener(Filer, Filer.onUpButton, filer);
    const view_btn = try app.button("Details");
    filer.view_button = view_btn;
    try view_btn.getModel().addActionListener(Filer, Filer.onViewButton, filer);
    const gap = try app.container();
    gap.component.setMinSize(.{ .width = 6, .height = 0 });
    gap.component.setMaxSize(.{ .width = 6, .height = std.math.inf(f32) });
    const path_field = try app.textField("");
    filer.path_field = path_field;
    path_field.component.setGrowX(1);
    path_field.component.setAlignY(.center);
    try path_field.addSubmitListener(Filer, Filer.onPathSubmit, filer);
    try path_field.addCancelListener(Filer, Filer.onPathCancel, filer);
    try bar.add(&up.component);
    try bar.add(&view_btn.component);
    try bar.add(&gap.component);
    try bar.add(&path_field.component);
    try north_stack.add(&bar.component);

    const search_bar = try app.container();
    search_bar.setLayout(nimbus.BoxLayout.horizontal());
    const search_field = try app.textField("");
    filer.search_field = search_field;
    search_field.component.setGrowX(1);
    search_field.component.setAlignY(.center);
    try search_field.addSubmitListener(Filer, Filer.onSearchSubmit, filer);
    try search_field.addCancelListener(Filer, Filer.onSearchCancel, filer);
    const search_btn = try app.button("Search");
    filer.search_button = search_btn;
    try search_btn.getModel().addActionListener(Filer, Filer.onSearchButton, filer);
    const cancel_btn = try app.button("Cancel");
    filer.cancel_button = cancel_btn;
    try cancel_btn.getModel().addActionListener(Filer, Filer.onCancelButton, filer);
    const result_count = try app.label("");
    filer.result_count = result_count;
    try search_bar.add(&search_field.component);
    try search_bar.add(&search_btn.component);
    try search_bar.add(&cancel_btn.component);
    try search_bar.add(&result_count.component);
    try north_stack.add(&search_bar.component);
    try nimbus.BorderLayout.add(&window.container, .north, &north_stack.component);

    // Status line (south).
    const status = try app.label("");
    filer.status = status;
    try nimbus.BorderLayout.add(&window.container, .south, &status.component);

    // Backspace / F5 are window-wide -> root. F2 / Delete are scoped to the
    // file views (WHEN_FOCUSED): bound on the list and table so they fire only
    // when one of those has focus, and so the rename TextField (focus owner
    // while editing) gets Delete first to remove a char. Key dispatch now walks
    // key_bindings from the focus owner up, so a binding on the focused widget
    // itself fires (see narrative/keybinding.md).
    const root = &window.container.component;
    try root.bindKey(nimbus.KeyStroke.of(.backspace), nimbus.KeyHandler.typed(Filer, Filer.onBackspace, filer));
    try root.bindKey(nimbus.KeyStroke.of(.f5), nimbus.KeyHandler.typed(Filer, Filer.onReloadKey, filer));
    for ([_]*nimbus.Component{ lst.asComponent(), tbl.asComponent() }) |c| {
        try c.bindKey(nimbus.KeyStroke.of(.f2), nimbus.KeyHandler.typed(Filer, Filer.onRenameKey, filer));
        try c.bindKey(nimbus.KeyStroke.of(.delete), nimbus.KeyHandler.typed(Filer, Filer.onDeleteKey, filer));
        try c.bindKey(nimbus.KeyStroke.cmdShift(.n), nimbus.KeyHandler.typed(Filer, Filer.onNewFolderKey, filer));
    }

    filer.buildPlaces(home);
    _ = filer.loadDir(start_dir);

    return filer;
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    const frame = try app.frame("nimbus filer", 760, 520);

    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    var buf: [PATH_BUF]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(init.io, &buf);
    const filer = try build(app, &frame.window, init.gpa, init.io, buf[0..n], init.environ_map.get(home_var));
    defer filer.deinitModel(init.gpa);
    defer app.deinit();
    defer filer.deinitUi();

    std.debug.print(
        \\filer M5 — toolbar "Details"/"List" toggles the right-pane view.
        \\Details view: click a header to sort, drag a column boundary to resize.
        \\Double-click/Enter opens, right-click for the menu, Ctrl+Shift+N creates a folder, F2 renames, Delete removes, F5 reloads.
        \\
    , .{});
    try app.run();
}
