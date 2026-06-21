const std = @import("std");
const builtin = @import("builtin");
const awt = @import("awt");

const Application = @import("Application.zig");
const BorderLayout = @import("BorderLayout.zig");
const BoxLayout = @import("BoxLayout.zig");
const Button = @import("Button.zig");
const Component = @import("Component.zig");
const ComboBox = @import("ComboBox.zig");
const Container = @import("Container.zig");
const Dialog = @import("Dialog.zig");
const Label = @import("Label.zig");
const LayoutManager = @import("LayoutManager.zig");
const List = @import("List.zig");
const PaddingLayout = @import("PaddingLayout.zig");
const ScrollPane = @import("ScrollPane.zig");
const SplitPane = @import("SplitPane.zig");
const Table = @import("Table.zig");
const TextField = @import("TextField.zig");
const Window = @import("Window.zig");
const ActionEvent = @import("listener.zig").ActionEvent;
const ChangeEvent = @import("listener.zig").ChangeEvent;

const PATH_BUF = 4096;
const FILE_ROW_HEIGHT = 28;
const FILE_ICON = 18;
const SOUTH_LABEL_WIDTH = 104;

extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;

pub const Mode = enum { open, save, select_directory };

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64 = 0,
    mtime: i64 = 0,
};

pub const PlaceEntry = struct {
    name: []const u8,
    path: []const u8,
    kind: Kind,

    pub const Kind = enum { home, root };
};

pub const DirSource = struct {
    vtable: *const VTable,
    user_data: *anyopaque,

    pub const VTable = struct {
        list: *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(DirEntry)) anyerror!void,
        realPath: *const fn (user_data: *anyopaque, path: []const u8, buf: []u8) anyerror![]const u8,
        places: *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(PlaceEntry)) anyerror!void,
    };
};

pub const OsDirSourceState = struct {
    io: std.Io,
};

pub fn osDirSource(state: *OsDirSourceState) DirSource {
    return .{
        .vtable = &os_vtable,
        .user_data = state,
    };
}

const os_vtable = DirSource.VTable{
    .list = osList,
    .realPath = osRealPath,
    .places = osPlaces,
};

fn osState(user_data: *anyopaque) *OsDirSourceState {
    return @ptrCast(@alignCast(user_data));
}

fn osList(user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(DirEntry)) !void {
    const state = osState(user_data);
    var dir = try std.Io.Dir.openDirAbsolute(state.io, path, .{ .iterate = true });
    defer dir.close(state.io);

    var it = dir.iterate();
    while (try it.next(state.io)) |ent| {
        const name = try allocator.dupe(u8, ent.name);
        errdefer allocator.free(name);
        try out.append(allocator, .{
            .name = name,
            .is_dir = ent.kind == .directory,
        });
    }
}

fn osRealPath(user_data: *anyopaque, path: []const u8, buf: []u8) ![]const u8 {
    const state = osState(user_data);
    var dir = try std.Io.Dir.openDirAbsolute(state.io, path, .{});
    defer dir.close(state.io);
    const n = try dir.realPath(state.io, buf);
    return buf[0..n];
}

fn osPlaces(user_data: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(PlaceEntry)) !void {
    _ = user_data;
    const home_var: [*:0]const u8 = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const raw_home_opt = std.c.getenv(home_var);
    if (raw_home_opt != null) {
        const raw_home = raw_home_opt.?;
        const home = try allocator.dupe(u8, std.mem.span(raw_home));
        errdefer allocator.free(home);
        const name = try allocator.dupe(u8, "Home");
        errdefer allocator.free(name);
        try out.append(allocator, .{
            .name = name,
            .path = home,
            .kind = .home,
        });
    }

    if (builtin.os.tag == .windows) {
        const drive_mask = GetLogicalDrives();
        var i: u5 = 0;
        while (i < 26) : (i += 1) {
            if ((drive_mask & (@as(u32, 1) << i)) == 0) continue;
            const drive = [3]u8{ 'A' + @as(u8, i), ':', std.fs.path.sep };
            try appendPlace(allocator, out, &drive, &drive, .root);
        }
    } else {
        try appendPlace(allocator, out, "/", "/", .root);
    }
}

fn appendPlace(allocator: std.mem.Allocator, out: *std.ArrayList(PlaceEntry), name: []const u8, path: []const u8, kind: PlaceEntry.Kind) !void {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);
    try out.append(allocator, .{ .name = name_dup, .path = path_dup, .kind = kind });
}

pub const Filter = struct {
    name: []const u8,
    extensions: std.ArrayList([]const u8),
};

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64 = 0,
    mtime: i64 = 0,
    visible: bool = true,
};

pub const Place = struct {
    name: []const u8,
    path: []const u8,
    kind: PlaceEntry.Kind,
};

pub const Ancestor = struct {
    name: []const u8,
    path: []const u8,
};

const ViewMode = enum { list, details };

const CardLayout = struct {
    base: LayoutManager,
    active: ?*Component = null,

    const vt = LayoutManager.VTable{
        .doLayout = doLayout,
        .computeMinSize = minSize,
        .computeMaxSize = maxSize,
    };

    fn doLayout(lm: *LayoutManager, c: *Container) void {
        const self: *CardLayout = @fieldParentPtr("base", lm);
        for (c.children.items) |elem| {
            const show = self.active != null and elem.component == self.active.?;
            elem.component.setBounds(if (show)
                .{ .x = 0, .y = 0, .width = c.component.size.width, .height = c.component.size.height }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 });
        }
    }

    fn minSize(_: *LayoutManager, _: *const Container) Component.Size {
        return .{ .width = 0, .height = 0 };
    }

    fn maxSize(_: *LayoutManager, _: *const Container) Component.Size {
        return .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
    }
};

const SortCtx = struct { col: usize, dir: Table.SortDirection };

const ViewSwitchPlan = struct {
    mode: ViewMode,
    carry: ?usize,
};

