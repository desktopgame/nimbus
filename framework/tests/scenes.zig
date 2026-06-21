//! Framework snapshot scenes.
//!
//! Each scene builds a small widget tree, lays it out at the render-target
//! size, and paints it. The snapshot test runner compares the result
//! against a fixture PNG under `framework/tests/fixtures/`.
//!
//! Scenes here intentionally mirror the numeric layout tests
//! (`box_layout_test.zig` / `border_layout_test.zig`) so that the picture
//! and the assertions read together — when a layout regresses, you can
//! see what went wrong instead of decoding bounds tuples.

const std = @import("std");
const awt = @import("awt");
const nimbus = @import("nimbus");

pub const default_font_bytes = nimbus.noto.noto_sans_jp_regular;

pub const PaintContext = struct {
    g: *awt.Graphics,
    allocator: std.mem.Allocator,
    font: awt.Font,
    width: i32,
    height: i32,
};

pub const Scene = struct {
    /// Stable identifier; used as the fixture file basename.
    name: []const u8,
    width: i32,
    height: i32,
    /// Clear color applied before `paint`. Off-white so colored Panels stand out.
    clear: [4]f32 = .{ 0.95, 0.95, 0.95, 1.0 },
    paint: *const fn (ctx: PaintContext) anyerror!void,
};

// ── helpers ──────────────────────────────────────────────────────────────

/// Build a colored Panel with min == max == (w, h). The fixed-size leaf
/// pattern from `box_layout_test.zig`, plus a visible background so the
/// bounds are recognizable in the snapshot image.
fn coloredLeaf(
    allocator: std.mem.Allocator,
    w: f32,
    h: f32,
    color: awt.Graphics.Color,
) !*nimbus.Panel {
    const p = try nimbus.Panel.create(allocator);
    p.setBackground(color);
    p.container.component.setMinSize(.{ .width = w, .height = h });
    p.container.component.setMaxSize(.{ .width = w, .height = h });
    return p;
}

/// Same as `coloredLeaf` but lets the Panel grow on the main axis (cap
/// max at inf). Useful for "grow weight" scenes.
fn growableLeaf(
    allocator: std.mem.Allocator,
    min_w: f32,
    h: f32,
    color: awt.Graphics.Color,
    grow: f32,
) !*nimbus.Panel {
    const p = try nimbus.Panel.create(allocator);
    p.setBackground(color);
    p.container.component.setMinSize(.{ .width = min_w, .height = h });
    p.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = h });
    p.container.component.setGrowX(grow);
    return p;
}

/// Build a root Container the size of the render target, run a layout
/// pass, paint, then free. All scenes go through this so they don't
/// re-implement the boilerplate.
const Setup = struct {
    container: *nimbus.Container,
    ctx: PaintContext,

    fn init(ctx: PaintContext) !Setup {
        const cont = try nimbus.Container.create(ctx.allocator);
        return .{ .container = cont, .ctx = ctx };
    }

    fn paint(self: *Setup) void {
        self.container.setBounds(.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.ctx.width),
            .height = @floatFromInt(self.ctx.height),
        });
        self.container.doLayout();
        for (self.container.children.items) |elem| {
            elem.component.paintAt(self.ctx.g);
        }
    }

    fn deinit(self: *Setup) void {
        self.container.component.vtable.destroy(&self.container.component, self.ctx.allocator);
    }
};

// ── BoxLayout scenes ─────────────────────────────────────────────────────

/// 3 fixed-size colored Panels packed from the left, no grow.
/// Mirrors `box_layout_test.zig::"horizontal: 3 fixed-size children pack from the left"`.
pub const box_horizontal_pack = Scene{
    .name = "box_horizontal_pack",
    .width = 400,
    .height = 80,
    .paint = paintBoxHorizontalPack,
};

