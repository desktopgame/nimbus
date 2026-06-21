//! Non-uniform column grid layout. Nimbus `GridLayout` is a non-uniform
//! column layout (column width = max natural width in that column), and is
//! not Swing's equal-cell `GridLayout`.

const std = @import("std");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const LayoutManager = @import("LayoutManager.zig");

const GridLayout = @This();

pub const Options = struct {
    col_spacing: f32 = 0,
    row_spacing: f32 = 0,
};

base: LayoutManager,
n_cols: usize,
col_spacing: f32,
row_spacing: f32,

const vtable = LayoutManager.VTable{
    .doLayout = doLayout,
    .computeMinSize = computeMinSize,
    .computeMaxSize = computeMaxSize,
    .deinit = deinit,
};

pub fn create(allocator: std.mem.Allocator, n_cols: usize, opts: Options) !*LayoutManager {
    std.debug.assert(n_cols > 0);
    const layout = try allocator.create(GridLayout);
    layout.* = .{
        .base = .{ .vtable = &vtable },
        .n_cols = n_cols,
        .col_spacing = opts.col_spacing,
        .row_spacing = opts.row_spacing,
    };
    return &layout.base;
}

fn deinit(self: *LayoutManager, allocator: std.mem.Allocator) void {
    const this: *GridLayout = @fieldParentPtr("base", self);
    allocator.destroy(this);
}

fn nRows(child_count: usize, n_cols: usize) usize {
    if (child_count == 0) return 0;
    return (child_count + n_cols - 1) / n_cols;
}

fn cellAt(container: *const Container, row: usize, col: usize, n_cols: usize) ?*Component {
    const index = row * n_cols + col;
    if (index >= container.children.items.len) return null;
    return container.children.items[index].component;
}

fn colNatural(container: *const Container, col: usize, n_cols: usize) f32 {
    var result: f32 = 0;
    const rows = nRows(container.children.items.len, n_cols);
    for (0..rows) |row| {
        const child = cellAt(container, row, col, n_cols) orelse continue;
        result = @max(result, child.effectiveMinSize().width);
    }
    return result;
}

fn colGrow(container: *const Container, col: usize, n_cols: usize) f32 {
    var result: f32 = 0;
    const rows = nRows(container.children.items.len, n_cols);
    for (0..rows) |row| {
        const child = cellAt(container, row, col, n_cols) orelse continue;
        result = @max(result, child.grow_x);
    }
    return result;
}

fn rowHeight(container: *const Container, row: usize, n_cols: usize) f32 {
    var result: f32 = 0;
    for (0..n_cols) |col| {
        const child = cellAt(container, row, col, n_cols) orelse continue;
        result = @max(result, child.effectiveMinSize().height);
    }
    return result;
}

fn naturalWidth(self: *const GridLayout, container: *const Container) f32 {
    if (container.children.items.len == 0) return 0;
    var result: f32 = 0;
    for (0..self.n_cols) |col| result += colNatural(container, col, self.n_cols);
    result += self.col_spacing * @as(f32, @floatFromInt(self.n_cols - 1));
    return result;
}

fn naturalHeight(self: *const GridLayout, container: *const Container) f32 {
    const rows = nRows(container.children.items.len, self.n_cols);
    if (rows == 0) return 0;
    var result: f32 = 0;
    for (0..rows) |row| result += rowHeight(container, row, self.n_cols);
    result += self.row_spacing * @as(f32, @floatFromInt(rows - 1));
    return result;
}

fn sumGrow(self: *const GridLayout, container: *const Container) f32 {
    var result: f32 = 0;
    for (0..self.n_cols) |col| result += colGrow(container, col, self.n_cols);
    return result;
}

fn colWidth(
    self: *const GridLayout,
    container: *const Container,
    col: usize,
    distributable: f32,
    grow_total: f32,
) f32 {
    const natural = colNatural(container, col, self.n_cols);
    if (grow_total <= 0 or distributable <= 0) return natural;
    return natural + distributable * (colGrow(container, col, self.n_cols) / grow_total);
}

fn clampSize(value: f32, min: f32, max: f32) f32 {
    var result = value;
    if (result > max) result = max;
    if (result < min) result = min;
    return result;
}

