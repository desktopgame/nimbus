//! Independent top-level window. See `framework/doc/frame.md`.

const std = @import("std");
const awt = @import("awt");
const Window = @import("Window.zig");
const MenuBar = @import("MenuBar.zig");

const Frame = @This();

window: Window,
menu_bar: ?*MenuBar = null,
owns_menu: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    app_ptr: *anyopaque,
    event_queue: *awt.EventQueue,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Frame {
    return .{
        .window = try Window.init(allocator, app_ptr, event_queue, title, w, h, device, context),
    };
}

/// Headless variant of `init`: the wrapped Window opens no OS window and
/// renders offscreen. See `Window.initHeadless`.
pub fn initHeadless(
    allocator: std.mem.Allocator,
    app_ptr: *anyopaque,
    event_queue: *awt.EventQueue,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Frame {
    return .{
        .window = try Window.initHeadless(allocator, app_ptr, event_queue, title, w, h, device, context),
    };
}

pub fn deinit(self: *Frame) void {
    // Tear down menu bar before window so its overlay state is consistent.
    if (self.menu_bar) |bar| {
        if (self.owns_menu) {
            bar.component.vtable.destroy(&bar.component, self.window.allocator);
        }
        self.menu_bar = null;
    }
    self.window.deinit();
}

pub fn asWindow(self: *Frame) *Window {
    return &self.window;
}

// ── menu bar ─────────────────────────────────────────────────────────────

pub fn setMenuBar(self: *Frame, bar: ?*MenuBar) !void {
    // Tear down previous.
    if (self.menu_bar) |old| {
        if (self.owns_menu) {
            old.component.vtable.destroy(&old.component, self.window.allocator);
        }
    }
    self.menu_bar = bar;
    self.owns_menu = bar != null;
    if (bar) |b| {
        b.setWindow(&self.window);
        try self.window.setMenuBar(&b.component);
    } else {
        try self.window.setMenuBar(null);
    }
}

pub fn setMenuBarBorrowed(self: *Frame, bar: ?*MenuBar) !void {
    if (self.menu_bar) |old| {
        if (self.owns_menu) {
            old.component.vtable.destroy(&old.component, self.window.allocator);
        }
    }
    self.menu_bar = bar;
    self.owns_menu = false;
    if (bar) |b| {
        b.setWindow(&self.window);
        try self.window.setMenuBar(&b.component);
    } else {
        try self.window.setMenuBar(null);
    }
}

pub fn getMenuBar(self: Frame) ?*MenuBar {
    return self.menu_bar;
}
