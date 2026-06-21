//! Metal Button LAF example.
//!
//! Usage:
//!     zig build run-widget_metalbutton

const std = @import("std");
const nimbus = @import("nimbus");

fn fitButtonHeight(button: *nimbus.Button) void {
    button.component.setAlignY(.center);
    button.component.setMaxSize(.{
        .width = std.math.inf(f32),
        .height = button.component.getMinSize().height,
    });
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget metal button", 520, 150);

    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());

    const normal = try app.button("Normal");
    const pressed = try app.button("Pressed");
    const disabled = try app.button("Disabled");
    pressed.getModel().setArmed(true);
    pressed.getModel().setPressed(true);
    disabled.getModel().setEnabled(false);

    try row.add(&normal.component);
    try row.add(&pressed.component);
    try row.add(&disabled.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    nimbus.laf.applyLook(&frame.window.container.component, nimbus.laf.metal.buttonTable());
    fitButtonHeight(normal);
    fitButtonHeight(pressed);
    fitButtonHeight(disabled);

    std.debug.print("Metal Button LAF demo. Close the window to exit.\n", .{});
    try app.run();
}
