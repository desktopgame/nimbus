//! Borderless top-level popup window primitive.
//!
//! This is intentionally only the primitive slice: callers can register and
//! dismiss a separate OS child window, and can test placement without opening
//! a window. ComboBox migration is a later slice.

const std = @import("std");
const awt = @import("awt");
const Window = @import("Window.zig");
const Application = @import("Application.zig");
const keybinding = @import("keybinding.zig");
const log = @import("log.zig");

const PopupWindow = @This();

pub const LocalRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

window: Window,
app: *Application,
owner: *Window,
shown: bool,
allocator: std.mem.Allocator,

pub fn init(
    app: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !PopupWindow {
    var window = try Window.initWithFlags(
        app.allocator,
        @ptrCast(app),
        app.event_queue,
        title,
        w,
        h,
        device,
        context,
        .{
            .borderless = true,
            .floating = true,
            .no_taskbar = true,
        },
    );
    window.awt_window.?.setVisible(false);
    return .{
        .window = window,
        .app = app,
        .owner = owner,
        .shown = false,
        .allocator = app.allocator,
    };
}

pub fn deinit(self: *PopupWindow) void {
    if (self.shown) self.dismiss();
    self.window.deinit();
}

pub fn destroy(self: *PopupWindow) void {
    const allocator = self.allocator;
    self.deinit();
    allocator.destroy(self);
}

pub fn showAtLocal(self: *PopupWindow, anchor: LocalRect, popup_size: awt.Window.Size) !void {
    if (self.owner.awt_window == null) return error.OwnerHasNoOsWindow;
    const owner_pos = self.owner.getPos();
    const scale = self.owner.awt_window.?.contentScale();
    const anchor_screen = ownerLocalRectToScreen(owner_pos, anchor, scale);
    const work = self.owner.awt_window.?.monitorWorkarea();
    try self.showAtScreen(anchor_screen, popup_size, work);
}

pub fn showAtScreen(
    self: *PopupWindow,
    anchor_screen: awt.Window.Rect,
    popup_size: awt.Window.Size,
    work_area: awt.Window.Rect,
) !void {
    if (self.shown) return;
    self.bindEscape();
    self.window.onFocusLost(@ptrCast(self), focusLost);
    self.window.awt_window.?.setShouldClose(false);

    const rect = decidePopupRect(anchor_screen, popup_size, work_area);
    self.window.setPos(rect.x, rect.y);
    self.window.setSize(rect.width, rect.height);
    self.window.awt_window.?.setPos(rect.x, rect.y);
    self.window.awt_window.?.setSize(rect.width, rect.height);

    try self.app.registerUnownedWindowNoReap(&self.window, @ptrCast(self));
    self.shown = true;
    self.window.awt_window.?.setVisible(true);
    self.window.awt_window.?.focus();
    self.window.repaint();
}

pub fn dismissFromSelection(self: *PopupWindow) void {
    self.dismiss();
}

pub fn dismissFromFocusLoss(self: *PopupWindow) void {
    self.dismiss();
}

pub fn dismissFromEscape(self: *PopupWindow) void {
    self.dismiss();
}

pub fn dismiss(self: *PopupWindow) void {
    if (!self.shown) return;
    self.window.awt_window.?.setVisible(false);
    self.app.unregisterWindow(&self.window);
    self.shown = false;
    awt.postEmptyEvent();
}

pub fn isShown(self: PopupWindow) bool {
    return self.shown;
}

fn bindEscape(self: *PopupWindow) void {
    self.window.container.component.bindKey(
        keybinding.KeyStroke.of(.escape),
        keybinding.Handler.typed(PopupWindow, escDismiss, self),
    ) catch |err| log.warn("popup", "esc binding failed: {s}", .{@errorName(err)});
}

fn escDismiss(self: *PopupWindow) void {
    self.dismissFromEscape();
}

fn focusLost(ctx: *anyopaque) void {
    const self: *PopupWindow = @ptrCast(@alignCast(ctx));
    self.dismissFromFocusLoss();
}

pub fn ownerLocalRectToScreen(owner_pos: awt.Window.Point, local: LocalRect, scale: f32) awt.Window.Rect {
    const s = if (scale > 0) scale else 1.0;
    return .{
        .x = owner_pos.x + roundToI32(local.x * s),
        .y = owner_pos.y + roundToI32(local.y * s),
        .width = @max(0, roundToI32(local.width * s)),
        .height = @max(0, roundToI32(local.height * s)),
    };
}

pub fn decidePopupRect(
    anchor: awt.Window.Rect,
    popup_size: awt.Window.Size,
    work_area: awt.Window.Rect,
) awt.Window.Rect {
    const width = @max(0, popup_size.width);
    const height = @max(0, popup_size.height);
    const x = clampStart(anchor.x, width, work_area.x, work_area.width);

    const work_bottom = work_area.y + work_area.height;
    const below_y = anchor.y + anchor.height;
    const above_y = anchor.y - height;
    const y = if (below_y + height <= work_bottom)
        below_y
    else if (above_y >= work_area.y)
        above_y
    else
        clampStart(below_y, height, work_area.y, work_area.height);

    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn clampStart(preferred: i32, size: i32, area_start: i32, area_size: i32) i32 {
    if (area_size <= 0) return area_start;
    if (size >= area_size) return area_start;
    const max_start = area_start + area_size - size;
    return @min(@max(preferred, area_start), max_start);
}

fn roundToI32(v: f32) i32 {
    return @intFromFloat(@round(v));
}

test "decidePopupRect places below when it fits" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = 100, .y = 130, .width = 180, .height = 120 },
        decidePopupRect(
            .{ .x = 100, .y = 100, .width = 80, .height = 30 },
            .{ .width = 180, .height = 120 },
            .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        ),
    );
}

test "decidePopupRect flips above when below overflows" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = 100, .y = 380, .width = 180, .height = 120 },
        decidePopupRect(
            .{ .x = 100, .y = 500, .width = 80, .height = 30 },
            .{ .width = 180, .height = 120 },
            .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        ),
    );
}

test "decidePopupRect clamps when neither side fits" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = 100, .y = 60, .width = 180, .height = 500 },
        decidePopupRect(
            .{ .x = 100, .y = 300, .width = 80, .height = 30 },
            .{ .width = 180, .height = 500 },
            .{ .x = 0, .y = 40, .width = 800, .height = 520 },
        ),
    );
}

test "decidePopupRect preserves work area offset with negative origin" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = -1720, .y = 200, .width = 260, .height = 180 },
        decidePopupRect(
            .{ .x = -1720, .y = 160, .width = 120, .height = 40 },
            .{ .width = 260, .height = 180 },
            .{ .x = -1920, .y = 40, .width = 1920, .height = 1040 },
        ),
    );
}

test "ownerLocalRectToScreen applies owner position and content scale" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = -90, .y = 235, .width = 150, .height = 45 },
        ownerLocalRectToScreen(
            .{ .x = -120, .y = 200 },
            .{ .x = 20, .y = 23.5, .width = 100, .height = 30 },
            1.5,
        ),
    );
}
