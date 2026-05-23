//! Snapshot test scenes. Each `Scene` is a deterministic paint sequence
//! that the snapshot test runner renders into an offscreen render target
//! and compares against a fixture PNG. The same scenes are usable from
//! `examples/snapshot` for visual inspection.

const std = @import("std");
const awt = @import("awt");
const framework = @import("nimbus");

// Re-export the framework's bundled Noto Sans JP so snapshot tests /
// inspector binaries can build Labels / Buttons without each one embedding
// its own copy.
pub const default_font_bytes = framework.noto.noto_sans_jp_regular;

pub const PaintContext = struct {
    g:         *awt.Graphics,
    allocator: std.mem.Allocator,
    font:      awt.Font,
    width:     i32,
    height:    i32,
};

pub const Scene = struct {
    /// Stable identifier; used as the fixture file basename.
    name: []const u8,
    /// Render target size (pixels).
    width: i32,
    height: i32,
    /// Clear color applied before `paint`.
    clear: [4]f32 = .{ 0.10, 0.10, 0.15, 1.0 },
    /// `paint` may use `ctx.allocator` / `ctx.font` for framework widgets,
    /// or just `ctx.g` for raw awt drawing.
    paint: *const fn (ctx: PaintContext) anyerror!void,
};

// ── basic shapes (raw awt) ───────────────────────────────────────────────

pub const basic_shapes = Scene{
    .name = "basic_shapes",
    .width = 400,
    .height = 300,
    .paint = paintBasicShapes,
};

fn paintBasicShapes(ctx: PaintContext) anyerror!void {
    const g = ctx.g;
    g.setColor(awt.Graphics.Color.rgb(0.95, 0.30, 0.30));
    g.fillRect(.{ .x = 20, .y = 20, .width = 100, .height = 60 });
    g.setColor(awt.Graphics.Color.rgb(0.30, 0.95, 0.50));
    g.fillRect(.{ .x = 140, .y = 20, .width = 100, .height = 60 });

    g.setColor(awt.Graphics.Color.rgb(0.30, 0.60, 0.95));
    g.fillRoundRect(.{ .x = 20, .y = 110, .width = 100, .height = 100 }, 20);
    g.setColor(awt.Graphics.Color.rgb(0.95, 0.85, 0.30));
    g.fillCircle(.{ .x = 140, .y = 110, .width = 100, .height = 100 });

    g.setColor(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));
    g.drawRect(.{ .x = 260, .y = 20, .width = 120, .height = 90 });
    g.drawRoundRect(.{ .x = 260, .y = 130, .width = 120, .height = 80 }, 16);
}

// ── framework layout scenes ──────────────────────────────────────────────

/// Helper: build a root Container, lay it out at full ctx size, paint, free.
const FrameworkSetup = struct {
    container: *framework.Container,
    ctx:       PaintContext,

    fn init(ctx: PaintContext) !FrameworkSetup {
        const cont = try framework.Container.create(ctx.allocator);
        return .{ .container = cont, .ctx = ctx };
    }

    fn paint(self: *FrameworkSetup) void {
        // Apply root bounds (window-like) and run layout, then paint via vtable.
        self.container.setBounds(.{
            .x = 0, .y = 0,
            .width = @floatFromInt(self.ctx.width),
            .height = @floatFromInt(self.ctx.height),
        });
        // Paint children directly (skip the container's own paint translate).
        for (self.container.children.items) |elem| {
            elem.component.paintAt(self.ctx.g);
        }
    }

    fn deinit(self: *FrameworkSetup) void {
        // Container.vtable.destroy frees the container and recursively its children.
        self.container.component.vtable.destroy(&self.container.component, self.ctx.allocator);
    }
};

// horizontal box: 3 buttons in a row, no grow → each takes its min width
pub const layout_horizontal_buttons = Scene{
    .name = "layout_horizontal_buttons",
    .width = 500,
    .height = 80,
    .paint = paintHorizontalButtons,
};

fn paintHorizontalButtons(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    setup.container.setLayout(framework.BoxLayout.horizontal());
    const font = awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const color = awt.Graphics.Color.rgb(0, 0, 0);

    inline for ([_][]const u8{ "Apple", "Banana", "Cherry" }) |label_text| {
        const b = try framework.Button.create(ctx.allocator, label_text, font, color);
        try setup.container.add(&b.component);
    }

    setup.paint();
}