pub const ChooserCore = struct {
    allocator: std.mem.Allocator,
    source: DirSource,
    mode: Mode = .open,
    entries: std.ArrayList(*Entry) = .empty,
    places: std.ArrayList(*Place) = .empty,
    filters: std.ArrayList(Filter) = .empty,
    selected_filter: usize = 0,
    cur: [PATH_BUF]u8 = undefined,
    cur_len: usize = 0,
    selected: [PATH_BUF]u8 = undefined,
    selected_len: usize = 0,
    filename: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: DirSource) !ChooserCore {
        var self = ChooserCore{
            .allocator = allocator,
            .source = source,
        };
        errdefer self.deinit();
        try self.loadPlaces();
        return self;
    }

    pub fn deinit(self: *ChooserCore) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.clearPlaces();
        self.places.deinit(self.allocator);
        self.clearFilters();
        self.filters.deinit(self.allocator);
        self.filename.deinit(self.allocator);
    }

    pub fn setMode(self: *ChooserCore, mode: Mode) void {
        self.mode = mode;
    }

    pub fn getCurrentDirectory(self: *const ChooserCore) []const u8 {
        return self.cur[0..self.cur_len];
    }

    pub fn getSelectedPath(self: *const ChooserCore) ?[]const u8 {
        if (self.selected_len == 0) return null;
        return self.selected[0..self.selected_len];
    }

    pub fn addFilter(self: *ChooserCore, name: []const u8, extensions: []const []const u8) !void {
        var filter = Filter{
            .name = try self.allocator.dupe(u8, name),
            .extensions = .empty,
        };
        errdefer {
            self.allocator.free(filter.name);
            for (filter.extensions.items) |ext| self.allocator.free(ext);
            filter.extensions.deinit(self.allocator);
        }
        try filter.extensions.ensureTotalCapacity(self.allocator, extensions.len);
        for (extensions) |ext| filter.extensions.appendAssumeCapacity(try self.allocator.dupe(u8, ext));
        try self.filters.append(self.allocator, filter);
        if (self.filters.items.len == 1) self.selected_filter = 0;
        self.applyFilter();
    }

    pub fn setFilter(self: *ChooserCore, index: usize) void {
        if (index >= self.filters.items.len) return;
        self.selected_filter = index;
        self.applyFilter();
    }

    pub fn loadDir(self: *ChooserCore, path: []const u8) !void {
        var tmp_entries: std.ArrayList(DirEntry) = .empty;
        defer freeDirEntries(self.allocator, &tmp_entries);
        try self.source.vtable.list(self.source.user_data, self.allocator, path, &tmp_entries);

        var real_buf: [PATH_BUF]u8 = undefined;
        const real = try self.source.vtable.realPath(self.source.user_data, path, &real_buf);
        try copyPath(&self.cur, &self.cur_len, real);
        self.selected_len = 0;

        self.clearEntries();
        try self.entries.ensureTotalCapacity(self.allocator, tmp_entries.items.len);
        for (tmp_entries.items) |src| {
            const e = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(e);
            e.* = .{
                .name = try self.allocator.dupe(u8, src.name),
                .is_dir = src.is_dir,
                .size = src.size,
                .mtime = src.mtime,
            };
            errdefer self.allocator.free(e.name);
            self.entries.appendAssumeCapacity(e);
        }
        self.sortEntries();
        self.applyFilter();
    }

    pub fn cd(self: *ChooserCore, name: []const u8) !void {
        var buf: [PATH_BUF]u8 = undefined;
        const next = try joinPath(&buf, self.getCurrentDirectory(), name);
        try self.loadDir(next);
    }

    pub fn up(self: *ChooserCore) !void {
        const cur_dir = self.getCurrentDirectory();
        const parent = std.fs.path.dirname(cur_dir) orelse return;
        try self.loadDir(parent);
    }

    pub fn selectPlace(self: *ChooserCore, index: usize) !void {
        if (index >= self.places.items.len) return;
        try self.loadDir(self.places.items[index].path);
    }

    pub fn ancestorChain(allocator: std.mem.Allocator, cur: []const u8) !std.ArrayList(Ancestor) {
        var reverse: std.ArrayList(Ancestor) = .empty;
        errdefer freeAncestorChain(allocator, &reverse);

        var path = cur;
        while (path.len > 0) {
            {
                const display = ancestorDisplayName(path);
                const name_dup = try allocator.dupe(u8, display);
                errdefer allocator.free(name_dup);
                const path_dup = try allocator.dupe(u8, path);
                errdefer allocator.free(path_dup);
                try reverse.append(allocator, .{
                    .name = name_dup,
                    .path = path_dup,
                });
            }

            const parent = std.fs.path.dirname(path) orelse break;
            if (std.mem.eql(u8, parent, path)) break;
            path = parent;
        }

        var result: std.ArrayList(Ancestor) = .empty;
        errdefer freeAncestorChain(allocator, &result);
        try result.ensureTotalCapacity(allocator, reverse.items.len);
        var i = reverse.items.len;
        while (i > 0) {
            i -= 1;
            result.appendAssumeCapacity(reverse.items[i]);
        }
        reverse.clearRetainingCapacity();
        reverse.deinit(allocator);
        return result;
    }

    pub fn setSelectedFromList(self: *ChooserCore, name: []const u8) !void {
        try self.commitName(name);
    }

    pub fn setSelectedFileName(self: *ChooserCore, name: []const u8) !void {
        self.filename.clearRetainingCapacity();
        try self.filename.appendSlice(self.allocator, name);
    }

    pub fn commitSaveName(self: *ChooserCore) !void {
        try self.commitName(self.filename.items);
    }

    pub fn overwriteNeeded(self: *const ChooserCore) bool {
        const selected = self.getSelectedPath() orelse return false;
        const name = basename(selected);
        for (self.entries.items) |entry| {
            if (!entry.is_dir and std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    pub fn visibleEntryCount(self: *const ChooserCore) usize {
        var count: usize = 0;
        for (self.entries.items) |e| {
            if (e.visible) count += 1;
        }
        return count;
    }

    pub fn visibleEntryAt(self: *const ChooserCore, visible_index: usize) ?*Entry {
        var count: usize = 0;
        for (self.entries.items) |e| {
            if (!e.visible) continue;
            if (count == visible_index) return e;
            count += 1;
        }
        return null;
    }

    fn loadPlaces(self: *ChooserCore) !void {
        var tmp_places: std.ArrayList(PlaceEntry) = .empty;
        defer freePlaceEntries(self.allocator, &tmp_places);
        try self.source.vtable.places(self.source.user_data, self.allocator, &tmp_places);

        self.clearPlaces();
        try self.places.ensureTotalCapacity(self.allocator, tmp_places.items.len);
        for (tmp_places.items) |src| {
            const p = try self.allocator.create(Place);
            errdefer self.allocator.destroy(p);
            p.* = .{
                .name = try self.allocator.dupe(u8, src.name),
                .path = try self.allocator.dupe(u8, src.path),
                .kind = src.kind,
            };
            errdefer {
                self.allocator.free(p.name);
                self.allocator.free(p.path);
            }
            self.places.appendAssumeCapacity(p);
        }
    }

    fn clearEntries(self: *ChooserCore) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.destroy(e);
        }
        self.entries.clearRetainingCapacity();
    }

    fn clearPlaces(self: *ChooserCore) void {
        for (self.places.items) |p| {
            self.allocator.free(p.name);
            self.allocator.free(p.path);
            self.allocator.destroy(p);
        }
        self.places.clearRetainingCapacity();
    }

    fn clearFilters(self: *ChooserCore) void {
        for (self.filters.items) |*filter| {
            self.allocator.free(filter.name);
            for (filter.extensions.items) |ext| self.allocator.free(ext);
            filter.extensions.deinit(self.allocator);
        }
        self.filters.clearRetainingCapacity();
    }

    fn sortEntries(self: *ChooserCore) void {
        std.sort.pdq(*Entry, self.entries.items, {}, entryLess);
    }

    fn applyFilter(self: *ChooserCore) void {
        for (self.entries.items) |e| {
            e.visible = self.entryPassesFilter(e);
        }
    }

    fn entryPassesFilter(self: *const ChooserCore, entry: *const Entry) bool {
        if (entry.is_dir) return true;
        if (self.filters.items.len == 0) return true;
        if (self.selected_filter >= self.filters.items.len) return true;
        const filter = self.filters.items[self.selected_filter];
        if (filter.extensions.items.len == 0) return true;
        for (filter.extensions.items) |ext| {
            if (hasExtension(entry.name, ext)) return true;
        }
        return false;
    }

    fn commitName(self: *ChooserCore, name: []const u8) !void {
        var buf: [PATH_BUF]u8 = undefined;
        const path = try joinPath(&buf, self.getCurrentDirectory(), name);
        try copyPath(&self.selected, &self.selected_len, path);
    }
};

