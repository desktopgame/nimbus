// ── runtime support (hand-written) ──────────────────────────────────────
// This block is prepended verbatim to the generated `framework/src/c_api.zig`
// by tools/apigen. Glue that cannot be derived mechanically from the binding
// spec (last-error storage, backend passthrough, future ctors that need an
// allocator / io) lives here. See doc/c_api_codegen.md.
const std = @import("std");
const framework = @import("nimbus");
const awt = framework.awt;

/// Borrowed UTF-8 string slice returned across the ABI (ptr + len; NOT
/// NUL-terminated). Mirrors C `nmStr`. Borrowed: valid until the source widget
/// mutates / is destroyed — callers copy immediately. `ptr` is null for an
/// absent optional value.
const nmStr = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

// Thread-local last-error storage. A failing export stores the error here and
// signals failure to C via NULL / a non-zero int (see CLAUDE.md
// 「エラーのC_ABIでの表現」). Callers read it back with the two accessors below.
threadlocal var last_error: ?anyerror = null;
threadlocal var last_error_buf: [256]u8 = [_]u8{0} ** 256;

fn setLastError(err: anyerror) void {
    last_error = err;
    const name = @errorName(err);
    const n = @min(name.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..n], name[0..n]);
    last_error_buf[n] = 0;
}

// Maps a Zig error to the stable integer code returned by `nmLastErrorCode`.
// Hand-maintained: extend as the public surface grows.
fn errorToCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => 1,
        error.IconNotFound => 2,
        else => 99,
    };
}

export fn nmLastErrorCode() c_int {
    return errorToCode(last_error orelse return 0);
}

export fn nmLastErrorMessage() [*:0]const u8 {
    return @ptrCast(&last_error_buf);
}

// Backend identification string. A passthrough into the awt layer rather than
// a framework method, so it is written by hand rather than generated.
export fn nmGetBackendVersion() [*:0]const u8 {
    return @ptrCast(awt.c.nmAwtBackendVersion());
}

// ── event accessors ──────────────────────────────────────────────────────
// Listener callbacks receive the semantic event as an opaque `const void*`
// (the native ChangeListenerList.Event passed straight through; see approach C
// in doc/c_api_codegen.md). These read its fields without copying. Hand-written
// because Event is a fixed framework type (source pointer + enum), not a
// codegen-friendly scalar struct.
export fn nmEventKind(event: *const framework.ChangeListenerList.Event) c_int {
    return @intFromEnum(event.kind); // 0 = change, 1 = action
}

export fn nmEventSource(event: *const framework.ChangeListenerList.Event) ?*anyopaque {
    return event.source; // the firing Model
}