fn alignOffset(alignment: Component.Alignment, available: f32, chosen: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .stretch, .center => (available - chosen) / 2,
        .end => available - chosen,
    };
}

fn doLayout(self: *LayoutManager, container: *Container) void {
    const this: *GridLayout = @fieldParentPtr("base", self);
    if (container.children.items.len == 0) return;

    const natural_total = this.naturalWidth(container);
    const excess = container.component.size.width - natural_total;
    const distributable = if (excess > 0) excess else 0;
    const grow_total = this.sumGrow(container);
    const rows = nRows(container.children.items.len, this.n_cols);

    var y: f32 = 0;
    for (0..rows) |row| {
        const row_h = rowHeight(container, row, this.n_cols);
        var x: f32 = 0;
        for (0..this.n_cols) |col| {
            const child = cellAt(container, row, col, this.n_cols) orelse {
                x += this.col_spacing;
                continue;
            };
            const col_w = this.colWidth(container, col, distributable, grow_total);
            const child_min = child.effectiveMinSize();
            const child_max = child.effectiveMaxSize();

            const desired_w = switch (child.align_x) {
                .stretch => col_w,
                else => child_min.width,
            };
            const w = clampSize(desired_w, child_min.width, child_max.width);
            const off_x = alignOffset(child.align_x, col_w, w);

            const desired_h = switch (child.align_y) {
                .stretch => row_h,
                else => child_min.height,
            };
            const h = clampSize(desired_h, child_min.height, child_max.height);
            const off_y = alignOffset(child.align_y, row_h, h);

            child.setBounds(.{
                .x = x + off_x,
                .y = y + off_y,
                .width = w,
                .height = h,
            });

            x += col_w + this.col_spacing;
        }
        y += row_h + this.row_spacing;
    }
}

fn computeMinSize(self: *LayoutManager, container: *const Container) Component.Size {
    const this: *GridLayout = @fieldParentPtr("base", self);
    return .{
        .width = this.naturalWidth(container),
        .height = this.naturalHeight(container),
    };
}

fn computeMaxSize(self: *LayoutManager, container: *const Container) Component.Size {
    const this: *GridLayout = @fieldParentPtr("base", self);
    const min = computeMinSize(self, container);
    return .{
        .width = if (this.sumGrow(container) > 0) std.math.inf(f32) else min.width,
        .height = min.height,
    };
}

fn expectRect(c: *const Component, x: f32, y: f32, w: f32, h: f32) !void {
    try std.testing.expectEqual(x, c.position.x);
    try std.testing.expectEqual(y, c.position.y);
    try std.testing.expectEqual(w, c.size.width);
    try std.testing.expectEqual(h, c.size.height);
}

fn makeChild(parent: *Container, width: f32, height: f32) !*Container {
    const child = try Container.create(std.testing.allocator);
    child.component.min_size = .{ .width = width, .height = height };
    try parent.add(&child.component);
    return child;
}

test "grid layout uses max natural width per column and row-major cells" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 2, .{}));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 50 });

    const a = try makeChild(parent, 10, 10);
    const b = try makeChild(parent, 20, 10);
    const c = try makeChild(parent, 30, 10);
    const d = try makeChild(parent, 40, 10);

    parent.doLayout();

    try expectRect(&a.component, 0, 0, 30, 10);
    try expectRect(&b.component, 30, 0, 40, 10);
    try expectRect(&c.component, 0, 10, 30, 10);
    try expectRect(&d.component, 30, 10, 40, 10);
}

test "grid layout gives horizontal excess to growing column" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 2, .{ .col_spacing = 5 }));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 20 });

    const label = try makeChild(parent, 20, 10);
    const field = try makeChild(parent, 30, 10);
    field.component.setGrowX(1);

    parent.doLayout();

    try expectRect(&label.component, 0, 0, 20, 10);
    try expectRect(&field.component, 25, 0, 75, 10);
}

test "grid layout distributes excess between growing columns proportionally" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 3, .{}));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 80, .height = 10 });

    const fixed = try makeChild(parent, 10, 10);
    const one = try makeChild(parent, 10, 10);
    const three = try makeChild(parent, 10, 10);
    one.component.setGrowX(1);
    three.component.setGrowX(3);

    parent.doLayout();

    try expectRect(&fixed.component, 0, 0, 10, 10);
    try expectRect(&one.component, 10, 0, 22.5, 10);
    try expectRect(&three.component, 32.5, 0, 47.5, 10);
}