pub const FileChooser = struct {
    allocator: std.mem.Allocator,
    app: *Application,
    owner: *Window,
    dialog: *Dialog,
    core: ChooserCore,
    os_state: ?OsDirSourceState,
    files_model: List.ListModel,
    places_model: List.ListModel,
    files_list: *List,
    files_table: *Table,
    list_sp: *ScrollPane,
    table_sp: *ScrollPane,
    card_holder: *Container,
    card: CardLayout,
    view_mode: ViewMode,
    sort_col: usize,
    sort_dir: Table.SortDirection,
    places_list: *List,
    look_in_combo: *ComboBox,
    look_in_paths: std.ArrayList([]const u8),
    syncing_look_in: bool,
    filename_field: *TextField,
    filter_combo: *ComboBox,
    ok_button: *Button,
    cancel_button: *Button,
    icon_folder: awt.Image,
    icon_file: awt.Image,
    icon_home: awt.Image,
    icon_root: awt.Image,

    pub fn create(app: *Application, owner: *Window) !*FileChooser {
        const chooser = try app.allocator.create(FileChooser);
        errdefer app.allocator.destroy(chooser);
        chooser.os_state = .{ .io = app.event_queue.io };
        return createInto(chooser, app, owner, osDirSource(&chooser.os_state.?));
    }

    pub fn createWithSource(app: *Application, owner: *Window, source: DirSource) !*FileChooser {
        const chooser = try app.allocator.create(FileChooser);
        errdefer app.allocator.destroy(chooser);
        chooser.os_state = null;
        return createInto(chooser, app, owner, source);
    }

    fn createInto(self: *FileChooser, app: *Application, owner: *Window, source: DirSource) !*FileChooser {
        const allocator = app.allocator;
        var core = try ChooserCore.init(allocator, source);
        errdefer core.deinit();

        if (core.places.items.len > 0) {
            try core.loadDir(core.places.items[0].path);
        }

        const dialog = try app.dialog(owner, "File Chooser", 720, 480);
        errdefer dialog.destroy();

        self.* = .{
            .allocator = allocator,
            .app = app,
            .owner = owner,
            .dialog = dialog,
            .core = core,
            .os_state = self.os_state,
            .files_model = List.ListModel.init(allocator),
            .places_model = List.ListModel.init(allocator),
            .files_list = undefined,
            .files_table = undefined,
            .list_sp = undefined,
            .table_sp = undefined,
            .card_holder = undefined,
            .card = .{ .base = .{ .vtable = &CardLayout.vt } },
            .view_mode = .list,
            .sort_col = 0,
            .sort_dir = .ascending,
            .places_list = undefined,
            .look_in_combo = undefined,
            .look_in_paths = .empty,
            .syncing_look_in = false,
            .filename_field = undefined,
            .filter_combo = undefined,
            .ok_button = undefined,
            .cancel_button = undefined,
            .icon_folder = try app.icon(.folder),
            .icon_file = try app.icon(.file),
            .icon_home = try app.icon(.house),
            .icon_root = try app.icon(.hard_drive),
        };
        errdefer {
            self.files_model.deinit();
            self.places_model.deinit();
            self.clearLookInPaths();
            self.look_in_paths.deinit(allocator);
        }

        try self.buildUi();
        try self.rebuildPlacesModel();
        try self.rebuildFilesModel();
        try self.syncFieldsFromCore();
        return self;
    }

    pub fn destroy(self: *FileChooser) void {
        self.dialog.destroy();
        self.files_model.deinit();
        self.places_model.deinit();
        self.clearLookInPaths();
        self.look_in_paths.deinit(self.allocator);
        self.core.deinit();
        self.allocator.destroy(self);
    }

    pub fn setMode(self: *FileChooser, mode: Mode) void {
        self.core.setMode(mode);
    }

    pub fn setCurrentDirectory(self: *FileChooser, path: []const u8) void {
        self.reloadPath(path) catch {};
    }

    pub fn addFilter(self: *FileChooser, name: []const u8, extensions: []const []const u8) !void {
        try self.core.addFilter(name, extensions);
        try self.rebuildFilterCombo();
        try self.rebuildFilesModel();
    }

    pub fn setSelectedFileName(self: *FileChooser, name: []const u8) void {
        self.core.setSelectedFileName(name) catch return;
        self.filename_field.setText(name) catch {};
    }

    pub fn showOpenDialog(self: *FileChooser) Dialog.Result {
        self.setMode(.open);
        return self.showDialog("Open");
    }

    pub fn showSaveDialog(self: *FileChooser) Dialog.Result {
        self.setMode(.save);
        return self.showDialog("Save");
    }

    pub fn showDialog(self: *FileChooser, approve_text: []const u8) Dialog.Result {
        self.ok_button.setText(approve_text) catch {};
        self.syncFieldsFromCore() catch {};
        return self.dialog.showModal();
    }

    pub fn getSelectedPath(self: *const FileChooser) ?[]const u8 {
        return self.core.getSelectedPath();
    }

    pub fn getCurrentDirectory(self: *const FileChooser) []const u8 {
        return self.core.getCurrentDirectory();
    }

    fn buildUi(self: *FileChooser) !void {
        const app = self.app;
        const a = self.allocator;
        const root = &self.dialog.window.container;
        root.setLayout(try PaddingLayout.create(a, PaddingLayout.Insets.all(8)));

        const body = try app.container();
        body.setLayout(BorderLayout.get());
        try root.add(&body.component);

        const north = try app.container();
        north.setLayout(try BoxLayout.horizontalSpaced(a, 8));
        const look_in_label = try app.label("Look In:");
        self.look_in_combo = try app.comboBox(&.{"."});
        self.look_in_combo.component.setGrowX(1);
        const up_button = try app.button("Up");
        const home_button = try app.button("Home");
        const details_button = try app.button("Details");
        const list_button = try app.button("List");
        try self.look_in_combo.addChangeListener(FileChooser, onLookInChanged, self);
        try up_button.getModel().addActionListener(FileChooser, onUp, self);
        try home_button.getModel().addActionListener(FileChooser, onHome, self);
        try details_button.getModel().addActionListener(FileChooser, onDetails, self);
        try list_button.getModel().addActionListener(FileChooser, onList, self);
        try north.add(&look_in_label.component);
        try north.add(&self.look_in_combo.component);
        try north.add(&up_button.component);
        try north.add(&home_button.component);
        try north.add(&details_button.component);
        try north.add(&list_button.component);
        try BorderLayout.add(body, .north, &north.component);

        self.places_list = try app.listWithModel(&self.places_model, .{ .create = createPlaceCell, .user_data = self });
        self.places_list.setRowHeight(FILE_ROW_HEIGHT);
        try self.places_list.addChangeListener(FileChooser, onPlaceSelected, self);
        const places_sp = try app.scrollPane(self.places_list.asComponent());
        places_sp.container.component.min_size.width = 180;

        self.files_list = try app.listWithModel(&self.files_model, .{ .create = createFileCell, .user_data = self });
        self.files_list.asComponent().setName("files-list");
        self.files_list.setRowHeight(FILE_ROW_HEIGHT);
        try self.files_list.addChangeListener(FileChooser, onFileSelected, self);
        try self.files_list.addActionListener(FileChooser, onFileActivated, self);
        self.list_sp = try app.scrollPane(self.files_list.asComponent());

        self.files_table = try app.tableWithModel(&self.files_model, &.{
            .{ .title = "Name", .width = 300, .factory = .{ .create = createNameCell, .user_data = self } },
            .{ .title = "Size", .width = 90, .factory = .{ .create = createSizeCell, .user_data = self } },
            .{ .title = "Modified", .width = 150, .factory = .{ .create = createDateCell, .user_data = self } },
        });
        self.files_table.setRowHeight(FILE_ROW_HEIGHT);
        self.files_table.setSortIndicator(0, .ascending);
        try self.files_table.addChangeListener(FileChooser, onFileSelected, self);
        try self.files_table.addActionListener(FileChooser, onFileActivated, self);
        try self.files_table.addSortListener(FileChooser, onSort, self);
        self.table_sp = try app.scrollPane(self.files_table.asComponent());
        try self.table_sp.setColumnHeaderView(try self.files_table.headerView());

        const card_holder = try app.container();
        self.card_holder = card_holder;
        card_holder.setLayout(&self.card.base);
        try card_holder.add(self.list_sp.asComponent());
        try card_holder.add(self.table_sp.asComponent());
        self.card.active = self.list_sp.asComponent();

        const split = try app.splitPane(.horizontal, &places_sp.container.component, &card_holder.component);
        split.setDividerLocation(180);
        split.setResizeWeight(0);
        const center = try app.container();
        center.setLayout(try PaddingLayout.create(a, .{ .top = 8, .bottom = 8 }));
        try center.add(split.asComponent());
        try BorderLayout.add(body, .center, &center.component);

        const south = try app.container();
        south.setLayout(try BoxLayout.verticalSpaced(a, 8));
        const row1 = try app.container();
        row1.setLayout(try BoxLayout.horizontalSpaced(a, 8));
        const row2 = try app.container();
        row2.setLayout(try BoxLayout.horizontalSpaced(a, 8));
        const row3 = try app.container();
        row3.setLayout(try BoxLayout.horizontalSpaced(a, 8));

        const file_name_label = try app.label("File Name:");
        file_name_label.component.min_size.width = SOUTH_LABEL_WIDTH;
        self.filename_field = try app.textField("");
        self.filename_field.component.setGrowX(1);
        const files_type_label = try app.label("Files of Type:");
        files_type_label.component.min_size.width = SOUTH_LABEL_WIDTH;
        self.filter_combo = try app.comboBox(&.{"All Files"});
        self.filter_combo.component.setGrowX(1);
        self.ok_button = try app.button("OK");
        self.cancel_button = try app.button("Cancel");
        const glue = try app.container();
        glue.component.setGrowX(1);

        try self.filter_combo.addChangeListener(FileChooser, onFilterChanged, self);
        try self.ok_button.getModel().addActionListener(FileChooser, onOk, self);
        try self.cancel_button.getModel().addActionListener(FileChooser, onCancel, self);
        try row1.add(&file_name_label.component);
        try row1.add(&self.filename_field.component);
        try row2.add(&files_type_label.component);
        try row2.add(&self.filter_combo.component);
        try row3.add(&glue.component);
        try row3.add(&self.ok_button.component);
        try row3.add(&self.cancel_button.component);
        try south.add(&row1.component);
        try south.add(&row2.component);
        try south.add(&row3.component);
        try BorderLayout.add(body, .south, &south.component);
    }

    fn rebuildFilesModel(self: *FileChooser) !void {
        self.files_model.clear();
        self.files_list.clearSelection();
        self.files_table.clearSelection();

        var entries: std.ArrayList(*Entry) = .empty;
        defer entries.deinit(self.allocator);
        try entries.ensureTotalCapacity(self.allocator, self.core.visibleEntryCount());
        var i: usize = 0;
        while (i < self.core.visibleEntryCount()) : (i += 1) {
            entries.appendAssumeCapacity(self.core.visibleEntryAt(i).?);
        }
        std.sort.pdq(*Entry, entries.items, SortCtx{ .col = self.sort_col, .dir = self.sort_dir }, entrySortLess);

        for (entries.items) |entry| try self.files_model.add(@ptrCast(entry));
        self.files_list.asComponent().markLayoutDirty();
        self.files_table.asComponent().markLayoutDirty();
    }

    fn rebuildPlacesModel(self: *FileChooser) !void {
        self.places_model.clear();
        for (self.core.places.items) |p| try self.places_model.add(@ptrCast(p));
    }

    fn rebuildFilterCombo(self: *FileChooser) !void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        if (self.core.filters.items.len == 0) {
            try names.append(self.allocator, "All Files");
        } else {
            try names.ensureTotalCapacity(self.allocator, self.core.filters.items.len);
            for (self.core.filters.items) |filter| names.appendAssumeCapacity(filter.name);
        }
        try self.filter_combo.setItems(names.items);
        self.filter_combo.setSelectedIndex(self.core.selected_filter);
    }

    fn rebuildLookInCombo(self: *FileChooser) !void {
        var chain = try ChooserCore.ancestorChain(self.allocator, self.core.getCurrentDirectory());
        defer freeAncestorChain(self.allocator, &chain);

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        try names.ensureTotalCapacity(self.allocator, chain.items.len);

        self.clearLookInPaths();
        try self.look_in_paths.ensureTotalCapacity(self.allocator, chain.items.len);
        for (chain.items) |ancestor| {
            names.appendAssumeCapacity(ancestor.name);
            self.look_in_paths.appendAssumeCapacity(try self.allocator.dupe(u8, ancestor.path));
        }

        self.syncing_look_in = true;
        defer self.syncing_look_in = false;
        try self.look_in_combo.setItems(names.items);
        if (chain.items.len > 0) self.look_in_combo.setSelectedIndex(chain.items.len - 1);
    }

    fn syncFieldsFromCore(self: *FileChooser) !void {
        try self.rebuildLookInCombo();
        try self.filename_field.setText(self.core.filename.items);
    }

    fn reloadPath(self: *FileChooser, path: []const u8) !void {
        self.files_model.clear();
        try self.core.loadDir(path);
        try self.rebuildFilesModel();
        try self.syncFieldsFromCore();
    }

    fn selectedIndex(self: *FileChooser) ?usize {
        return switch (self.view_mode) {
            .list => self.files_list.getSelected(),
            .details => self.files_table.getSelected(),
        };
    }

    fn setActiveSelected(self: *FileChooser, idx: ?usize) void {
        switch (self.view_mode) {
            .list => self.files_list.setSelected(idx),
            .details => self.files_table.setSelected(idx),
        }
    }

    fn activeFilesComponent(self: *FileChooser) *Component {
        return switch (self.view_mode) {
            .list => self.files_list.asComponent(),
            .details => self.files_table.asComponent(),
        };
    }

    fn setViewMode(self: *FileChooser, mode: ViewMode) void {
        const plan = viewSwitchPlan(self.view_mode, mode, self.selectedIndex()) orelse return;
        self.view_mode = plan.mode;
        self.card.active = switch (mode) {
            .list => self.list_sp.asComponent(),
            .details => self.table_sp.asComponent(),
        };
        self.card_holder.component.markLayoutDirty();
        self.card_holder.component.repaint();
        self.setActiveSelected(plan.carry);
        self.activeFilesComponent().requestFocus();
    }

    fn selectedVisibleEntry(self: *FileChooser) ?*Entry {
        const idx = self.selectedIndex() orelse return null;
        const raw = self.files_model.getElementAt(idx) orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    fn selectedFileName(self: *FileChooser) ?[]const u8 {
        const e = self.selectedVisibleEntry() orelse return null;
        if (e.is_dir) return null;
        return e.name;
    }

    fn openEntry(self: *FileChooser, e: *Entry) !void {
        if (e.is_dir) {
            self.files_model.clear();
            try self.core.cd(e.name);
            try self.rebuildFilesModel();
            try self.syncFieldsFromCore();
        } else {
            try self.core.setSelectedFromList(e.name);
            try self.core.setSelectedFileName(e.name);
            try self.syncFieldsFromCore();
        }
    }

    fn clearLookInPaths(self: *FileChooser) void {
        for (self.look_in_paths.items) |path| self.allocator.free(path);
        self.look_in_paths.clearRetainingCapacity();
    }

    fn homePlaceIndex(self: *const FileChooser) ?usize {
        for (self.core.places.items, 0..) |place, i| {
            if (place.kind == .home) return i;
        }
        return null;
    }

    fn navigateToPlaceIndex(self: *FileChooser, idx: usize) !void {
        self.files_model.clear();
        try self.core.selectPlace(idx);
        try self.rebuildFilesModel();
        try self.syncFieldsFromCore();
    }

    fn onUp(self: *FileChooser, _: *const ActionEvent) void {
        self.files_model.clear();
        self.core.up() catch {};
        self.rebuildFilesModel() catch {};
        self.syncFieldsFromCore() catch {};
    }

    fn onPlaceSelected(self: *FileChooser, _: *const ChangeEvent) void {
        const idx = self.places_list.getSelected() orelse return;
        self.navigateToPlaceIndex(idx) catch {};
    }

    fn onLookInChanged(self: *FileChooser, _: *const ChangeEvent) void {
        if (self.syncing_look_in) return;
        const idx = self.look_in_combo.getSelectedIndex();
        if (idx >= self.look_in_paths.items.len) return;
        const path = self.look_in_paths.items[idx];
        if (std.mem.eql(u8, path, self.core.getCurrentDirectory())) return;
        self.reloadPath(path) catch {};
    }

    fn onHome(self: *FileChooser, _: *const ActionEvent) void {
        const idx = self.homePlaceIndex() orelse return;
        self.navigateToPlaceIndex(idx) catch {};
    }

    fn onDetails(self: *FileChooser, _: *const ActionEvent) void {
        self.setViewMode(.details);
    }

    fn onList(self: *FileChooser, _: *const ActionEvent) void {
        self.setViewMode(.list);
    }

    fn onFileSelected(self: *FileChooser, _: *const ChangeEvent) void {
        if (self.selectedFileName()) |name| {
            self.core.setSelectedFromList(name) catch {};
            self.core.setSelectedFileName(name) catch {};
            self.syncFieldsFromCore() catch {};
        }
    }

    fn onFileActivated(self: *FileChooser, _: *const ActionEvent) void {
        const e = self.selectedVisibleEntry() orelse return;
        self.openEntry(e) catch {};
    }

    fn onFilterChanged(self: *FileChooser, _: *const ChangeEvent) void {
        self.files_model.clear();
        self.core.setFilter(self.filter_combo.getSelectedIndex());
        self.rebuildFilesModel() catch {};
    }

    fn onSort(self: *FileChooser, e: *const Table.SortEvent) void {
        self.sort_col = e.column;
        self.sort_dir = e.direction;
        const keep = self.selectedVisibleEntry();
        self.rebuildFilesModel() catch {};
        if (keep) |entry| self.selectEntryPointer(entry);
    }

    fn selectEntryPointer(self: *FileChooser, entry: *Entry) void {
        var i: usize = 0;
        while (i < self.files_model.getSize()) : (i += 1) {
            const raw = self.files_model.getElementAt(i) orelse continue;
            const cur: *Entry = @ptrCast(@alignCast(raw));
            if (cur == entry) {
                self.setActiveSelected(i);
                return;
            }
        }
    }

    fn onOk(self: *FileChooser, _: *const ActionEvent) void {
        switch (self.core.mode) {
            .save => {
                self.core.setSelectedFileName(self.filename_field.getText()) catch return;
                self.core.commitSaveName() catch return;
                if (self.core.overwriteNeeded() and !self.confirmOverwrite()) return;
                self.dialog.close(.ok);
            },
            .open, .select_directory => {
                if (self.selectedVisibleEntry()) |e| {
                    if (self.core.mode == .select_directory and e.is_dir) {
                        self.core.setSelectedFromList(e.name) catch return;
                    } else if (!e.is_dir) {
                        self.core.setSelectedFromList(e.name) catch return;
                    }
                }
                if (self.core.getSelectedPath() != null) self.dialog.close(.ok);
            },
        }
    }

    fn onCancel(self: *FileChooser, _: *const ActionEvent) void {
        self.dialog.close(.cancel);
    }

    fn confirmOverwrite(self: *FileChooser) bool {
        const d = self.app.dialog(self.owner, "Confirm overwrite", 320, 140) catch return false;
        defer d.destroy();
        d.window.container.setLayout(PaddingLayout.create(self.allocator, PaddingLayout.Insets.all(12)) catch return false);
        const body = self.app.container() catch return false;
        body.setLayout(BoxLayout.verticalSpaced(self.allocator, 8) catch return false);
        const msg = self.app.label("Overwrite existing file?") catch return false;
        const row = self.app.container() catch return false;
        row.setLayout(BoxLayout.horizontalSpaced(self.allocator, 8) catch return false);
        const yes = self.app.button("Yes") catch return false;
        const no = self.app.button("No") catch return false;
        yes.getModel().addActionListener(Dialog, confirmYes, d) catch return false;
        no.getModel().addActionListener(Dialog, confirmNo, d) catch return false;
        row.add(&yes.component) catch return false;
        row.add(&no.component) catch return false;
        body.add(&msg.component) catch return false;
        body.add(&row.component) catch return false;
        d.window.add(&body.component) catch return false;
        return d.showModal() == .ok;
    }
};