// vertical box: header / body(grow) / footer
pub const layout_vertical_grow = Scene{
    .name = "layout_vertical_grow",
    .width = 300,
    .height = 400,
    .paint = paintVerticalGrow,
};

fn paintVerticalGrow(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    setup.container.setLayout(framework.BoxLayout.vertical());

    const header = try framework.Panel.create(ctx.allocator);
    header.setBackground(awt.Graphics.Color.rgb(0.6, 0.3, 0.3));
    header.container.component.min_size = .{ .width = 0, .height = 40 };
    header.container.component.max_size = .{ .width = std.math.inf(f32), .height = 40 };
    try setup.container.add(&header.container.component);

    const body = try framework.Panel.create(ctx.allocator);
    body.setBackground(awt.Graphics.Color.rgb(0.3, 0.4, 0.6));
    body.container.component.setGrowY(1);
    try setup.container.add(&body.container.component);

    const footer = try framework.Panel.create(ctx.allocator);
    footer.setBackground(awt.Graphics.Color.rgb(0.3, 0.6, 0.4));
    footer.container.component.min_size = .{ .width = 0, .height = 30 };
    footer.container.component.max_size = .{ .width = std.math.inf(f32), .height = 30 };
    try setup.container.add(&footer.container.component);

    setup.paint();
}

// right alignment: filler + 2 buttons
pub const layout_right_aligned = Scene{
    .name = "layout_right_aligned",
    .width = 500,
    .height = 60,
    .paint = paintRightAligned,
};

fn paintRightAligned(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    setup.container.setLayout(framework.BoxLayout.horizontal());
    const font = awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const color = awt.Graphics.Color.rgb(0, 0, 0);

    const f = try framework.Panel.create(ctx.allocator);
    f.container.component.setGrowX(1);
    try setup.container.add(&f.container.component);

    const ok = try framework.Button.create(ctx.allocator, "OK", font, color);
    try setup.container.add(&ok.component);

    const cancel = try framework.Button.create(ctx.allocator, "Cancel", font, color);
    try setup.container.add(&cancel.component);

    setup.paint();
}

// center alignment: filler + content + filler
pub const layout_centered = Scene{
    .name = "layout_centered",
    .width = 500,
    .height = 60,
    .paint = paintCentered,
};

fn paintCentered(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    setup.container.setLayout(framework.BoxLayout.horizontal());
    const font = awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const color = awt.Graphics.Color.rgb(0, 0, 0);

    const left = try framework.Panel.create(ctx.allocator);
    left.container.component.setGrowX(1);
    try setup.container.add(&left.container.component);

    const content = try framework.Button.create(ctx.allocator, "Centered", font, color);
    try setup.container.add(&content.component);

    const right = try framework.Panel.create(ctx.allocator);
    right.container.component.setGrowX(1);
    try setup.container.add(&right.container.component);

    setup.paint();
}

// panel with background + border
pub const layout_panel_decoration = Scene{
    .name = "layout_panel_decoration",
    .width = 300,
    .height = 200,
    .paint = paintPanelDecoration,
};

fn paintPanelDecoration(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    const panel = try framework.Panel.create(ctx.allocator);
    panel.setBackground(awt.Graphics.Color.rgb(1, 1, 1));
    panel.setBorder(.{
        .thickness = 2,
        .color = awt.Graphics.Color.rgb(0.3, 0.3, 0.4),
    });
    panel.container.component.setBounds(.{ .x = 30, .y = 20, .width = 240, .height = 160 });
    try setup.container.add(&panel.container.component);

    // No layout on root container, manual placement of one panel.
    setup.container.setBounds(.{
        .x = 0, .y = 0,
        .width = @floatFromInt(ctx.width),
        .height = @floatFromInt(ctx.height),
    });
    // setBounds calls doLayout which is a no-op without a layout manager,
    // so we override the panel's bounds set above with explicit re-set.
    panel.container.component.setBounds(.{ .x = 30, .y = 20, .width = 240, .height = 160 });

    for (setup.container.children.items) |elem| {
        elem.component.paintAt(ctx.g);
    }
}

// border layout: toolbar / status / sidebar / content shell
pub const layout_border_shell = Scene{
    .name = "layout_border_shell",
    .width = 500,
    .height = 300,
    .paint = paintBorderShell,
};

