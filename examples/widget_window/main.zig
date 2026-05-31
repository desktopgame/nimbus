//! Window-geometry sync demo. A Frame with three buttons that drive (and read
//! back) the window's own position and size from code:
//!   - "位置を変更"   toggles the window between two screen positions.
//!   - "サイズを変更" toggles the window between two sizes.
//!   - "現在値を表示" just refreshes the label — no geometry change.
//! A label mirrors the geometry (`window.getPos` / `getSize`).
//!
//! This exercises Application's event-loop-tail geometry sync: `setPos` /
//! `setSize` update the framework-side model, and the change is pushed to the
//! OS window at the end of the loop iteration (see `application.md`「OS との同期」).
//! Resizing the window by dragging its edge keeps working — the OS resize
//! callback writes the realized size back into the model.
//!
//! Usage:
//!     zig build run-widget_window
//!
//! Test recipe:
//!     - click "サイズを変更" → the window grows / shrinks; label updates
//!     - click "位置を変更"   → the window jumps between two spots; label updates
//!     - drag the window (title bar / edge) to move / resize it, then click
//!       "現在値を表示" → the label reflects the new OS geometry (proves the
//!       OS → model direction of the sync)

const std = @import("std");
const nimbus = @import("nimbus");
const Event = nimbus.ChangeListenerList.Event;

const State = struct {
    frame: *nimbus.Frame,
    label: *nimbus.Label,
    moved: bool = false,
    grown: bool = false,
    buf:   [128]u8 = undefined,
};

fn refreshLabel(s: *State) void {
    const p = s.frame.window.getPos();
    const sz = s.frame.window.getSize();
    const text = std.fmt.bufPrint(
        &s.buf,
        "pos=({d}, {d})  size=({d} x {d})",
        .{ p.x, p.y, sz.width, sz.height },
    ) catch return;
    s.label.setText(text) catch {};
}

fn onShow(s: *State, _: *const Event) void {
    // Refresh the label without touching geometry — handy for reading back the
    // window's pos/size after dragging it (the move/resize callbacks keep the
    // model in sync, so this reflects the live OS geometry).
    refreshLabel(s);
}

fn onMove(s: *State, _: *const Event) void {
    s.moved = !s.moved;
    if (s.moved) s.frame.window.setPos(500, 350) else s.frame.window.setPos(150, 150);
    refreshLabel(s);
}

fn onResize(s: *State, _: *const Event) void {
    s.grown = !s.grown;
    if (s.grown) s.frame.window.setSize(640, 480) else s.frame.window.setSize(400, 280);
    refreshLabel(s);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_window", 400, 280);

    const label = try app.label("pos/size はボタンで変更");
    var state = State{ .frame = frame, .label = label };

    const move_btn = try app.button("位置を変更");
    const size_btn = try app.button("サイズを変更");
    const show_btn = try app.button("現在値を表示");
    try move_btn.getModel().addActionListener(State, onMove, &state);
    try size_btn.getModel().addActionListener(State, onResize, &state);
    try show_btn.getModel().addActionListener(State, onShow, &state);

    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());
    try col.add(&move_btn.component);
    try col.add(&size_btn.component);
    try col.add(&show_btn.component);
    try col.add(&label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    // Seed the label with the initial geometry.
    refreshLabel(&state);

    std.debug.print("Click buttons to move / resize the window.\n", .{});
    try app.run();
}
