//! TextArea smoke test. A multi-line editor inside a ScrollPane, with a button
//! that toggles line wrapping. Demonstrates the two ScrollPane integration
//! modes (no-wrap → horizontal+vertical scroll; wrap → vertical only) and caret
//! follow (the pane scrolls to keep the caret visible while editing).
//!
//! Usage:
//!     zig build run-widget_textarea
//!
//! Test recipe:
//!     - type across multiple lines; Enter inserts a newline
//!     - arrows incl. Up/Down move across lines; Home/End per visual line
//!     - Shift+arrow / mouse drag → multi-line selection highlight
//!     - Backspace / Delete / Ctrl+A,C,X,V
//!     - type past the bottom/right edge → pane scrolls to follow the caret
//!     - click "wrap: on/off" → toggle wrapping (no-wrap shows a horizontal bar)
//!     - IME (Windows/macOS): preedit shows inline at the caret

const std = @import("std");
const nimbus = @import("nimbus");

const SAMPLE =
    \\The quick brown fox jumps over the lazy dog.
    \\
    \\nimbus TextArea is backed by a gap buffer, so editing longer text stays
    \\cheap. This line is intentionally quite long so that with wrapping turned
    \\off you can scroll horizontally to reach its end, and with wrapping on it
    \\reflows to the viewport width instead.
    \\
    \\日本語の入力もできます（確定済みテキスト）。
    \\Enter で改行、Ctrl+A で全選択。
;

const State = struct {
    area:   *nimbus.TextArea,
    button: *nimbus.Button,
};

fn onToggleWrap(user_data: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(user_data));
    const now = !state.area.getLineWrap();
    state.area.setLineWrap(now);
    state.button.setText(if (now) "wrap: on" else "wrap: off") catch {};
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("textarea demo", 640, 420);

    const area = try app.textArea(SAMPLE);
    const sp = try app.scrollPane(&area.component);
    sp.asComponent().setGrowX(1);
    sp.asComponent().setGrowY(1);

    const button = try app.button("wrap: off");
    button.component.setAlignX(.start);

    // Top: toggle button row. Center: the scroll pane.
    const top = try app.container();
    top.setLayout(nimbus.BoxLayout.horizontal());
    try top.add(&button.component);

    var state = State{ .area = area, .button = button };
    try button.getModel().addActionListener(onToggleWrap, @ptrCast(&state));

    try nimbus.BorderLayout.add(&frame.window.container, .north, &top.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, sp.asComponent());

    std.debug.print("Edit the text. Toggle wrapping with the button. Close to exit.\n", .{});
    try app.run();
}
