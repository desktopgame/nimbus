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
        .face = try awt.Font.init(std.testing.allocator, nimbus.noto.noto_sans_jp_regular, 0),
        .pixel_size = 14,
    };
}

fn deinitTestTextFont(font: *awt.Graphics.TextFont) void {
    font.face.deinit();
    awt.deinit();
}

const FocusStub = struct {
    owner: ?*nimbus.Component = null,

    fn request(_: *anyopaque, _: ?*nimbus.Component) void {}

    fn current(user_data: *anyopaque) ?*nimbus.Component {
        const self: *FocusStub = @ptrCast(@alignCast(user_data));
        return self.owner;
    }

    fn controller(self: *FocusStub) nimbus.Component.FocusController {
        return .{
            .user_data = @ptrCast(self),
            .request_focus_for = request,
            .current_owner = current,
        };
    }
};

const TestTextCell = struct {
    label: *nimbus.Label,

    fn createList(_: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
        const self = try allocator.create(TestTextCell);
        errdefer allocator.destroy(self);
        self.* = .{
            .label = try nimbus.Label.create(
                allocator,
                "",
                test_text_font.?,
                nimbus.Theme.default.text,
            ),
        };
        return .{
            .component = &self.label.component,
            .update = updateList,
            .destroy = destroy,
            .user_data = self,
        };
    }

    fn createTable(_: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.Table.Cell {
        const self = try allocator.create(TestTextCell);
        errdefer allocator.destroy(self);
        self.* = .{
            .label = try nimbus.Label.create(
                allocator,
                "",
                test_text_font.?,
                nimbus.Theme.default.text,
            ),
        };
        return .{
            .component = &self.label.component,
            .update = updateTable,
            .destroy = destroy,
            .user_data = self,
        };
    }

    fn updateList(user_data: *anyopaque, cell_ctx: nimbus.List.CellContext) void {
        const self: *TestTextCell = @ptrCast(@alignCast(user_data));
        const text: *[]const u8 = @ptrCast(@alignCast(cell_ctx.value));
        self.label.setText(text.*) catch {};
    }

    fn updateTable(user_data: *anyopaque, cell_ctx: nimbus.Table.CellContext) void {
        const self: *TestTextCell = @ptrCast(@alignCast(user_data));
        const text: *[]const u8 = @ptrCast(@alignCast(cell_ctx.value));
        self.label.setText(text.*) catch {};
    }

    fn destroy(user_data: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TestTextCell = @ptrCast(@alignCast(user_data));
        self.label.component.vtable.destroy(&self.label.component, allocator);
        allocator.destroy(self);
    }
};

var test_text_font: ?awt.Graphics.TextFont = null;

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

const bare_component_vtable = nimbus.Component.VTable{
    .install = bareInstall,
    .uninstall = bareUninstall,
    .processEvent = bareProcessEvent,
    .destroy = bareDestroy,
};

fn bareInstall(_: *nimbus.Component) !void {}
fn bareUninstall(_: *nimbus.Component) void {}
fn bareProcessEvent(_: *nimbus.Component, _: *nimbus.Component.Event) void {}
fn bareDestroy(_: *nimbus.Component, _: std.mem.Allocator) void {}

test "applyLook preserves explicit leaf min size and remeasures derived leaves" {
    const allocator = std.testing.allocator;
    var explicit_leaf = nimbus.Component.init(allocator, &bare_component_vtable);
    defer explicit_leaf.deinit();
    var implicit_leaf = nimbus.Component.init(allocator, &bare_component_vtable);
    defer implicit_leaf.deinit();
    var derived_leaf = nimbus.Component.init(allocator, &bare_component_vtable);
    defer derived_leaf.deinit();

    const explicit_min = nimbus.Component.Size{ .width = 11, .height = 180 };
    explicit_leaf.setMinSize(explicit_min);
    try std.testing.expect(explicit_leaf.min_size_explicit);

    implicit_leaf.min_size = .{ .width = 1, .height = 2 };

    const derived_min = nimbus.Component.Size{ .width = 21, .height = 22 };
    derived_leaf.setMinSizeDerived(derived_min);
    try std.testing.expect(!derived_leaf.min_size_explicit);

    var fake_ctx = FakeLookContext{ .size = .{ .width = 33, .height = 44 } };
    const table = [_]nimbus.laf.RemapEntry{
        .{
            .from = &nimbus.Component.base_look_vtable,
            .to = .{ .vtable = &fake_button_look, .ctx = &fake_ctx },
        },
    };

    nimbus.laf.applyLook(&explicit_leaf, &table);
    try std.testing.expect(explicit_leaf.ui.vtable == &fake_button_look);
    try expectSizeBitEqual(explicit_min, explicit_leaf.min_size);

    nimbus.laf.applyLook(&implicit_leaf, &table);
    try expectSizeBitEqual(fake_ctx.size, implicit_leaf.min_size);

    nimbus.laf.applyLook(&derived_leaf, &table);
    try expectSizeBitEqual(fake_ctx.size, derived_leaf.min_size);
}

test "applyLook metal table keeps explicit vertical slider height" {
    const allocator = std.testing.allocator;
    const slider = try nimbus.Slider.create(allocator, .vertical, 0, 60, 100);
    defer slider.component.vtable.destroy(&slider.component, allocator);

    slider.component.setMinSize(.{
        .width = slider.component.getMinSize().width,
        .height = 180,
    });
    nimbus.laf.applyLook(&slider.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(slider.component.min_size_explicit);
    try std.testing.expectApproxEqAbs(@as(f32, 180), slider.component.getMinSize().height, 0.001);
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

test "Metal Button measureMinSize uses Metal padding without GPU device" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const button = try nimbus.Button.create(allocator, "OK", text_font, nimbus.Theme.default.text);
    defer button.component.vtable.destroy(&button.component, allocator);

    const text_m = text_font.measureString("OK");
    const metal_min = nimbus.laf.metal.metal_button_look.measureMinSize(
        &button.component,
        &nimbus.laf.metal.metal_palette,
    );
    const expected_metal = nimbus.Component.Size{
        .width = text_m.width + 14 * 2,
        .height = text_m.height + 7 * 2,
    };
    const expected_flat = nimbus.Component.Size{
        .width = text_m.width + 12 * 2,
        .height = text_m.height + 4 * 2,
    };

    try expectSizeBitEqual(expected_metal, metal_min);
    try expectSizeBitEqual(expected_flat, button.component.min_size);
    try std.testing.expect(!nimbus.Component.Size.eql(button.component.min_size, metal_min));
}

test "Metal selection widgets measureMinSize without GPU device" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const checkbox = try nimbus.CheckBox.create(allocator, "Check", text_font, nimbus.Theme.default.text);
    defer checkbox.component.vtable.destroy(&checkbox.component, allocator);
    const radio = try nimbus.RadioButton.create(allocator, "Radio", text_font, nimbus.Theme.default.text);
    defer radio.component.vtable.destroy(&radio.component, allocator);
    const items = [_][]const u8{ "Short", "Longer item" };
    const combo = try nimbus.ComboBox.create(allocator, &items, text_font, nimbus.Theme.default.text);
    defer combo.component.vtable.destroy(&combo.component, allocator);

    const check_text = text_font.measureString("Check");
    const radio_text = text_font.measureString("Radio");
    const combo_text = text_font.measureString("Longer item");
    const line_h = text_font.face.metrics().line_height;

    const metal_check = nimbus.laf.metal.metal_checkbox_look.measureMinSize(
        &checkbox.component,
        &nimbus.laf.metal.metal_palette,
    );
    const metal_radio = nimbus.laf.metal.metal_radio_look.measureMinSize(
        &radio.component,
        &nimbus.laf.metal.metal_palette,
    );
    const metal_combo = nimbus.laf.metal.metal_combobox_look.measureMinSize(
        &combo.component,
        &nimbus.laf.metal.metal_palette,
    );

    try expectSizeBitEqual(.{
        .width = 16 + 6 + check_text.width + 4 * 2,
        .height = @max(@as(f32, 16), check_text.height) + 4 * 2,
    }, metal_check);
    try expectSizeBitEqual(.{
        .width = 16 + 6 + radio_text.width + 4 * 2,
        .height = @max(@as(f32, 16), radio_text.height) + 4 * 2,
    }, metal_radio);
    try expectSizeBitEqual(.{
        .width = combo_text.width + 8 * 2 + 18,
        .height = line_h + 4 * 2,
    }, metal_combo);

    try expectSizeBitEqual(checkbox.component.min_size, metal_check);
    try expectSizeBitEqual(radio.component.min_size, metal_radio);
    try std.testing.expect(!nimbus.Component.Size.eql(combo.component.min_size, metal_combo));
}

test "Metal range widgets measureMinSize without GPU device" {
    const allocator = std.testing.allocator;

    const slider_h = try nimbus.Slider.create(allocator, .horizontal, 0, 50, 100);
    defer slider_h.component.vtable.destroy(&slider_h.component, allocator);
    const slider_v = try nimbus.Slider.create(allocator, .vertical, 0, 50, 100);
    defer slider_v.component.vtable.destroy(&slider_v.component, allocator);
    const scrollbar_h = try nimbus.ScrollBar.create(allocator, .horizontal, 0, 25, 100);
    defer scrollbar_h.component.vtable.destroy(&scrollbar_h.component, allocator);
    const scrollbar_v = try nimbus.ScrollBar.create(allocator, .vertical, 0, 25, 100);
    defer scrollbar_v.component.vtable.destroy(&scrollbar_v.component, allocator);

    try expectSizeBitEqual(.{ .width = 32, .height = 20 }, nimbus.laf.metal.metal_slider_look.measureMinSize(
        &slider_h.component,
        &nimbus.laf.metal.metal_palette,
    ));
    try expectSizeBitEqual(.{ .width = 20, .height = 32 }, nimbus.laf.metal.metal_slider_look.measureMinSize(
        &slider_v.component,
        &nimbus.laf.metal.metal_palette,
    ));
    try expectSizeBitEqual(.{ .width = 40, .height = 14 }, nimbus.laf.metal.metal_scrollbar_look.measureMinSize(
        &scrollbar_h.component,
        &nimbus.laf.metal.metal_palette,
    ));
    try expectSizeBitEqual(.{ .width = 14, .height = 40 }, nimbus.laf.metal.metal_scrollbar_look.measureMinSize(
        &scrollbar_v.component,
        &nimbus.laf.metal.metal_palette,
    ));
}

test "Metal container widgets measureMinSize without GPU device" {
    const allocator = std.testing.allocator;

    const panel = try nimbus.Panel.create(allocator);
    defer panel.asComponent().vtable.destroy(panel.asComponent(), allocator);

    const split_left = try nimbus.Panel.create(allocator);
    const split_right = try nimbus.Panel.create(allocator);
    const split = try nimbus.SplitPane.create(allocator, .horizontal, split_left.asComponent(), split_right.asComponent());
    defer split.asComponent().vtable.destroy(split.asComponent(), allocator);

    const view = try nimbus.Panel.create(allocator);
    const scroll = try nimbus.ScrollPane.create(allocator, view.asComponent());
    defer scroll.asComponent().vtable.destroy(scroll.asComponent(), allocator);

    try expectSizeBitEqual(.{ .width = 0, .height = 0 }, nimbus.laf.metal.metal_panel_look.measureMinSize(
        panel.asComponent(),
        &nimbus.laf.metal.metal_palette,
    ));
    try expectSizeBitEqual(.{ .width = 0, .height = 0 }, nimbus.laf.metal.metal_splitpane_look.measureMinSize(
        split.asComponent(),
        &nimbus.laf.metal.metal_palette,
    ));
    try expectSizeBitEqual(.{ .width = 0, .height = 0 }, nimbus.laf.metal.metal_scrollpane_look.measureMinSize(
        scroll.asComponent(),
        &nimbus.laf.metal.metal_palette,
    ));
}

test "Metal table reaches Part A container widgets" {
    const allocator = std.testing.allocator;

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    const panel = try nimbus.Panel.create(allocator);
    try root.add(panel.asComponent());

    const split_left = try nimbus.Panel.create(allocator);
    const split_right = try nimbus.Panel.create(allocator);
    const split = try nimbus.SplitPane.create(allocator, .horizontal, split_left.asComponent(), split_right.asComponent());
    try root.add(split.asComponent());

    const view = try nimbus.Panel.create(allocator);
    const scroll = try nimbus.ScrollPane.create(allocator, view.asComponent());
    try root.add(scroll.asComponent());

    nimbus.laf.applyLook(&root.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(panel.asComponent().ui.vtable == &nimbus.laf.metal.metal_panel_look);
    try std.testing.expect(split.asComponent().ui.vtable == &nimbus.laf.metal.metal_splitpane_look);
    try std.testing.expect(scroll.asComponent().ui.vtable == &nimbus.laf.metal.metal_scrollpane_look);
}

test "Metal collection widgets measureMinSize without GPU device" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);
    test_text_font = text_font;
    defer test_text_font = null;

    var list_model = nimbus.List.ListModel.init(allocator);
    defer list_model.deinit();
    var list_row: []const u8 = "row";
    try list_model.add(@ptrCast(&list_row));

    var factory_ctx: u8 = 0;
    const list = try nimbus.List.createWithModel(allocator, &list_model, .{
        .create = TestTextCell.createList,
        .user_data = &factory_ctx,
    });
    defer list.asComponent().vtable.destroy(list.asComponent(), allocator);
    const list_min = list.asComponent().min_size;

    var table_model = nimbus.Table.Model.init(allocator);
    defer table_model.deinit();
    var table_row: []const u8 = "cell";
    try table_model.add(@ptrCast(&table_row));
    const columns = [_]nimbus.Table.Column{
        .{ .title = "Name", .width = 120, .factory = .{ .create = TestTextCell.createTable, .user_data = &factory_ctx } },
    };
    const table = try nimbus.Table.createWithModel(allocator, &table_model, &columns, text_font);
    defer table.asComponent().vtable.destroy(table.asComponent(), allocator);
    const table_min = table.asComponent().min_size;

    try expectSizeBitEqual(list_min, nimbus.laf.metal.metal_list_look.measureMinSize(
        list.asComponent(),
        &nimbus.laf.metal.metal_palette,
    ));
    try expectSizeBitEqual(table_min, nimbus.laf.metal.metal_table_look.measureMinSize(
        table.asComponent(),
        &nimbus.laf.metal.metal_palette,
    ));
}

