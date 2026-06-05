//! RadioButton + ButtonGroup smoke test. Three mutually-exclusive
//! radios; a label below mirrors the current selection.
//!
//! Usage:
//!     zig build run-widget_radio

const std = @import("std");
const nimbus = @import("nimbus");
const Event = nimbus.ActionEvent;

const State = struct {
    rb_small:  *nimbus.RadioButton,
    rb_medium: *nimbus.RadioButton,
    rb_large:  *nimbus.RadioButton,
    label:     *nimbus.Label,
    buf:       [128]u8 = undefined,
};

fn refresh(state: *State) void {
    const choice =
        if (state.rb_small.isSelected())  "small"
        else if (state.rb_medium.isSelected()) "medium"
        else if (state.rb_large.isSelected())  "large"
        else "none";
    const text = std.fmt.bufPrint(&state.buf, "size: {s}", .{choice}) catch return;
    state.label.setText(text) catch {};
}

fn onChange(state: *State, _: *const Event) void {
    refresh(state);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_radio", 400, 200);

    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());

    const rb_small  = try app.radioButton("Small");
    const rb_medium = try app.radioButton("Medium");
    const rb_large  = try app.radioButton("Large");
    rb_medium.setSelected(true);

    const label = try app.label("size: medium");

    try col.add(&rb_small.component);
    try col.add(&rb_medium.component);
    try col.add(&rb_large.component);
    try col.add(&label.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    // Build the group AFTER the radios but BEFORE wiring listeners
    // (so order of `defer ... deinit` is: group first, then radios).
    const group = try app.buttonGroup();
    defer group.destroy();
    try group.add(rb_small.getModel());
    try group.add(rb_medium.getModel());
    try group.add(rb_large.getModel());

    var state = State{
        .rb_small = rb_small,
        .rb_medium = rb_medium,
        .rb_large = rb_large,
        .label = label,
    };
    refresh(&state);
    try rb_small.getModel().addActionListener(State, onChange, &state);
    try rb_medium.getModel().addActionListener(State, onChange, &state);
    try rb_large.getModel().addActionListener(State, onChange, &state);

    std.debug.print("Pick a size — selection is mutually exclusive.\n", .{});
    try app.run();
}
