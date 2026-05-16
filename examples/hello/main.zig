const std = @import("std");
const nimbus = @import("nimbus");

pub fn main() !void {
    const awt = nimbus.awt;

    std.debug.print("AWT backend: {s}\n", .{awt.backendVersion()});

    try awt.init();
    defer awt.deinit();

    var window = try awt.Window.init("hello nimbus", 800, 600);
    defer window.deinit();

    std.debug.print("Window opened. Close it to exit.\n", .{});
    while (!window.shouldClose()) {
        awt.waitEvents();
    }
    std.debug.print("Bye.\n", .{});
}
