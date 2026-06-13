//! Multi-column table with a header row. See `framework/doc/table.md`.
//!
//! Rows are virtualized the same way as `List` (visible range + recycle), but
//! the cell pool is held per-column and each column has its own CellFactory.
//! The framework never interprets a row: each column's cell casts the row item
//! and reads its own field. Sorting is not done here — the header click only
//! notifies (SortEvent) and updates the indicator; the app reorders the model.
//! The header is painted by the Table itself, pinned to the top of the
//! viewport (it counteracts the scroll offset), so it stays visible without
//! any ScrollPane column-header support.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const List = @import("List.zig");
const SelectionModel = @import("SelectionModel.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ActionListenerList = listener.ActionListenerList;
const ChangeEvent = listener.ChangeEvent;
const ActionEvent = listener.ActionEvent;

const Table = @This();

const DEFAULT_ROW_HEIGHT: f32 = 24;
const HEADER_HEIGHT: f32 = 26;
const HEADER_PAD: f32 = 6;
/// Half-width of the grab zone around a column boundary (px each side).
const RESIZE_GRIP: f32 = 4;
const BUFFER_ROWS: usize = 2;
const DOUBLE_CLICK_S: f64 = 0.4;

// Colors come from `component.theme`: surface_input (body bg), selection_bg
// (selected row), surface_window (header bg), text (titles), border_soft
// (separators / header underline), accent (sort indicator).

/// Row source. Same type as List's model (rows = borrowed `*anyopaque` +
/// change notification), so one model can back both a List and a Table view.
pub const Model = List.ListModel;

pub const SortDirection = enum { ascending, descending };

// ── public cell protocol (List's, plus the column index) ───────────────────

pub const CellContext = struct {
    table: *Table,
    value: *anyopaque, // the row item; the cell casts it
    row: usize,
    col: usize,
    selected: bool,
    focused: bool,
};

/// Optional edit lifecycle for a cell (single-cell editing — see table.md /
/// narrative). Non-null only on cells of editable columns; null = read-only.
/// Mirrors `List.CellEdit`.
pub const CellEdit = struct {
    // Enter edit mode: swap the subtree to a scratch input, seed from the item,
    // request focus on the input.
    start: *const fn (self: *anyopaque, ctx: CellContext) void,
    // Commit: write the scratch value back to the item, return to display mode.
    commit: *const fn (self: *anyopaque) void,
    // Cancel: discard the scratch, return to display mode (item unchanged).
    cancel: *const fn (self: *anyopaque) void,
};

pub const Cell = struct {
    component: *Component,
    update: *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy: *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    edit: ?CellEdit = null,
    user_data: *anyopaque,
};

/// Which cell is being edited (at most one). See `edit` / `commitEdit`.
pub const EditPos = struct { row: usize, col: usize };

pub const CellFactory = struct {
    create: *const fn (self: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell,
    user_data: *anyopaque,
};

/// Column definition passed to `create`. Copied by value (the `title` is
/// duped); `factory` is borrowed (kept alive by the caller).
pub const Column = struct {
    title: []const u8,
    width: f32 = 120,
    min_width: f32 = 40,
    sortable: bool = true,
    factory: CellFactory,
};

/// Header click on a sortable column, after the indicator was updated.
pub const SortEvent = struct {
    source: *anyopaque,
    column: usize,
    direction: SortDirection,
};

/// Context-menu request (right press over a body row). Same shape as
/// List.ContextMenuEvent; cross-widget unification is framework#8.
pub const ContextMenuEvent = struct {
    source: *anyopaque,
    row: ?usize,
    x: f32,
    y: f32,
};

const SortListenerList = listener.ListenerList(SortEvent);
const ContextMenuListenerList = listener.ListenerList(ContextMenuEvent);

const PooledCell = struct {
    cell: Cell,
    row: ?usize, // bound row, or null = free (recyclable)
};

/// Per-column definition + runtime state. Owns the duped title and the
/// column's own cell pool.
const ColumnState = struct {
    title: []u8,
    width: f32,
    min_width: f32,
    sortable: bool,
    factory: CellFactory,
    pool: std.ArrayList(PooledCell),
};

/// Column-resize gesture in progress. `grab` is the cursor's offset from the
/// column's right edge at press time, so the edge doesn't jump on the first move.
const HeaderDrag = struct {
    col: usize,
    grab: f32,
};

// ── fields ───────────────────────────────────────────────────────────────

component: Component,
model: *Model,
owns_model: bool,
columns: []ColumnState,
header_font: awt.Graphics.TextFont,
selection: SelectionModel,
editing: ?EditPos,
row_height: f32,
sort_column: ?usize,
sort_direction: SortDirection,
has_focus: bool,
hovered: ?*Component,
header_drag: ?HeaderDrag,
last_click_time: f64,
last_click_row: ?usize,
change_listeners: ChangeListenerList,
action_listeners: ActionListenerList,
context_listeners: ContextMenuListenerList,
sort_listeners: SortListenerList,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

// ── construction ───────────────────────────────────────────────────────────

pub fn create(allocator: std.mem.Allocator, columns: []const Column, font: awt.Graphics.TextFont) !*Table {
    const model = try allocator.create(Model);
    errdefer allocator.destroy(model);
    model.* = Model.init(allocator);
    errdefer model.deinit();
    return createInternal(allocator, model, true, columns, font);
}

pub fn createWithModel(allocator: std.mem.Allocator, model: *Model, columns: []const Column, font: awt.Graphics.TextFont) !*Table {
    return createInternal(allocator, model, false, columns, font);
}

fn createInternal(
    allocator: std.mem.Allocator,
    model: *Model,
    owns_model: bool,
    columns_in: []const Column,
    font: awt.Graphics.TextFont,
) !*Table {
    if (columns_in.len == 0) return error.NoColumns;

    const table = try allocator.create(Table);
    errdefer allocator.destroy(table);

    const cols = try allocator.alloc(ColumnState, columns_in.len);
    errdefer allocator.free(cols);
    var built: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < built) : (i += 1) {
            allocator.free(cols[i].title);
            cols[i].pool.deinit(allocator);
        }
    }
    for (columns_in, 0..) |c, i| {
        cols[i] = .{
            .title = try allocator.dupe(u8, c.title),
            .width = c.width,
            .min_width = c.min_width,
            .sortable = c.sortable,
            .factory = c.factory,
            .pool = .empty,
        };
        built = i + 1;
    }

    table.* = .{
        .component = Component.init(allocator, &vtable),
        .model = model,
        .owns_model = owns_model,
        .columns = cols,
        .header_font = font,
        .selection = SelectionModel.init(allocator),
        .editing = null,
        .row_height = DEFAULT_ROW_HEIGHT,
        .sort_column = null,
        .sort_direction = .ascending,
        .has_focus = false,
        .hovered = null,
        .header_drag = null,
        .last_click_time = 0,
        .last_click_row = null,
        .change_listeners = ChangeListenerList.init(allocator),
        .action_listeners = ActionListenerList.init(allocator),
        .context_listeners = ContextMenuListenerList.init(allocator),
        .sort_listeners = SortListenerList.init(allocator),
        .allocator = allocator,
    };
    table.component.role = .table;
    errdefer table.change_listeners.deinit();
    errdefer table.action_listeners.deinit();
    errdefer table.context_listeners.deinit();
    errdefer table.sort_listeners.deinit();

    // No tracks_viewport_width hint: columns define the width, so the enclosing
    // ScrollPane gives a horizontal scrollbar when they exceed the viewport.
    table.syncContentSize();

    try Table.vtable.install(&table.component);
    return table;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn asComponent(self: *Table) *Component {
    return &self.component;
}

pub fn getSelected(self: Table) ?usize {
    return self.selection.getLead();
}

pub fn setSelected(self: *Table, idx: ?usize) void {
    var clamped = idx;
    if (clamped) |i| {
        if (i >= self.model.getSize()) clamped = null;
    }
    const changed = self.selection.selectOnly(clamped) catch return;
    self.applySelectionChange(changed);
}

/// Selected row indices, sorted ascending. Borrowed; valid until the next
/// selection change.
pub fn getSelectedIndices(self: Table) []const usize {
    return self.selection.indices();
}

pub fn isSelected(self: Table, i: usize) bool {
    return self.selection.isSelected(i);
}

pub fn clearSelection(self: *Table) void {
    self.applySelectionChange(self.selection.clear());
}

pub fn setSelectionMode(self: *Table, mode: SelectionModel.Mode) void {
    const changed = self.selection.setMode(mode) catch return;
    self.applySelectionChange(changed);
}

pub fn getRowHeight(self: Table) f32 {
    return self.row_height;
}

pub fn setRowHeight(self: *Table, h: f32) void {
    if (self.row_height == h) return;
    self.row_height = h;
    self.syncContentSize();
    self.component.repaint();
}

pub fn getColumnWidth(self: Table, col: usize) f32 {
    if (col >= self.columns.len) return 0;
    return self.columns[col].width;
}

pub fn setColumnWidth(self: *Table, col: usize, width: f32) void {
    if (col >= self.columns.len) return;
    self.columns[col].width = @max(width, self.columns[col].min_width);
    self.syncContentSize();
    self.component.markLayoutDirty();
    self.component.repaint();
}

pub fn getSortColumn(self: Table) ?usize {
    return self.sort_column;
}

pub fn getSortDirection(self: Table) SortDirection {
    return self.sort_direction;
}

/// Set the sort indicator only (no event fired). For an initial state where
/// the app has already sorted the model.
pub fn setSortIndicator(self: *Table, column: ?usize, direction: SortDirection) void {
    self.sort_column = column;
    self.sort_direction = direction;
    self.component.repaint();
}

// ── editing (single cell; List.CellEdit ported) ─────────────────────────────

pub fn getEditing(self: Table) ?EditPos {
    return self.editing;
}

/// Begin editing the cell at (`row`, `col`). Finishes any current edit first
/// (commit). No-op if out of range or the column's cell is read-only
/// (`Cell.edit == null`). Materializes the row (scrolls it into view).
pub fn edit(self: *Table, row: usize, col: usize) void {
    if (row >= self.model.getSize() or col >= self.columns.len) return;
    if (self.editing != null) self.commitEdit();

    self.scrollToRow(row);
    self.reconcile();
    const colp = &self.columns[col];
    const ci = findCellRowIndex(colp, row) orelse return;
    const cell = colp.pool.items[ci].cell;
    const e = cell.edit orelse return; // read-only column: nothing to edit
    const value = self.model.getElementAt(row) orelse return;

    self.editing = .{ .row = row, .col = col };
    e.start(cell.user_data, self.cellContext(row, col, value));
    self.component.repaint();
}

/// Commit the in-progress edit (if any): the cell writes its scratch back and
/// returns to display mode; the display re-projects the item.
pub fn commitEdit(self: *Table) void {
    const pos = self.editing orelse return;
    self.editing = null;
    const colp = &self.columns[pos.col];
    if (findCellRowIndex(colp, pos.row)) |ci| {
        const cell = colp.pool.items[ci].cell;
        if (cell.edit) |e| e.commit(cell.user_data);
        self.bindCell(colp, ci, pos.row, pos.col);
    }
    self.component.requestFocus(); // back to the table for arrow keys
    self.component.repaint();
}

/// Cancel the in-progress edit (if any): discard the scratch; item unchanged.
pub fn cancelEdit(self: *Table) void {
    const pos = self.editing orelse return;
    self.editing = null;
    const colp = &self.columns[pos.col];
    if (findCellRowIndex(colp, pos.row)) |ci| {
        const cell = colp.pool.items[ci].cell;
        if (cell.edit) |e| e.cancel(cell.user_data);
        self.bindCell(colp, ci, pos.row, pos.col);
    }
    self.component.requestFocus();
    self.component.repaint();
}

pub fn addChangeListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}
pub fn removeChangeListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