test "Metal table reaches Part B collection widgets" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);
    test_text_font = text_font;
    defer test_text_font = null;

    var list_model = nimbus.List.ListModel.init(allocator);
    defer list_model.deinit();
    var list_row: []const u8 = "list row";
    try list_model.add(@ptrCast(&list_row));

    var table_model = nimbus.Table.Model.init(allocator);
    defer table_model.deinit();
    var table_row: []const u8 = "table row";
    try table_model.add(@ptrCast(&table_row));

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    var factory_ctx: u8 = 0;
    const list = try nimbus.List.createWithModel(allocator, &list_model, .{
        .create = TestTextCell.createList,
        .user_data = &factory_ctx,
    });
    try root.add(list.asComponent());

    const columns = [_]nimbus.Table.Column{
        .{ .title = "Name", .width = 120, .factory = .{ .create = TestTextCell.createTable, .user_data = &factory_ctx } },
    };
    const table = try nimbus.Table.createWithModel(allocator, &table_model, &columns, text_font);
    try root.add(table.asComponent());

    nimbus.laf.applyLook(&root.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(list.asComponent().ui.vtable == &nimbus.laf.metal.metal_list_look);
    try std.testing.expect(table.asComponent().ui.vtable == &nimbus.laf.metal.metal_table_look);
}

