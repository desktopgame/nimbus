//! CheckBox smoke test. Three independent checkboxes; a label below
//! mirrors which ones are currently checked.
//!
//! Usage:
//!     zig build run-widget_checkbox

const std = @import("std");
const nimbus = @import("nimbus");
const Event = nimbus.ActionEvent;

const State = struct {
    cb_a:  *nimbus.CheckBox,
    cb_b:  *nimbus.CheckBox,
    cb_c:  *nimbus.CheckBox,
    label: *nimbus.Label,
    buf:   [256]u8 = undefined,
};

fn refresh(state: *State) void {
    const text = std.fmt.bufPrint(&state.buf, "A={s} B={s} C={s}", .{
        if (state.cb_a.isSelected()) "[x]" else "[ ]",
        if (state.cb_b.isSelected()) "[x]" else "[ ]",
        if (state.cb_c.isSelected()) "[x]" else "[ ]",
    }) catch return;
    state.label.setText(text) catch {};
}

fn onToggle(state: *State, _: *const Event) void {
    refresh(state);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_checkbox", 400, 200);

    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());

    const cb_a = try app.checkBox("Receive newsletter");
    const cb_b = try app.checkBox("Enable notifications");
    cb_b.setSelected(true);
    const cb_c = try app.checkBox("Auto-update");

    const label = try app.label("A=[ ] B=[x] C=[ ]");

    try col.add(&cb_a.component);
    try col.add(&cb_b.component);
    try col.add(&cb_c.component);
    try col.add(&label.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    var state = State{ .cb_a = cb_a, .cb_b = cb_b, .cb_c = cb_c, .label = label };
    refresh(&state);

    try cb_a.getModel().addActionListener(State, onToggle, &state);
    try cb_b.getModel().addActionListener(State, onToggle, &state);
    try cb_c.getModel().addActionListener(State, onToggle, &state);

    std.debug.print("Toggle the checkboxes — label updates on each change.\n", .{});
    try app.run();
}