pub fn addActionListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void {
    try self.action_listeners.addTyped(T, f, user_data);
}
pub fn removeActionListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void {
    self.action_listeners.removeTyped(T, f, user_data);
}

pub fn addContextMenuListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) !void {
    try self.context_listeners.addTyped(T, f, user_data);
}
pub fn removeContextMenuListener(self: *Table, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) void {
    self.context_listeners.removeTyped(T, f, user_data);
}

pub fn addSortListener(self: *Table, comptime T: type, comptime f: fn (*T, *const SortEvent) void, user_data: *T) !void {
    try self.sort_listeners.addTyped(T, f, user_data);
}
pub fn removeSortListener(self: *Table, comptime T: type, comptime f: fn (*T, *const SortEvent) void, user_data: *T) void {
    self.sort_listeners.removeTyped(T, f, user_data);
}

// ── internal helpers ───────────────────────────────────────────────────────

fn eqOpt(a: ?usize, b: ?usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn totalWidth(self: *const Table) f32 {
    var w: f32 = 0;
    for (self.columns) |c| w += c.width;
    return w;
}

fn columnX(self: *const Table, col: usize) f32 {
    var x: f32 = 0;
    for (self.columns[0..col]) |c| x += c.width;
    return x;
}

/// Column whose body region contains content-x `lx`, or null.
fn columnAt(self: *const Table, lx: f32) ?usize {
    if (lx < 0) return null;
    var x: f32 = 0;
    for (self.columns, 0..) |c, ci| {
        if (lx >= x and lx < x + c.width) return ci;
        x += c.width;
    }
    return null;
}

/// Column whose right boundary is within the grab zone of content-x `lx`.
fn columnAtBoundary(self: *const Table, lx: f32) ?usize {
    var x: f32 = 0;
    for (self.columns, 0..) |c, ci| {
        x += c.width;
        if (@abs(lx - x) <= RESIZE_GRIP) return ci;
    }
    return null;
}

fn syncContentSize(self: *Table) void {
    const h = HEADER_HEIGHT + @as(f32, @floatFromInt(self.model.getSize())) * self.row_height;
    self.component.setMinSize(.{ .width = self.totalWidth(), .height = h });
}

fn findCellRowIndex(col: *ColumnState, row: usize) ?usize {
    for (col.pool.items, 0..) |pc, i| {
        if (pc.row) |r| {
            if (r == row) return i;
        }
    }
    return null;
}

fn acquireFreeCell(self: *Table, col: *ColumnState) !usize {
    for (col.pool.items, 0..) |pc, i| {
        if (pc.row == null) return i;
    }
    const cell = try col.factory.create(col.factory.user_data, self.allocator);
    cell.component.parent = &self.component;
    col.pool.append(self.allocator, .{ .cell = cell, .row = null }) catch |e| {
        cell.destroy(cell.user_data, self.allocator);
        return e;
    };
    return col.pool.items.len - 1;
}

fn cellContext(self: *Table, row: usize, ci: usize, value: *anyopaque) CellContext {
    return .{
        .table = self,
        .value = value,
        .row = row,
        .col = ci,
        .selected = self.selection.isSelected(row),
        .focused = self.has_focus and eqOpt(self.selection.getLead(), row),
    };
}

fn bindCell(self: *Table, col: *ColumnState, idx: usize, row: usize, ci: usize) void {
    const value = self.model.getElementAt(row) orelse return;
    const pc = &col.pool.items[idx];
    pc.cell.update(pc.cell.user_data, self.cellContext(row, ci, value));
}

fn layoutCell(self: *Table, col: *ColumnState, ci: usize, idx: usize, row: usize) void {
    const comp = col.pool.items[idx].cell.component;
    comp.setBounds(.{
        .x = self.columnX(ci),
        .y = HEADER_HEIGHT + @as(f32, @floatFromInt(row)) * self.row_height,
        .width = col.width,
        .height = self.row_height,
    });
    if (comp.container) |c| c.doLayout();
}

/// Re-project the cells of one row (selection state changed). No-op if the row
/// is not currently materialized.
fn reprojectRow(self: *Table, row_opt: ?usize) void {
    const row = row_opt orelse return;
    for (self.columns, 0..) |*col, ci| {
        if (findCellRowIndex(col, row)) |i| self.bindCell(col, i, row, ci);
    }
}

/// Re-bind every materialized cell across all columns (selection styling may
/// have changed across an arbitrary range).
fn reprojectVisible(self: *Table) void {
    for (self.columns, 0..) |*col, ci| {
        for (col.pool.items, 0..) |pc, i| {
            if (pc.row) |r| self.bindCell(col, i, r, ci);
        }
    }
}

fn applySelectionChange(self: *Table, changed: bool) void {
    if (!changed) return;
    self.reprojectVisible();
    self.change_listeners.fire(&.{ .source = self });
    self.component.repaint();
}

fn reconcile(self: *Table) void {
    const n = self.model.getSize();
    const rh = self.row_height;
    if (rh <= 0) return;

    const scroll_top = @max(0, -self.component.position.y);
    const vp_h = if (self.component.parent) |p| p.size.height else self.component.size.height;
    const bot = scroll_top + vp_h;

    // Body starts at content y = HEADER_HEIGHT; row r occupies
    // [HEADER + r*rh, HEADER + (r+1)*rh].
    var first_f = @floor((scroll_top - HEADER_HEIGHT) / rh);
    if (first_f < 0) first_f = 0;
    var first: usize = @intFromFloat(first_f);
    first = if (first > BUFFER_ROWS) first - BUFFER_ROWS else 0;

    var last_f = @ceil((bot - HEADER_HEIGHT) / rh);
    if (last_f < 0) last_f = 0;
    var last: usize = @intFromFloat(last_f);
    last += BUFFER_ROWS;
    if (last > n) last = n;
    if (first > n) first = n;

    // An edit on a row that scrolled out of the window ends (commit): the
    // editing cell is never recycled, so it must finish before its cell could
    // be reused (mirrors List).
    if (self.editing) |e| {
        if (e.row < first or e.row >= last) self.commitEdit();
    }

    for (self.columns, 0..) |*col, ci| {
        // 1. Release cells that scrolled out of the window — but never the
        // editing cell (it stays bound so its scratch survives).
        for (col.pool.items) |*pc| {
            if (pc.row) |r| {
                const is_editing = if (self.editing) |e| (e.row == r and e.col == ci) else false;
                if ((r < first or r >= last) and !is_editing) pc.row = null;
            }
        }
        // 2. Bind a cell to every visible row not already covered.
        var row = first;
        while (row < last) : (row += 1) {
            if (findCellRowIndex(col, row) == null) {
                const idx = self.acquireFreeCell(col) catch return; // OOM: retry next frame
                col.pool.items[idx].row = row;
                self.bindCell(col, idx, row, ci);
            }
        }
        // 3. Reposition all bound cells (width / row_height may have changed).
        for (col.pool.items, 0..) |pc, i| {
            if (pc.row) |r| self.layoutCell(col, ci, i, r);
        }
    }
}

fn moveSelection(self: *Table, delta: i32, extend: bool) void {
    const n = self.model.getSize();
    if (n == 0) return;
    const cur: i32 = if (self.selection.getLead()) |s| @intCast(s) else -1;
    var next = cur + delta;
    if (next < 0) next = 0;
    if (next >= @as(i32, @intCast(n))) next = @as(i32, @intCast(n)) - 1;
    const row: usize = @intCast(next);
    const changed = if (extend)
        self.selection.extendTo(row) catch return
    else
        self.selection.selectOnly(row) catch return;
    self.applySelectionChange(changed);
    self.scrollToRow(row);
}

fn scrollToRow(self: *Table, row: usize) void {
    const sc = self.component.enclosingScrollController() orelse return;
    const y = HEADER_HEIGHT + @as(f32, @floatFromInt(row)) * self.row_height;
    // Expand the rect upward by the header height so scrolling a row up never
    // tucks it under the pinned header; the downward case is unchanged (the
    // extra top and extra height cancel in ScrollPane's bottom calculation).
    sc.scroll_rect_to_visible(sc.user_data, .{
        .x = 0,
        .y = y - HEADER_HEIGHT,
        .width = self.component.size.width,
        .height = self.row_height + HEADER_HEIGHT,
    });
}

fn updateHover(self: *Table, target: ?*Component, x: f32, y: f32) void {
    if (self.hovered == target) return;
    if (self.hovered) |old| {
        var ev = Component.Event{ .payload = .{ .mouse = .{ .x = x, .y = y, .action = .move } } };
        old.vtable.processEvent(old, &ev);
    }
    self.hovered = target;
}

fn toggleSort(self: *Table, ci: usize) void {
    if (self.sort_column != null and self.sort_column.? == ci) {
        self.sort_direction = if (self.sort_direction == .ascending) .descending else .ascending;
    } else {
        self.sort_column = ci;
        self.sort_direction = .ascending;
    }
    self.component.repaint();
    self.sort_listeners.fire(&.{ .source = self, .column = ci, .direction = self.sort_direction });
}

fn updateResize(self: *Table, hd: HeaderDrag, lx: f32) void {
    const col = &self.columns[hd.col];
    const new_right = lx - hd.grab;
    col.width = @max(new_right - self.columnX(hd.col), col.min_width);
    self.syncContentSize();
    self.component.markLayoutDirty();
    self.component.repaint();
}

fn handleHeaderPress(self: *Table, ev: *Component.Event, lx: f32) void {
    if (self.editing != null) self.commitEdit(); // clicking the header ends an edit
    if (self.columnAtBoundary(lx)) |ci| {
        const right = self.columnX(ci) + self.columns[ci].width;
        self.header_drag = .{ .col = ci, .grab = lx - right };
        ev.requestCapture(@ptrCast(&self.component));
        ev.consume();
        return;
    }
    if (self.columnAt(lx)) |ci| {
        if (self.columns[ci].sortable) {
            self.toggleSort(ci);
            ev.consume();
        }
    }
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    const table: *Table = @fieldParentPtr("component", self);
    try table.model.addChangeListener(Table, onModelChange, table);
}

fn uninstall(self: *Component) void {
    const table: *Table = @fieldParentPtr("component", self);
    if (table.has_focus) self.releaseFocus();
    table.model.removeChangeListener(Table, onModelChange, table);
}

fn onModelChange(table: *Table, _: *const ChangeEvent) void {
    for (table.columns) |*col| {
        for (col.pool.items) |*pc| pc.row = null;
    }
    _ = table.selection.clampToSize(table.model.getSize());
    table.syncContentSize();
    table.component.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const table: *Table = @fieldParentPtr("component", self);
    table.reconcile();
    const sz = self.size;

    g.setColor(self.theme.surface_input);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    g.setColor(self.theme.selection_bg);
    for (table.selection.indices()) |r| {
        g.fillRect(.{
            .x = 0,
            .y = HEADER_HEIGHT + @as(f32, @floatFromInt(r)) * table.row_height,
            .width = sz.width,
            .height = table.row_height,
        });
    }

    for (table.columns) |*col| {
        for (col.pool.items) |pc| {
            if (pc.row != null) pc.cell.component.paintAt(g);
        }
    }

    // Pinned header, drawn last (on top of any cell scrolled into its band).
    const scroll_top = @max(0, -self.position.y);
    table.paintHeader(g, scroll_top, sz.width);
}

fn paintHeader(self: *Table, g: *awt.Graphics, top: f32, width: f32) void {
    const t = self.component.theme;
    g.setColor(t.surface_window);
    g.fillRect(.{ .x = 0, .y = top, .width = width, .height = HEADER_HEIGHT });

    g.setFont(self.header_font);
    var x: f32 = 0;
    for (self.columns, 0..) |col, ci| {
        const m = self.header_font.measureString(col.title);
        const ty = top + (HEADER_HEIGHT - m.height) / 2;
        g.setColor(t.text);
        g.drawString(col.title, x + HEADER_PAD, ty);

        if (self.sort_column) |sc| {
            if (sc == ci) self.paintSortIndicator(g, x + col.width, top, self.sort_direction == .ascending);
        }

        g.setColor(t.border_soft);
        g.fillRect(.{ .x = x + col.width - 1, .y = top, .width = 1, .height = HEADER_HEIGHT });
        x += col.width;
    }

    g.setColor(t.border_soft);
    g.fillRect(.{ .x = 0, .y = top + HEADER_HEIGHT - 1, .width = width, .height = 1 });
}

/// Small caret near a column's right edge: stacked bars (no triangle
/// primitive). Ascending points up (narrow at top), descending points down.
fn paintSortIndicator(self: *Table, g: *awt.Graphics, col_right: f32, top: f32, ascending: bool) void {
    g.setColor(self.component.theme.accent);
    const cx = col_right - HEADER_PAD - 4;
    const cy = top + HEADER_HEIGHT / 2;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const step: f32 = @floatFromInt(i);
        const hw = if (ascending) (step + 1) else (4 - step);
        g.fillRect(.{ .x = cx - hw, .y = cy - 4 + step * 2, .width = hw * 2, .height = 2 });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const table: *Table = @fieldParentPtr("component", self);
    table.reconcile();

    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const scroll_top = @max(0, -self.position.y);

            // Active column-resize drag (captured) takes precedence.
            if (table.header_drag) |hd| {
                switch (m.action) {
                    .move => {
                        table.updateResize(hd, lx);
                        ev.consume();
                        return;
                    },
                    .release => {
                        table.header_drag = null;
                        ev.consume();
                        return;
                    },
                    else => {},
                }
            }

            if (m.action == .scroll) return; // let the enclosing ScrollPane wheel

            // Header band (pinned to the viewport top in content coords).
            if (ly >= scroll_top and ly < scroll_top + HEADER_HEIGHT) {
                if (m.action == .press and (m.button orelse .left) == .left) {
                    table.handleHeaderPress(ev, lx);
                }
                return;
            }

            // Body: forward to the visible cell under the pointer first.
            var hit_row: ?usize = null;
            var hit_cell: ?*Component = null;
            outer: for (table.columns) |*col| {
                for (col.pool.items) |pc| {
                    if (pc.row) |r| {
                        if (pc.cell.component.containsWindowPoint(m.x, m.y)) {
                            pc.cell.component.vtable.processEvent(pc.cell.component, ev);
                            hit_row = r;
                            hit_cell = pc.cell.component;
                            break :outer;
                        }
                    }
                }
            }
            if (m.action == .move) table.updateHover(hit_cell, m.x, m.y);

            // A press off the editing row ends the current edit (focus-lost =
            // commit). A press inside the editing cell was already forwarded to
            // the scratch above (same row → no commit).
            if (m.action == .press) {
                if (table.editing) |e| {
                    if (hit_row == null or hit_row.? != e.row) table.commitEdit();
                }
            }

            if (m.action == .press and (m.button orelse .left) == .left) {
                const now = awt.time();
                const dbl = hit_row != null and
                    eqOpt(table.last_click_row, hit_row) and
                    (now - table.last_click_time) < DOUBLE_CLICK_S;
                table.last_click_time = now;
                table.last_click_row = hit_row;
                if (!ev.isConsumed()) {
                    self.requestFocus();
                    if (hit_row) |r| {
                        const changed = if (m.modifiers.ctrl)
                            table.selection.toggle(r) catch return
                        else if (m.modifiers.shift)
                            table.selection.extendTo(r) catch return
                        else
                            table.selection.selectOnly(r) catch return;
                        table.applySelectionChange(changed);
                        if (dbl and !m.modifiers.ctrl and !m.modifiers.shift)
                            table.action_listeners.fire(&.{ .source = table });
                    }
                }
            } else if (m.action == .press and (m.button orelse .left) == .right) {
                if (!ev.isConsumed()) {
                    self.requestFocus();
                    // Keep a multi-selection if right-pressing an already-selected row.
                    if (hit_row) |r| {
                        if (!table.selection.isSelected(r))
                            table.applySelectionChange(table.selection.selectOnly(r) catch return);
                    }
                    table.context_listeners.fire(&.{ .source = table, .row = hit_row, .x = m.x, .y = m.y });
                    ev.consume();
                }
            }
        },
        .key => |k| {
            if (k.action == .press or k.action == .repeat) {
                switch (k.code) {
                    .arrow_down => {
                        table.moveSelection(1, k.modifiers.shift);
                        ev.consume();
                    },
                    .arrow_up => {
                        table.moveSelection(-1, k.modifiers.shift);
                        ev.consume();
                    },
                    .enter => {
                        // While editing, the scratch field owns focus and
                        // handles Enter itself, so the table never sees it here.
                        if (table.editing == null) {
                            if (table.selection.getLead()) |_| {
                                table.action_listeners.fire(&.{ .source = table });
                                ev.consume();
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        .focus => |f| {
            table.has_focus = f.gained;
            table.reprojectVisible();
            self.repaint();
        },
        .char, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const table: *Table = @fieldParentPtr("component", self);
    self.deinit(); // uninstall (removes model listener) + property cleanup
    for (table.columns) |*col| {
        for (col.pool.items) |pc| pc.cell.destroy(pc.cell.user_data, allocator);
        col.pool.deinit(allocator);
        allocator.free(col.title);
    }
    allocator.free(table.columns);
    table.change_listeners.deinit();
    table.action_listeners.deinit();
    table.context_listeners.deinit();
    table.sort_listeners.deinit();
    table.selection.deinit();
    if (table.owns_model) {
        table.model.deinit();
        allocator.destroy(table.model);
    }
    allocator.destroy(table);
}

// ── tests ──────────────────────────────────────────────────────────────────

const Panel = @import("Panel.zig");

// GPU-free cell factory (a bare Panel; no projection, no font). Lets the
// virtualization / layout / event paths run without a device. Tests never
// paint, so the undefined header font is never dereferenced.
const TestFactory = struct {
    fn create(_: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell {
        const p = try Panel.create(allocator);
        return .{
            .component = &p.container.component,
            .update = updateCell,
            .destroy = destroyCell,
            .user_data = @ptrCast(p),
        };
    }
    fn updateCell(_: *anyopaque, _: CellContext) void {}
    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const p: *Panel = @ptrCast(@alignCast(ud));
        p.container.component.vtable.destroy(&p.container.component, allocator);
    }
};

fn testTable(a: std.mem.Allocator) !*Table {
    var dummy: u8 = 0;
    const f = CellFactory{ .create = TestFactory.create, .user_data = @ptrCast(&dummy) };
    return create(a, &.{
        .{ .title = "A", .width = 100, .factory = f },
        .{ .title = "B", .width = 60, .min_width = 30, .factory = f },
    }, .{ .face = undefined, .pixel_size = 14 });
}

fn layoutAt(t: *Table, w: f32, h: f32) void {
    t.component.setBounds(.{ .x = 0, .y = 0, .width = w, .height = h });
    t.reconcile();
}

test "table: content size = header + rows tall, all columns wide" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);

    var items: [3]u32 = .{ 1, 2, 3 };
    for (&items) |*it| try t.model.add(@ptrCast(it));

    const min = t.component.effectiveMinSize();
    try std.testing.expectApproxEqAbs(@as(f32, 160), min.width, 0.001); // 100 + 60
    try std.testing.expectApproxEqAbs(@as(f32, 26 + 3 * 24), min.height, 0.001);
}

test "table: cells lay out per column at row offsets" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);

    var items: [2]u32 = .{ 1, 2 };
    for (&items) |*it| try t.model.add(@ptrCast(it));
    layoutAt(t, 200, 200);

    // Column 0 cell of row 0: x=0, y=HEADER, w=100, h=24.
    const c0 = t.columns[0].pool.items[0].cell.component;
    try std.testing.expectApproxEqAbs(@as(f32, 0), c0.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 26), c0.position.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), c0.size.width, 0.001);
    // Column 1 starts at x=100.
    const c1 = t.columns[1].pool.items[0].cell.component;
    try std.testing.expectApproxEqAbs(@as(f32, 100), c1.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), c1.size.width, 0.001);
}