fn confirmYes(d: *Dialog, _: *const ActionEvent) void {
    d.close(.ok);
}

fn confirmNo(d: *Dialog, _: *const ActionEvent) void {
    d.close(.cancel);
}

const FileCell = struct {
    root: *Container,
    label: *Label,
    chooser: *FileChooser,

    fn update(user_data: *anyopaque, ctx: List.CellContext) void {
        const self: *FileCell = @ptrCast(@alignCast(user_data));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.label.setText(e.name) catch {};
        self.label.setIcon(if (e.is_dir) self.chooser.icon_folder else self.chooser.icon_file);
    }

    fn destroy(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FileCell = @ptrCast(@alignCast(user_data));
        self.root.component.vtable.destroy(&self.root.component, allocator);
        allocator.destroy(self);
    }
};

fn createFileCell(user_data: *anyopaque, allocator: std.mem.Allocator) anyerror!List.Cell {
    const chooser: *FileChooser = @ptrCast(@alignCast(user_data));
    const cell = try allocator.create(FileCell);
    errdefer allocator.destroy(cell);

    const root = try chooser.app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(try PaddingLayout.create(allocator, .{ .left = 6, .right = 6 }));

    const label = try chooser.app.label("");
    label.setIconSize(.{ .width = 18, .height = 18 });
    try root.add(&label.component);

    cell.* = .{ .root = root, .label = label, .chooser = chooser };
    return .{
        .component = &root.component,
        .update = FileCell.update,
        .destroy = FileCell.destroy,
        .user_data = cell,
    };
}