fn paintBoxHorizontalPack(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.horizontal());

    try setup.container.add(&(try coloredLeaf(ctx.allocator, 50, 30, awt.Graphics.Color.rgb(0.90, 0.30, 0.30))).container.component);
    try setup.container.add(&(try coloredLeaf(ctx.allocator, 80, 40, awt.Graphics.Color.rgb(0.30, 0.80, 0.40))).container.component);
    try setup.container.add(&(try coloredLeaf(ctx.allocator, 60, 25, awt.Graphics.Color.rgb(0.30, 0.50, 0.90))).container.component);

    setup.paint();
}

/// Two growable children with weights 1 and 3 split the horizontal space.
/// Mirrors `box_layout_test.zig::"horizontal: grow split by weight"`.
pub const box_horizontal_grow_weights = Scene{
    .name = "box_horizontal_grow_weights",
    .width = 400,
    .height = 60,
    .paint = paintBoxHorizontalGrowWeights,
};

fn paintBoxHorizontalGrowWeights(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.horizontal());

    try setup.container.add(&(try growableLeaf(ctx.allocator, 0, 30, awt.Graphics.Color.rgb(0.85, 0.55, 0.25), 1)).container.component);
    try setup.container.add(&(try growableLeaf(ctx.allocator, 0, 30, awt.Graphics.Color.rgb(0.25, 0.55, 0.85), 3)).container.component);

    setup.paint();
}

/// Vertical box with 4 children, each using a different cross-axis
/// alignment (start / center / end / stretch).
/// Mirrors `box_layout_test.zig::"vertical: cross-axis alignment"`.
pub const box_vertical_align_cross = Scene{
    .name = "box_vertical_align_cross",
    .width = 200,
    .height = 100,
    .paint = paintBoxVerticalAlignCross,
};

fn paintBoxVerticalAlignCross(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const palette = [_]awt.Graphics.Color{
        awt.Graphics.Color.rgb(0.85, 0.30, 0.30),
        awt.Graphics.Color.rgb(0.85, 0.65, 0.20),
        awt.Graphics.Color.rgb(0.30, 0.70, 0.40),
        awt.Graphics.Color.rgb(0.30, 0.50, 0.85),
    };
    const aligns = [_]nimbus.Component.Alignment{ .start, .center, .end, .stretch };

    inline for (aligns, 0..) |a, i| {
        const child = try coloredLeaf(ctx.allocator, 40, 20, palette[i]);
        if (a == .stretch) {
            child.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = 20 });
        }
        child.container.component.setAlignX(a);
        try setup.container.add(&child.container.component);
    }

    setup.paint();
}

// ── BorderLayout scenes ──────────────────────────────────────────────────

/// All 5 regions filled with color-coded fixed-size Panels.
/// Mirrors `border_layout_test.zig::"all 5 regions partition correctly"`.
pub const border_five_regions = Scene{
    .name = "border_five_regions",
    .width = 400,
    .height = 300,
    .paint = paintBorderFiveRegions,
};

fn paintBorderFiveRegions(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BorderLayout.get());

    try nimbus.BorderLayout.add(setup.container, .north, &(try coloredLeaf(ctx.allocator, 50, 20, awt.Graphics.Color.rgb(0.85, 0.30, 0.30))).container.component);
    try nimbus.BorderLayout.add(setup.container, .south, &(try coloredLeaf(ctx.allocator, 50, 30, awt.Graphics.Color.rgb(0.30, 0.50, 0.85))).container.component);
    try nimbus.BorderLayout.add(setup.container, .west, &(try coloredLeaf(ctx.allocator, 40, 50, awt.Graphics.Color.rgb(0.85, 0.65, 0.20))).container.component);
    try nimbus.BorderLayout.add(setup.container, .east, &(try coloredLeaf(ctx.allocator, 60, 50, awt.Graphics.Color.rgb(0.30, 0.70, 0.40))).container.component);
    try nimbus.BorderLayout.add(setup.container, .center, &(try coloredLeaf(ctx.allocator, 50, 50, awt.Graphics.Color.rgb(0.55, 0.55, 0.55))).container.component);

    setup.paint();
}

// ── toggle widgets (CheckBox / RadioButton / ComboBox) ───────────────────