test "table: setColumnWidth clamps to min_width and shifts later columns" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);

    t.setColumnWidth(0, 140);
    try std.testing.expectApproxEqAbs(@as(f32, 140), t.getColumnWidth(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 140), t.columnX(1), 0.001);

    t.setColumnWidth(1, 5); // below min_width 30
    try std.testing.expectApproxEqAbs(@as(f32, 30), t.getColumnWidth(1), 0.001);
}

test "table: header click fires sort and toggles direction" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);

    const Ctx = struct {
        col: ?usize = null,
        dir: SortDirection = .ascending,
        fires: u32 = 0,
        fn onSort(self: *@This(), e: *const SortEvent) void {
            self.col = e.column;
            self.dir = e.direction;
            self.fires += 1;
        }
    };
    var ctx: Ctx = .{};
    try t.addSortListener(Ctx, Ctx.onSort, &ctx);

    layoutAt(t, 200, 200);

    // Click column 0's title (x within [0,100), y in header band [0,26)).
    var e1 = Component.Event{ .payload = .{ .mouse = .{ .x = 30, .y = 10, .action = .press, .button = .left } } };
    t.component.vtable.processEvent(&t.component, &e1);
    try std.testing.expectEqual(@as(u32, 1), ctx.fires);
    try std.testing.expectEqual(@as(?usize, 0), ctx.col);
    try std.testing.expectEqual(SortDirection.ascending, ctx.dir);
    try std.testing.expectEqual(@as(?usize, 0), t.getSortColumn());

    // Click again → descending.
    var e2 = Component.Event{ .payload = .{ .mouse = .{ .x = 30, .y = 10, .action = .press, .button = .left } } };
    t.component.vtable.processEvent(&t.component, &e2);
    try std.testing.expectEqual(SortDirection.descending, ctx.dir);
}

