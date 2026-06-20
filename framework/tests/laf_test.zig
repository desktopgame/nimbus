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
