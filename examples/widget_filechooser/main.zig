const std = @import("std");
const nimbus = @import("nimbus");
const ActionEvent = nimbus.ActionEvent;

const State = struct {
    chooser: *nimbus.FileChooser,
    label: *nimbus.Label,
};

fn onChoose(state: *State, _: *const ActionEvent) void {
    if (state.chooser.showOpenDialog() == .ok) {
        if (state.chooser.getSelectedPath()) |path| {
            state.label.setText(path) catch {};
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_filechooser", 560, 160);
    const chooser = try app.fileChooser(&frame.window);
    defer chooser.destroy();
    try chooser.addFilter("Text", &.{ "txt", "md" });
    try chooser.addFilter("All Files", &.{});

    const row = try app.container();
    row.setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 8));

    const button = try app.button("Open...");
    const label = try app.label("(no file selected)");
    label.component.setGrowX(1);
    var state = State{ .chooser = chooser, .label = label };
    try button.getModel().addActionListener(State, onChoose, &state);

    try row.add(&button.component);
    try row.add(&label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    std.debug.print("Click Open... to show the FileChooser.\n", .{});
    try app.run();
}