test "table: dragging a column boundary resizes the column" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);
    layoutAt(t, 200, 200);

    // Press on column 0's right boundary (x=100, header band).
    var press = Component.Event{ .payload = .{ .mouse = .{ .x = 100, .y = 10, .action = .press, .button = .left } } };
    t.component.vtable.processEvent(&t.component, &press);
    try std.testing.expect(press.isConsumed());
    try std.testing.expect(press.capture_target != null);

    // Drag right to x=150 → column 0 widens to ~150.
    var move = Component.Event{ .payload = .{ .mouse = .{ .x = 150, .y = 10, .action = .move } } };
    t.component.vtable.processEvent(&t.component, &move);
    try std.testing.expectApproxEqAbs(@as(f32, 150), t.getColumnWidth(0), 0.001);

    var rel = Component.Event{ .payload = .{ .mouse = .{ .x = 150, .y = 10, .action = .release, .button = .left } } };
    t.component.vtable.processEvent(&t.component, &rel);
    try std.testing.expect(t.header_drag == null);
}

test "table: body click selects row; Enter activates" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);

    var items: [3]u32 = .{ 1, 2, 3 };
    for (&items) |*it| try t.model.add(@ptrCast(it));
    layoutAt(t, 200, 200);

    // Click row 1: content y in [HEADER+1*24, HEADER+2*24) = [50, 74).
    var click = Component.Event{ .payload = .{ .mouse = .{ .x = 20, .y = 62, .action = .press, .button = .left } } };
    t.component.vtable.processEvent(&t.component, &click);
    try std.testing.expectEqual(@as(?usize, 1), t.getSelected());

    const Ctx = struct {
        fired: u32 = 0,
        fn onAct(self: *@This(), _: *const ActionEvent) void {
            self.fired += 1;
        }
    };
    var ctx: Ctx = .{};
    try t.addActionListener(Ctx, Ctx.onAct, &ctx);

    var enter = Component.Event{ .payload = .{ .key = .{ .code = .enter, .action = .press, .modifiers = .{} } } };
    t.component.vtable.processEvent(&t.component, &enter);
    try std.testing.expectEqual(@as(u32, 1), ctx.fired);
}