/// Three CheckBoxes stacked vertically: one unchecked, one checked, one
/// disabled (so the disabled rendering is visible too).
pub const toggle_checkboxes = Scene{
    .name = "toggle_checkboxes",
    .width = 300,
    .height = 120,
    .paint = paintToggleCheckboxes,
};

fn paintToggleCheckboxes(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const black = awt.Graphics.Color.rgb(0, 0, 0);

    const cb1 = try nimbus.CheckBox.create(ctx.allocator, "Unchecked", font, black);
    const cb2 = try nimbus.CheckBox.create(ctx.allocator, "Checked", font, black);
    cb2.setSelected(true);
    const cb3 = try nimbus.CheckBox.create(ctx.allocator, "Disabled (checked)", font, black);
    cb3.setSelected(true);
    cb3.getModel().button.setEnabled(false);

    try setup.container.add(&cb1.component);
    try setup.container.add(&cb2.component);
    try setup.container.add(&cb3.component);
    setup.paint();
}

/// Three RadioButtons in a group, with the middle one selected.
pub const toggle_radios = Scene{
    .name = "toggle_radios",
    .width = 300,
    .height = 120,
    .paint = paintToggleRadios,
};

fn paintToggleRadios(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const black = awt.Graphics.Color.rgb(0, 0, 0);

    const rb1 = try nimbus.RadioButton.create(ctx.allocator, "Small", font, black);
    const rb2 = try nimbus.RadioButton.create(ctx.allocator, "Medium", font, black);
    rb2.setSelected(true);
    const rb3 = try nimbus.RadioButton.create(ctx.allocator, "Large", font, black);

    try setup.container.add(&rb1.component);
    try setup.container.add(&rb2.component);
    try setup.container.add(&rb3.component);
    setup.paint();
}

/// Closed-state ComboBox showing the currently-selected item plus the
/// down chevron. The popup is not exercised here (it would require an
/// open Window with overlay support).
pub const toggle_combobox_closed = Scene{
    .name = "toggle_combobox_closed",
    .width = 300,
    .height = 60,
    .paint = paintToggleComboboxClosed,
};

fn paintToggleComboboxClosed(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const black = awt.Graphics.Color.rgb(0, 0, 0);

    const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
    const combo = try nimbus.ComboBox.create(ctx.allocator, &items, font, black);
    combo.setSelectedIndex(1);

    try setup.container.add(&combo.component);
    setup.paint();
}

pub const metal_buttons = Scene{
    .name = "metal_buttons",
    .width = 300,
    .height = 150,
    .paint = paintMetalButtons,
};

fn paintMetalButtons(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const text = awt.Graphics.Color.rgb(0.08, 0.10, 0.12);

    const normal = try nimbus.Button.create(ctx.allocator, "Normal", font, text);
    const pressed = try nimbus.Button.create(ctx.allocator, "Pressed", font, text);
    pressed.getModel().setArmed(true);
    pressed.getModel().setPressed(true);
    const disabled = try nimbus.Button.create(ctx.allocator, "Disabled", font, text);
    disabled.getModel().setEnabled(false);

    try setup.container.add(&normal.component);
    try setup.container.add(&pressed.component);
    try setup.container.add(&disabled.component);
    nimbus.laf.applyLook(&setup.container.component, nimbus.laf.metal.buttonTable());

    normal.component.setBounds(.{ .x = 24, .y = 18, .width = 132, .height = 36 });
    pressed.component.setBounds(.{ .x = 24, .y = 58, .width = 132, .height = 36 });
    disabled.component.setBounds(.{ .x = 24, .y = 98, .width = 132, .height = 36 });

    setup.paint();
}

pub const metal_checkboxes = Scene{
    .name = "metal_checkboxes",
    .width = 300,
    .height = 120,
    .paint = paintMetalCheckboxes,
};

