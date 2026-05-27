//! Drag-to-reorder on a List, built entirely *on top of* List — the List
//! widget source is not modified. It demonstrates the DnD foundation:
//!   - the List is both a drag source and a drop target (self-drop / reorder),
//!     wired via the `Component.drag_source` / `drop_target` fields set
//!     externally (the VTable is untouched)
//!   - `onDragStart` maps the press position to a source row; `onOver` maps the
//!     cursor to an insertion index and returns acceptance; `onDrop` reorders
//!     the model via the additive `ListModel.move`
//!   - the insertion line is drawn by *decorating* the List's paint: we copy
//!     List's (public) vtable and override only `paint`, calling the original
//!     first and then drawing the line in the List's own Graphics so it scrolls
//!     and clips for free
//!
//! See `framework/doc/dnd.md`「List の行並べ替え」.
//!
//! Usage:
//!     zig build run-widget_listdnd
//!
//! Test recipe:
//!     - press a row and drag up/down: a blue insertion line tracks the cursor
//!     - release: the dragged row moves to that position, others shift
//!     - press Escape mid-drag: nothing moves
//!     - drag a row onto its own position: no change

const std = @import("std");
const nimbus = @import("nimbus");
const dnd = nimbus.dnd;

const ROW_COUNT = 12;

/// Backing per-row data, owned by `main` and borrowed by the ListModel.
const Row = struct { name: []const u8 };

/// Identifies "a Row is being dragged" so a drop target only accepts our rows.
const row_tag = dnd.tagOf(Row);

// ── reorder controller (shared by the List's drag_source + drop_target) ──
const Reorder = struct {
    list: *nimbus.List,
    src_row: ?usize = null, // row the drag started on (set in onDragStart)
    drop_at: ?usize = null, // insertion index under the cursor (drawn by paint)

    /// Drag started on the List: map the press y to a row and carry that item.
    fn onDragStart(ud: *anyopaque, x: f32, y: f32) ?dnd.Transfer {
        _ = x;
        const self: *Reorder = @ptrCast(@alignCast(ud));
        const h = self.list.getRowHeight();
        if (h <= 0 or y < 0) return null;
        const row: usize = @intFromFloat(y / h);
        const item = self.list.model.getElementAt(row) orelse return null;
        self.src_row = row;
        return .{
            .flavor = .object,
            .ctx = item,
            .type_tag = row_tag,
            .source = self.list.asComponent(),
        };
    }

    fn onOver(ud: *anyopaque, e: *const dnd.DragEvent) bool {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        if (e.transfer.flavor != .object or e.transfer.type_tag != row_tag) return false;
        self.drop_at = self.insertionRow(e.y);
        self.list.asComponent().repaint();
        return true;
    }

    fn onLeave(ud: *anyopaque) void {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        self.drop_at = null;
        self.list.asComponent().repaint();
    }

    fn onDrop(ud: *anyopaque, e: *const dnd.DragEvent) void {
        const self: *Reorder = @ptrCast(@alignCast(ud));
        const src = self.src_row orelse return;
        const dst = self.insertionRow(e.y);
        self.drop_at = null;
        self.list.model.move(src, dst); // model order changes; List rebinds cells
        self.list.asComponent().repaint();
        // source == target, so the whole move happens here; onDragDone unused.
    }

    /// List-local y → insertion index (0..=size). Upper half of a row inserts
    /// before it, lower half after.
    fn insertionRow(self: *Reorder, y: f32) usize {
        const h = self.list.getRowHeight();
        const i: usize = if (y <= 0) 0 else @intFromFloat((y + h / 2) / h);
        const n = self.list.model.getSize();
        return if (i > n) n else i;
    }

    /// Draw a 2px insertion line at `row`'s boundary. Called from the decorated
    /// paint, inside the List's own Graphics (translate/clip), so it follows
    /// scroll and clips to the viewport automatically.
    fn drawLine(self: *Reorder, g: *nimbus.awt.Graphics, row: usize) void {
        const h = self.list.getRowHeight();
        const w = self.list.asComponent().size.width;
        const y = @as(f32, @floatFromInt(row)) * h;
        g.setColor(nimbus.awt.Graphics.Color.rgb(0.20, 0.52, 1.0));
        g.fillRect(.{ .x = 0, .y = y - 1, .width = w, .height = 2 });
    }
};