// Editable stub cell: records which lifecycle calls fired (no real widgets).
const EditState = struct {
    var started: u32 = 0;
    var committed: u32 = 0;
    var canceled: u32 = 0;
    fn reset() void {
        started = 0;
        committed = 0;
        canceled = 0;
    }
};

const EditFactory = struct {
    fn create(_: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell {
        const p = try Panel.create(allocator);
        return .{
            .component = &p.container.component,
            .update = upd,
            .destroy = des,
            .edit = .{ .start = start, .commit = commit, .cancel = cancel },
            .user_data = @ptrCast(p),
        };
    }
    fn upd(_: *anyopaque, _: CellContext) void {}
    fn start(_: *anyopaque, _: CellContext) void {
        EditState.started += 1;
    }
    fn commit(_: *anyopaque) void {
        EditState.committed += 1;
    }
    fn cancel(_: *anyopaque) void {
        EditState.canceled += 1;
    }
    fn des(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const p: *Panel = @ptrCast(@alignCast(ud));
        p.container.component.vtable.destroy(&p.container.component, allocator);
    }
};

test "table: edit() starts on an editable cell; commit / cancel end it" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const ro = CellFactory{ .create = TestFactory.create, .user_data = @ptrCast(&dummy) };
    const rw = CellFactory{ .create = EditFactory.create, .user_data = @ptrCast(&dummy) };
    const t = try create(a, &.{
        .{ .title = "A", .width = 100, .factory = rw }, // editable
        .{ .title = "B", .width = 60, .factory = ro }, // read-only
    }, .{ .face = undefined, .pixel_size = 14 });
    defer t.component.vtable.destroy(&t.component, a);

    var items: [3]u32 = .{ 1, 2, 3 };
    for (&items) |*it| try t.model.add(@ptrCast(it));
    layoutAt(t, 200, 200);
    EditState.reset();

    // Editing a read-only column is a no-op.
    t.edit(1, 1);
    try std.testing.expect(t.getEditing() == null);
    try std.testing.expectEqual(@as(u32, 0), EditState.started);

    // Editing the editable column starts a session.
    t.edit(1, 0);
    try std.testing.expectEqual(@as(u32, 1), EditState.started);
    try std.testing.expectEqual(@as(?EditPos, .{ .row = 1, .col = 0 }), t.getEditing());

    // Commit ends it.
    t.commitEdit();
    try std.testing.expect(t.getEditing() == null);
    try std.testing.expectEqual(@as(u32, 1), EditState.committed);

    // Cancel path.
    t.edit(2, 0);
    t.cancelEdit();
    try std.testing.expect(t.getEditing() == null);
    try std.testing.expectEqual(@as(u32, 1), EditState.canceled);
}