fn paintMetalCheckboxes(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const text = awt.Graphics.Color.rgb(0.08, 0.10, 0.12);

    const normal = try nimbus.CheckBox.create(ctx.allocator, "Unchecked", font, text);
    const checked = try nimbus.CheckBox.create(ctx.allocator, "Checked", font, text);
    checked.setSelected(true);
    const disabled = try nimbus.CheckBox.create(ctx.allocator, "Disabled", font, text);
    disabled.setSelected(true);
    disabled.getModel().button.setEnabled(false);

    try setup.container.add(&normal.component);
    try setup.container.add(&checked.component);
    try setup.container.add(&disabled.component);
    nimbus.laf.applyLook(&setup.container.component, nimbus.laf.metal.metalTable());
    setup.paint();
}

pub const metal_radios = Scene{
    .name = "metal_radios",
    .width = 300,
    .height = 120,
    .paint = paintMetalRadios,
};

fn paintMetalRadios(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const text = awt.Graphics.Color.rgb(0.08, 0.10, 0.12);

    const normal = try nimbus.RadioButton.create(ctx.allocator, "Small", font, text);
    const selected = try nimbus.RadioButton.create(ctx.allocator, "Medium", font, text);
    selected.setSelected(true);
    const disabled = try nimbus.RadioButton.create(ctx.allocator, "Disabled", font, text);
    disabled.setSelected(true);
    disabled.getModel().button.setEnabled(false);

    try setup.container.add(&normal.component);
    try setup.container.add(&selected.component);
    try setup.container.add(&disabled.component);
    nimbus.laf.applyLook(&setup.container.component, nimbus.laf.metal.metalTable());
    setup.paint();
}

pub const metal_combobox_closed = Scene{
    .name = "metal_combobox_closed",
    .width = 300,
    .height = 90,
    .paint = paintMetalComboboxClosed,
};

fn paintMetalComboboxClosed(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BoxLayout.vertical());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const text = awt.Graphics.Color.rgb(0.08, 0.10, 0.12);
    const items = [_][]const u8{ "Apple", "Banana", "Cherry" };

    const normal = try nimbus.ComboBox.create(ctx.allocator, &items, font, text);
    normal.setSelectedIndex(1);
    const disabled = try nimbus.ComboBox.create(ctx.allocator, &items, font, text);
    disabled.setSelectedIndex(2);
    disabled.setEnabled(false);

    try setup.container.add(&normal.component);
    try setup.container.add(&disabled.component);
    nimbus.laf.applyLook(&setup.container.component, nimbus.laf.metal.metalTable());
    setup.paint();
}

pub const metal_combobox_popup = Scene{
    .name = "metal_combobox_popup",
    .width = 260,
    .height = 150,
    .paint = paintMetalComboboxPopup,
};

fn paintMetalComboboxPopup(ctx: PaintContext) anyerror!void {
    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const text = awt.Graphics.Color.rgb(0.08, 0.10, 0.12);
    const items = [_][]const u8{ "Apple", "Banana", "Cherry", "Date" };
    const combo = try nimbus.ComboBox.create(ctx.allocator, &items, font, text);
    defer combo.component.vtable.destroy(&combo.component, ctx.allocator);

    combo.setSelectedIndex(1);
    combo.hovered_index = 2;
    combo.component.setBounds(.{ .x = 28, .y = 18, .width = 160, .height = combo.component.min_size.height });
    combo.popup_root.position = .{ .x = 28, .y = 52 };
    combo.popup_root.size = .{ .width = 160, .height = (font.face.metrics().line_height + 8) * @as(f32, @floatFromInt(items.len)) };
    nimbus.laf.applyLook(&combo.component, nimbus.laf.metal.metalTable());

    combo.component.paintAt(ctx.g);
    combo.popup_root.paintAt(ctx.g);
}

// Composite widget scenes ----------------------------------------------------

pub const panel_paint_over_child = Scene{
    .name = "panel_paint_over_child",
    .width = 260,
    .height = 180,
    .paint = paintPanelPaintOverChild,
};