// ── vtable decoration: draw the insertion line without touching List source ──
// List.vtable is public, so we copy it and override only `paint`. All other
// methods keep List's implementations — no delegation stubs, no global needed.
fn decorPaint(self: *nimbus.Component, g: *nimbus.awt.Graphics) void {
    nimbus.List.vtable.paint(self, g); // List's own paint first
    if (self.getTyped(Reorder)) |r| {
        if (r.drop_at) |row| r.drawLine(g, row);
    }
}

const decor_vt = blk: {
    var vt = nimbus.List.vtable;
    vt.paint = decorPaint;
    break :blk vt;
};

// ── cells: plain labels (display only; drag/drop lives on the List) ──
const Ctx = struct { app: *nimbus.Application };

const RowCell = struct {
    label: *nimbus.Label,

    fn update(ud: *anyopaque, c: nimbus.List.CellContext) void {
        const self: *RowCell = @ptrCast(@alignCast(ud));
        const row: *Row = @ptrCast(@alignCast(c.value));
        self.label.setText(row.name) catch {};
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *RowCell = @ptrCast(@alignCast(ud));
        const comp = &self.label.component;
        comp.vtable.destroy(comp, allocator);
        allocator.destroy(self);
    }
};

fn createCell(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
    const ctx: *Ctx = @ptrCast(@alignCast(ud));
    const cell = try allocator.create(RowCell);
    errdefer allocator.destroy(cell);
    const label = try ctx.app.label("");
    cell.* = .{ .label = label };
    return .{
        .component = &label.component,
        .update = RowCell.update,
        .destroy = RowCell.destroyCell,
        .user_data = cell,
    };
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_listdnd", 320, 420);

    var names: [ROW_COUNT][16]u8 = undefined;
    var rows: [ROW_COUNT]Row = undefined;
    for (0..ROW_COUNT) |i| {
        const s = try std.fmt.bufPrint(&names[i], "row {d}", .{i});
        rows[i] = .{ .name = s };
    }

    var ctx = Ctx{ .app = app };
    const lst = try app.list(.{ .create = createCell, .user_data = &ctx });
    lst.setRowHeight(32);

    var reorder = Reorder{ .list = lst };

    // The List is both drag source and drop target (self-reorder). Set the
    // capabilities from outside — the List widget itself is not modified.
    lst.asComponent().drag_source = .{
        .onDragStart = Reorder.onDragStart,
        .user_data = &reorder,
        // onDragDone unused: a self-reorder completes inside onDrop.
    };
    lst.asComponent().drop_target = .{
        .onOver = Reorder.onOver,
        .onLeave = Reorder.onLeave,
        .onDrop = Reorder.onDrop,
        .user_data = &reorder,
    };
    // Decorate paint for the insertion line, and stash the controller so the
    // decorated paint can find it from just `self` (app owns it → destroy null).
    lst.asComponent().vtable = &decor_vt;
    try lst.asComponent().putProperty(@typeName(Reorder), &reorder, null);

    for (0..ROW_COUNT) |i| try lst.model.add(@ptrCast(&rows[i]));

    const sp = try app.scrollPane(lst.asComponent());
    sp.asComponent().setGrowX(1);
    sp.asComponent().setGrowY(1);
    try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());

    std.debug.print(
        \\Press a row and drag up/down: a blue line shows where it will land.
        \\Release to reorder. Escape mid-drag cancels. (List source is unmodified.)
        \\
    , .{});
    try app.run();
}
