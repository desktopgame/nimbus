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

    try std.testing.expect(button.component.ui != null);
    try std.testing.expect(button.component.ui.?.vtable == &nimbus.Button.look_vtable);
    try std.testing.expect(container.component.ui != null);
    try std.testing.expect(container.component.ui.?.vtable == &nimbus.Container.look_vtable);
    try std.testing.expect(panel.container.component.ui != null);
    try std.testing.expect(panel.container.component.ui.?.vtable == &nimbus.Panel.look_vtable);

    try std.testing.expect(tabbed.container.component.ui != null);
    try std.testing.expect(tabbed.container.component.ui.?.vtable == &nimbus.TabbedPane.look_vtable);
    try std.testing.expect(label.component.ui != null);
    try std.testing.expect(label.component.ui.?.vtable == &nimbus.Label.look_vtable);
    try std.testing.expect(checkbox.component.ui != null);
    try std.testing.expect(checkbox.component.ui.?.vtable == &nimbus.CheckBox.look_vtable);
    try std.testing.expect(menu.component.ui != null);
    try std.testing.expect(menu.component.ui.?.vtable == &nimbus.Menu.look_vtable);
    try std.testing.expect(menu.popup_root.ui != null);
    try std.testing.expect(popup.popup_root.ui != null);
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
