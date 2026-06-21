const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

fn quietLog(level: awt.LogLevel, category: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level < awt.c.nmLogLevelWarn) return;
    const tag: []const u8 = if (level == awt.c.nmLogLevelWarn) "WARN" else "ERROR";
    const cat: [*:0]const u8 = category;
    const msg: [*:0]const u8 = message;
    std.debug.print("[{s}] [{s}] {s}\n", .{ tag, std.mem.span(cat), std.mem.span(msg) });
}

fn newApp() !*nimbus.Application {
    awt.setLogCallback(quietLog, null);
    return nimbus.Application.initHeadless(std.testing.allocator, std.testing.io) catch
        return error.SkipZigTest;
}

test "widgets use default Look" {
    const app = try newApp();
    defer app.deinit();

    const text_font = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };

    const button = try nimbus.Button.create(std.testing.allocator, "x", text_font, nimbus.Theme.default.text);
    defer button.component.vtable.destroy(&button.component, std.testing.allocator);

    const container = try nimbus.Container.create(std.testing.allocator);
    defer container.component.vtable.destroy(&container.component, std.testing.allocator);

    const panel = try nimbus.Panel.create(std.testing.allocator);
    defer panel.container.component.vtable.destroy(&panel.container.component, std.testing.allocator);

    const tabbed = try nimbus.TabbedPane.create(std.testing.allocator, text_font);
    defer tabbed.container.component.vtable.destroy(&tabbed.container.component, std.testing.allocator);

    const label = try nimbus.Label.create(std.testing.allocator, "x", text_font, nimbus.Theme.default.text);
    defer label.component.vtable.destroy(&label.component, std.testing.allocator);

    const checkbox = try nimbus.CheckBox.create(std.testing.allocator, "x", text_font, nimbus.Theme.default.text);
    defer checkbox.component.vtable.destroy(&checkbox.component, std.testing.allocator);

    const menu = try nimbus.Menu.create(std.testing.allocator, "File", text_font, nimbus.Theme.default.text);
    defer menu.component.vtable.destroy(&menu.component, std.testing.allocator);

    const popup = try nimbus.PopupMenu.create(std.testing.allocator);
    defer popup.destroy();
    try std.testing.expect(button.component.ui.vtable == &nimbus.Button.look_vtable);
    try std.testing.expect(container.component.ui.vtable == &nimbus.Container.look_vtable);
    try std.testing.expect(panel.container.component.ui.vtable == &nimbus.Panel.look_vtable);
    try std.testing.expect(tabbed.container.component.ui.vtable == &nimbus.TabbedPane.look_vtable);
    try std.testing.expect(label.component.ui.vtable == &nimbus.Label.look_vtable);
    try std.testing.expect(checkbox.component.ui.vtable == &nimbus.CheckBox.look_vtable);
    try std.testing.expect(menu.component.ui.vtable == &nimbus.Menu.look_vtable);
    try std.testing.expect(menu.popup_root.ui.vtable != &nimbus.Component.base_look_vtable);
    try std.testing.expect(popup.popup_root.ui.vtable != &nimbus.Component.base_look_vtable);
}

const PaintLog = struct {
    entries: [8]u8 = undefined,
    len: usize = 0,

    fn append(self: *PaintLog, marker: u8) void {
        self.entries[self.len] = marker;
        self.len += 1;
    }

    fn slice(self: *const PaintLog) []const u8 {
        return self.entries[0..self.len];
    }
};

const RecordingLookContext = struct {
    log: *PaintLog,
    paint_marker: u8,
    over_marker: u8 = 0,
};

const recording_look_vtable = nimbus.Component.LookVTable{
    .paint = recordingPaint,
    .paintOver = recordingPaintOver,
    .measureMinSize = recordingMeasureMinSize,
};