fn paintBorderShell(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    setup.container.setLayout(framework.BorderLayout.get());

    const toolbar = try framework.Panel.create(ctx.allocator);
    toolbar.setBackground(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));
    toolbar.container.component.min_size = .{ .width = 0, .height = 32 };

    const status = try framework.Panel.create(ctx.allocator);
    status.setBackground(awt.Graphics.Color.rgb(0.4, 0.4, 0.5));
    status.container.component.min_size = .{ .width = 0, .height = 24 };

    const sidebar = try framework.Panel.create(ctx.allocator);
    sidebar.setBackground(awt.Graphics.Color.rgb(0.92, 0.92, 0.94));
    sidebar.container.component.min_size = .{ .width = 120, .height = 0 };

    const content = try framework.Panel.create(ctx.allocator);
    content.setBackground(awt.Graphics.Color.rgb(1, 1, 1));

    try framework.BorderLayout.add(setup.container, .north,  &toolbar.container.component);
    try framework.BorderLayout.add(setup.container, .south,  &status.container.component);
    try framework.BorderLayout.add(setup.container, .west,   &sidebar.container.component);
    try framework.BorderLayout.add(setup.container, .center, &content.container.component);

    setup.paint();
}

// nested: vertical box of (horizontal toolbar + grow body + footer)
pub const layout_nested = Scene{
    .name = "layout_nested",
    .width = 500,
    .height = 300,
    .paint = paintNested,
};

fn paintNested(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    setup.container.setLayout(framework.BoxLayout.vertical());
    const font = awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const color = awt.Graphics.Color.rgb(0, 0, 0);

    // Toolbar: horizontal box with 2 buttons + filler
    const toolbar = try framework.Panel.create(ctx.allocator);
    toolbar.setBackground(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));
    toolbar.container.setLayout(framework.BoxLayout.horizontal());
    toolbar.container.component.min_size = .{ .width = 0, .height = 40 };
    toolbar.container.component.max_size = .{ .width = std.math.inf(f32), .height = 40 };
    {
        const b_save = try framework.Button.create(ctx.allocator, "Save", font, color);
        const b_open = try framework.Button.create(ctx.allocator, "Open", font, color);
        const tb_filler = try framework.Panel.create(ctx.allocator);
        tb_filler.container.component.setGrowX(1);
        try toolbar.container.add(&b_save.component);
        try toolbar.container.add(&b_open.component);
        try toolbar.container.add(&tb_filler.container.component);
    }
    try setup.container.add(&toolbar.container.component);

    // Body: grow=1
    const body = try framework.Panel.create(ctx.allocator);
    body.setBackground(awt.Graphics.Color.rgb(0.95, 0.95, 0.97));
    body.container.component.setGrowY(1);
    try setup.container.add(&body.container.component);

    // Footer
    const footer = try framework.Panel.create(ctx.allocator);
    footer.setBackground(awt.Graphics.Color.rgb(0.4, 0.4, 0.5));
    footer.container.component.min_size = .{ .width = 0, .height = 24 };
    footer.container.component.max_size = .{ .width = std.math.inf(f32), .height = 24 };
    try setup.container.add(&footer.container.component);

    setup.paint();
}

/// All scenes the snapshot runner should cover. Add entries here when
/// introducing a new scene; the runner generates one test per entry.
// menu bar (closed) on top of a content panel
pub const menu_bar_closed = Scene{
    .name = "menu_bar_closed",
    .width = 500,
    .height = 80,
    .paint = paintMenuBarClosed,
};

fn paintMenuBarClosed(ctx: PaintContext) anyerror!void {
    var setup = try FrameworkSetup.init(ctx);
    defer setup.deinit();

    const font = awt.Graphics.TextFont{ .face = ctx.font, .pixel_size = 14 };
    const color = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

    const bar = try framework.MenuBar.create(ctx.allocator, font, color);
    // Build 3 menus (closed, just labels visible).
    inline for ([_][]const u8{ "File", "Edit", "Help" }) |label_text| {
        const menu = try framework.Menu.create(ctx.allocator, label_text, font, color);
        try bar.add(menu);
    }

    // Lay out the bar at top, full width.
    bar.component.setBounds(.{
        .x = 0, .y = 0,
        .width = @floatFromInt(ctx.width),
        .height = bar.component.min_size.height,
    });

    bar.component.paintAt(ctx.g);

    // Cleanup (no overlays since no menu opened).
    bar.component.vtable.destroy(&bar.component, ctx.allocator);
}

pub const all = [_]Scene{
    basic_shapes,
    layout_horizontal_buttons,
    layout_vertical_grow,
    layout_right_aligned,
    layout_centered,
    layout_panel_decoration,
    layout_nested,
    layout_border_shell,
    menu_bar_closed,
};
