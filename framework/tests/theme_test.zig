//! Theme DI tests (theme.md): factory injection, recursive injection into
//! composite internals, the default for factory-less creation, and the
//! value-copy contract of initWithTheme. GPU device required (skips when
//! unavailable).

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

const custom_accent = awt.Graphics.Color.rgb(0.9, 0.1, 0.2);

/// Test-quiet log: drop debug/info chatter, keep warn/error visible. Any
/// stderr from a passing test binary makes `zig build` print it under a
/// noisy "failed command:" banner, so the happy path must stay silent.
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

test "factories inject the application theme (and composites recurse)" {
    const app = try newApp();
    defer app.deinit();
    // Equivalent to initWithTheme for the headless path: set before any
    // factory call (the theme is fixed-at-startup by contract).
    app.theme.accent = custom_accent;

    // Parent everything under a frame so app.deinit tears it all down.
    const frame = try app.frameHeadless("t", 200, 100);
    const holder = try app.container();

    const b = try app.button("x");
    try holder.add(&b.component);
    try std.testing.expect(b.component.theme == &app.theme);
    try std.testing.expectEqual(custom_accent, b.component.theme.accent);

    // ScrollPane: internal viewport / bars exist at creation and must be
    // reached by the recursive injection.
    const column = try app.container();
    const sp = try app.scrollPane(&column.component);
    try holder.add(&sp.container.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &holder.component);

    try std.testing.expect(sp.container.component.theme == &app.theme);
    try std.testing.expect(sp.hbar.component.theme == &app.theme);
    try std.testing.expect(sp.vbar.component.theme == &app.theme);
    try std.testing.expect(sp.viewport.component.theme == &app.theme);
    try std.testing.expect(column.component.theme == &app.theme);

    // Window root (frame factory).
    try std.testing.expect(frame.window.container.component.theme == &app.theme);
}

test "direct create (no factory) stays on the built-in default theme" {
    const app = try newApp();
    defer app.deinit();
    app.theme.accent = custom_accent;

    const font = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
    const b = try nimbus.Button.create(std.testing.allocator, "x", font, app.theme.text);
    defer b.component.vtable.destroy(&b.component, std.testing.allocator);

    try std.testing.expect(b.component.theme == &nimbus.Theme.default);
    try std.testing.expect(b.component.theme != &app.theme);
}

test "initWithTheme copies the theme by value" {
    awt.setLogCallback(quietLog, null);
    var theme = nimbus.Theme{ .accent = custom_accent };
    const app = nimbus.Application.initWithTheme(std.testing.allocator, std.testing.io, theme) catch
        return error.SkipZigTest;
    defer app.deinit();

    // Mutating the caller's variable after init must not affect the app copy.
    theme.accent = awt.Graphics.Color.rgb(0, 1, 0);
    try std.testing.expectEqual(custom_accent, app.theme.accent);
}
