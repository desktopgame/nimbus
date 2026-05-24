//! ComboBox smoke test. A drop-down with three items; the label below
//! shows the current selection.
//!
//! Usage:
//!     zig build run-widget_combobox
//!
//! Try:
//!     - click → popup opens at the field's bottom
//!     - hover over items in the popup → row highlights
//!     - click an item → selection commits, popup closes, label updates
//!     - press ↑ / ↓ when focused (popup closed) → selection cycles inline
//!     - press Enter / Space when focused (popup closed) → popup opens
//!     - press ↑ / ↓ / Enter inside the popup → keyboard navigation + commit
//!     - press Escape when popup open → closes without changing selection

const std = @import("std");
const nimbus = @import("nimbus");

const State = struct {
    combo: *nimbus.ComboBox,
    label: *nimbus.Label,
    buf:   [128]u8 = undefined,
};

fn refresh(state: *State) void {
    const sel = state.combo.getSelectedItem() orelse "(none)";
    const text = std.fmt.bufPrint(&state.buf, "selected: {s}", .{sel}) catch return;
    state.label.setText(text) catch {};
}

fn onChange(user_data: *anyopaque) void {
    const state: *State = @ptrCast(@alignCast(user_data));
    refresh(state);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_combobox", 400, 200);

    const items = [_][]const u8{ "Apple", "Banana", "Cherry", "Durian" };
    const combo = try app.comboBox(&items);

    const label = try app.label("selected: Apple");

    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());
    try col.add(&combo.component);
    try col.add(&label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    var state = State{ .combo = combo, .label = label };
    refresh(&state);
    try combo.addChangeListener(onChange, @ptrCast(&state));

    std.debug.print("Click the combobox or use ↑ / ↓ / Enter to pick an item.\n", .{});
    try app.run();
}