test "Metal table reaches Table header through ScrollPane column header" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);
    test_text_font = text_font;
    defer test_text_font = null;

    var table_model = nimbus.Table.Model.init(allocator);
    defer table_model.deinit();
    var table_row: []const u8 = "table row";
    try table_model.add(@ptrCast(&table_row));

    var factory_ctx: u8 = 0;
    const columns = [_]nimbus.Table.Column{
        .{ .title = "Name", .width = 120, .factory = .{ .create = TestTextCell.createTable, .user_data = &factory_ctx } },
    };
    const table = try nimbus.Table.createWithModel(allocator, &table_model, &columns, text_font);
    const scroll = try nimbus.ScrollPane.create(allocator, table.asComponent());
    defer scroll.asComponent().vtable.destroy(scroll.asComponent(), allocator);
    try scroll.setColumnHeaderView(try table.headerView());

    nimbus.laf.applyLook(scroll.asComponent(), nimbus.laf.metal.metalTable());

    try std.testing.expect(table.asComponent().ui.vtable == &nimbus.laf.metal.metal_table_look);
    try std.testing.expect(table.header_view.?.component.ui.vtable == &nimbus.laf.metal.metal_tableheader_look);
}

test "Metal tabbed pane measureMinSize without GPU device" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const tabs = try nimbus.TabbedPane.create(allocator, text_font);
    defer tabs.asComponent().vtable.destroy(tabs.asComponent(), allocator);

    try expectSizeBitEqual(.{ .width = 0, .height = 0 }, nimbus.laf.metal.metal_tabbedpane_look.measureMinSize(
        tabs.asComponent(),
        &nimbus.laf.metal.metal_palette,
    ));
}