fn recordingPaint(_: *nimbus.Component, ctx: *anyopaque, _: *awt.Graphics) void {
    const rec: *RecordingLookContext = @ptrCast(@alignCast(ctx));
    rec.log.append(rec.paint_marker);
}

fn recordingPaintOver(_: *nimbus.Component, ctx: *anyopaque, _: *awt.Graphics) void {
    const rec: *RecordingLookContext = @ptrCast(@alignCast(ctx));
    if (rec.over_marker != 0) rec.log.append(rec.over_marker);
}

fn recordingMeasureMinSize(_: *nimbus.Component, _: *anyopaque) nimbus.Component.Size {
    return .{ .width = 0, .height = 0 };
}

fn initTestTextFont() !awt.Graphics.TextFont {
    awt.setLogCallback(quietLog, null);
    try awt.init();
    errdefer awt.deinit();
    return .{
        .face = try awt.Font.init(nimbus.noto.noto_sans_jp_regular, 0),
        .pixel_size = 14,
    };
}

fn deinitTestTextFont(font: *awt.Graphics.TextFont) void {
    font.face.deinit();
    awt.deinit();
}

const ComponentSnapshot = struct {
    component: *nimbus.Component,
    vtable: *const nimbus.Component.LookVTable,
    ctx: *anyopaque,
    min_size: nimbus.Component.Size,
};

fn collectSnapshots(out: *std.ArrayList(ComponentSnapshot), node: *nimbus.Component) !void {
    try out.append(std.testing.allocator, .{
        .component = node,
        .vtable = node.ui.vtable,
        .ctx = node.ui.ctx,
        .min_size = node.min_size,
    });
    const child_count = node.automationChildCount();
    for (0..child_count) |i| {
        try collectSnapshots(out, node.automationChildAt(i));
    }
    if (node.detached_look_roots) |roots| {
        const root_count = roots.count(node);
        for (0..root_count) |i| {
            try collectSnapshots(out, roots.at(node, i));
        }
    }
}

fn expectSizeBitEqual(expected: nimbus.Component.Size, actual: nimbus.Component.Size) !void {
    try std.testing.expectEqual(@as(u32, @bitCast(expected.width)), @as(u32, @bitCast(actual.width)));
    try std.testing.expectEqual(@as(u32, @bitCast(expected.height)), @as(u32, @bitCast(actual.height)));
}

fn expectSnapshotsUnchanged(snapshots: []const ComponentSnapshot) !void {
    for (snapshots) |snapshot| {
        try std.testing.expect(snapshot.component.ui.vtable == snapshot.vtable);
        try std.testing.expect(snapshot.component.ui.ctx == snapshot.ctx);
        try expectSizeBitEqual(snapshot.min_size, snapshot.component.min_size);
    }
}

