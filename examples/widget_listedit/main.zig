//! List cell-editing validation: the JavaFX-style "same cell toggles into an
//! edit mode" CellEditor design.
//!
//! A scrollable list of editable text rows. Each cell shows a Label in display
//! mode and swaps to a TextField (scratch) while editing. The edited text is
//! committed back to the row data; cancel reverts.
//!
//! Usage:
//!     zig build run-widget_listedit
//!
//! Test recipe:
//!     - double-click a row (or select + Enter): it becomes an editable field
//!     - type, then Enter: the new text is committed and shown as a label
//!     - edit again, then Escape: the edit reverts to the previous text
//!     - while editing, click another row: the edit commits (focus-lost = commit)
//!     - scroll the editing row far off-screen: the edit commits (no recycle
//!       of an editing cell)

const std = @import("std");
const nimbus = @import("nimbus");
const Event = nimbus.ActionEvent;

const ROW_COUNT = 40;

/// Backing per-row data, owned by `main`. `buf`/`len` hold the committed text;
/// the cell's editor writes the scratch value back here on commit.
const Row = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Row) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *Row, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }
};

const Ctx = struct {
    app:  *nimbus.Application,
    list: *nimbus.List = undefined,
};

/// One real cell. Display mode = `label` as the container's center; edit mode
/// = `field` as the center. The cell owns both widgets and the container.
const EditCell = struct {
    root:    *nimbus.Container,
    label:   *nimbus.Label,
    field:   *nimbus.TextField,
    list:    *nimbus.List,
    cur_row: ?*Row = null,
    in_edit: bool = false,

    // Cell.update — display-mode projection (suspended while editing).
    fn update(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *EditCell = @ptrCast(@alignCast(ud));
        const row: *Row = @ptrCast(@alignCast(ctx.value));
        self.cur_row = row;
        self.label.setText(row.text()) catch {};
    }

    // CellEdit.start — enter edit mode.
    fn start(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *EditCell = @ptrCast(@alignCast(ud));
        const row: *Row = @ptrCast(@alignCast(ctx.value));
        self.cur_row = row;
        self.field.setText(row.text()) catch {};
        self.swapTo(true);
        self.field.component.requestFocus();
    }

    // CellEdit.commit — write scratch back to the item, return to display.
    fn commit(ud: *anyopaque) void {
        const self: *EditCell = @ptrCast(@alignCast(ud));
        if (self.cur_row) |row| row.set(self.field.getText());
        self.swapTo(false);
        if (self.cur_row) |row| self.label.setText(row.text()) catch {};
    }

    // CellEdit.cancel — discard scratch, return to display (item unchanged).
    fn cancel(ud: *anyopaque) void {
        const self: *EditCell = @ptrCast(@alignCast(ud));
        self.swapTo(false);
    }

    fn swapTo(self: *EditCell, edit_mode: bool) void {
        if (edit_mode == self.in_edit) return;
        if (edit_mode) {
            self.root.remove(&self.label.component);
            nimbus.BorderLayout.add(self.root, .center, &self.field.component) catch {};
        } else {
            self.root.remove(&self.field.component);
            nimbus.BorderLayout.add(self.root, .center, &self.label.component) catch {};
        }
        self.in_edit = edit_mode;
        self.root.doLayout(); // size the newly-shown child to fill the cell
    }

    // Wired to the field's Enter / Escape via submit / cancel listeners.
    fn onSubmit(self: *EditCell, _: *const Event) void {
        self.list.commitEdit();
    }
    fn onCancel(self: *EditCell, _: *const Event) void {
        self.list.cancelEdit();
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *EditCell = @ptrCast(@alignCast(ud));
        // Detach both (remove is a no-op if not currently added) so the
        // container destroys neither; the cell owns both and frees them itself.
        self.root.remove(&self.label.component);
        self.root.remove(&self.field.component);
        const rc = &self.root.component;
        rc.vtable.destroy(rc, allocator);
        self.label.component.vtable.destroy(&self.label.component, allocator);
        self.field.component.vtable.destroy(&self.field.component, allocator);
        allocator.destroy(self);
    }
};

fn createCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const cx: *Ctx = @ptrCast(@alignCast(ud));
    const app = cx.app;

    const cell = try allocator.create(EditCell);
    errdefer allocator.destroy(cell);

    const root = try app.container();
    root.setLayout(nimbus.BorderLayout.get());
    const label = try app.label("");
    const field = try app.textField("");
    try nimbus.BorderLayout.add(root, .center, &label.component); // start in display mode

    cell.* = .{ .root = root, .label = label, .field = field, .list = cx.list };
    try field.addSubmitListener(EditCell, EditCell.onSubmit, cell);
    try field.addCancelListener(EditCell, EditCell.onCancel, cell);

    return .{
        .component = &root.component,
        .update    = EditCell.update,
        .destroy   = EditCell.destroyCell,
        .edit      = .{ .start = EditCell.start, .commit = EditCell.commit, .cancel = EditCell.cancel },
        .user_data = cell,
    };
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_listedit", 320, 420);

    var rows: [ROW_COUNT]Row = undefined;
    for (0..ROW_COUNT) |i| {
        rows[i] = .{};
        var b: [32]u8 = undefined;
        rows[i].set(try std.fmt.bufPrint(&b, "row {d}", .{i}));
    }

    var ctx = Ctx{ .app = app };
    const lst = try app.list(.{ .create = createCell, .user_data = &ctx });
    ctx.list = lst;
    lst.setRowHeight(30);
    for (0..ROW_COUNT) |i| {
        try lst.model.add(@ptrCast(&rows[i]));
    }

    const sp = try app.scrollPane(lst.asComponent());
    sp.asComponent().setGrowX(1);
    sp.asComponent().setGrowY(1);
    try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());

    std.debug.print(
        \\Double-click a row (or select + Enter) to edit. Enter commits, Escape reverts.
        \\Clicking another row while editing commits (focus-lost = commit).
        \\
    , .{});
    try app.run();
}