// ── bootstrap ────────────────────────────────────────────────────────────
// `Application.init` needs an allocator and an `Io`, neither of which can come
// across the C ABI, so the entry point is hand-written here (not generated).
// Defaults: libc allocator + std's process-wide single-threaded Io (nimbus is
// single-UI-thread, so single-threaded Io fits). `nmAppRun` IS generated
// (`Application.run` is a plain `!void` method). See doc/c_api_codegen.md.
export fn nmAppCreate() ?*framework.Application {
    const io = std.Io.Threaded.global_single_threaded.io();
    return framework.Application.init(std.heap.c_allocator, io) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmAppDestroy(self: *framework.Application) void {
    self.deinit(); // also frees the Application itself (allocator.destroy(self))
}

// ── images / icons (bespoke; see doc/c_api_codegen.md「Image / icon」) ────────
// awt.Image wraps a GPU texture. These are hand-written, not generated: getIcon
// returns the ADDRESS of an optional field (not a method call), setIcon derefs
// an optional handle, the loader boxes a by-value return, and the icon getters
// return a cache pointer after a method call — none expressible in apigen.
//
// Ownership: nmAppLoadImage produces an OWNED boxed Image (free once with
// nmImageDestroy). nmAppIcon / nmAppIconNamed / nmButtonGetIcon return BORROWED
// pointers (into the Application's icon cache / a Button's icon field) — never
// destroy them; they live as long as their owner.

/// Curated built-in icons exposed across the ABI. nimbus owns this enum (stable
/// order, append-only), unlike the ~1700-member lucide.Icon whose ordering is
/// upstream-owned. Mirrors the C `nmIcon` in preamble_protos.h — keep in sync.
const nmIcon = enum(c_int) {
    open,
    save,
    save_as,
    undo,
    redo,
    cut,
    copy,
    paste,
};

/// Map a curated nmIcon to its lucide glyph. Referencing the lucide members
/// directly IS the drift check: an upstream rename / removal makes a switch arm
/// fail to resolve (a compile error), so this can never silently point at the
/// wrong icon. Returns null for an out-of-range integer.
fn nmIconToLucide(id: c_int) ?framework.lucide.Icon {
    const count = @typeInfo(nmIcon).@"enum".fields.len;
    if (id < 0 or id >= count) return null;
    const ic: nmIcon = @enumFromInt(id);
    return switch (ic) {
        .open => .folder_open,
        .save => .save,
        .save_as => .save_all,
        .undo => .undo,
        .redo => .redo,
        .cut => .scissors,
        .copy => .copy,
        .paste => .clipboard_paste,
    };
}

/// Decode image bytes into an OWNED, heap-boxed Image (uses the Application's
/// device + allocator transiently for decode). Failure = NULL + last_error;
/// any texture decoded before a later failure is released (no leak).
export fn nmAppLoadImage(app: *framework.Application, bytes: [*]const u8, len: usize) ?*awt.Image {
    var img = awt.Image.fromMemory(app.allocator, app.device, bytes[0..len]) catch |e| {
        setLastError(e);
        return null;
    };
    const boxed = std.heap.c_allocator.create(awt.Image) catch |e| {
        img.deinit(); // release the GPU texture we just uploaded
        setLastError(e);
        return null;
    };
    boxed.* = img;
    return boxed;
}

/// Free an OWNED Image (from nmAppLoadImage). Deinits the texture + frees the
/// box. Must NOT be called on a borrowed Image (icon getters).
export fn nmImageDestroy(self: *awt.Image) void {
    self.deinit();
    std.heap.c_allocator.destroy(self);
}

export fn nmImageWidth(self: *const awt.Image) i32 {
    return self.width;
}

export fn nmImageHeight(self: *const awt.Image) i32 {
    return self.height;
}

/// Built-in curated icon as a BORROWED Image (pointer into the Application's
/// icon cache; lives as long as the Application). Decodes + caches on first use.
export fn nmAppIcon(self: *framework.Application, id: c_int) ?*awt.Image {
    const lucide_id = nmIconToLucide(id) orelse {
        setLastError(error.IconNotFound);
        return null;
    };
    _ = self.icon(lucide_id) catch |e| {
        setLastError(e);
        return null;
    };
    return &self.icon_cache[@intFromEnum(lucide_id)].?;
}

/// Built-in icon by lucide name (e.g. "circle_plus") — the escape hatch for
/// icons outside the curated nmIcon set. Unknown name = NULL + last_error.
export fn nmAppIconNamed(self: *framework.Application, name: [*:0]const u8) ?*awt.Image {
    // lucide.Icon has ~1700 members; stringToEnum builds a comptime lookup over
    // all of them, which exceeds the default branch quota.
    @setEvalBranchQuota(20000);
    const id = std.meta.stringToEnum(framework.lucide.Icon, std.mem.span(name)) orelse {
        setLastError(error.IconNotFound);
        return null;
    };
    _ = self.icon(id) catch |e| {
        setLastError(e);
        return null;
    };
    return &self.icon_cache[@intFromEnum(id)].?;
}

/// BORROWED pointer into the Button's icon field (NULL = no icon, not an error).
export fn nmButtonGetIcon(self: *framework.Button) ?*awt.Image {
    if (self.icon) |*img| return img;
    return null;
}

/// Set / clear the Button's icon. Copies the Image by value (a borrow — the
/// Button does not own the texture). Pass null to clear.
export fn nmButtonSetIcon(self: *framework.Button, icon: ?*awt.Image) void {
    self.setIcon(if (icon) |p| p.* else null);
}

// ── List cell protocol (bespoke; see doc/c_api_codegen.md「List / CellFactory」) ──
// "An interface that returns an interface": the C nmCellFactory.create returns
// an nmCell of C function pointers. These adapt that to the native
// List.CellFactory / List.Cell (Zig fnptrs). The C factory pointer is borrowed
// (the caller keeps nmCellFactory alive); each produced cell's C fnptrs +
// user_data are boxed (heap nmCell) so the native single `*anyopaque` self can
// reach them, and the box is freed in the cell's destroy trampoline.

const nmCellContext = extern struct {
    list: ?*framework.List,
    value: ?*anyopaque,
    index: usize,
    selected: bool,
    focused: bool,
};

const nmCell = extern struct {
    component: ?*anyopaque, // nmComponent* (*Component); null = create failed
    update: ?*const fn (?*anyopaque, *const nmCellContext) callconv(.c) void,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

const nmCellFactory = extern struct {
    create: ?*const fn (?*anyopaque) callconv(.c) nmCell,
    factory_ud: ?*anyopaque,
};

// native CellFactory.create: invokes the C factory, then boxes the returned
// nmCell so the native Cell trampolines can reach its C fnptrs via `self`.
fn nm_list_factory_create(self: *anyopaque, allocator: std.mem.Allocator) anyerror!framework.List.Cell {
    const cf: *const nmCellFactory = @ptrCast(@alignCast(self));
    const create_fn = cf.create orelse return error.CellCreateFailed;
    const c_cell = create_fn(cf.factory_ud);
    const comp = c_cell.component orelse return error.CellCreateFailed;
    const box = try allocator.create(nmCell);
    box.* = c_cell;
    return .{
        .component = @ptrCast(@alignCast(comp)),
        .update = nm_list_cell_update,
        .destroy = nm_list_cell_destroy,
        .user_data = box,
    };
}

// native Cell.update: translate the native context to the C struct and forward.
fn nm_list_cell_update(self: *anyopaque, ctx: framework.List.CellContext) void {
    const box: *nmCell = @ptrCast(@alignCast(self));
    const c_ctx = nmCellContext{
        .list = ctx.list,
        .value = ctx.value,
        .index = ctx.index,
        .selected = ctx.selected,
        .focused = ctx.focused,
    };
    if (box.update) |u| u(box.user_data, &c_ctx);
}

// native Cell.destroy: let C tear down its subtree + state, then free the box.
fn nm_list_cell_destroy(self: *anyopaque, allocator: std.mem.Allocator) void {
    const box: *nmCell = @ptrCast(@alignCast(self));
    if (box.destroy) |d| d(box.user_data);
    allocator.destroy(box);
}

/// Create a List driven by the given C cell factory. The factory pointer is
/// borrowed (stored in the native CellFactory.user_data) — keep it alive for
/// the List's lifetime.
export fn nmAppList(app: *framework.Application, factory: *const nmCellFactory) ?*framework.List {
    return app.list(.{
        .create = nm_list_factory_create,
        .user_data = @ptrCast(@constCast(factory)),
    }) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmListGetModel(self: *framework.List) *framework.List.ListModel {
    return self.model;
}

export fn nmListGetSelected(self: *framework.List) i64 {
    return if (self.getSelected()) |s| @intCast(s) else -1;
}

export fn nmListSetSelected(self: *framework.List, idx: i64) void {
    self.setSelected(if (idx < 0) null else @intCast(idx));
}

// nmListEdit is generated (List.edit takes a plain usize — see nimbus.api).

export fn nmListModelAdd(self: *framework.List.ListModel, item: *anyopaque) c_int {
    self.add(item) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmListModelRemove(self: *framework.List.ListModel, idx: usize) void {
    self.remove(idx);
}

export fn nmListModelClear(self: *framework.List.ListModel) void {
    self.clear();
}

export fn nmListModelMove(self: *framework.List.ListModel, from: usize, to: usize) void {
    self.move(from, to);
}

export fn nmListModelGetSize(self: *framework.List.ListModel) usize {
    return self.getSize();
}

export fn nmListModelGetElementAt(self: *framework.List.ListModel, idx: usize) ?*anyopaque {
    return self.getElementAt(idx);
}

// ── generated exports (do not edit; regenerate with `zig build apigen`) ──

const nmColor = extern struct { r: f32, g: f32, b: f32, a: f32, };

const nmSize = extern struct { width: f32, height: f32, };

comptime {
    std.debug.assert(@intFromEnum(framework.Component.Alignment.start) == 0);
    std.debug.assert(@intFromEnum(framework.Component.Alignment.center) == 1);
    std.debug.assert(@intFromEnum(framework.Component.Alignment.end) == 2);
    std.debug.assert(@intFromEnum(framework.Component.Alignment.stretch) == 3);
}

const nmChangeListener = extern struct {
    fn_ptr: ?*const fn (?*anyopaque, ?*const anyopaque) callconv(.c) void,
    userdata: ?*anyopaque,
};
fn nm_trampoline_nmChangeListener(box: *nmChangeListener, e: *const framework.ChangeListenerList.Event) void {
    if (box.fn_ptr) |f| f(box.userdata, e);
}

export fn nmAppRun(self: *framework.Application) c_int {
    self.run() catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmAppButton(self: *framework.Application, text: [*:0]const u8) ?*framework.Button {
    return self.button(std.mem.span(text)) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmButtonSetText(self: *framework.Button, text: [*:0]const u8) c_int {
    self.setText(std.mem.span(text)) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmContainerAdd(self: *framework.Container, child: *framework.Component) c_int {
    self.add(child) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmButtonSetColor(self: *framework.Button, c: nmColor) void {
    self.setColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a });
}

export fn nmButtonGetColor(self: *framework.Button) nmColor {
    const _ret = self.getColor();
    return .{ .r = _ret.r, .g = _ret.g, .b = _ret.b, .a = _ret.a };
}

export fn nmButtonGetText(self: *framework.Button) nmStr {
    const _s = self.getText();
    return .{ .ptr = _s.ptr, .len = _s.len };
}

export fn nmComboBoxGetSelected(self: *framework.ComboBox) nmStr {
    const _s = self.getSelectedItem();
    return if (_s) |v| .{ .ptr = v.ptr, .len = v.len } else .{ .ptr = null, .len = 0 };
}

export fn nmButtonSetIconSize(self: *framework.Button, sz: ?*const nmSize) void {
    self.setIconSize(if (sz) |_p| .{ .width = _p.width, .height = _p.height } else null);
}

export fn nmButtonGetIconSize(self: *framework.Button, out: *nmSize) bool {
    const _v = self.getIconSize();
    if (_v) |s| {
        out.* = .{ .width = s.width, .height = s.height };
        return true;
    }
    return false;
}

export fn nmAppFrame(self: *framework.Application, title: [*:0]const u8, w: u32, h: u32) ?*framework.Frame {
    return self.frame(std.mem.span(title), w, h) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmComponentSetGrowX(self: *framework.Component, v: f32) void {
    self.setGrowX(v);
}

export fn nmComponentGetGrowX(self: *framework.Component) f32 {
    return self.getGrowX();
}

export fn nmComponentSetAlignX(self: *framework.Component, a: c_int) void {
    self.setAlignX(@enumFromInt(a));
}

export fn nmComponentGetAlignX(self: *framework.Component) c_int {
    return @intFromEnum(self.getAlignX());
}

export fn nmAppComboBox(self: *framework.Application, items: [*]const [*:0]const u8, items_len: usize) ?*framework.ComboBox {
    const _items = std.heap.c_allocator.alloc([]const u8, items_len) catch |e| { setLastError(e); return null; };
    defer std.heap.c_allocator.free(_items);
    for (_items, 0..) |*_it, _i| _it.* = std.mem.span(items[_i]);
    return self.comboBox(_items) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmComboBoxOnChange(self: *framework.ComboBox, cb: *nmChangeListener) c_int {
    self.addChangeListener(nmChangeListener, nm_trampoline_nmChangeListener, cb) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmComboBoxOffChange(self: *framework.ComboBox, cb: *nmChangeListener) void {
    self.removeChangeListener(nmChangeListener, nm_trampoline_nmChangeListener, cb);
}

export fn nmComboBoxGetSelectedIndex(self: *framework.ComboBox) usize {
    return self.getSelectedIndex();
}

export fn nmComboBoxSetSelectedIndex(self: *framework.ComboBox, idx: usize) void {
    self.setSelectedIndex(idx);
}

export fn nmComboBoxItemCount(self: *framework.ComboBox) usize {
    return self.getItemCount();
}

export fn nmComboBoxGetItem(self: *framework.ComboBox, idx: usize) nmStr {
    const _s = self.getItem(idx);
    return if (_s) |v| .{ .ptr = v.ptr, .len = v.len } else .{ .ptr = null, .len = 0 };
}

export fn nmListGetRowHeight(self: *framework.List) f32 {
    return self.getRowHeight();
}

export fn nmListSetRowHeight(self: *framework.List, h: f32) void {
    self.setRowHeight(h);
}

export fn nmListEdit(self: *framework.List, idx: usize) void {
    self.edit(idx);
}

export fn nmListOnChange(self: *framework.List, cb: *nmChangeListener) c_int {
    self.addChangeListener(nmChangeListener, nm_trampoline_nmChangeListener, cb) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmListOffChange(self: *framework.List, cb: *nmChangeListener) void {
    self.removeChangeListener(nmChangeListener, nm_trampoline_nmChangeListener, cb);
}

export fn nmButtonAsComponent(self: *framework.Button) *framework.Component {
    return &self.component;
}

export fn nmContainerAsComponent(self: *framework.Container) *framework.Component {
    return &self.component;
}

export fn nmListAsComponent(self: *framework.List) *framework.Component {
    return &self.component;
}

export fn nmComponentDestroy(self: *framework.Component) void {
    self.vtable.destroy(self, self.allocator);
}
