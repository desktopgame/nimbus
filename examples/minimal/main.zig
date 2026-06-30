//! Minimal framework example: a window with a label and a button.
//! No listeners, no layout tuning — the smallest thing that renders.
//!
//! Usage:
//!     zig build run-minimal

const std = @import("std");
const nimbus = @import("nimbus");

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("hello nimbus", 320, 120);
    const label = try app.label("Hello, nimbus!");
    const button = try app.button("OK");

    try nimbus.BorderLayout.add(&frame.window.container, .center, &label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .south, &button.component);

    try app.run();
}
