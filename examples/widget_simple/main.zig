//! Simple framework example. Places Button + Slider + Label horizontally
//! inside a Frame and wires listeners so each interaction updates the label.
//!
//! Usage:
//!     zig build run-widget_simple

const std = @import("std");
const nimbus = @import("nimbus");
const ChangeEvent = nimbus.ChangeEvent;
const ActionEvent = nimbus.ActionEvent;

const State = struct {
    label:         *nimbus.Label,
    slider:        *nimbus.Slider,
    button_clicks: u32 = 0,
    buf:           [128]u8 = undefined,
};

fn refreshLabel(state: *State) void {
    const text = std.fmt.bufPrint(
        &state.buf,
        "clicks: {d} / value: {d}",
        .{ state.button_clicks, state.slider.getModel().getValue() },
    ) catch return;
    state.label.setText(text) catch {};
}

fn onClick(state: *State, _: *const ActionEvent) void {
    state.button_clicks += 1;
    refreshLabel(state);
}

fn onSliderChange(state: *State, _: *const ChangeEvent) void {
    refreshLabel(state);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget simple", 600, 120);

    // Build a horizontal row and put it in the window's center region
    // (the Window defaults to BorderLayout).
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());

    const button = try app.button("Click");
    button.component.setAlignY(.center);
    // Cap the button's vertical max to its min so it doesn't stretch when the
    // row is tall. Width stays inf so it can still grow horizontally if needed.
    button.component.setMaxSize(.{
        .width = std.math.inf(f32),
        .height = button.component.getMinSize().height,
    });
    const slider = try app.slider(.horizontal, 0, 50, 100);
    slider.component.setGrowX(1);     // slider eats leftover horizontal space
    slider.component.setAlignY(.center);
    const label = try app.label("clicks: 0 / value: 50");
    label.component.setAlignY(.center);

    try row.add(&button.component);
    try row.add(&slider.component);
    try row.add(&label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    var state = State{ .label = label, .slider = slider };
    try button.getModel().addActionListener(State, onClick, &state);
    try slider.getModel().addChangeListener(State, onSliderChange, &state);

    std.debug.print("Click the button or drag the slider. Close the window to exit.\n", .{});
    try app.run();
}
