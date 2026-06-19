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
const List = @import("List.zig");
const PaddingLayout = @import("PaddingLayout.zig");
const ScrollPane = @import("ScrollPane.zig");
const SplitPane = @import("SplitPane.zig");
const TextField = @import("TextField.zig");
const Window = @import("Window.zig");
const ActionEvent = @import("listener.zig").ActionEvent;
const ChangeEvent = @import("listener.zig").ChangeEvent;

const PATH_BUF = 4096;

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
        var entry = DirEntry{
            .name = try allocator.dupe(u8, ent.name),
            .is_dir = ent.kind == .directory,
        };
        errdefer allocator.free(entry.name);

        if (dir.statFile(state.io, ent.name, .{}) catch null) |st| {
            entry.size = st.size;
            entry.mtime = @intCast(@divFloor(st.mtime.nanoseconds, 1_000_000_000));
        }
        try out.append(allocator, entry);
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
    const state = osState(user_data);
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
        var letter: u8 = 'A';
        while (letter <= 'Z') : (letter += 1) {
            const drive = [3]u8{ letter, ':', std.fs.path.sep };
            std.Io.Dir.accessAbsolute(state.io, &drive, .{}) catch continue;
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
    places_list: *List,
    path_field: *TextField,
    filename_field: *TextField,
    filter_combo: *ComboBox,
    ok_button: *Button,
    cancel_button: *Button,
    up_button: *Button,
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
            .places_list = undefined,
            .path_field = undefined,
            .filename_field = undefined,
            .filter_combo = undefined,
            .ok_button = undefined,
            .cancel_button = undefined,
            .up_button = undefined,
            .icon_folder = try app.icon(.folder),
            .icon_file = try app.icon(.file),
            .icon_home = try app.icon(.house),
            .icon_root = try app.icon(.hard_drive),
        };
        errdefer {
            self.files_model.deinit();
            self.places_model.deinit();
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
        self.up_button = try app.button("Up");
        self.path_field = try app.textField("");
        self.path_field.component.setGrowX(1);
        try self.up_button.getModel().addActionListener(FileChooser, onUp, self);
        try self.path_field.addSubmitListener(FileChooser, onPathSubmit, self);
        try north.add(&self.up_button.component);
        try north.add(&self.path_field.component);
        try BorderLayout.add(body, .north, &north.component);

        self.places_list = try app.listWithModel(&self.places_model, .{ .create = createPlaceCell, .user_data = self });
        self.places_list.setRowHeight(28);
        try self.places_list.addChangeListener(FileChooser, onPlaceSelected, self);
        const places_sp = try app.scrollPane(self.places_list.asComponent());
        places_sp.container.component.min_size.width = 180;

        self.files_list = try app.listWithModel(&self.files_model, .{ .create = createFileCell, .user_data = self });
        self.files_list.setRowHeight(28);
        try self.files_list.addChangeListener(FileChooser, onFileSelected, self);
        try self.files_list.addActionListener(FileChooser, onFileActivated, self);
        const files_sp = try app.scrollPane(self.files_list.asComponent());

        const card_holder = try app.container();
        card_holder.setLayout(BorderLayout.get());
        try BorderLayout.add(card_holder, .center, &files_sp.container.component);

        const split = try app.splitPane(.horizontal, &places_sp.container.component, &card_holder.component);
        split.setDividerLocation(180);
        split.setResizeWeight(0);
        try BorderLayout.add(body, .center, split.asComponent());

        const south = try app.container();
        south.setLayout(try BoxLayout.horizontalSpaced(a, 8));
        self.filename_field = try app.textField("");
        self.filename_field.component.setGrowX(1);
        self.filter_combo = try app.comboBox(&.{"All Files"});
        self.ok_button = try app.button("OK");
        self.cancel_button = try app.button("Cancel");
        try self.filter_combo.addChangeListener(FileChooser, onFilterChanged, self);
        try self.ok_button.getModel().addActionListener(FileChooser, onOk, self);
        try self.cancel_button.getModel().addActionListener(FileChooser, onCancel, self);
        try south.add(&self.filename_field.component);
        try south.add(&self.filter_combo.component);
        try south.add(&self.ok_button.component);
        try south.add(&self.cancel_button.component);
        try BorderLayout.add(body, .south, &south.component);
    }

    fn rebuildFilesModel(self: *FileChooser) !void {
        self.files_model.clear();
        self.files_list.clearSelection();
        var i: usize = 0;
        while (i < self.core.visibleEntryCount()) : (i += 1) {
            try self.files_model.add(@ptrCast(self.core.visibleEntryAt(i).?));
        }
        self.files_list.asComponent().markLayoutDirty();
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

    fn syncFieldsFromCore(self: *FileChooser) !void {
        try self.path_field.setText(self.core.getCurrentDirectory());
        try self.filename_field.setText(self.core.filename.items);
    }

    fn reloadPath(self: *FileChooser, path: []const u8) !void {
        self.files_model.clear();
        try self.core.loadDir(path);
        try self.rebuildFilesModel();
        try self.syncFieldsFromCore();
    }

    fn selectedVisibleEntry(self: *FileChooser) ?*Entry {
        const idx = self.files_list.getSelected() orelse return null;
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

    fn onUp(self: *FileChooser, _: *const ActionEvent) void {
        self.files_model.clear();
        self.core.up() catch {};
        self.rebuildFilesModel() catch {};
        self.syncFieldsFromCore() catch {};
    }

    fn onPathSubmit(self: *FileChooser, _: *const ActionEvent) void {
        self.reloadPath(self.path_field.getText()) catch {};
    }

    fn onPlaceSelected(self: *FileChooser, _: *const ChangeEvent) void {
        const idx = self.places_list.getSelected() orelse return;
        self.files_model.clear();
        self.core.selectPlace(idx) catch return;
        self.rebuildFilesModel() catch {};
        self.syncFieldsFromCore() catch {};
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

fn hasExtension(name: []const u8, ext: []const u8) bool {
    if (ext.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const actual = name[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(actual, ext);
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
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
    return fake;
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
