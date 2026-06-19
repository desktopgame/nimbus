const std = @import("std");
const builtin = @import("builtin");

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

const OsDirSourceState = struct {
    io: std.Io,
};

var os_dir_source_state: OsDirSourceState = undefined;

pub fn osDirSource(io: std.Io) DirSource {
    os_dir_source_state = .{ .io = io };
    return .{
        .vtable = &os_vtable,
        .user_data = &os_dir_source_state,
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
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (std.process.getEnvVarOwned(allocator, home_var)) |home| {
        errdefer allocator.free(home);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, "Home"),
            .path = home,
            .kind = .home,
        });
    } else |_| {}

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