test "Metal table reaches TabbedPane" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);

    const tabs = try nimbus.TabbedPane.create(allocator, text_font);
    try root.add(tabs.asComponent());

    nimbus.laf.applyLook(&root.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(tabs.asComponent().ui.vtable == &nimbus.laf.metal.metal_tabbedpane_look);
}

test "Metal TabbedPane keeps hidden tab content at zero size" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const tabs = try nimbus.TabbedPane.create(allocator, text_font);
    defer tabs.asComponent().vtable.destroy(tabs.asComponent(), allocator);

    try tabs.addTab("One", (try nimbus.Panel.create(allocator)).asComponent());
    try tabs.addTab("Two", (try nimbus.Panel.create(allocator)).asComponent());
    try tabs.addTab("Three", (try nimbus.Panel.create(allocator)).asComponent());
    tabs.setSelectedIndex(1);
    nimbus.laf.applyLook(tabs.asComponent(), nimbus.laf.metal.metalTable());

    tabs.asComponent().setBounds(.{ .x = 0, .y = 0, .width = 320, .height = 180 });
    tabs.container.doLayout();

    const first = tabs.getContentAt(0);
    const selected = tabs.getContentAt(1);
    const third = tabs.getContentAt(2);
    try expectSizeBitEqual(.{ .width = 0, .height = 0 }, first.size);
    try expectSizeBitEqual(.{ .width = 320, .height = 154 }, selected.size);
    try expectSizeBitEqual(.{ .width = 0, .height = 0 }, third.size);
}

