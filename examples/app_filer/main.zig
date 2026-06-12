//! app_filer: dogfooding file manager (M2 — two panes via SplitPane).
//!
//! A real (if minimal) app built only on nimbus public APIs, to surface
//! missing pieces and rough edges. Current state:
//!   - left pane: places (Home + drives on Windows, / elsewhere); a single
//!     click navigates the right pane there
//!   - right pane: entries of the current directory (folders first, then
//!     files, case-insensitively sorted), each row = icon + name
//!   - double-click / Enter on a folder enters it; on a file it just reports
//!     in the status line (file operations come in a later milestone)
//!   - the toolbar's up-arrow button (or Backspace anywhere) goes to the
//!     parent directory; the current path shows next to the button
//!   - the divider between the panes drags; the left pane keeps its width on
//!     window resize (SplitPane's resize_weight 0 default)
//!   - starts in the process's working directory
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
    entries:     std.ArrayList(*Entry) = .empty,
    places:      std.ArrayList(*Place) = .empty,
    cur:         [PATH_BUF]u8 = undefined,
    cur_len:     usize = 0,
    status_buf:  [512]u8 = undefined,

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
        self.list.setSelected(if (self.entries.items.len > 0) 0 else null);
        self.sp.setScrollY(0);
        self.setStatus("{d} items", .{self.entries.items.len});
    }

    fn openSelected(self: *Filer) void {
        const idx = self.list.getSelected() orelse return;
        if (idx >= self.entries.items.len) return;
        const e = self.entries.items[idx];
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

    // ── listeners ────────────────────────────────────────────────────────

    fn onActivate(self: *Filer, _: *const ActionEvent) void {
        self.openSelected();
    }

    fn onUpButton(self: *Filer, _: *const ActionEvent) void {
        self.goUp();
    }

    fn onBackspace(self: *Filer) void {
        self.goUp();
    }

    /// Sidebar selection = navigation (single click, like a places sidebar).
    fn onPlaceSelected(self: *Filer, _: *const ChangeEvent) void {
        const idx = self.places_list.getSelected() orelse return;
        if (idx >= self.places.items.len) return;
        self.loadDir(self.places.items[idx].path);
    }
};

// ── cells ────────────────────────────────────────────────────────────────

/// One recycled file row: [6px margin | icon+name label]. Read-only (no
/// edit), so double-click / Enter fall through to the List's activation
/// listener.
const FileCell = struct {
    root:        *nimbus.Container,
    label:       *nimbus.Label,
    icon_folder: awt.Image,
    icon_file:   awt.Image,

    fn update(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.label.setText(e.name) catch {};
        self.label.setIcon(if (e.is_dir) self.icon_folder else self.icon_file);
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FileCell = @ptrCast(@alignCast(ud));
        const comp = &self.root.component;
        comp.vtable.destroy(comp, allocator); // frees the subtree (margin + label)
        allocator.destroy(self);
    }
};

/// One recycled places row: same shape as FileCell, icon by place kind.
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

/// Shared skeleton for both cell kinds: [6px margin | icon-capable label].
fn createRowSkeleton(app: *nimbus.Application, allocator: std.mem.Allocator) anyerror!struct {
    root:  *nimbus.Container,
    label: *nimbus.Label,
} {
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

    return .{ .root = root, .label = label };
}

fn createFileCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const fc = try allocator.create(FileCell);
    errdefer allocator.destroy(fc);
    const sk = try createRowSkeleton(filer.app, allocator);
    fc.* = .{
        .root = sk.root,
        .label = sk.label,
        .icon_folder = filer.icon_folder,
        .icon_file = filer.icon_file,
    };
    return .{
        .component = &sk.root.component,
        .update    = FileCell.update,
        .destroy   = FileCell.destroyCell,
        .user_data = fc,
    };
}

fn createPlaceCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const filer: *Filer = @ptrCast(@alignCast(ud));
    const pc = try allocator.create(PlaceCell);
    errdefer allocator.destroy(pc);
    const sk = try createRowSkeleton(filer.app, allocator);
    pc.* = .{
        .root = sk.root,
        .label = sk.label,
        .icon_home = filer.icon_home,
        .icon_drive = filer.icon_drive,
    };
    return .{
        .component = &sk.root.component,
        .update    = PlaceCell.update,
        .destroy   = PlaceCell.destroyCell,
        .user_data = pc,
    };
}

// ── ui assembly ──────────────────────────────────────────────────────────

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
    try lst.addActionListener(Filer, Filer.onActivate, &filer);
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

    // Backspace anywhere = go up (bound on the window root, not the list, so
    // it works regardless of which widget holds focus).
    try frame.window.container.component.bindKey(
        nimbus.KeyStroke.of(.backspace),
        nimbus.KeyHandler.typed(Filer, Filer.onBackspace, &filer),
    );

    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    filer.buildPlaces(init.environ_map.get(home_var));

    // Start in the working directory.
    var buf: [PATH_BUF]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(init.io, &buf);
    filer.loadDir(buf[0..n]);

    std.debug.print("filer M2 — click a place on the left; double-click/Enter opens a folder; Backspace goes up.\n", .{});
    try app.run();
}