test "table: pressing another row commits the active edit" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const rw = CellFactory{ .create = EditFactory.create, .user_data = @ptrCast(&dummy) };
    const t = try create(a, &.{
        .{ .title = "A", .width = 100, .factory = rw },
    }, .{ .face = undefined, .pixel_size = 14 });
    defer t.component.vtable.destroy(&t.component, a);

    var items: [3]u32 = .{ 1, 2, 3 };
    for (&items) |*it| try t.model.add(@ptrCast(it));
    layoutAt(t, 200, 200);
    EditState.reset();

    t.edit(0, 0);
    try std.testing.expectEqual(@as(u32, 1), EditState.started);

    // Left press on row 2 (content y in [HEADER+2*24, +3*24) = [74,98)).
    var click = Component.Event{ .payload = .{ .mouse = .{ .x = 20, .y = 84, .action = .press, .button = .left } } };
    t.component.vtable.processEvent(&t.component, &click);
    try std.testing.expectEqual(@as(u32, 1), EditState.committed); // edit committed by the off-row press
    try std.testing.expect(t.getEditing() == null);
}

test "table: right press selects the row and fires context menu" {
    const a = std.testing.allocator;
    const t = try testTable(a);
    defer t.component.vtable.destroy(&t.component, a);

    var items: [3]u32 = .{ 1, 2, 3 };
    for (&items) |*it| try t.model.add(@ptrCast(it));
    layoutAt(t, 200, 200);

    const Ctx = struct {
        row: ?usize = null,
        fired: u32 = 0,
        fn onCtx(self: *@This(), e: *const ContextMenuEvent) void {
            self.row = e.row;
            self.fired += 1;
        }
    };
    var ctx: Ctx = .{};
    try t.addContextMenuListener(Ctx, Ctx.onCtx, &ctx);

    var rc = Component.Event{ .payload = .{ .mouse = .{ .x = 20, .y = 62, .action = .press, .button = .right } } };
    t.component.vtable.processEvent(&t.component, &rc);
    try std.testing.expectEqual(@as(u32, 1), ctx.fired);
    try std.testing.expectEqual(@as(?usize, 1), ctx.row); // y=62 → row (62-26)/24 = 1
    try std.testing.expectEqual(@as(?usize, 1), t.getSelected());
}