test "Metal TabbedPane tab geometry matches hit testing" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const tabs = try nimbus.TabbedPane.create(allocator, text_font);
    defer tabs.asComponent().vtable.destroy(tabs.asComponent(), allocator);

    const titles = [_][]const u8{ "Overview", "Activity", "Settings" };
    inline for (titles) |title| {
        try tabs.addTab(title, (try nimbus.Panel.create(allocator)).asComponent());
    }
    nimbus.laf.applyLook(tabs.asComponent(), nimbus.laf.metal.metalTable());

    const tab_height = nimbus.laf.metal.tabbedPaneTabHeight();
    var x: f32 = 0;
    for (titles, 0..) |title, i| {
        const w = nimbus.laf.metal.tabbedPaneTabWidth(tabs, title);
        const y = tab_height / 2;
        try std.testing.expectEqual(@as(?usize, i), tabs.tabAt(x + 0.5, y));
        try std.testing.expectEqual(@as(?usize, i), tabs.tabAt(x + w / 2, y));
        try std.testing.expectEqual(@as(?usize, i), tabs.tabAt(x + w - 0.5, y));
        x += w;
    }
}

test "Metal text widgets measureMinSize without GPU device" {
    const allocator = std.testing.allocator;
    const app = try newApp();
    defer app.deinit();
    const text_font = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };

    const flat = try nimbus.TextField.create(allocator, app, text_font, nimbus.Theme.default.text, "flat");
    defer flat.component.vtable.destroy(&flat.component, allocator);
    const metal = try nimbus.TextField.create(allocator, app, text_font, nimbus.Theme.default.text, "metal");
    defer metal.component.vtable.destroy(&metal.component, allocator);

    try expectSizeBitEqual(flat.component.min_size, nimbus.laf.metal.metal_textfield_look.measureMinSize(
        &metal.component,
        &nimbus.laf.metal.metal_palette,
    ));
    nimbus.laf.applyLook(&metal.component, nimbus.laf.metal.metalTable());
    try expectSizeBitEqual(flat.component.min_size, metal.component.min_size);

    try flat.setText("updated text");
    try metal.setText("updated text");
    try expectSizeBitEqual(flat.component.min_size, metal.component.min_size);

    const area = try nimbus.TextArea.create(allocator, app, text_font, nimbus.Theme.default.text, "one\ntwo");
    defer area.component.vtable.destroy(&area.component, allocator);
    const area_min = area.component.min_size;
    nimbus.laf.applyLook(&area.component, nimbus.laf.metal.metalTable());
    try expectSizeBitEqual(area_min, nimbus.laf.metal.metal_textarea_look.measureMinSize(
        &area.component,
        &nimbus.laf.metal.metal_palette,
    ));
}