fn paintPanelPaintOverChild(ctx: PaintContext) anyerror!void {
    const panel = try nimbus.Panel.create(ctx.allocator);
    defer panel.asComponent().vtable.destroy(panel.asComponent(), ctx.allocator);

    panel.setBackground(awt.Graphics.Color.rgb(0.97, 0.98, 1.00));
    panel.setBorder(.{
        .thickness = 10,
        .color = awt.Graphics.Color.rgb(0.12, 0.17, 0.24),
    });
    panel.container.setLayout(null);
    panel.asComponent().setBounds(.{ .x = 24, .y = 22, .width = 210, .height = 130 });

    const child = try nimbus.Panel.create(ctx.allocator);
    child.setBackground(awt.Graphics.Color.rgb(0.94, 0.42, 0.26));
    child.asComponent().setBounds(.{ .x = 0, .y = 0, .width = 210, .height = 130 });
    try panel.container.add(child.asComponent());

    panel.asComponent().paintAt(ctx.g);
}

pub const split_pane_divider = Scene{
    .name = "split_pane_divider",
    .width = 360,
    .height = 150,
    .paint = paintSplitPaneDivider,
};

fn paintSplitPaneDivider(ctx: PaintContext) anyerror!void {
    const left = try coloredLeaf(ctx.allocator, 60, 80, awt.Graphics.Color.rgb(0.30, 0.55, 0.88));
    const right = try coloredLeaf(ctx.allocator, 80, 80, awt.Graphics.Color.rgb(0.86, 0.52, 0.28));
    const split = try nimbus.SplitPane.create(ctx.allocator, .horizontal, left.asComponent(), right.asComponent());
    defer split.asComponent().vtable.destroy(split.asComponent(), ctx.allocator);

    split.setDividerSize(12);
    split.setDividerLocation(138);
    split.asComponent().setBounds(.{ .x = 22, .y = 24, .width = 316, .height = 102 });
    split.container.doLayout();
    split.asComponent().paintAt(ctx.g);
}

pub const scroll_pane_bars = Scene{
    .name = "scroll_pane_bars",
    .width = 300,
    .height = 220,
    .paint = paintScrollPaneBars,
};

fn paintScrollPaneBars(ctx: PaintContext) anyerror!void {
    const view = try nimbus.Panel.create(ctx.allocator);
    view.setBackground(awt.Graphics.Color.rgb(0.78, 0.90, 0.78));
    view.asComponent().setMinSize(.{ .width = 420, .height = 320 });

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const label = try nimbus.Label.create(ctx.allocator, "large view", font, awt.Graphics.Color.rgb(0.10, 0.16, 0.10));
    label.component.setBounds(.{ .x = 18, .y = 16, .width = 140, .height = 24 });
    try view.container.add(&label.component);

    const sp = try nimbus.ScrollPane.create(ctx.allocator, view.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), ctx.allocator);
    sp.setHorizontalPolicy(.always);
    sp.setVerticalPolicy(.always);
    sp.setScrollX(48);
    sp.setScrollY(36);
    sp.asComponent().setBounds(.{ .x = 24, .y = 20, .width = 236, .height = 164 });
    sp.container.doLayout();
    sp.asComponent().paintAt(ctx.g);
}

var list_cell_font: ?awt.Font = null;

const TableRow = struct {
    name: []const u8,
    kind: []const u8,
    size: []const u8,
};