const NameCell = struct {
    root: *Container,
    label: *Label,
    chooser: *FileChooser,

    fn update(user_data: *anyopaque, ctx: Table.CellContext) void {
        const self: *NameCell = @ptrCast(@alignCast(user_data));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        self.label.setText(e.name) catch {};
        self.label.setIcon(if (e.is_dir) self.chooser.icon_folder else self.chooser.icon_file);
    }

    fn destroy(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *NameCell = @ptrCast(@alignCast(user_data));
        self.root.component.vtable.destroy(&self.root.component, allocator);
        allocator.destroy(self);
    }
};

fn createNameCell(user_data: *anyopaque, allocator: std.mem.Allocator) anyerror!Table.Cell {
    const chooser: *FileChooser = @ptrCast(@alignCast(user_data));
    const cell = try allocator.create(NameCell);
    errdefer allocator.destroy(cell);

    const root = try chooser.app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(try PaddingLayout.create(allocator, .{ .left = 6, .right = 6 }));

    const label = try chooser.app.label("");
    label.setIconSize(.{ .width = FILE_ICON, .height = FILE_ICON });
    try root.add(&label.component);

    cell.* = .{ .root = root, .label = label, .chooser = chooser };
    return .{
        .component = &root.component,
        .update = NameCell.update,
        .destroy = NameCell.destroy,
        .user_data = cell,
    };
}

const TextKind = enum { size, date };

const TextCell = struct {
    label: *Label,
    kind: TextKind,
    buf: [40]u8 = undefined,

    fn update(user_data: *anyopaque, ctx: Table.CellContext) void {
        const self: *TextCell = @ptrCast(@alignCast(user_data));
        const e: *Entry = @ptrCast(@alignCast(ctx.value));
        const text = switch (self.kind) {
            .size => if (e.is_dir) "" else fmtSize(&self.buf, e.size),
            .date => fmtDate(&self.buf, e.mtime),
        };
        self.label.setText(text) catch {};
    }

    fn destroy(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TextCell = @ptrCast(@alignCast(user_data));
        self.label.component.vtable.destroy(&self.label.component, allocator);
        allocator.destroy(self);
    }
};

