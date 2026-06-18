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