const TextCell = struct {
    label: *nimbus.Label,

    fn createList(_: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
        const self = try allocator.create(TextCell);
        errdefer allocator.destroy(self);
        const font = nimbus.awt.Graphics.TextFont{ .face = list_cell_font.?, .pixel_size = 14 };
        self.* = .{
            .label = try nimbus.Label.create(allocator, "", font, awt.Graphics.Color.rgb(0.08, 0.10, 0.12)),
        };
        self.label.component.setMinSize(.{ .width = 0, .height = 22 });
        return .{
            .component = &self.label.component,
            .update = updateList,
            .destroy = destroyList,
            .user_data = self,
        };
    }

    fn updateList(user_data: *anyopaque, cell_ctx: nimbus.List.CellContext) void {
        const self: *TextCell = @ptrCast(@alignCast(user_data));
        const text_ptr: *[]const u8 = @ptrCast(@alignCast(cell_ctx.value));
        self.label.setText(text_ptr.*) catch {};
    }

    fn destroyList(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TextCell = @ptrCast(@alignCast(user_data));
        self.label.component.vtable.destroy(&self.label.component, allocator);
        allocator.destroy(self);
    }

    fn createTable(_: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.Table.Cell {
        const self = try allocator.create(TextCell);
        errdefer allocator.destroy(self);
        const font = nimbus.awt.Graphics.TextFont{ .face = list_cell_font.?, .pixel_size = 13 };
        self.* = .{
            .label = try nimbus.Label.create(allocator, "", font, awt.Graphics.Color.rgb(0.08, 0.10, 0.12)),
        };
        self.label.component.setMinSize(.{ .width = 0, .height = 20 });
        return .{
            .component = &self.label.component,
            .update = updateTable,
            .destroy = destroyTable,
            .user_data = self,
        };
    }

    fn updateTable(user_data: *anyopaque, cell_ctx: nimbus.Table.CellContext) void {
        const self: *TextCell = @ptrCast(@alignCast(user_data));
        const row: *TableRow = @ptrCast(@alignCast(cell_ctx.value));
        const text = switch (cell_ctx.col) {
            0 => row.name,
            1 => row.kind,
            else => row.size,
        };
        self.label.setText(text) catch {};
    }

    fn destroyTable(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        destroyList(user_data, allocator);
    }
};

pub const list_selection = Scene{
    .name = "list_selection",
    .width = 260,
    .height = 170,
    .paint = paintListSelection,
};

fn paintListSelection(ctx: PaintContext) anyerror!void {
    list_cell_font = ctx.font;
    var model = nimbus.List.ListModel.init(ctx.allocator);
    defer model.deinit();
    var rows = [_][]const u8{ "Alpha", "Beta selected", "Gamma", "Delta" };
    for (&rows) |*row| try model.add(@ptrCast(row));

    var factory_ctx: u8 = 0;
    const factory = nimbus.List.CellFactory{
        .create = TextCell.createList,
        .user_data = &factory_ctx,
    };
    const list = try nimbus.List.createWithModel(ctx.allocator, &model, factory);
    defer list.asComponent().vtable.destroy(list.asComponent(), ctx.allocator);
    list.setRowHeight(30);
    list.setSelected(1);
    list.asComponent().setBounds(.{ .x = 28, .y = 24, .width = 196, .height = 120 });
    list.asComponent().paintAt(ctx.g);
}

pub const table_header_grid = Scene{
    .name = "table_header_grid",
    .width = 390,
    .height = 210,
    .paint = paintTableHeaderGrid,
};

fn paintTableHeaderGrid(ctx: PaintContext) anyerror!void {
    list_cell_font = ctx.font;
    var model = nimbus.Table.Model.init(ctx.allocator);
    defer model.deinit();
    var rows = [_]TableRow{
        .{ .name = "README.md", .kind = "doc", .size = "12 KB" },
        .{ .name = "src", .kind = "dir", .size = "--" },
        .{ .name = "nimbus.zig", .kind = "zig", .size = "7 KB" },
        .{ .name = "assets", .kind = "dir", .size = "--" },
    };
    for (&rows) |*row| try model.add(@ptrCast(row));

    var factory_ctx: u8 = 0;
    const columns = [_]nimbus.Table.Column{
        .{ .title = "Name", .width = 150, .factory = .{ .create = TextCell.createTable, .user_data = &factory_ctx } },
        .{ .title = "Kind", .width = 90, .factory = .{ .create = TextCell.createTable, .user_data = &factory_ctx } },
        .{ .title = "Size", .width = 80, .factory = .{ .create = TextCell.createTable, .user_data = &factory_ctx } },
    };
    const table = try nimbus.Table.createWithModel(ctx.allocator, &model, &columns, .{ .face = ctx.font, .pixel_size = 13 });
    table.setSelected(1);
    table.setSortIndicator(0, .ascending);

    const sp = try nimbus.ScrollPane.create(ctx.allocator, table.asComponent());
    defer sp.asComponent().vtable.destroy(sp.asComponent(), ctx.allocator);
    try sp.setColumnHeaderView(try table.headerView());
    sp.setHorizontalPolicy(.always);
    sp.setVerticalPolicy(.always);
    sp.asComponent().setBounds(.{ .x = 20, .y = 22, .width = 338, .height = 148 });
    sp.container.doLayout();
    sp.asComponent().paintAt(ctx.g);
}

pub const popup_menu_open = Scene{
    .name = "popup_menu_open",
    .width = 230,
    .height = 160,
    .paint = paintPopupMenuOpen,
};

fn paintPopupMenuOpen(ctx: PaintContext) anyerror!void {
    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const color = awt.Graphics.Color.rgb(0.08, 0.10, 0.12);
    const popup = try nimbus.PopupMenu.create(ctx.allocator);
    defer popup.destroy();

    try popup.add(&(try nimbus.MenuItem.create(ctx.allocator, "Open", font, color)).component);
    try popup.add(&(try nimbus.MenuItem.create(ctx.allocator, "Save As", font, color)).component);
    try popup.addSeparator();
    try popup.add(&(try nimbus.MenuItem.create(ctx.allocator, "Close", font, color)).component);

    popup.popup_root.position = .{ .x = 38, .y = 24 };
    popup.popup_root.size = .{ .width = 136, .height = 1 };
    var cur_y: f32 = 1;
    for (popup.items.items) |item| {
        popup.popup_root.size.height += item.min_size.height;
        item.parent = &popup.popup_root;
        item.setBounds(.{ .x = 0, .y = cur_y, .width = 136, .height = item.min_size.height });
        cur_y += item.min_size.height;
    }
    popup.popup_root.size.height += 1;
    popup.popup_root.paintAt(ctx.g);
}

// ── TabbedPane scene ───────────────────────────────────────────────────────

/// TabbedPane with three tabs and the middle tab selected. The colored pages
/// make it clear which content is currently visible.
pub const tabbed_pane = Scene{
    .name = "tabbed_pane",
    .width = 420,
    .height = 220,
    .paint = paintTabbedPane,
};

fn tabPage(
    allocator: std.mem.Allocator,
    font: nimbus.awt.Graphics.TextFont,
    title: []const u8,
    detail: []const u8,
    color: awt.Graphics.Color,
) !*nimbus.Panel {
    const p = try nimbus.Panel.create(allocator);
    p.setBackground(color);
    p.asContainer().setLayout(null);

    const label = try nimbus.Label.create(allocator, title, font, awt.Graphics.Color.rgb(0.10, 0.10, 0.10));
    label.component.setBounds(.{ .x = 18, .y = 18, .width = 260, .height = 24 });
    const body = try nimbus.Label.create(allocator, detail, font, awt.Graphics.Color.rgb(0.10, 0.10, 0.10));
    body.component.setBounds(.{ .x = 18, .y = 52, .width = 340, .height = 24 });

    try p.asContainer().add(&label.component);
    try p.asContainer().add(&body.component);
    return p;
}

fn paintTabbedPane(ctx: PaintContext) anyerror!void {
    var setup = try Setup.init(ctx);
    defer setup.deinit();
    setup.container.setLayout(nimbus.BorderLayout.get());

    const font = nimbus.awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const tabs = try nimbus.TabbedPane.create(ctx.allocator, font);
    try tabs.addTab(
        "Overview",
        &(try tabPage(ctx.allocator, font, "Overview", "General account information.", awt.Graphics.Color.rgb(0.86, 0.93, 0.99))).container.component,
    );
    try tabs.addTab(
        "Activity",
        &(try tabPage(ctx.allocator, font, "Activity", "Second tab is selected.", awt.Graphics.Color.rgb(0.90, 0.96, 0.88))).container.component,
    );
    try tabs.addTab(
        "Settings",
        &(try tabPage(ctx.allocator, font, "Settings", "Preferences and toggles.", awt.Graphics.Color.rgb(0.98, 0.91, 0.86))).container.component,
    );
    tabs.setSelectedIndex(1);

    try nimbus.BorderLayout.add(setup.container, .center, tabs.asComponent());
    setup.paint();
}
