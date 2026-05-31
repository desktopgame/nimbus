//! Standalone popup menu (right-click / dropdown).
//! See `framework/doc/popup_menu.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Event = @import("ChangeListenerList.zig").Event;
const ButtonModel = @import("ButtonModel.zig");
const MenuItem = @import("MenuItem.zig");
const Menu = @import("Menu.zig");
const Window = @import("Window.zig");
const log = @import("log.zig");

const PopupMenu = @This();

const POPUP_BORDER_COLOR = awt.Graphics.Color.rgb(0.55, 0.55, 0.60);
const POPUP_BG_COLOR = awt.Graphics.Color.rgb(1, 1, 1);

popup_root: Component,
items:      std.ArrayList(*Component),
open:       bool,
open_child: ?*Menu,            // hovered submenu, if any
window:     ?*Window,
allocator:  std.mem.Allocator,

const popup_vtable = Component.VTable{
    .install      = popupInstall,
    .uninstall    = popupUninstall,
    .paint        = popupPaint,
    .processEvent = popupProcessEvent,
    .destroy      = popupDestroyNoop,
};

pub fn create(allocator: std.mem.Allocator) !*PopupMenu {
    const pm = try allocator.create(PopupMenu);
    pm.* = .{
        .popup_root = Component.init(allocator, &popup_vtable),
        .items      = .empty,
        .open       = false,
        .open_child = null,
        .window     = null,
        .allocator  = allocator,
    };
    return pm;
}

pub fn destroy(self: *PopupMenu) void {
    if (self.open) self.hide();
    self.popup_root.deinit();
    for (self.items.items) |item| item.vtable.destroy(item, self.allocator);
    self.items.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn add(self: *PopupMenu, item: *Component) !void {
    std.debug.assert(!self.open);
    try self.items.append(self.allocator, item);
    item.parent = null;
    if (item.vtable == &Menu.vtable) {
        const sub: *Menu = @fieldParentPtr("component", item);
        sub.setMode(.item);
    } else if (modelOf(item)) |m| {
        try m.addActionListener(PopupMenu, onItemAction, self);
    }
}

pub fn addSeparator(self: *PopupMenu) !void {
    const MenuSeparator = @import("MenuSeparator.zig");
    const sep = try MenuSeparator.create(self.allocator);
    try self.add(&sep.component);
}

pub fn show(self: *PopupMenu, w: *Window, x: f32, y: f32) !void {
    if (self.open) return;
    self.window = w;

    // Cache window pointer for any Menu submenus.
    for (self.items.items) |item| {
        if (item.vtable == &Menu.vtable) {
            const sub: *Menu = @fieldParentPtr("component", item);
            sub.setWindow(w);
        }
    }

    // Compute popup size.
    var popup_w: f32 = 0;
    var popup_h: f32 = 0;
    for (self.items.items) |item| {
        if (item.min_size.width > popup_w) popup_w = item.min_size.width;
        popup_h += item.min_size.height;
    }
    popup_w = @max(popup_w, 80);
    popup_h += 2;  // border

    const win_size = w.awt_window.size();
    const win_w: f32 = @floatFromInt(win_size.width);
    const win_h: f32 = @floatFromInt(win_size.height);
    var px = x;
    var py = y;
    if (px + popup_w > win_w) px = @max(0, win_w - popup_w);
    if (py + popup_h > win_h) py = @max(0, win_h - popup_h);

    self.popup_root.position = .{ .x = px, .y = py };
    self.popup_root.size = .{ .width = popup_w, .height = popup_h };

    var cur_y: f32 = 1;
    for (self.items.items) |item| {
        item.parent = &self.popup_root;
        item.setBounds(.{
            .x = 0,
            .y = cur_y,
            .width = popup_w,
            .height = item.min_size.height,
        });
        cur_y += item.min_size.height;
    }

    try w.overlays.add(&self.popup_root, @ptrCast(self), onOverlayDismiss);
    self.open = true;
}

pub fn hide(self: *PopupMenu) void {
    if (!self.open) return;
    if (self.open_child) |child| {
        child.hide();
        self.open_child = null;
    }
    if (self.window) |w| w.overlays.remove(@ptrCast(self));
    self.open = false;
    for (self.items.items) |item| item.parent = null;
}

fn onOverlayDismiss(user_data: *anyopaque) void {
    const self: *PopupMenu = @ptrCast(@alignCast(user_data));
    if (self.open_child) |child| {
        child.hide();
        self.open_child = null;
    }
    self.open = false;
    for (self.items.items) |item| item.parent = null;
}

fn onItemAction(self: *PopupMenu, _: *const Event) void {
    if (self.window) |w| w.overlays.dismissAll();
}

fn modelOf(c: *Component) ?*ButtonModel {
    const CheckBoxMenuItem = @import("CheckBoxMenuItem.zig");
    if (c.vtable == &MenuItem.vtable) {
        const it: *MenuItem = @fieldParentPtr("component", c);
        return it.model;
    }
    if (c.vtable == &CheckBoxMenuItem.vtable) {
        const it: *CheckBoxMenuItem = @fieldParentPtr("component", c);
        return &it.model.button;
    }
    return null;
}

// ── popup_root vtable ────────────────────────────────────────────────────

fn popupInstall(_: *Component) !void {}
fn popupUninstall(_: *Component) void {}
fn popupDestroyNoop(_: *Component, _: std.mem.Allocator) void {}

fn popupPaint(self: *Component, g: *awt.Graphics) void {
    const pm: *PopupMenu = @fieldParentPtr("popup_root", self);
    const sz = self.size;

    g.setColor(POPUP_BG_COLOR);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    for (pm.items.items) |item| item.paintAt(g);

    // Border drawn last so item hover backgrounds don't overlap the edges.
    g.setColor(POPUP_BORDER_COLOR);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = sz.height - 1, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = sz.height });
    g.fillRect(.{ .x = sz.width - 1, .y = 0, .width = 1, .height = sz.height });
}

fn popupProcessEvent(self: *Component, ev: *Component.Event) void {
    const pm: *PopupMenu = @fieldParentPtr("popup_root", self);
    switch (ev.payload) {
        .mouse => |m| {
            if (m.action == .move) {
                var hovered_menu: ?*Menu = null;
                for (pm.items.items) |item| {
                    if (item.containsWindowPoint(m.x, m.y) and item.vtable == &Menu.vtable) {
                        hovered_menu = @fieldParentPtr("component", item);
                        break;
                    }
                }
                if (pm.open_child) |open_sub| {
                    if (hovered_menu != open_sub) {
                        open_sub.hide();
                        pm.open_child = null;
                    }
                }
                for (pm.items.items) |item| item.vtable.processEvent(item, ev);
                if (hovered_menu) |sub| {
                    if (!sub.open) {
                        if (pm.window) |w| {
                            const ox = self.position.x + self.size.width;
                            const oy = self.position.y + sub.component.position.y;
                            sub.show(w, .{ .x = ox, .y = oy }) catch |err|
                                log.warn("menu", "show (popup submenu hover) failed: {s}", .{@errorName(err)});
                            pm.open_child = sub;
                        }
                    }
                }
                return;
            }
            var i: usize = pm.items.items.len;
            while (i > 0) {
                i -= 1;
                const item = pm.items.items[i];
                if (item.containsWindowPoint(m.x, m.y)) {
                    item.vtable.processEvent(item, ev);
                    if (ev.isConsumed()) return;
                }
            }
        },
        .key, .char, .focus, .composition => {},
    }
}