fn createSizeCell(user_data: *anyopaque, allocator: std.mem.Allocator) anyerror!Table.Cell {
    return createTextCell(user_data, allocator, .size);
}

fn createDateCell(user_data: *anyopaque, allocator: std.mem.Allocator) anyerror!Table.Cell {
    return createTextCell(user_data, allocator, .date);
}

fn createTextCell(user_data: *anyopaque, allocator: std.mem.Allocator, kind: TextKind) anyerror!Table.Cell {
    const chooser: *FileChooser = @ptrCast(@alignCast(user_data));
    const cell = try allocator.create(TextCell);
    errdefer allocator.destroy(cell);
    const label = try chooser.app.label("");
    cell.* = .{ .label = label, .kind = kind };
    return .{
        .component = &label.component,
        .update = TextCell.update,
        .destroy = TextCell.destroy,
        .user_data = cell,
    };
}

const PlaceCell = struct {
    root: *Container,
    label: *Label,
    chooser: *FileChooser,

    fn update(user_data: *anyopaque, ctx: List.CellContext) void {
        const self: *PlaceCell = @ptrCast(@alignCast(user_data));
        const p: *Place = @ptrCast(@alignCast(ctx.value));
        self.label.setText(p.name) catch {};
        self.label.setIcon(switch (p.kind) {
            .home => self.chooser.icon_home,
            .root => self.chooser.icon_root,
        });
    }

    fn destroy(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *PlaceCell = @ptrCast(@alignCast(user_data));
        self.root.component.vtable.destroy(&self.root.component, allocator);
        allocator.destroy(self);
    }
};

fn createPlaceCell(user_data: *anyopaque, allocator: std.mem.Allocator) anyerror!List.Cell {
    const chooser: *FileChooser = @ptrCast(@alignCast(user_data));
    const cell = try allocator.create(PlaceCell);
    errdefer allocator.destroy(cell);

    const root = try chooser.app.container();
    errdefer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(try PaddingLayout.create(allocator, .{ .left = 6, .right = 6 }));

    const label = try chooser.app.label("");
    label.setIconSize(.{ .width = 18, .height = 18 });
    try root.add(&label.component);

    cell.* = .{ .root = root, .label = label, .chooser = chooser };
    return .{
        .component = &root.component,
        .update = PlaceCell.update,
        .destroy = PlaceCell.destroy,
        .user_data = cell,
    };
}

