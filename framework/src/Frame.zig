//! Independent top-level window. See `framework/doc/frame.md`.

const std = @import("std");
const awt = @import("awt");
const Window = @import("Window.zig");

const Frame = @This();

window: Window,

pub fn init(
    allocator: std.mem.Allocator,
    app_ptr: *anyopaque,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Frame {
    return .{
        .window = try Window.init(allocator, app_ptr, title, w, h, device, context),
    };
}

pub fn deinit(self: *Frame) void {
    self.window.deinit();
}

pub fn asWindow(self: *Frame) *Window {
    return &self.window;
}
