//! Horizontal menu bar (Frame's top strip). See `framework/doc/menu_bar.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Menu = @import("Menu.zig");
const Window = @import("Window.zig");

const MenuBar = @This();

const BG_COLOR = awt.Graphics.Color.rgb(0.94, 0.94, 0.96);
const BORDER_COLOR = awt.Graphics.Color.rgb(0.78, 0.78, 0.82);

component:  Component,
menus:      std.ArrayList(*Menu),
open_menu:  ?*Menu,
font:       awt.Graphics.TextFont,
color:      awt.Graphics.Color,
window:     ?*Window,
allocator:  std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn create(
    allocator: std.mem.Allocator,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*MenuBar {
    const bar = try allocator.create(MenuBar);
    errdefer allocator.destroy(bar);
    bar.* = .{
        .component = Component.init(allocator, &vtable),
        .menus     = .empty,
        .open_menu = null,
        .font      = font,
        .color     = color,
        .window    = null,
        .allocator = allocator,
    };
    // Min height ≒ font ascent + padding. Computed lazily once a menu is added.
    const m = font.measureString("Mg");
    bar.component.min_size = .{ .width = 0, .height = m.height + 8 };
    bar.component.max_size = .{ .width = std.math.inf(f32), .height = bar.component.min_size.height };
    return bar;
}

pub fn setWindow(self: *MenuBar, w: *Window) void {
    self.window = w;
    for (self.menus.items) |menu| menu.setWindow(w);
}

pub fn add(self: *MenuBar, menu: *Menu) !void {
    menu.setMode(.bar);
    try self.menus.append(self.allocator, menu);
    menu.component.parent = &self.component;
    if (self.window) |w| menu.setWindow(w);
    self.relayout();
}

pub fn count(self: MenuBar) usize {
    return self.menus.items.len;
}

pub fn at(self: MenuBar, index: usize) ?*Menu {
    if (index >= self.menus.items.len) return null;
    return self.menus.items[index];
}

fn relayout(self: *MenuBar) void {
    // Place each menu side by side starting at x=0, y=0.
    const max_h = self.component.size.height;
    var x: f32 = 0;
    for (self.menus.items) |menu| {
        const w = menu.component.min_size.width;
        menu.component.setBounds(.{ .x = x, .y = 0, .width = w, .height = max_h });
        x += w;
    }
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(_: *Component) void {}
fn uninstall(_: *Component) void {}

fn paint(self: *Component, g: *awt.Graphics) void {
    const bar: *MenuBar = @fieldParentPtr("component", self);
    const sz = self.size;

    // Re-layout in case width changed (Window.redraw sets us to full window width).
    bar.relayout();

    // Background.
    g.setColor(BG_COLOR);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Bottom border.
    g.setColor(BORDER_COLOR);
    g.fillRect(.{ .x = 0, .y = sz.height - 1, .width = sz.width, .height = 1 });

    // Menu labels.
    for (bar.menus.items) |menu| menu.component.paintAt(g);
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const bar: *MenuBar = @fieldParentPtr("component", self);

    switch (ev.payload) {
        .mouse => |m| {
            // Hit-test which Menu the cursor is over.
            var hovered: ?*Menu = null;
            for (bar.menus.items) |menu| {
                if (menu.component.containsWindowPoint(m.x, m.y)) {
                    hovered = menu;
                    break;
                }
            }

            switch (m.action) {
                .press => {
                    if (hovered) |menu| {
                        menu.component.vtable.processEvent(&menu.component, ev);
                        if (ev.isConsumed()) {
                            // Track which is open (we only ever have one open at a time).
                            bar.open_menu = if (menu.open) menu else null;
                        }
                    }
                },
                .release => {},
                .move => {
                    // Update rollover on each.
                    for (bar.menus.items) |menu| {
                        const inside = menu == hovered;
                        if (menu.model.isRollover() != inside) {
                            menu.model.setRollover(inside);
                        }
                    }
                    // If a menu is open and user hovered a different one, switch.
                    if (bar.open_menu) |cur| {
                        if (hovered) |new| {
                            if (cur != new) {
                                cur.hide();
                                if (bar.window) |w| {
                                    const origin = new.component.absoluteOriginInWindow();
                                    new.show(w, .{
                                        .x = origin.x,
                                        .y = origin.y + new.component.size.height,
                                    }) catch {};
                                    bar.open_menu = new;
                                }
                            }
                        }
                    }
                },
                .scroll => {},
            }
        },
        .key => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const bar: *MenuBar = @fieldParentPtr("component", self);
    self.deinit();
    for (bar.menus.items) |menu| menu.component.vtable.destroy(&menu.component, allocator);
    bar.menus.deinit(allocator);
    allocator.destroy(bar);
}
