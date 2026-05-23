//! Simple framework example. Places Button + Slider + Label horizontally
//! inside a Frame and wires listeners so each interaction updates the label.
//!
//! Usage:
//!     zig build run-widget_simple

const std = @import("std");
const nimbus = @import("nimbus");

const noto_sans_ttf = @embedFile("assets/NotoSansJP-Regular.ttf");

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

fn onClick(user_data: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(user_data));
    state.button_clicks += 1;
    refreshLabel(state);
}

fn onSliderChange(user_data: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(user_data));
    refreshLabel(state);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io, noto_sans_ttf);
    defer app.deinit();

    const frame = try app.frame("widget simple", 600, 120);

    // Build a horizontal row and add it to the frame's window.
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    row.component.setGrowY(1);        // fill the window vertically

    const button = try app.button("Click");
    const slider = try app.slider(.horizontal, 0, 50, 100);
    slider.component.setGrowX(1);     // slider eats leftover horizontal space
    const label = try app.label("clicks: 0 / value: 50");

    try row.add(&button.component);
    try row.add(&slider.component);
    try row.add(&label.component);
    try frame.window.add(&row.component);

    var state = State{ .label = label, .slider = slider };
    try button.getModel().addActionListener(onClick, @ptrCast(&state));
    try slider.getModel().addChangeListener(onSliderChange, @ptrCast(&state));

    std.debug.print("Click the button or drag the slider. Close the window to exit.\n", .{});
    try app.run();
}