test "Metal table reaches text widgets but not Label" {
    const allocator = std.testing.allocator;
    const app = try newApp();
    defer app.deinit();
    const text_font = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    const field = try nimbus.TextField.create(allocator, app, text_font, nimbus.Theme.default.text, "field");
    try root.add(&field.component);
    const area = try nimbus.TextArea.create(allocator, app, text_font, nimbus.Theme.default.text, "area");
    try root.add(&area.component);
    const label = try nimbus.Label.create(allocator, "label", text_font, nimbus.Theme.default.text);
    try root.add(&label.component);

    nimbus.laf.applyLook(&root.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(field.component.ui.vtable == &nimbus.laf.metal.metal_textfield_look);
    try std.testing.expect(area.component.ui.vtable == &nimbus.laf.metal.metal_textarea_look);
    try std.testing.expect(label.component.ui.vtable == &nimbus.Label.look_vtable);
}

test "TextArea reflow stays independent of Metal vtable" {
    const allocator = std.testing.allocator;
    const app = try newApp();
    defer app.deinit();
    const text_font = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };

    const flat = try nimbus.TextArea.create(allocator, app, text_font, nimbus.Theme.default.text, "initial");
    defer flat.component.vtable.destroy(&flat.component, allocator);
    const metal = try nimbus.TextArea.create(allocator, app, text_font, nimbus.Theme.default.text, "initial");
    defer metal.component.vtable.destroy(&metal.component, allocator);
    nimbus.laf.applyLook(&metal.component, nimbus.laf.metal.metalTable());

    flat.component.setBounds(.{ .x = 0, .y = 0, .width = 96, .height = 40 });
    metal.component.setBounds(.{ .x = 0, .y = 0, .width = 96, .height = 40 });
    try flat.setText("alpha beta gamma delta epsilon");
    try metal.setText("alpha beta gamma delta epsilon");
    try expectSizeBitEqual(flat.component.min_size, metal.component.min_size);

    flat.setLineWrap(true);
    metal.setLineWrap(true);
    try expectSizeBitEqual(flat.component.min_size, metal.component.min_size);
}
test "Metal table reaches ComboBox popup detached root" {
    const allocator = std.testing.allocator;
    var text_font = try initTestTextFont();
    defer deinitTestTextFont(&text_font);

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    const checkbox = try nimbus.CheckBox.create(allocator, "Check", text_font, nimbus.Theme.default.text);
    try root.add(&checkbox.component);
    const radio = try nimbus.RadioButton.create(allocator, "Radio", text_font, nimbus.Theme.default.text);
    try root.add(&radio.component);
    const items = [_][]const u8{ "One", "Two" };
    const combo = try nimbus.ComboBox.create(allocator, &items, text_font, nimbus.Theme.default.text);
    try root.add(&combo.component);

    try std.testing.expect(combo.popup_root.ui.vtable == &nimbus.ComboBox.popup_look_vtable);

    nimbus.laf.applyLook(&root.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(checkbox.component.ui.vtable == &nimbus.laf.metal.metal_checkbox_look);
    try std.testing.expect(radio.component.ui.vtable == &nimbus.laf.metal.metal_radio_look);
    try std.testing.expect(combo.component.ui.vtable == &nimbus.laf.metal.metal_combobox_look);
    try std.testing.expect(combo.popup_root.ui.vtable == &nimbus.laf.metal.metal_combobox_popup_look);
}

test "Metal table reaches range widgets and ScrollPane bars" {
    const allocator = std.testing.allocator;

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);
    root.setLayout(nimbus.BoxLayout.vertical());

    const slider = try nimbus.Slider.create(allocator, .horizontal, 0, 50, 100);
    try root.add(&slider.component);
    const scrollbar = try nimbus.ScrollBar.create(allocator, .vertical, 0, 20, 100);
    try root.add(&scrollbar.component);

    const view = try nimbus.Panel.create(allocator);
    view.asComponent().setMinSize(.{ .width = 300, .height = 240 });
    const sp = try nimbus.ScrollPane.create(allocator, view.asComponent());
    sp.setHorizontalPolicy(.always);
    sp.setVerticalPolicy(.always);
    try root.add(sp.asComponent());

    nimbus.laf.applyLook(&root.component, nimbus.laf.metal.metalTable());

    try std.testing.expect(slider.component.ui.vtable == &nimbus.laf.metal.metal_slider_look);
    try std.testing.expect(scrollbar.component.ui.vtable == &nimbus.laf.metal.metal_scrollbar_look);
    try std.testing.expect(sp.asComponent().ui.vtable == &nimbus.laf.metal.metal_scrollpane_look);
    try std.testing.expect(sp.hbar.component.ui.vtable == &nimbus.laf.metal.metal_scrollbar_look);
    try std.testing.expect(sp.vbar.component.ui.vtable == &nimbus.laf.metal.metal_scrollbar_look);
}

