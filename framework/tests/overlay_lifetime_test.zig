//! Overlay lifetime regression tests.

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

test "window deinit dismisses caller-owned popup before overlay list is freed" {
    const app = try newApp();
    defer app.deinit();

    const frame = try app.frameHeadless("t", 300, 200);
    const popup = try app.popupMenu();
    defer popup.destroy();

    const item = try app.menuItem("Open");
    try popup.add(&item.component);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    try popup.show(&frame.window, 10, 10);
    try std.testing.expect(popup.open);

    frame.window.dispose();
    app.tickOnce();

    try std.testing.expect(!popup.open);
}
