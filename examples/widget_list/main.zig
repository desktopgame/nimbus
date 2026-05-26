//! List validation: the JavaFX-style visible-range + recycle cell model.
//!
//! A scrollable list of 40 rows. Each cell is a real Component subtree
//! (checkbox + label + delete button), materialized only for the visible
//! range and recycled on scroll. This exercises every novel part of the
//! design:
//!   - real-cell events: the delete button and checkbox respond to clicks
//!   - identity: delete removes the *correct* row (no reverse lookup)
//!   - persistent per-row state: the checkbox toggles that row's `done` flag,
//!     which lives in the row data — scroll away and back, it is preserved and
//!     does NOT leak onto other rows (the recycle correctness check)
//!   - selection: click an empty part of a row to select it; arrow keys move
//!
//! Usage:
//!     zig build run-widget_list
//!
//! Test recipe:
//!     - check a few boxes, scroll down past them and back: states preserved,
//!       no other rows spuriously checked (recycle does not leak)
//!     - click delete on a middle row: that exact row disappears, rest shift up
//!     - click empty row area to select; Up/Down move the selection

const std = @import("std");
const nimbus = @import("nimbus");

const ROW_COUNT = 40;

/// Backing per-row data, owned by `main` and borrowed by the ListModel.
const Row = struct {
    name: []const u8,
    done: bool,
};

/// Factory context: the factory needs the List (to delete rows) and the
/// Application (to build widgets). `list` is filled in after List creation.
const Ctx = struct {
    app:  *nimbus.Application,
    list: *nimbus.List = undefined,
};

/// One real cell instance. Reused across rows via `update` (recycle).
const TaskCell = struct {
    panel:     *nimbus.Panel,
    check:     *nimbus.CheckBox,
    label:     *nimbus.Label,
    del:       *nimbus.Button,
    list:      *nimbus.List,
    cur_row:   ?*Row = null,   // row data currently bound (write-back target)
    cur_index: usize = 0,      // its index (delete target)

    /// JavaFX updateItem: bind this cell to one row. Projection only —
    /// content + persistent state come from the row data.
    fn update(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
        const row: *Row = @ptrCast(@alignCast(ctx.value));
        self.cur_row = row;
        self.cur_index = ctx.index;
        self.label.setText(row.name) catch {};
        self.check.setSelected(row.done); // re-project persistent state every bind
    }

    /// Checkbox toggled: write the new value back to the row data (the truth).
    fn onToggle(ud: *anyopaque) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
        if (self.cur_row) |row| row.done = self.check.isSelected();
    }

    /// Delete clicked: the cell knows its own row, so no reverse lookup.
    fn onDelete(ud: *anyopaque) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
        self.list.model.remove(self.cur_index);
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TaskCell = @ptrCast(@alignCast(ud));
        const comp = &self.panel.container.component;
        comp.vtable.destroy(comp, allocator); // frees panel + children + their models
        allocator.destroy(self);
    }
};

fn createCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const ctx: *Ctx = @ptrCast(@alignCast(ud));
    const app = ctx.app;

    const tc = try allocator.create(TaskCell);
    errdefer allocator.destroy(tc);

    const panel = try app.panel();
    errdefer {
        const comp = &panel.container.component;
        comp.vtable.destroy(comp, allocator);
    }
    panel.container.setLayout(nimbus.BoxLayout.horizontal());

    const check = try app.checkBox("");
    const label = try app.label("");
    label.component.setGrowX(1); // push the delete button to the right edge
    const del = try app.button("delete");

    try panel.container.add(&check.component);
    try panel.container.add(&label.component);
    try panel.container.add(&del.component);

    tc.* = .{ .panel = panel, .check = check, .label = label, .del = del, .list = ctx.list };

    // Listeners registered once, here, with the cell's own state as user_data.
    try del.getModel().addActionListener(TaskCell.onDelete, tc);
    try check.getModel().addActionListener(TaskCell.onToggle, tc);

    return .{
        .component = &panel.container.component,
        .update    = TaskCell.update,
        .destroy   = TaskCell.destroyCell,
        .user_data = tc,
    };
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_list", 360, 420);

    // Row data lives on the stack for the whole run; the ListModel borrows it.
    var names: [ROW_COUNT][16]u8 = undefined;
    var rows: [ROW_COUNT]Row = undefined;
    for (0..ROW_COUNT) |i| {
        const s = try std.fmt.bufPrint(&names[i], "item {d}", .{i});
        rows[i] = .{ .name = s, .done = (i % 4 == 0) };
    }

    var ctx = Ctx{ .app = app };
    const lst = try app.list(.{ .create = createCell, .user_data = &ctx });
    ctx.list = lst;
    lst.setRowHeight(36);
    for (0..ROW_COUNT) |i| {
        try lst.model.add(@ptrCast(&rows[i]));
    }

    const sp = try app.scrollPane(lst.asComponent());
    sp.asComponent().setGrowX(1);
    sp.asComponent().setGrowY(1);
    try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());

    std.debug.print(
        \\Check boxes, scroll, and watch state stay with its row (no leak on recycle).
        \\Delete removes the exact row. Click a row to select; Up/Down to move.
        \\
    , .{});
    try app.run();
}
