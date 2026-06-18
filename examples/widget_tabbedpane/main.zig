//! TabbedPane smoke test. Three tabs with distinct colored pages; clicking
//! a tab switches the visible content.
//!
//! Usage:
//!     zig build run-widget_tabbedpane

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

fn page(app: *nimbus.Application, title: []const u8, detail: []const u8, color: awt.Graphics.Color) !*nimbus.Panel {
    const p = try app.panel();
    p.setBackground(color);
    p.asContainer().setLayout(null);

    const heading = try app.label(title);
    heading.component.setBounds(.{ .x = 18, .y = 18, .width = 360, .height = 26 });
    const body = try app.label(detail);
    body.component.setBounds(.{ .x = 18, .y = 52, .width = 420, .height = 24 });

    try p.asContainer().add(&heading.component);
    try p.asContainer().add(&body.component);
    return p;
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_tabbedpane", 520, 320);

    const tabs = try app.tabbedPane();
    tabs.asComponent().setGrowX(1);
    tabs.asComponent().setGrowY(1);

    const overview = try page(
        app,
        "Overview",
        "General account information lives on this page.",
        awt.Graphics.Color.rgb(0.86, 0.93, 0.99),
    );
    const activity = try page(
        app,
        "Activity",
        "Recent events and status updates are shown here.",
        awt.Graphics.Color.rgb(0.90, 0.96, 0.88),
    );
    const settings = try page(
        app,
        "Settings",
        "Toggles and preferences would be edited in this tab.",
        awt.Graphics.Color.rgb(0.98, 0.91, 0.86),
    );

    try tabs.addTab("Overview", &overview.container.component);
    try tabs.addTab("Activity", &activity.container.component);
    try tabs.addTab("Settings", &settings.container.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, tabs.asComponent());

    std.debug.print("Click the tab strip to switch between pages.\n", .{});
    try app.run();
}