test "grid layout uses max row height and vertical alignment" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 2, .{}));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 40, .height = 40 });

    const label = try makeChild(parent, 10, 10);
    const field = try makeChild(parent, 10, 30);
    label.component.setAlignY(.center);

    parent.doLayout();

    try expectRect(&label.component, 0, 10, 10, 10);
    try expectRect(&field.component, 10, 0, 10, 30);
}

test "grid layout applies horizontal alignment inside column frame" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 1, .{}));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 30, .height = 40 });

    const start = try makeChild(parent, 10, 10);
    const center = try makeChild(parent, 30, 10);
    const end = try makeChild(parent, 10, 10);
    const stretch = try makeChild(parent, 10, 10);
    start.component.setAlignX(.start);
    center.component.setAlignX(.center);
    end.component.setAlignX(.end);

    parent.doLayout();

    try expectRect(&start.component, 0, 0, 10, 10);
    try expectRect(&center.component, 0, 10, 30, 10);
    try expectRect(&end.component, 20, 20, 10, 10);
    try expectRect(&stretch.component, 0, 30, 30, 10);
}

test "grid layout computes min size from columns rows and gaps" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 2, .{ .col_spacing = 3, .row_spacing = 4 }));

    _ = try makeChild(parent, 10, 5);
    _ = try makeChild(parent, 20, 10);
    _ = try makeChild(parent, 30, 15);

    const min = parent.getMinSize();
    try std.testing.expectEqual(@as(f32, 53), min.width);
    try std.testing.expectEqual(@as(f32, 29), min.height);
}

test "grid layout ignores missing cells in ragged final row" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 3, .{ .col_spacing = 2, .row_spacing = 1 }));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 50 });

    const a = try makeChild(parent, 10, 10);
    const b = try makeChild(parent, 20, 10);
    const c = try makeChild(parent, 30, 10);
    const d = try makeChild(parent, 40, 15);

    parent.doLayout();

    try expectRect(&a.component, 0, 0, 40, 10);
    try expectRect(&b.component, 42, 0, 20, 10);
    try expectRect(&c.component, 64, 0, 30, 10);
    try expectRect(&d.component, 0, 11, 40, 15);
}

test "grid layout reports infinite max width when any column grows" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 2, .{}));

    _ = try makeChild(parent, 10, 10);
    const growing = try makeChild(parent, 10, 10);
    growing.component.setGrowX(1);

    const max = parent.getMaxSize();
    try std.testing.expect(std.math.isInf(max.width));
    try std.testing.expectEqual(@as(f32, 10), max.height);
}

test "grid layout keeps cell min size implicit and recomputes columns after natural size changes" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    parent.setLayout(try create(allocator, 2, .{}));
    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 40 });

    const short_label = try makeChild(parent, 10, 10);
    const field_a = try makeChild(parent, 20, 10);
    const long_label = try makeChild(parent, 30, 10);
    const field_b = try makeChild(parent, 20, 10);

    parent.doLayout();
    try std.testing.expect(!short_label.component.min_size_explicit);
    try std.testing.expect(!long_label.component.min_size_explicit);
    try expectRect(&short_label.component, 0, 0, 30, 10);
    try expectRect(&long_label.component, 0, 10, 30, 10);

    short_label.component.setMinSizeDerived(.{ .width = 50, .height = 10 });
    parent.doLayout();

    try std.testing.expect(!short_label.component.min_size_explicit);
    try std.testing.expect(!long_label.component.min_size_explicit);
    try expectRect(&short_label.component, 0, 0, 50, 10);
    try expectRect(&long_label.component, 0, 10, 50, 10);
    try expectRect(&field_a.component, 50, 0, 20, 10);
    try expectRect(&field_b.component, 50, 10, 20, 10);
}

test "grid layout allocated instance is released by container ownership" {
    const allocator = std.testing.allocator;
    const parent = try Container.create(allocator);
    parent.setLayout(try create(allocator, 2, .{}));
    parent.component.vtable.destroy(&parent.component, allocator);
}
