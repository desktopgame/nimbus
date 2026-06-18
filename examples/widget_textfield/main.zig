//! TextField smoke test. One TextField above a Label; typing into the
//! field mirrors the current text into the label.
//!
//! nimbus は per-component insets を持たないので、余白は PaddingLayout
//! （外周マージン）と BoxLayout の spacing（子間ギャップ）で表現する。
//! 本例はその正典レシピを兼ねる。
//!
//! Usage:
//!     zig build run-widget_textfield
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
    buf: [256]u8 = undefined,
};

fn refreshLabel(state: *State) void {
    const t = state.field.getText();
    const display = std.fmt.bufPrint(&state.buf, "input: \"{s}\"", .{t}) catch return;
    state.label.setText(display) catch {};
}

fn onFieldChange(state: *State, _: *const nimbus.ChangeEvent) void {
    refreshLabel(state);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("textfield demo", 600, 200);

    const field = try app.textField("hello");
    field.component.setGrowX(1); // fill the padded row

    const label = try app.label("input: \"hello\"");

    const root = try app.container();
    root.setLayout(try nimbus.PaddingLayout.create(app.allocator, .{ .left = 12, .top = 12, .right = 12 }));

    const col = try app.container();
    // root/col を破棄すれば差した PaddingLayout / verticalSpaced も自動解放される。
    col.setLayout(try nimbus.BoxLayout.verticalSpaced(app.allocator, 8));
    try col.add(&field.component);
    try col.add(&label.component);
    try root.add(&col.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, &root.component);

    // Mirror the field into the label via TextField's change listener
    // (fires only on actual content changes — no polling timer needed).
    var state = State{ .field = field, .label = label };
    try field.addChangeListener(State, onFieldChange, &state);
    refreshLabel(&state); // initial sync

    std.debug.print("Type into the field; the label mirrors the contents.\n", .{});
    try app.run();
}