const identity_laf = [_]nimbus.laf.RemapEntry{
    .{ .from = &nimbus.Button.look_vtable, .to = .{ .vtable = &nimbus.Button.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.CheckBox.look_vtable, .to = .{ .vtable = &nimbus.CheckBox.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.CheckBoxMenuItem.look_vtable, .to = .{ .vtable = &nimbus.CheckBoxMenuItem.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.ComboBox.look_vtable, .to = .{ .vtable = &nimbus.ComboBox.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Container.look_vtable, .to = .{ .vtable = &nimbus.Container.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Label.look_vtable, .to = .{ .vtable = &nimbus.Label.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.List.look_vtable, .to = .{ .vtable = &nimbus.List.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Menu.look_vtable, .to = .{ .vtable = &nimbus.Menu.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.MenuBar.look_vtable, .to = .{ .vtable = &nimbus.MenuBar.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.MenuItem.look_vtable, .to = .{ .vtable = &nimbus.MenuItem.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.MenuSeparator.look_vtable, .to = .{ .vtable = &nimbus.MenuSeparator.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Panel.look_vtable, .to = .{ .vtable = &nimbus.Panel.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.RadioButton.look_vtable, .to = .{ .vtable = &nimbus.RadioButton.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.RadioButtonMenuItem.look_vtable, .to = .{ .vtable = &nimbus.RadioButtonMenuItem.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.ScrollBar.look_vtable, .to = .{ .vtable = &nimbus.ScrollBar.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.ScrollPane.look_vtable, .to = .{ .vtable = &nimbus.ScrollPane.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Slider.look_vtable, .to = .{ .vtable = &nimbus.Slider.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.SplitPane.look_vtable, .to = .{ .vtable = &nimbus.SplitPane.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.TabbedPane.look_vtable, .to = .{ .vtable = &nimbus.TabbedPane.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Table.look_vtable, .to = .{ .vtable = &nimbus.Table.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.TextArea.look_vtable, .to = .{ .vtable = &nimbus.TextArea.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.TextField.look_vtable, .to = .{ .vtable = &nimbus.TextField.look_vtable, .ctx = &nimbus.Component.default_look_context } },
    .{ .from = &nimbus.Window.look_vtable, .to = .{ .vtable = &nimbus.Window.look_vtable, .ctx = &nimbus.Component.default_look_context } },
};

test "applyLook with FlatLaf identity table preserves component state" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    const button = try nimbus.Button.create(allocator, "Apply", text_font, nimbus.Theme.default.text);
    try root.add(&button.component);

    const panel = try nimbus.Panel.create(allocator);
    try root.add(panel.asComponent());

    const label = try nimbus.Label.create(allocator, "Label", text_font, nimbus.Theme.default.text);
    try panel.asContainer().add(&label.component);

    const checkbox = try nimbus.CheckBox.create(allocator, "Check", text_font, nimbus.Theme.default.text);
    try root.add(&checkbox.component);

    const menu_bar = try nimbus.MenuBar.create(allocator, text_font, nimbus.Theme.default.text);
    try root.add(&menu_bar.component);
    const file_menu = try nimbus.Menu.create(allocator, "File", text_font, nimbus.Theme.default.text);
    try menu_bar.add(file_menu);
    const open_item = try nimbus.MenuItem.create(allocator, "Open", text_font, nimbus.Theme.default.text);
    try file_menu.add(&open_item.component);

    var snapshots: std.ArrayList(ComponentSnapshot) = .empty;
    defer snapshots.deinit(allocator);
    try collectSnapshots(&snapshots, &root.component);

    nimbus.laf.applyLook(&root.component, &identity_laf);
    try expectSnapshotsUnchanged(snapshots.items);

    nimbus.laf.applyLook(&root.component, &identity_laf);
    try expectSnapshotsUnchanged(snapshots.items);
}

const FakeLookContext = struct {
    size: nimbus.Component.Size,
};

const fake_button_look = nimbus.Component.LookVTable{
    .paint = fakePaint,
    .paintOver = fakePaintOver,
    .measureMinSize = fakeMeasureMinSize,
};

const fake_panel_look = nimbus.Component.LookVTable{
    .paint = fakePaint,
    .paintOver = fakePaintOver,
    .measureMinSize = fakeMeasureMinSize,
};

const fake_menu_bar_look = nimbus.Component.LookVTable{
    .paint = fakePaint,
    .paintOver = fakePaintOver,
    .measureMinSize = fakeMeasureMinSize,
};

const fake_menu_look = nimbus.Component.LookVTable{
    .paint = fakePaint,
    .paintOver = fakePaintOver,
    .measureMinSize = fakeMeasureMinSize,
};

const fake_menu_item_look = nimbus.Component.LookVTable{
    .paint = fakePaint,
    .paintOver = fakePaintOver,
    .measureMinSize = fakeMeasureMinSize,
};

fn fakePaint(_: *nimbus.Component, _: *anyopaque, _: *awt.Graphics) void {}

fn fakePaintOver(_: *nimbus.Component, _: *anyopaque, _: *awt.Graphics) void {}

fn fakeMeasureMinSize(_: *nimbus.Component, ctx: *anyopaque) nimbus.Component.Size {
    const fake: *FakeLookContext = @ptrCast(@alignCast(ctx));
    return fake.size;
}

test "applyLook remaps partial fake LAF and invalidates container size cache" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    const button = try nimbus.Button.create(allocator, "Button", text_font, nimbus.Theme.default.text);
    try root.add(&button.component);
    const original_button_min = button.component.min_size;

    const panel = try nimbus.Panel.create(allocator);
    const original_panel_min = panel.container.component.min_size;
    try root.add(panel.asComponent());

    const label = try nimbus.Label.create(allocator, "Label", text_font, nimbus.Theme.default.text);
    const original_label_min = label.component.min_size;
    try root.add(&label.component);

    const plain_container = try nimbus.Container.create(allocator);
    plain_container.setLayout(nimbus.BoxLayout.horizontal());
    try root.add(&plain_container.component);

    const menu_bar = try nimbus.MenuBar.create(allocator, text_font, nimbus.Theme.default.text);
    const original_menu_bar_min = menu_bar.component.min_size;
    try root.add(&menu_bar.component);

    const file_menu = try nimbus.Menu.create(allocator, "File", text_font, nimbus.Theme.default.text);
    try menu_bar.add(file_menu);
    const open_item = try nimbus.MenuItem.create(allocator, "Open", text_font, nimbus.Theme.default.text);
    try file_menu.add(&open_item.component);

    _ = root.getMinSize();
    _ = plain_container.getMinSize();
    try std.testing.expect(root.min_cache != null);
    try std.testing.expect(plain_container.min_cache != null);

    var fake_button_ctx = FakeLookContext{ .size = .{ .width = 123, .height = 45 } };
    var fake_panel_ctx = FakeLookContext{ .size = .{ .width = 67, .height = 89 } };
    var fake_menu_bar_ctx = FakeLookContext{ .size = .{ .width = 7, .height = 8 } };
    var fake_menu_ctx = FakeLookContext{ .size = .{ .width = 222, .height = 33 } };
    var fake_menu_item_ctx = FakeLookContext{ .size = .{ .width = 111, .height = 22 } };
    const table = [_]nimbus.laf.RemapEntry{
        .{ .from = &nimbus.Button.look_vtable, .to = .{ .vtable = &fake_button_look, .ctx = &fake_button_ctx } },
        .{ .from = &nimbus.Panel.look_vtable, .to = .{ .vtable = &fake_panel_look, .ctx = &fake_panel_ctx } },
        .{ .from = &nimbus.MenuBar.look_vtable, .to = .{ .vtable = &fake_menu_bar_look, .ctx = &fake_menu_bar_ctx } },
        .{ .from = &nimbus.Menu.look_vtable, .to = .{ .vtable = &fake_menu_look, .ctx = &fake_menu_ctx } },
        .{ .from = &nimbus.MenuItem.look_vtable, .to = .{ .vtable = &fake_menu_item_look, .ctx = &fake_menu_item_ctx } },
    };

    nimbus.laf.applyLook(&root.component, &table);

    try std.testing.expect(button.component.ui.vtable == &fake_button_look);
    try std.testing.expect(button.component.ui.ctx == @as(*anyopaque, @ptrCast(&fake_button_ctx)));
    try expectSizeBitEqual(fake_button_ctx.size, button.component.min_size);
    try std.testing.expect(!nimbus.Component.Size.eql(original_button_min, button.component.min_size));

    try std.testing.expect(panel.container.component.ui.vtable == &fake_panel_look);
    try std.testing.expect(panel.container.component.ui.ctx == @as(*anyopaque, @ptrCast(&fake_panel_ctx)));
    try expectSizeBitEqual(original_panel_min, panel.container.component.min_size);

    try std.testing.expect(label.component.ui.vtable == &nimbus.Label.look_vtable);
    try std.testing.expect(label.component.ui.ctx == @as(*anyopaque, @ptrCast(&nimbus.Component.default_look_context)));
    try expectSizeBitEqual(original_label_min, label.component.min_size);

    try std.testing.expect(plain_container.component.ui.vtable == &nimbus.Container.look_vtable);
    try std.testing.expect(root.min_cache == null);
    try std.testing.expect(plain_container.min_cache == null);

    try std.testing.expect(menu_bar.component.ui.vtable == &fake_menu_bar_look);
    try std.testing.expect(menu_bar.component.ui.ctx == @as(*anyopaque, @ptrCast(&fake_menu_bar_ctx)));
    try expectSizeBitEqual(original_menu_bar_min, menu_bar.component.min_size);
    try std.testing.expect(file_menu.component.ui.vtable == &fake_menu_look);
    try std.testing.expect(file_menu.component.ui.ctx == @as(*anyopaque, @ptrCast(&fake_menu_ctx)));
    try expectSizeBitEqual(fake_menu_ctx.size, file_menu.component.min_size);
    try std.testing.expect(open_item.component.ui.vtable == &fake_menu_item_look);
    try std.testing.expect(open_item.component.ui.ctx == @as(*anyopaque, @ptrCast(&fake_menu_item_ctx)));
    try expectSizeBitEqual(fake_menu_item_ctx.size, open_item.component.min_size);

    const popup = try nimbus.PopupMenu.create(allocator);
    defer popup.destroy();
    const popup_item = try nimbus.MenuItem.create(allocator, "Standalone", text_font, nimbus.Theme.default.text);
    try popup.add(&popup_item.component);

    nimbus.laf.applyLook(&popup.popup_root, &table);
    try std.testing.expect(popup_item.component.ui.vtable == &fake_menu_item_look);
    try std.testing.expect(popup_item.component.ui.ctx == @as(*anyopaque, @ptrCast(&fake_menu_item_ctx)));
    try expectSizeBitEqual(fake_menu_item_ctx.size, popup_item.component.min_size);
}

test "paintAt dispatches Look paint, children, then paintOver" {
    const allocator = std.testing.allocator;
    var log = PaintLog{};

    const parent = try nimbus.Container.create(allocator);
    defer parent.component.vtable.destroy(&parent.component, allocator);
    const child1 = try nimbus.Container.create(allocator);
    const child2 = try nimbus.Container.create(allocator);

    var parent_ctx = RecordingLookContext{ .log = &log, .paint_marker = 'P', .over_marker = 'O' };
    var child1_ctx = RecordingLookContext{ .log = &log, .paint_marker = '1' };
    var child2_ctx = RecordingLookContext{ .log = &log, .paint_marker = '2' };
    parent.component.ui = .{ .vtable = &recording_look_vtable, .ctx = &parent_ctx };
    child1.component.ui = .{ .vtable = &recording_look_vtable, .ctx = &child1_ctx };
    child2.component.ui = .{ .vtable = &recording_look_vtable, .ctx = &child2_ctx };

    parent.component.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 80 });
    child1.component.setBounds(.{ .x = 0, .y = 0, .width = 40, .height = 30 });
    child2.component.setBounds(.{ .x = 40, .y = 0, .width = 40, .height = 30 });
    try parent.add(&child1.component);
    try parent.add(&child2.component);

    var g = awt.Graphics{
        .cb = undefined,
        .ctx = undefined,
        .window_w = 100,
        .window_h = 80,
        .fb_w = 100,
        .fb_h = 80,
        .origin_x = 0,
        .origin_y = 0,
        .clip_rect = .{ .x = 0, .y = 0, .width = 100, .height = 80 },
        .current_color = awt.Graphics.Color.rgb(0, 0, 0),
        .current_font = null,
    };

    parent.component.paintAt(&g);
    try std.testing.expectEqualStrings("P12O", log.slice());
}
