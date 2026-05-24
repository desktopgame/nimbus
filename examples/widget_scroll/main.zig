//! ScrollPane smoke test. A grid of labels larger than the window in both
//! dimensions, wrapped in a ScrollPane so both scrollbars appear. Drag the
//! bars, click the track to page, or use the mouse wheel (Shift+wheel for
//! horizontal).
//!
//! Usage:
//!     zig build run-widget_scroll
//!
//! Test recipe:
//!     - vertical wheel scrolls down; the vertical bar thumb follows
//!     - Shift+wheel scrolls horizontally
//!     - drag either thumb; click the track above/below the thumb to page
//!     - content is clipped to the viewport (never paints over the bars)

const std = @import("std");
const nimbus = @import("nimbus");

const COLS = 8;
const ROWS = 30;
const CELL_W: f32 = 140;
const CELL_H: f32 = 70;

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_scroll", 520, 360);

    // Content: a Container with no layout, larger than the viewport. Children
    // are placed at explicit positions so scrolling is clearly visible.
    const content = try app.container();
    content.component.setMinSize(.{ .width = COLS * CELL_W, .height = ROWS * CELL_H });
    content.component.setMaxSize(.{ .width = COLS * CELL_W, .height = ROWS * CELL_H });

    var r: usize = 0;
    while (r < ROWS) : (r += 1) {
        var c: usize = 0;
        while (c < COLS) : (c += 1) {
            var buf: [16]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "r{d}c{d}", .{ r, c });
            const cell = try app.label(text);
            cell.component.setBounds(.{
                .x = @as(f32, @floatFromInt(c)) * CELL_W + 12,
                .y = @as(f32, @floatFromInt(r)) * CELL_H + 12,
                .width = CELL_W - 24,
                .height = CELL_H - 24,
            });
            try content.add(&cell.component);
        }
    }

    const sp = try app.scrollPane(&content.component);
    sp.asComponent().setGrowX(1);
    sp.asComponent().setGrowY(1);

    try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());

    std.debug.print("Scroll with the wheel (Shift+wheel = horizontal), or drag the bars.\n", .{});
    try app.run();
}