fn entryLess(_: void, a: *Entry, b: *Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn entrySortLess(ctx: SortCtx, a: *Entry, b: *Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    const eq = switch (ctx.col) {
        1 => a.size == b.size,
        2 => a.mtime == b.mtime,
        else => std.ascii.eqlIgnoreCase(a.name, b.name),
    };
    if (eq) return std.ascii.lessThanIgnoreCase(a.name, b.name);
    const less = switch (ctx.col) {
        1 => a.size < b.size,
        2 => a.mtime < b.mtime,
        else => std.ascii.lessThanIgnoreCase(a.name, b.name),
    };
    return if (ctx.dir == .ascending) less else !less;
}

fn viewSwitchPlan(current: ViewMode, mode: ViewMode, selected: ?usize) ?ViewSwitchPlan {
    if (current == mode) return null;
    return .{ .mode = mode, .carry = selected };
}

fn hasExtension(name: []const u8, ext: []const u8) bool {
    if (ext.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const actual = name[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(actual, ext);
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
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

fn ancestorDisplayName(path: []const u8) []const u8 {
    if (std.fs.path.dirname(path) == null) return path;
    const name = basename(path);
    if (name.len == 0) return path;
    return name;
}

fn freeAncestorChain(allocator: std.mem.Allocator, chain: *std.ArrayList(Ancestor)) void {
    for (chain.items) |ancestor| {
        allocator.free(ancestor.name);
        allocator.free(ancestor.path);
    }
    chain.deinit(allocator);
}

fn copyPath(buf: *[PATH_BUF]u8, len: *usize, path: []const u8) !void {
    if (path.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    len.* = path.len;
}

fn joinPath(buf: []u8, dir: []const u8, name: []const u8) ![]const u8 {
    if (name.len == 0) return error.EmptyName;
    if (std.fs.path.isAbsolute(name)) {
        if (name.len > buf.len) return error.PathTooLong;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    if (dir.len == 0) return error.EmptyPath;
    const needs_sep = !hasTrailingSep(dir);
    const total = dir.len + @intFromBool(needs_sep) + name.len;
    if (total > buf.len) return error.PathTooLong;
    @memcpy(buf[0..dir.len], dir);
    var pos = dir.len;
    if (needs_sep) {
        buf[pos] = pathSepFor(dir);
        pos += 1;
    }
    @memcpy(buf[pos..][0..name.len], name);
    return buf[0..total];
}

fn hasTrailingSep(path: []const u8) bool {
    return path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\');
}

fn pathSepFor(path: []const u8) u8 {
    if (std.mem.indexOfScalar(u8, path, '/') != null and std.mem.indexOfScalar(u8, path, '\\') == null) return '/';
    return std.fs.path.sep;
}

fn freeDirEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(DirEntry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

fn freePlaceEntries(allocator: std.mem.Allocator, places: *std.ArrayList(PlaceEntry)) void {
    for (places.items) |place| {
        allocator.free(place.name);
        allocator.free(place.path);
    }
    places.deinit(allocator);
}

const FakeDirSource = struct {
    allocator: std.mem.Allocator,
    dirs: std.ArrayList(FakeDir),
    places: std.ArrayList(PlaceEntry),
    list_calls: usize = 0,

    const FakeDir = struct {
        path: []const u8,
        entries: std.ArrayList(DirEntry),
    };

    fn init(allocator: std.mem.Allocator) FakeDirSource {
        return .{
            .allocator = allocator,
            .dirs = .empty,
            .places = .empty,
        };
    }

    fn deinit(self: *FakeDirSource) void {
        for (self.dirs.items) |*dir| {
            self.allocator.free(dir.path);
            freeDirEntries(self.allocator, &dir.entries);
        }
        self.dirs.deinit(self.allocator);
        freePlaceEntries(self.allocator, &self.places);
    }

    fn source(self: *FakeDirSource) DirSource {
        return .{ .vtable = &fake_vtable, .user_data = self };
    }

    fn addDir(self: *FakeDirSource, path: []const u8, entries: []const DirEntry) !void {
        var dir = FakeDir{
            .path = try self.allocator.dupe(u8, path),
            .entries = .empty,
        };
        errdefer {
            self.allocator.free(dir.path);
            freeDirEntries(self.allocator, &dir.entries);
        }
        try dir.entries.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |entry| {
            dir.entries.appendAssumeCapacity(.{
                .name = try self.allocator.dupe(u8, entry.name),
                .is_dir = entry.is_dir,
                .size = entry.size,
                .mtime = entry.mtime,
            });
        }
        try self.dirs.append(self.allocator, dir);
    }

    fn addPlace(self: *FakeDirSource, name: []const u8, path: []const u8, kind: PlaceEntry.Kind) !void {
        try appendPlace(self.allocator, &self.places, name, path, kind);
    }

    fn findDir(self: *FakeDirSource, path: []const u8) ?*FakeDir {
        for (self.dirs.items) |*dir| {
            if (std.mem.eql(u8, dir.path, path)) return dir;
        }
        return null;
    }
};

const fake_vtable = DirSource.VTable{
    .list = fakeList,
    .realPath = fakeRealPath,
    .places = fakePlaces,
};

fn fakeSource(user_data: *anyopaque) *FakeDirSource {
    return @ptrCast(@alignCast(user_data));
}

fn fakeList(user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(DirEntry)) !void {
    const fake = fakeSource(user_data);
    fake.list_calls += 1;
    const dir = fake.findDir(path) orelse return error.FileNotFound;
    try out.ensureTotalCapacity(allocator, dir.entries.items.len);
    for (dir.entries.items) |entry| {
        out.appendAssumeCapacity(.{
            .name = try allocator.dupe(u8, entry.name),
            .is_dir = entry.is_dir,
            .size = entry.size,
            .mtime = entry.mtime,
        });
    }
}

fn fakeRealPath(_: *anyopaque, path: []const u8, buf: []u8) ![]const u8 {
    if (path.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

fn fakePlaces(user_data: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(PlaceEntry)) !void {
    const fake = fakeSource(user_data);
    try out.ensureTotalCapacity(allocator, fake.places.items.len);
    for (fake.places.items) |place| {
        out.appendAssumeCapacity(.{
            .name = try allocator.dupe(u8, place.name),
            .path = try allocator.dupe(u8, place.path),
            .kind = place.kind,
        });
    }
}

fn expectVisibleNames(core: *const ChooserCore, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, core.visibleEntryCount());
    for (expected, 0..) |name, i| {
        const entry = core.visibleEntryAt(i).?;
        try std.testing.expectEqualStrings(name, entry.name);
    }
}

fn populateFake(allocator: std.mem.Allocator) !FakeDirSource {
    var fake = FakeDirSource.init(allocator);
    errdefer fake.deinit();
    try fake.addPlace("Home", "/home/me", .home);
    try fake.addPlace("Root", "/", .root);
    try fake.addPlace("C", "C:\\", .root);
    try fake.addDir("/", &.{
        .{ .name = "home", .is_dir = true },
        .{ .name = "tmp", .is_dir = true },
        .{ .name = "root.txt", .is_dir = false },
    });
    try fake.addDir("/home/me", &.{
        .{ .name = "docs", .is_dir = true },
        .{ .name = "photo.PNG", .is_dir = false, .size = 10 },
        .{ .name = "notes.txt", .is_dir = false, .size = 20 },
    });
    try fake.addDir("/home/me/docs", &.{
        .{ .name = "paper.md", .is_dir = false },
    });
    try fake.addDir("/tmp", &.{
        .{ .name = "scratch.txt", .is_dir = false },
    });
    try fake.addDir("C:\\", &.{
        .{ .name = "Users", .is_dir = true },
        .{ .name = "boot.ini", .is_dir = false },
    });
    try fake.addDir("C:\\Users", &.{
        .{ .name = "me", .is_dir = true },
    });
    try fake.addDir("C:\\Users\\me", &.{
        .{ .name = "note.txt", .is_dir = false },
    });
    return fake;
}

test "ancestor chain splits POSIX and Windows paths from root" {
    var posix = try ChooserCore.ancestorChain(std.testing.allocator, "/home/me/docs");
    defer freeAncestorChain(std.testing.allocator, &posix);
    try std.testing.expectEqual(@as(usize, 4), posix.items.len);
    try std.testing.expectEqualStrings("/", posix.items[0].name);
    try std.testing.expectEqualStrings("/", posix.items[0].path);
    try std.testing.expectEqualStrings("home", posix.items[1].name);
    try std.testing.expectEqualStrings("/home", posix.items[1].path);
    try std.testing.expectEqualStrings("me", posix.items[2].name);
    try std.testing.expectEqualStrings("/home/me", posix.items[2].path);
    try std.testing.expectEqualStrings("docs", posix.items[3].name);
    try std.testing.expectEqualStrings("/home/me/docs", posix.items[3].path);

    var windows = try ChooserCore.ancestorChain(std.testing.allocator, "C:\\Users\\me");
    defer freeAncestorChain(std.testing.allocator, &windows);
    try std.testing.expectEqual(@as(usize, 3), windows.items.len);
    try std.testing.expectEqualStrings("C:\\", windows.items[0].name);
    try std.testing.expectEqualStrings("C:\\", windows.items[0].path);
    try std.testing.expectEqualStrings("Users", windows.items[1].name);
    try std.testing.expectEqualStrings("C:\\Users", windows.items[1].path);
    try std.testing.expectEqualStrings("me", windows.items[2].name);
    try std.testing.expectEqualStrings("C:\\Users\\me", windows.items[2].path);
}

test "navigation cd up selectPlace and drive root up no-op" {
    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    var core = try ChooserCore.init(std.testing.allocator, fake.source());
    defer core.deinit();

    try core.loadDir("/home/me");
    try core.cd("docs");
    try std.testing.expectEqualStrings("/home/me/docs", core.getCurrentDirectory());
    try core.up();
    try std.testing.expectEqualStrings("/home/me", core.getCurrentDirectory());
    try core.selectPlace(1);
    try std.testing.expectEqualStrings("/", core.getCurrentDirectory());
    try core.selectPlace(2);
    try std.testing.expectEqualStrings("C:\\", core.getCurrentDirectory());
    try core.up();
    try std.testing.expectEqualStrings("C:\\", core.getCurrentDirectory());
}

test "filter applies by extension keeps folders visible and folders-first sort" {
    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    var core = try ChooserCore.init(std.testing.allocator, fake.source());
    defer core.deinit();

    try core.addFilter("Images", &.{ "png", "jpg" });
    try core.loadDir("/home/me");
    try expectVisibleNames(&core, &.{ "docs", "photo.PNG" });
    try std.testing.expect(core.visibleEntryAt(0).?.is_dir);
}

test "list selection commits current directory plus name" {
    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    var core = try ChooserCore.init(std.testing.allocator, fake.source());
    defer core.deinit();

    try core.loadDir("/home/me");
    try core.setSelectedFromList("notes.txt");
    try std.testing.expectEqualStrings("/home/me/notes.txt", core.getSelectedPath().?);
}

test "save filename commit and overwrite detection" {
    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    var core = try ChooserCore.init(std.testing.allocator, fake.source());
    defer core.deinit();

    core.setMode(.save);
    try core.loadDir("/home/me");
    try core.setSelectedFileName("notes.txt");
    try core.commitSaveName();
    try std.testing.expectEqualStrings("/home/me/notes.txt", core.getSelectedPath().?);
    try std.testing.expect(core.overwriteNeeded());

    try core.setSelectedFileName("new.txt");
    try core.commitSaveName();
    try std.testing.expectEqualStrings("/home/me/new.txt", core.getSelectedPath().?);
    try std.testing.expect(!core.overwriteNeeded());
}

test "reload replaces owned entry store without leaks or stale entries" {
    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    var core = try ChooserCore.init(std.testing.allocator, fake.source());
    defer core.deinit();

    try core.loadDir("/home/me");
    try expectVisibleNames(&core, &.{ "docs", "notes.txt", "photo.PNG" });
    try core.loadDir("/tmp");
    try expectVisibleNames(&core, &.{"scratch.txt"});
    try std.testing.expectEqualStrings("/tmp", core.getCurrentDirectory());
}

test "details sort keeps folders first and applies column keys" {
    var dir_b = Entry{ .name = "zeta", .is_dir = true };
    var dir_a = Entry{ .name = "Alpha", .is_dir = true };
    var small = Entry{ .name = "small.txt", .is_dir = false, .size = 10, .mtime = 20 };
    var large = Entry{ .name = "large.txt", .is_dir = false, .size = 100, .mtime = 10 };
    var same = Entry{ .name = "Same.txt", .is_dir = false, .size = 100, .mtime = 30 };

    var by_size = [_]*Entry{ &small, &dir_b, &large, &dir_a, &same };
    std.sort.pdq(*Entry, &by_size, SortCtx{ .col = 1, .dir = .descending }, entrySortLess);
    try std.testing.expectEqualStrings("Alpha", by_size[0].name);
    try std.testing.expectEqualStrings("zeta", by_size[1].name);
    try std.testing.expectEqualStrings("large.txt", by_size[2].name);
    try std.testing.expectEqualStrings("Same.txt", by_size[3].name);
    try std.testing.expectEqualStrings("small.txt", by_size[4].name);

    var by_date = [_]*Entry{ &small, &large, &same };
    std.sort.pdq(*Entry, &by_date, SortCtx{ .col = 2, .dir = .ascending }, entrySortLess);
    try std.testing.expectEqualStrings("large.txt", by_date[0].name);
    try std.testing.expectEqualStrings("small.txt", by_date[1].name);
    try std.testing.expectEqualStrings("Same.txt", by_date[2].name);
}

test "view switch plan carries selected index and ignores same mode" {
    try std.testing.expectEqual(@as(?ViewSwitchPlan, null), viewSwitchPlan(.list, .list, 2));
    const to_details = viewSwitchPlan(.list, .details, 2).?;
    try std.testing.expectEqual(ViewMode.details, to_details.mode);
    try std.testing.expectEqual(@as(?usize, 2), to_details.carry);
    const to_list = viewSwitchPlan(.details, .list, null).?;
    try std.testing.expectEqual(ViewMode.list, to_list.mode);
    try std.testing.expectEqual(@as(?usize, null), to_list.carry);
}

test "home place index resolves home and missing home stays no-op" {
    awt.setLogCallback(@import("Robot.zig").QuietLog.cb, null);
    const app = Application.initHeadless(std.testing.allocator, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();
    const frame = try app.frameHeadless("owner", 320, 200);

    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    const chooser = try FileChooser.createWithSource(app, &frame.window, fake.source());
    defer chooser.destroy();

    try std.testing.expectEqual(@as(?usize, 0), chooser.homePlaceIndex());
    try chooser.reloadPath("/tmp");
    try std.testing.expectEqualStrings("/tmp", chooser.getCurrentDirectory());
    var action_source: u8 = 0;
    const ev = ActionEvent{ .source = &action_source };
    FileChooser.onHome(chooser, &ev);
    try std.testing.expectEqualStrings("/home/me", chooser.getCurrentDirectory());

    var no_home = FakeDirSource.init(std.testing.allocator);
    defer no_home.deinit();
    try no_home.addPlace("Root", "/", .root);
    try no_home.addDir("/", &.{
        .{ .name = "tmp", .is_dir = true },
    });
    const chooser_no_home = try FileChooser.createWithSource(app, &frame.window, no_home.source());
    defer chooser_no_home.destroy();

    const before_calls = no_home.list_calls;
    try std.testing.expectEqual(@as(?usize, null), chooser_no_home.homePlaceIndex());
    FileChooser.onHome(chooser_no_home, &ev);
    try std.testing.expectEqualStrings("/", chooser_no_home.getCurrentDirectory());
    try std.testing.expectEqual(before_calls, no_home.list_calls);
}

test "look in rebuild does not navigate through change listener" {
    awt.setLogCallback(@import("Robot.zig").QuietLog.cb, null);
    const app = Application.initHeadless(std.testing.allocator, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();
    const frame = try app.frameHeadless("owner", 320, 200);

    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    const chooser = try FileChooser.createWithSource(app, &frame.window, fake.source());
    defer chooser.destroy();

    try chooser.reloadPath("/home/me/docs");
    const before_calls = fake.list_calls;
    try chooser.rebuildLookInCombo();
    try std.testing.expectEqual(before_calls, fake.list_calls);
    try std.testing.expectEqual(@as(usize, 4), chooser.look_in_paths.items.len);
    try std.testing.expectEqualStrings("/home/me/docs", chooser.getCurrentDirectory());
    try std.testing.expectEqualStrings("/home/me/docs", chooser.look_in_paths.items[3]);
}

test "file chooser widget reload helper repopulates borrowed list model" {
    awt.setLogCallback(@import("Robot.zig").QuietLog.cb, null);
    const app = Application.initHeadless(std.testing.allocator, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();
    const frame = try app.frameHeadless("owner", 320, 200);

    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    const chooser = try FileChooser.createWithSource(app, &frame.window, fake.source());
    defer chooser.destroy();

    try chooser.dialog.show();
    var robot = @import("Robot.zig").init(app, &chooser.dialog.window);
    robot.pump();

    try std.testing.expectEqualStrings("/home/me", chooser.getCurrentDirectory());
    try std.testing.expect(chooser.files_model.getSize() > 1);
    // reloadPath owns the required order: clear the borrowed ListModel before
    // core.loadDir replaces Entry storage, then publish the fresh visible rows.
    try chooser.reloadPath("/tmp");
    robot.pump();
    try std.testing.expectEqual(@as(usize, 1), chooser.files_model.getSize());
    const raw = chooser.files_model.getElementAt(0).?;
    const entry: *Entry = @ptrCast(@alignCast(raw));
    try std.testing.expectEqualStrings("scratch.txt", entry.name);
}

test "file chooser headless smoke selects a file and closes with OK" {
    awt.setLogCallback(@import("Robot.zig").QuietLog.cb, null);
    const app = Application.initHeadless(std.testing.allocator, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();
    const frame = try app.frameHeadless("owner", 420, 260);

    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    const chooser = try FileChooser.createWithSource(app, &frame.window, fake.source());
    defer chooser.destroy();

    try chooser.dialog.show();
    var robot = @import("Robot.zig").init(app, &chooser.dialog.window);
    var driver = @import("Driver.zig"){ .robot = &robot };
    robot.pump();

    chooser.files_list.setSelected(1);
    const selected_before = chooser.selectedVisibleEntry().?;
    try driver.clickOn(.{ .role = .button, .text = "Details" });
    robot.pump();
    try std.testing.expectEqual(ViewMode.details, chooser.view_mode);
    try std.testing.expectEqual(chooser.table_sp.asComponent(), chooser.card.active.?);
    try std.testing.expectEqual(@as(?usize, 1), chooser.files_table.getSelected());
    try std.testing.expectEqual(selected_before, chooser.selectedVisibleEntry().?);
    try std.testing.expect(chooser.files_model.getSize() > 0);
    _ = try driver.find(.{ .role = .table });

    try driver.clickOn(.{ .role = .button, .text = "List" });
    robot.pump();
    try std.testing.expectEqual(ViewMode.list, chooser.view_mode);
    try std.testing.expectEqual(chooser.list_sp.asComponent(), chooser.card.active.?);
    try std.testing.expectEqual(@as(?usize, 1), chooser.files_list.getSelected());
    _ = try driver.find(.{ .role = .list, .name = "files-list" });

    try driver.clickOn(.{ .role = .button, .text = "Details" });
    robot.pump();
    try std.testing.expectEqual(selected_before, chooser.selectedVisibleEntry().?);
    chooser.core.selected_len = 0;
    try driver.clickOn(.{ .role = .button, .text = "OK" });
    robot.pump();

    try std.testing.expectEqual(Dialog.Result.ok, chooser.dialog.getResult());
    try std.testing.expectEqualStrings("/home/me/notes.txt", chooser.getSelectedPath().?);

    const tree = try robot.snapshotTree(std.testing.allocator);
    defer @import("Robot.zig").freeTree(std.testing.allocator, tree);
    try std.testing.expect(tree.children.len > 0);
}

test "file chooser save path detects overwrite before confirmation" {
    awt.setLogCallback(@import("Robot.zig").QuietLog.cb, null);
    const app = Application.initHeadless(std.testing.allocator, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();
    const frame = try app.frameHeadless("owner", 320, 200);

    var fake = try populateFake(std.testing.allocator);
    defer fake.deinit();
    const chooser = try FileChooser.createWithSource(app, &frame.window, fake.source());
    defer chooser.destroy();

    chooser.setMode(.save);
    chooser.setSelectedFileName("notes.txt");
    try chooser.core.commitSaveName();
    try std.testing.expect(chooser.core.overwriteNeeded());
}