test "ScrollPane focusOwner descendant predicate works with FocusController stub" {
    const allocator = std.testing.allocator;

    const root = try nimbus.Container.create(allocator);
    defer root.component.vtable.destroy(&root.component, allocator);

    var focus_stub = FocusStub{};
    var focus_controller = focus_stub.controller();
    try root.component.putProperty(@typeName(nimbus.Component.FocusController), @ptrCast(&focus_controller), null);

    const view = try nimbus.Panel.create(allocator);
    const scroll = try nimbus.ScrollPane.create(allocator, view.asComponent());
    try root.add(scroll.asComponent());

    focus_stub.owner = view.asComponent();
    try std.testing.expect(scroll.asComponent().focusOwner() == view.asComponent());
    try std.testing.expect(scroll.asComponent().isSelfOrDescendant(view.asComponent()));
    const focused = if (scroll.asComponent().focusOwner()) |owner|
        scroll.asComponent().isSelfOrDescendant(owner)
    else
        false;
    try std.testing.expect(focused);

    focus_stub.owner = null;
    try std.testing.expect(scroll.asComponent().focusOwner() == null);
    const unfocused = if (scroll.asComponent().focusOwner()) |owner|
        scroll.asComponent().isSelfOrDescendant(owner)
    else
        false;
    try std.testing.expect(!unfocused);
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
