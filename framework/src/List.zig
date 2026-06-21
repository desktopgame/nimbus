//! Vertical list with single or multiple selection. See `framework/doc/list.md`.
//!
//! Cells are real Component subtrees, materialized only for the visible range
//! (plus a small buffer) and recycled as the list scrolls  Ethe JavaFX
//! VirtualFlow model. The List owns a `pool` of cells; `reconcile` binds each
//! visible row to a cell and repositions it. Transient interaction state
//! (pressed/hover) lives on the cell instance; persistent per-row state lives
//! in the ListModel item and is projected onto the cell via `Cell.update`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const SelectionModel = @import("SelectionModel.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;
const ActionListenerList = listener.ActionListenerList;
const ActionEvent = listener.ActionEvent;

const List = @This();

const DEFAULT_ROW_HEIGHT: f32 = 28;
/// Extra rows kept materialized above/below the viewport so a scroll step does
/// not flash an unbound cell before the next reconcile.
const BUFFER_ROWS: usize = 2;
/// Two presses on the same row within this window count as a double-click.
const DOUBLE_CLICK_S: f64 = 0.4;

// Colors come from `component.theme`: surface_input (background) and
// selection_bg (selected row). See `framework/doc/theme.md`.

// ── public cell protocol ───────────────────────────────────────────────────

/// Context passed to `Cell.update` to bind a cell to one row. `value` is the
/// ListModel item (cast by the cell); `selected`/`focused` are List-side facts
/// not present in the item, supplied here so the cell can project them.
pub const CellContext = struct {
    list: *List,
    value: *anyopaque,
    index: usize,
    selected: bool,
    focused: bool,
};

/// Optional edit lifecycle for a cell. Present (non-null on `Cell.edit`) only
/// for cells that need a *durational* editing session (text editing). Cells
/// whose write-back is atomic (button / checkbox) leave this null. See
/// `framework/doc/list.md`「編雁E(CellEditor)、E
pub const CellEdit = struct {
    // Enter edit mode: swap the subtree to a scratch input, seed from the item,
    // request focus on the input.
    start: *const fn (self: *anyopaque, ctx: CellContext) void,
    // Commit: write the scratch value back to the item, return to display mode.
    commit: *const fn (self: *anyopaque) void,
    // Cancel: discard the scratch, return to display mode (item unchanged).
    cancel: *const fn (self: *anyopaque) void,
};

/// One real cell instance produced by a `CellFactory`. `component` is the root
/// of the cell subtree (leaf or Container). `update` (JavaFX `updateItem`)
/// rebinds the cell to a row. `destroy` frees both the subtree and the cell's
/// own state struct. `edit` is null for read-only cells. Owned by the List
/// once produced.
pub const Cell = struct {
    component: *Component,
    update: *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy: *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    edit: ?CellEdit = null,
    user_data: *anyopaque,
};

/// Context-menu request (right press on the list). `row` is the hit row  E/// already selected when non-null; null = the press landed below the rows.
/// `x`/`y` are window coordinates, ready to pass to `PopupMenu.show`.
pub const ContextMenuEvent = struct {
    source: *anyopaque,
    row: ?usize,
    x: f32,
    y: f32,
};

const ContextMenuListenerList = listener.ListenerList(ContextMenuEvent);

/// How an edit session begins. See `list.md`「開始トリガとフォーカス喪失、E
pub const EditTrigger = enum {
    double_click,
    enter,
    double_click_or_enter,
    manual,
};

/// What happens to an in-progress edit when the scratch loses focus.
pub const FocusLostPolicy = enum {
    commit,
    cancel,
};

