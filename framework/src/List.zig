//! Vertical single-selection list. See `framework/doc/list.md`.
//!
//! Cells are real Component subtrees, materialized only for the visible range
//! (plus a small buffer) and recycled as the list scrolls — the JavaFX
//! VirtualFlow model. The List owns a `pool` of cells; `reconcile` binds each
//! visible row to a cell and repositions it. Transient interaction state
//! (pressed/hover) lives on the cell instance; persistent per-row state lives
//! in the ListModel item and is projected onto the cell via `Cell.update`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const ChangeListenerList = @import("ChangeListenerList.zig");

const List = @This();

const DEFAULT_ROW_HEIGHT: f32 = 28;
/// Extra rows kept materialized above/below the viewport so a scroll step does
/// not flash an unbound cell before the next reconcile.
const BUFFER_ROWS: usize = 2;
/// Two presses on the same row within this window count as a double-click.
const DOUBLE_CLICK_S: f64 = 0.4;

const LIST_BG = awt.Graphics.Color.rgb(1.0, 1.0, 1.0);
const SEL_BG  = awt.Graphics.Color.rgb(0.80, 0.87, 0.98);

// ── public cell protocol ───────────────────────────────────────────────────

/// Context passed to `Cell.update` to bind a cell to one row. `value` is the
/// ListModel item (cast by the cell); `selected`/`focused` are List-side facts
/// not present in the item, supplied here so the cell can project them.
pub const CellContext = struct {
    list:     *List,
    value:    *anyopaque,
    index:    usize,
    selected: bool,
    focused:  bool,
};

/// Optional edit lifecycle for a cell. Present (non-null on `Cell.edit`) only
/// for cells that need a *durational* editing session (text editing). Cells
/// whose write-back is atomic (button / checkbox) leave this null. See
/// `framework/doc/list.md`「編集 (CellEditor)」.
pub const CellEdit = struct {
    // Enter edit mode: swap the subtree to a scratch input, seed from the item,
    // request focus on the input.
    start:  *const fn (self: *anyopaque, ctx: CellContext) void,
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
    update:    *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy:   *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    edit:      ?CellEdit = null,
    user_data: *anyopaque,
};

/// How an edit session begins. See `list.md`「開始トリガとフォーカス喪失」.
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
    create:    *const fn (self: *anyopaque, allocator: std.mem.Allocator) anyerror!Cell,
    user_data: *anyopaque,
};

const PooledCell = struct {
    cell: Cell,
    /// Row this cell is currently bound to; null = free (recyclable / hidden).
    row:  ?usize,
};

// ── ListModel ────────────────────────────────────────────────────────────

/// Observable item source. Items are borrowed `*anyopaque` — the backing
/// memory is owned by the caller and must outlive the List / ListModel.
pub const ListModel = struct {
    items:            std.ArrayList(*anyopaque),
    change_listeners: ChangeListenerList,
    allocator:        std.mem.Allocator,

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
        self.change_listeners.fire();
    }

    pub fn remove(self: *ListModel, idx: usize) void {
        if (idx >= self.items.items.len) return;
        _ = self.items.orderedRemove(idx);
        self.change_listeners.fire();
    }

    pub fn clear(self: *ListModel) void {
        if (self.items.items.len == 0) return;
        self.items.clearRetainingCapacity();
        self.change_listeners.fire();
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
        self.change_listeners.fire();
    }

    pub fn getSize(self: ListModel) usize {
        return self.items.items.len;
    }

    pub fn getElementAt(self: ListModel, idx: usize) ?*anyopaque {
        if (idx >= self.items.items.len) return null;
        return self.items.items[idx];
    }

    pub fn addChangeListener(self: *ListModel, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void {
        try self.change_listeners.add(fn_ptr, user_data);
    }

    pub fn removeChangeListener(self: *ListModel, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void {
        self.change_listeners.remove(fn_ptr, user_data);
    }
};

// ── List fields ────────────────────────────────────────────────────────────

component:        Component,
model:            *ListModel,
owns_model:       bool,
factory:          CellFactory,
selected:         ?usize,
row_height:       f32,
pool:             std.ArrayList(PooledCell),
has_focus:        bool,
/// Cell root the pointer is currently over, for synthesizing `mouseExited`
/// when the pointer moves off it (same role as `Container.last_hovered`).
hovered:          ?*Component,
editing:          ?usize,            // 編集中の行 (高々 1 つ)。 読み取り専用なら常に null
edit_trigger:     EditTrigger,
focus_lost:       FocusLostPolicy,
last_click_time:  f64,               // ダブルクリック検出用 (awt.time)
last_click_row:   ?usize,
change_listeners: ChangeListenerList,
allocator:        std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
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
        .selected = null,
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
        .allocator = allocator,
    };
    errdefer list.change_listeners.deinit();
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

