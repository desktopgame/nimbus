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
dismiss_ctx: ?*anyopaque,
dismiss_cb: ?*const fn (*anyopaque) void,
focus_on_show: bool,

pub const Options = struct {
    no_activate: bool = false,
};

pub fn init(
    app: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !PopupWindow {
    return initWithOptions(app, owner, title, w, h, device, context, .{});
}

pub fn initWithOptions(
    app: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
    options: Options,
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
            .no_activate = options.no_activate,
        },
    );
    window.awt_window.?.setVisible(false);
    return .{
        .window = window,
        .app = app,
        .owner = owner,
        .shown = false,
        .allocator = app.allocator,
        .dismiss_ctx = null,
        .dismiss_cb = null,
        .focus_on_show = !options.no_activate,
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
    const work = self.owner.awt_window.?.monitorWorkarea();
    try self.showAtScreen(ownerLocalPopupRect(owner_pos, anchor, popup_size, scale, work), popup_size);
}

pub fn showAtScreen(
    self: *PopupWindow,
    rect: awt.Window.Rect,
    popup_size_logical: awt.Window.Size,
) !void {
    if (self.shown) return;
    self.bindEscape();
    self.window.onFocusLost(@ptrCast(self), focusLost);
    self.window.awt_window.?.setShouldClose(false);

    self.window.setPos(rect.x, rect.y);
    self.window.setSize(popup_size_logical.width, popup_size_logical.height);
    self.window.awt_window.?.setPos(rect.x, rect.y);
    self.window.awt_window.?.setSize(popup_size_logical.width, popup_size_logical.height);

    try self.app.registerUnownedWindowNoReap(&self.window, @ptrCast(self));
    self.shown = true;
    self.window.awt_window.?.setVisible(true);
    if (self.focus_on_show) self.window.awt_window.?.focus();
    self.window.repaint();
}

pub fn onDismiss(self: *PopupWindow, ctx: *anyopaque, cb: *const fn (*anyopaque) void) void {
    self.dismiss_ctx = ctx;
    self.dismiss_cb = cb;
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
    self.shown = false;
    self.window.awt_window.?.setVisible(false);
    self.app.unregisterWindow(&self.window);
    if (self.dismiss_cb) |cb| cb(self.dismiss_ctx.?);
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

pub fn scaleSizeToScreen(size: awt.Window.Size, scale: f32) awt.Window.Size {
    const s = if (scale > 0) scale else 1.0;
    return .{
        .width = @max(0, roundToI32(@as(f32, @floatFromInt(size.width)) * s)),
        .height = @max(0, roundToI32(@as(f32, @floatFromInt(size.height)) * s)),
    };
}

pub fn ownerLocalPopupRect(
    owner_pos: awt.Window.Point,
    local_anchor: LocalRect,
    popup_size: awt.Window.Size,
    scale: f32,
    work_area: awt.Window.Rect,
) awt.Window.Rect {
    return decidePopupRect(
        ownerLocalRectToScreen(owner_pos, local_anchor, scale),
        scaleSizeToScreen(popup_size, scale),
        work_area,
    );
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

test "ownerLocalPopupRect scales popup size before flip decision" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = 0, .y = 80, .width = 200, .height = 240 },
        ownerLocalPopupRect(
            .{ .x = 0, .y = 0 },
            .{ .x = 0, .y = 160, .width = 100, .height = 40 },
            .{ .width = 100, .height = 120 },
            2.0,
            .{ .x = 0, .y = 0, .width = 800, .height = 500 },
        ),
    );
}

test "ownerLocalPopupRect scales popup size before clamp decision" {
    try std.testing.expectEqual(
        awt.Window.Rect{ .x = 15, .y = 120, .width = 180, .height = 360 },
        ownerLocalPopupRect(
            .{ .x = 0, .y = 0 },
            .{ .x = 10, .y = 250, .width = 120, .height = 30 },
            .{ .width = 120, .height = 240 },
            1.5,
            .{ .x = 0, .y = 120, .width = 640, .height = 360 },
        ),
    );
}