/// Produces fresh cell instances on demand (when the pool must grow). Borrowed
/// by the List; the caller retains ownership of the factory itself.
pub const CellFactory = struct {
    create: *const fn (self: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell,
    user_data: *anyopaque,
};

const PooledCell = struct {
    cell: Cell,
    /// Row this cell is currently bound to; null = free (recyclable / hidden).
    row: ?usize,
};

// ── ListModel ────────────────────────────────────────────────────────────

/// Observable item source. Items are borrowed `*anyopaque`  Ethe backing
/// memory is owned by the caller and must outlive the List / ListModel.
pub const ListModel = struct {
    items: std.ArrayList(*anyopaque),
    change_listeners: ChangeListenerList,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ListModel {
        return .{
            .items = .empty,
            .change_listeners = ChangeListenerList.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ListModel) void {
        self.items.deinit(self.allocator);
        self.change_listeners.deinit();
    }

    pub fn add(self: *ListModel, item: *anyopaque) !void {
        try self.items.append(self.allocator, item);
        self.change_listeners.fire(&.{ .source = self });
    }

    pub fn remove(self: *ListModel, idx: usize) void {
        if (idx >= self.items.items.len) return;
        _ = self.items.orderedRemove(idx);
        self.change_listeners.fire(&.{ .source = self });
    }

    pub fn clear(self: *ListModel) void {
        if (self.items.items.len == 0) return;
        self.items.clearRetainingCapacity();
        self.change_listeners.fire(&.{ .source = self });
    }

    /// Move the item at `from` to insertion position `to` (0..=size, expressed
    /// in the pre-move indexing). Used by drag-to-reorder (`dnd.md`). No-op if
    /// `from` is out of range or the move would not change the order.
    pub fn move(self: *ListModel, from: usize, to: usize) void {
        const n = self.items.items.len;
        if (from >= n) return;
        // Inserting at `from` or just after `from` leaves the order unchanged.
        if (to == from or to == from + 1) return;
        const item = self.items.orderedRemove(from); // capacity retained
        // Translate the insertion index into the post-removal array.
        var dst = to;
        if (dst > from) dst -= 1;
        if (dst > self.items.items.len) dst = self.items.items.len;
        // orderedRemove kept capacity, so inserting one element never allocates.
        self.items.insert(self.allocator, dst, item) catch unreachable;
        self.change_listeners.fire(&.{ .source = self });
    }

    pub fn getSize(self: ListModel) usize {
        return self.items.items.len;
    }

    pub fn getElementAt(self: ListModel, idx: usize) ?*anyopaque {
        if (idx >= self.items.items.len) return null;
        return self.items.items[idx];
    }

    pub fn addChangeListener(self: *ListModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void {
        try self.change_listeners.addTyped(T, f, user_data);
    }

    pub fn removeChangeListener(self: *ListModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void {
        self.change_listeners.removeTyped(T, f, user_data);
    }
};

// ── List fields ────────────────────────────────────────────────────────────

component: Component,
model: *ListModel,
owns_model: bool,
factory: CellFactory,
selection: SelectionModel,
row_height: f32,
pool: std.ArrayList(PooledCell),
has_focus: bool,
/// Cell root the pointer is currently over, for synthesizing `mouseExited`
/// when the pointer moves off it (same role as `Container.last_hovered`).
hovered: ?*Component,
editing: ?usize, // 編雁E��の衁E(高、E1 つ)、E読み取り専用なら常に null
edit_trigger: EditTrigger,
focus_lost: FocusLostPolicy,
last_click_time: f64, // ダブルクリチE��検�E用 (awt.time)
last_click_row: ?usize,
change_listeners: ChangeListenerList,
action_listeners: ActionListenerList,
context_listeners: ContextMenuListenerList,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub const look_vtable = Component.LookVTable{
    .paint = lookPaint,
    .paintOver = lookPaintOver,
    .measureMinSize = lookMeasureMinSize,
};

// ── construction ───────────────────────────────────────────────────────────

pub fn create(allocator: std.mem.Allocator, factory: CellFactory) !*List {
    const model = try allocator.create(ListModel);
    errdefer allocator.destroy(model);
    model.* = ListModel.init(allocator);
    errdefer model.deinit();
    return createInternal(allocator, model, true, factory);
}

pub fn createWithModel(allocator: std.mem.Allocator, model: *ListModel, factory: CellFactory) !*List {
    return createInternal(allocator, model, false, factory);
}

fn createInternal(allocator: std.mem.Allocator, model: *ListModel, owns_model: bool, factory: CellFactory) !*List {
    const list = try allocator.create(List);
    errdefer allocator.destroy(list);

    list.* = .{
        .component = Component.init(allocator, &vtable),
        .model = model,
        .owns_model = owns_model,
        .factory = factory,
        .selection = SelectionModel.init(allocator),
        .row_height = DEFAULT_ROW_HEIGHT,
        .pool = .empty,
        .has_focus = false,
        .hovered = null,
        .editing = null,
        .edit_trigger = .double_click_or_enter,
        .focus_lost = .commit,
        .last_click_time = 0,
        .last_click_row = null,
        .change_listeners = ChangeListenerList.init(allocator),
        .action_listeners = ActionListenerList.init(allocator),
        .context_listeners = ContextMenuListenerList.init(allocator),
        .allocator = allocator,
    };
    list.component.role = .list;
    list.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    errdefer list.change_listeners.deinit();
    errdefer list.action_listeners.deinit();
    errdefer list.context_listeners.deinit();
    errdefer list.pool.deinit(allocator);

    // Fill the viewport width and scroll only vertically (typical list).
    list.component.scrollable = .{ .tracks_viewport_width = true };
    list.syncContentHeight();

    try List.vtable.install(&list.component);
    return list;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn asComponent(self: *List) *Component {
    return &self.component;
}

/// The lead (current) row, or null. For the full multi-selection use
/// `getSelectedIndices`.
pub fn getSelected(self: List) ?usize {
    return self.selection.getLead();
}

/// Select exactly `idx` (clearing any other selection); null clears it.
pub fn setSelected(self: *List, idx: ?usize) void {
    var clamped = idx;
    if (clamped) |i| {
        if (i >= self.model.getSize()) clamped = null;
    }
    const changed = self.selection.selectOnly(clamped) catch return;
    self.applySelectionChange(changed);
}

/// Selected row indices, sorted ascending. Borrowed; valid until the next
/// selection change.
pub fn getSelectedIndices(self: List) []const usize {
    return self.selection.indices();
}

pub fn isSelected(self: List, i: usize) bool {
    return self.selection.isSelected(i);
}

pub fn clearSelection(self: *List) void {
    self.applySelectionChange(self.selection.clear());
}

pub fn setSelectionMode(self: *List, mode: SelectionModel.Mode) void {
    const changed = self.selection.setMode(mode) catch return;
    self.applySelectionChange(changed);
}

pub fn getRowHeight(self: List) f32 {
    return self.row_height;
}

pub fn setRowHeight(self: *List, h: f32) void {
    if (self.row_height == h) return;
    self.row_height = h;
    self.syncContentHeight();
    self.component.repaint();
}

pub fn addChangeListener(self: *List, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}

pub fn removeChangeListener(self: *List, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

/// Row activation: fires when a row is "opened"  Eleft double-click on a row,
/// or Enter on the selected row  Eand the gesture did not start an edit (the
/// edit trigger has priority when the cell is editable). The activated row is
/// `getSelected()` (selection happens before activation). This is how a file
/// list opens an item while keeping single-click = select.
pub fn addActionListener(self: *List, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void {
    try self.action_listeners.addTyped(T, f, user_data);
}

pub fn removeActionListener(self: *List, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void {
    self.action_listeners.removeTyped(T, f, user_data);
}

/// Context menu: fires on a right press over the list, after the hit row (if
/// any) was selected and the list took focus. The app shows its own
/// `PopupMenu` at the event's window coordinates.
pub fn addContextMenuListener(self: *List, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) !void {
    try self.context_listeners.addTyped(T, f, user_data);
}

pub fn removeContextMenuListener(self: *List, comptime T: type, comptime f: fn (*T, *const ContextMenuEvent) void, user_data: *T) void {
    self.context_listeners.removeTyped(T, f, user_data);
}

// ── editing ────────────────────────────────────────────────────────────────

pub fn getEditing(self: List) ?usize {
    return self.editing;
}

pub fn setEditTrigger(self: *List, t: EditTrigger) void {
    self.edit_trigger = t;
}

pub fn setFocusLostPolicy(self: *List, p: FocusLostPolicy) void {
    self.focus_lost = p;
}

/// Begin editing `idx`. Finishes any current edit first (commit). No-op if the
/// row is out of range or its cell is read-only (`edit == null`). Materializes
/// the row (scrolls it into view) so it has a cell to edit.
pub fn edit(self: *List, idx: usize) void {
    if (idx >= self.model.getSize()) return;
    if (self.editing != null) self.commitEdit();

    self.scrollToRow(idx);
    self.reconcile();
    const ci = self.findCellRowIndex(idx) orelse return;
    const cell = self.pool.items[ci].cell;
    const e = cell.edit orelse return; // read-only cell: nothing to edit
    const ctx = self.cellContext(idx) orelse return;

    self.editing = idx;
    e.start(cell.user_data, ctx);
    self.component.repaint();
}

/// Commit the in-progress edit (if any): the cell writes its scratch back to
/// the item, returns to display mode, and the display re-projects the item.
pub fn commitEdit(self: *List) void {
    const idx = self.editing orelse return;
    self.editing = null;
    if (self.findCellRowIndex(idx)) |ci| {
        const cell = self.pool.items[ci].cell;
        if (cell.edit) |e| e.commit(cell.user_data);
        self.bindCell(ci, idx); // re-project the committed item into display
    }
    self.component.requestFocus(); // return focus to the list for arrow keys
    self.component.repaint();
}

/// Cancel the in-progress edit (if any): discard the scratch, return to
/// display mode; the item is unchanged.
pub fn cancelEdit(self: *List) void {
    const idx = self.editing orelse return;
    self.editing = null;
    if (self.findCellRowIndex(idx)) |ci| {
        const cell = self.pool.items[ci].cell;
        if (cell.edit) |e| e.cancel(cell.user_data);
        self.bindCell(ci, idx);
    }
    self.component.requestFocus();
    self.component.repaint();
}

// ── internal helpers ───────────────────────────────────────────────────────

fn eqOpt(a: ?usize, b: ?usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// Report the total content height so an enclosing ScrollPane can size the
/// scroll range. Width is left at 0 (the viewport stretches us via the
/// `tracks_viewport_width` hint).
fn syncContentHeight(self: *List) void {
    const h = @as(f32, @floatFromInt(self.model.getSize())) * self.row_height;
    self.component.setMinSizeDerived(.{ .width = 0, .height = h });
}

fn findCellRowIndex(self: *List, row: usize) ?usize {
    for (self.pool.items, 0..) |pc, i| {
        if (pc.row) |r| {
            if (r == row) return i;
        }
    }
    return null;
}

/// Index of a free pooled cell, growing the pool (via the factory) if none is
/// free. The new cell is attached to the List's parent chain so its subtree
/// hit-tests and paints through the existing machinery.
fn acquireFreeCell(self: *List) !usize {
    for (self.pool.items, 0..) |pc, i| {
        if (pc.row == null) return i;
    }
    const cell = try self.factory.create(self.factory.user_data, self.allocator);
    cell.component.parent = &self.component;
    self.pool.append(self.allocator, .{ .cell = cell, .row = null }) catch |e| {
        cell.destroy(cell.user_data, self.allocator);
        return e;
    };
    return self.pool.items.len - 1;
}

fn cellContext(self: *List, row: usize) ?CellContext {
    const value = self.model.getElementAt(row) orelse return null;
    return .{
        .list = self,
        .value = value,
        .index = row,
        .selected = self.selection.isSelected(row),
        .focused = self.has_focus and eqOpt(self.selection.getLead(), row),
    };
}

fn bindCell(self: *List, idx: usize, row: usize) void {
    const ctx = self.cellContext(row) orelse return;
    const pc = &self.pool.items[idx];
    pc.cell.update(pc.cell.user_data, ctx);
}

/// Re-bind every materialized cell to its current row (selection styling may
/// have changed across an arbitrary range).
fn reprojectVisible(self: *List) void {
    for (self.pool.items, 0..) |pc, i| {
        if (pc.row) |r| self.bindCell(i, r);
    }
}

fn applySelectionChange(self: *List, changed: bool) void {
    if (!changed) return;
    self.reprojectVisible();
    self.change_listeners.fire(&.{ .source = self });
    self.component.repaint();
}

fn layoutCell(self: *List, idx: usize, row: usize, width: f32) void {
    const comp = self.pool.items[idx].cell.component;
    comp.setBounds(.{
        .x = 0,
        .y = @as(f32, @floatFromInt(row)) * self.row_height,
        .width = width,
        .height = self.row_height,
    });
    // A leaf cell needs nothing more, but a Container-rooted cell (the common
    // case  Ea Panel of widgets) must run its layout so children get sized;
    // plain Component.setBounds does not recurse into the layout manager.
    if (comp.container) |c| c.doLayout();
}

/// Compute the visible row window from the current scroll offset and viewport
/// height, then ensure exactly those rows (plus buffer) are bound to cells.
/// Idempotent  Esafe to call before both paint and event dispatch.
fn reconcile(self: *List) void {
    const n = self.model.getSize();
    const rh = self.row_height;
    if (rh <= 0) return;
    const width = self.component.size.width;

    // We are the ScrollPane's view, placed at a negative offset; -position.y is
    // how far we are scrolled. The viewport (our parent) gives the visible height.
    const scroll_top = @max(0, -self.component.position.y);
    const vp_h = if (self.component.parent) |p| p.size.height else self.component.size.height;

    const first_f = @floor(scroll_top / rh);
    var first: usize = if (first_f <= 0) 0 else @intFromFloat(first_f);
    first = if (first > BUFFER_ROWS) first - BUFFER_ROWS else 0;

    const last_f = @ceil((scroll_top + vp_h) / rh);
    var last: usize = if (last_f <= 0) 0 else @intFromFloat(last_f);
    last += BUFFER_ROWS;
    if (last > n) last = n;
    if (first > n) first = n;

    // An edit in progress on a row that has scrolled out of the visible
    // window ends the edit (the constraint: an editing cell is never recycled,
    // so we must finish before its cell could be reused). Commit per default.
    if (self.editing) |e_idx| {
        if (e_idx < first or e_idx >= last) self.commitEdit();
    }

    // 1. Release cells whose row scrolled out of the window  Ebut never the
    // editing row (it stays bound so its scratch survives).
    for (self.pool.items) |*pc| {
        if (pc.row) |r| {
            if ((r < first or r >= last) and !eqOpt(self.editing, r)) pc.row = null;
        }
    }
    // 2. Bind a cell to every visible row not already covered (= recycle).
    var row = first;
    while (row < last) : (row += 1) {
        if (self.findCellRowIndex(row) == null) {
            const idx = self.acquireFreeCell() catch return; // OOM: retry next frame
            self.pool.items[idx].row = row;
            self.bindCell(idx, row);
        }
    }
    // 3. Reposition all bound cells (width / row_height may have changed).
    for (self.pool.items, 0..) |pc, i| {
        if (pc.row) |r| self.layoutCell(i, r, width);
    }
}

fn moveSelection(self: *List, delta: i32, extend: bool) void {
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

/// Mirror of `Container.updateHover` for the manually-managed cell pool: when
/// the hovered cell changes, send the old cell a synthesized `.move` at the
/// (now-outside) pointer position so its subtree re-evaluates and drops hover
/// state (e.g. a button's rollover).
fn updateHover(self: *List, target: ?*Component, x: f32, y: f32) void {
    if (self.hovered == target) return;
    if (self.hovered) |old| {
        var ev = Component.Event{ .payload = .{ .mouse = .{ .x = x, .y = y, .action = .move } } };
        old.vtable.processEvent(old, &ev);
    }
    self.hovered = target;
}

fn scrollToRow(self: *List, row: usize) void {
    const sc = self.component.enclosingScrollController() orelse return;
    sc.scroll_rect_to_visible(sc.user_data, .{
        .x = 0,
        .y = @as(f32, @floatFromInt(row)) * self.row_height,
        .width = self.component.size.width,
        .height = self.row_height,
    });
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    const list: *List = @fieldParentPtr("component", self);
    try list.model.addChangeListener(List, onModelChange, list);
}

fn uninstall(self: *Component) void {
    const list: *List = @fieldParentPtr("component", self);
    // Focus goes to null when its owner is torn down (keybinding.md).
    if (list.has_focus) self.releaseFocus();
    list.model.removeChangeListener(List, onModelChange, list);
}

/// The structure (item count) changed: every row's content may have shifted,
/// so drop all bindings and let the next reconcile rebind from scratch.
fn onModelChange(list: *List, _: *const ChangeEvent) void {
    for (list.pool.items) |*pc| pc.row = null;
    _ = list.selection.clampToSize(list.model.getSize());
    list.syncContentHeight();
    list.component.repaint();
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const list: *List = @fieldParentPtr("component", self);
    list.reconcile();

    g.setColor(self.theme.surface_input);
    g.fillRect(.{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height });

    // Selection background behind the cell content (every selected row).
    g.setColor(self.theme.selection_bg);
    for (list.selection.indices()) |r| {
        g.fillRect(.{
            .x = 0,
            .y = @as(f32, @floatFromInt(r)) * list.row_height,
            .width = self.size.width,
            .height = list.row_height,
        });
    }

    for (list.pool.items) |pc| {
        if (pc.row != null) pc.cell.component.paintAt(g);
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    return self.min_size;
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const list: *List = @fieldParentPtr("component", self);
    list.reconcile();

    switch (ev.payload) {
        .mouse => |m| {
            if (m.action == .scroll) return; // let the enclosing ScrollPane handle the wheel

            // Forward to the visible cell under the pointer (its children do
            // their own hit-test, capture, etc.).
            var hit_row: ?usize = null;
            var hit_cell: ?*Component = null;
            for (list.pool.items) |pc| {
                if (pc.row) |r| {
                    if (pc.cell.component.containsWindowPoint(m.x, m.y)) {
                        pc.cell.component.vtable.processEvent(pc.cell.component, ev);
                        hit_row = r;
                        hit_cell = pc.cell.component;
                        break;
                    }
                }
            }
            // Track hover so the cell the pointer left re-evaluates its rollover.
            if (m.action == .move) list.updateHover(hit_cell, m.x, m.y);

            if (m.action == .press and (m.button orelse .left) == .left) {
                const now = awt.time();
                const dbl = hit_row != null and
                    eqOpt(list.last_click_row, hit_row) and
                    (now - list.last_click_time) < DOUBLE_CLICK_S;
                list.last_click_time = now;
                list.last_click_row = hit_row;

                // Focus-lost: a press off the editing row ends the current edit.
                if (list.editing) |e_idx| {
                    if (!eqOpt(hit_row, e_idx)) switch (list.focus_lost) {
                        .commit => list.commitEdit(),
                        .cancel => list.cancelEdit(),
                    };
                }

                // If the cell didn't consume the press, treat it as row
                // interaction: select + focus, and maybe start editing.
                if (!ev.isConsumed()) {
                    self.requestFocus();
                    if (hit_row) |r| {
                        // Selection gesture: ctrl toggles, shift extends a range,
                        // a plain click selects only the row.
                        const changed = if (m.modifiers.ctrl)
                            list.selection.toggle(r) catch return
                        else if (m.modifiers.shift)
                            list.selection.extendTo(r) catch return
                        else
                            list.selection.selectOnly(r) catch return;
                        list.applySelectionChange(changed);
                        // ctrl / shift are selection-only; only a plain click may
                        // start editing or activate the row.
                        if (!m.modifiers.ctrl and !m.modifiers.shift) {
                            const start = switch (list.edit_trigger) {
                                .double_click, .double_click_or_enter => dbl,
                                .enter, .manual => false,
                            };
                            if (start) list.edit(r);
                            if (dbl and list.editing == null)
                                list.action_listeners.fire(&.{ .source = list });
                        }
                    }
                }
            } else if (m.action == .press and (m.button orelse .left) == .right) {
                // Same focus-lost rule as a left press: a right press off the
                // editing row ends the current edit first.
                if (list.editing) |e_idx| {
                    if (!eqOpt(hit_row, e_idx)) switch (list.focus_lost) {
                        .commit => list.commitEdit(),
                        .cancel => list.cancelEdit(),
                    };
                }
                if (!ev.isConsumed()) {
                    self.requestFocus();
                    // Right-press on an unselected row selects just it; on an
                    // already-selected row it keeps the (possibly multi)
                    // selection so the menu can act on every selected row.
                    if (hit_row) |r| {
                        if (!list.selection.isSelected(r))
                            list.applySelectionChange(list.selection.selectOnly(r) catch return);
                    }
                    list.context_listeners.fire(&.{
                        .source = list,
                        .row = hit_row,
                        .x = m.x,
                        .y = m.y,
                    });
                    ev.consume();
                }
            }
        },
        .key => |k| {
            if (k.action == .press or k.action == .repeat) {
                switch (k.code) {
                    .arrow_down => {
                        list.moveSelection(1, k.modifiers.shift);
                        ev.consume();
                    },
                    .arrow_up => {
                        list.moveSelection(-1, k.modifiers.shift);
                        ev.consume();
                    },
                    .enter => {
                        // Enter on the selected row starts editing (when the
                        // trigger allows it); if no edit began (read-only cell
                        // or a trigger without Enter), it activates the row
                        // instead. While editing, the scratch field owns focus
                        // and handles Enter itself, so List never sees Enter
                        // in that state.
                        if (list.editing == null) {
                            if (list.selection.getLead()) |s| {
                                const want = switch (list.edit_trigger) {
                                    .enter, .double_click_or_enter => true,
                                    .double_click, .manual => false,
                                };
                                if (want) list.edit(s);
                                if (list.editing == null)
                                    list.action_listeners.fire(&.{ .source = list });
                                ev.consume();
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        .focus => |f| {
            list.has_focus = f.gained;
            list.reprojectVisible();
            self.repaint();
        },
        .char, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const list: *List = @fieldParentPtr("component", self);
    self.deinit(); // uninstall (removes model listener) + property cleanup
    for (list.pool.items) |pc| {
        pc.cell.destroy(pc.cell.user_data, allocator);
    }
    list.pool.deinit(allocator);
    list.change_listeners.deinit();
    list.action_listeners.deinit();
    list.context_listeners.deinit();
    list.selection.deinit();
    if (list.owns_model) {
        list.model.deinit();
        allocator.destroy(list.model);
    }
    allocator.destroy(list);
}

// ── tests ──────────────────────────────────────────────────────────────────

test "list: Enter on a read-only cell fires activation, not editing" {
    const a = std.testing.allocator;
    const Panel = @import("Panel.zig");

    // GPU-free factory: a bare Panel as the cell, no projection.
    const F = struct {
        fn createCell(_: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell {
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

    var fac_state: u8 = 0;
    const list = try create(a, .{ .create = F.createCell, .user_data = @ptrCast(&fac_state) });
    defer list.component.vtable.destroy(&list.component, a);

    var item: u32 = 42;
    try list.model.add(@ptrCast(&item));
    list.setSelected(0);

    const Ctx = struct {
        fired: u32 = 0,
        fn onActivate(self: *@This(), _: *const ActionEvent) void {
            self.fired += 1;
        }
    };
    var ctx: Ctx = .{};
    try list.addActionListener(Ctx, Ctx.onActivate, &ctx);

    // Default trigger (.double_click_or_enter) tries to edit first; the cell
    // is read-only (edit == null), so Enter must fall through to activation.
    var ev = Component.Event{ .payload = .{ .key = .{ .code = .enter, .action = .press, .modifiers = .{} } } };
    list.component.vtable.processEvent(&list.component, &ev);

    try std.testing.expectEqual(@as(u32, 1), ctx.fired);
    try std.testing.expect(ev.isConsumed());
    try std.testing.expect(list.getEditing() == null);

    // No selection ↁEEnter neither fires nor consumes.
    list.setSelected(null);
    var ev2 = Component.Event{ .payload = .{ .key = .{ .code = .enter, .action = .press, .modifiers = .{} } } };
    list.component.vtable.processEvent(&list.component, &ev2);
    try std.testing.expectEqual(@as(u32, 1), ctx.fired);
    try std.testing.expect(!ev2.isConsumed());
}