pub fn getSelected(self: List) ?usize {
    return self.selected;
}

pub fn setSelected(self: *List, idx: ?usize) void {
    var clamped = idx;
    if (clamped) |i| {
        if (i >= self.model.getSize()) clamped = null;
    }
    if (eqOpt(self.selected, clamped)) return;
    const old = self.selected;
    self.selected = clamped;
    // Re-project selection onto the two affected visible cells.
    if (old) |r| if (self.findCellRowIndex(r)) |i| self.bindCell(i, r);
    if (clamped) |r| if (self.findCellRowIndex(r)) |i| self.bindCell(i, r);
    self.change_listeners.fire();
    self.component.repaint();
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

pub fn addChangeListener(self: *List, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void {
    try self.change_listeners.add(fn_ptr, user_data);
}

pub fn removeChangeListener(self: *List, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void {
    self.change_listeners.remove(fn_ptr, user_data);
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
    const e = cell.edit orelse return;   // read-only cell: nothing to edit
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
    self.component.setMinSize(.{ .width = 0, .height = h });
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
        .selected = eqOpt(self.selected, row),
        .focused = self.has_focus and eqOpt(self.selected, row),
    };
}

fn bindCell(self: *List, idx: usize, row: usize) void {
    const ctx = self.cellContext(row) orelse return;
    const pc = &self.pool.items[idx];
    pc.cell.update(pc.cell.user_data, ctx);
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
    // case — a Panel of widgets) must run its layout so children get sized;
    // plain Component.setBounds does not recurse into the layout manager.
    if (comp.container) |c| c.doLayout();
}

/// Compute the visible row window from the current scroll offset and viewport
/// height, then ensure exactly those rows (plus buffer) are bound to cells.
/// Idempotent — safe to call before both paint and event dispatch.
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

    // 1. Release cells whose row scrolled out of the window — but never the
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

fn moveSelection(self: *List, delta: i32) void {
    const n = self.model.getSize();
    if (n == 0) return;
    const cur: i32 = if (self.selected) |s| @intCast(s) else -1;
    var next = cur + delta;
    if (next < 0) next = 0;
    if (next >= @as(i32, @intCast(n))) next = @as(i32, @intCast(n)) - 1;
    self.setSelected(@intCast(next));
    self.scrollToRow(@intCast(next));
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
    try list.model.addChangeListener(onModelChange, @ptrCast(list));
}

fn uninstall(self: *Component) void {
    const list: *List = @fieldParentPtr("component", self);
    list.model.removeChangeListener(onModelChange, @ptrCast(list));
}

/// The structure (item count) changed: every row's content may have shifted,
/// so drop all bindings and let the next reconcile rebind from scratch.
fn onModelChange(user_data: *anyopaque) void {
    const list: *List = @ptrCast(@alignCast(user_data));
    for (list.pool.items) |*pc| pc.row = null;
    const n = list.model.getSize();
    if (list.selected) |s| {
        if (n == 0) {
            list.selected = null;
        } else if (s >= n) {
            list.selected = n - 1;
        }
    }
    list.syncContentHeight();
    list.component.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const list: *List = @fieldParentPtr("component", self);
    list.reconcile();

    g.setColor(LIST_BG);
    g.fillRect(.{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height });

    // Selection background behind the cell content.
    if (list.selected) |r| {
        g.setColor(SEL_BG);
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
                        list.setSelected(r);
                        const start = switch (list.edit_trigger) {
                            .double_click, .double_click_or_enter => dbl,
                            .enter, .manual => false,
                        };
                        if (start) list.edit(r);
                    }
                }
            }
        },
        .key => |k| {
            if (k.action == .press or k.action == .repeat) {
                switch (k.code) {
                    .arrow_down => {
                        list.moveSelection(1);
                        ev.consume();
                    },
                    .arrow_up => {
                        list.moveSelection(-1);
                        ev.consume();
                    },
                    .enter => {
                        // Enter on the selected row starts editing (when the
                        // trigger allows it). While editing, the scratch field
                        // owns focus and handles Enter itself, so List never
                        // sees Enter in that state.
                        if (list.editing == null) {
                            const want = switch (list.edit_trigger) {
                                .enter, .double_click_or_enter => true,
                                .double_click, .manual => false,
                            };
                            if (want) if (list.selected) |s| {
                                list.edit(s);
                                ev.consume();
                            };
                        }
                    },
                    else => {},
                }
            }
        },
        .focus => |f| {
            list.has_focus = f.gained;
            if (list.selected) |r| if (list.findCellRowIndex(r)) |i| list.bindCell(i, r);
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
    if (list.owns_model) {
        list.model.deinit();
        allocator.destroy(list.model);
    }
    allocator.destroy(list);
}
