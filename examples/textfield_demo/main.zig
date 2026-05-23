//! TextField smoke test. One TextField above a Label; typing into the
//! field mirrors the current text into the label.
//!
//! Usage:
//!     zig build run-textfield_demo
//!
//! Test recipe:
//!     - type letters / numbers (and Shift combos) → mirror in label
//!     - arrow keys / Home / End → caret moves, label unchanged
//!     - Shift+arrow / mouse drag → selection highlight visible
//!     - Backspace / Delete → text shrinks
//!     - Ctrl+A → select all; Ctrl+C / Ctrl+X / Ctrl+V → clipboard round-trip
//!     - click outside text → focus lost (caret stops blinking)
//!     - click back inside → focus regained (caret reappears)

const std = @import("std");
const nimbus = @import("nimbus");

const State = struct {
    field: *nimbus.TextField,
    label: *nimbus.Label,
    buf:   [256]u8 = undefined,
};

fn refreshLabel(state: *State) void {
    const t = state.field.getText();
    const display = std.fmt.bufPrint(&state.buf, "input: \"{s}\"", .{t}) catch return;
    state.label.setText(display) catch {};
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("textfield demo", 600, 160);

    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());

    const field = try app.textField("hello");
    const label = try app.label("input: \"hello\"");
    label.component.setAlignY(.center);

    try col.add(&field.component);
    try col.add(&label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    // No public ChangeListener API on TextField in v1 — instead we drive the
    // mirror update from the timer that already runs the caret blink, so any
    // edit shows up within ~500ms. Good enough as a smoke test; a proper
    // ChangeListener slot can come later.
    var state = State{ .field = field, .label = label };
    _ = try app.setInterval(120, tick, @ptrCast(&state));

    std.debug.print("Type into the field; the label mirrors the contents.\n", .{});
    try app.run();
}

fn tick(user_data: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(user_data));
    refreshLabel(state);
}
