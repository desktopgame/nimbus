//! TextField smoke test. One TextField above a Label; typing into the
//! field mirrors the current text into the label.
//!
//! Also doubles as the documented recipe for "margin via empty Panel":
//! nimbus has no per-component `insets`, so visual breathing room is
//! built with horizontal / vertical spacer Panels (see `hSpacer` /
//! `vSpacer` below).
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

// ── tiny layout helpers (the "empty Panel as margin" pattern) ────────────

/// Height-`h` slab that eats vertical space. Used as top / between-row
/// padding inside a vertical BoxLayout.
fn vSpacer(app: *nimbus.Application, h: f32) !*nimbus.Panel {
    const p = try app.panel();
    p.container.component.setMinSize(.{ .width = 0, .height = h });
    p.container.component.setMaxSize(.{ .width = std.math.inf(f32), .height = h });
    return p;
}

/// Width-`w` slab that eats horizontal space. Used as left / right
/// padding inside a horizontal BoxLayout.
fn hSpacer(app: *nimbus.Application, w: f32) !*nimbus.Panel {
    const p = try app.panel();
    p.container.component.setMinSize(.{ .width = w, .height = 0 });
    p.container.component.setMaxSize(.{ .width = w, .height = std.math.inf(f32) });
    return p;
}

/// Wrap `child` with `pad` px of empty Panel on its left and right.
/// The returned row is a horizontal BoxLayout container.
fn padHorizontal(app: *nimbus.Application, child: *nimbus.Component, pad: f32) !*nimbus.Container {
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    try row.add(&(try hSpacer(app, pad)).container.component);
    try row.add(child);
    try row.add(&(try hSpacer(app, pad)).container.component);
    return row;
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("textfield demo", 600, 200);

    const field = try app.textField("hello");
    field.component.setGrowX(1); // fill the padded row

    const label = try app.label("input: \"hello\"");
    label.component.setAlignY(.center);

    // Vertical stack with manual top / between / bottom margins.
    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());
    try col.add(&(try vSpacer(app, 12)).container.component);
    try col.add(&(try padHorizontal(app, &field.component, 12)).component);
    try col.add(&(try vSpacer(app, 8)).container.component);
    try col.add(&(try padHorizontal(app, &label.component, 12)).component);
    // Push everything to the top by absorbing leftover height.
    const bottom_spring = try app.panel();
    bottom_spring.container.component.setGrowY(1);
    try col.add(&bottom_spring.container.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    // Mirror the field into the label via TextField's change listener
    // (fires only on actual content changes — no polling timer needed).
    var state = State{ .field = field, .label = label };
    try field.addChangeListener(State, onFieldChange, &state);
    refreshLabel(&state); // initial sync

    std.debug.print("Type into the field; the label mirrors the contents.\n", .{});
    try app.run();
}
