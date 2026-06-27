//! Horizontal menu bar (Frame's top strip). See `framework/doc/menu_bar.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Menu = @import("Menu.zig");
const Window = @import("Window.zig");
const log = @import("log.zig");

const MenuBar = @This();

// Colors come from `component.theme`: surface_window (background) and
// border_soft (bottom border). See `framework/doc/theme.md`.

component: Component,
menus: std.ArrayList(*Menu),
open_menu: ?*Menu,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
window: ?*Window,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub const look_vtable = Component.LookVTable{
    .paint = lookPaint,
    .paintOver = lookPaintOver,
    .measureMinSize = lookMeasureMinSize,
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
        .menus = .empty,
        .open_menu = null,
        .font = font,
        .color = color,
        .window = null,
        .allocator = allocator,
    };
    // Min height ≁Efont ascent + padding. Computed lazily once a menu is added.
    bar.component.role = .menu_bar;
    bar.component.tree_children = .{ .count = treeChildCount, .at = treeChildAt };
    bar.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
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

pub fn hoverSwitchTarget(open_menu: ?*Menu, hovered: ?*Menu) ?*Menu {
    const cur = open_menu orelse return null;
    const new = hovered orelse return null;
    return if (cur != new) new else null;
}

pub fn clearOpenMenu(self: *MenuBar, dismissed: *Menu) void {
    if (self.open_menu == dismissed) self.open_menu = null;
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

fn treeChildCount(c: *const Component) usize {
    const bar: *const MenuBar = @fieldParentPtr("component", c);
    return bar.menus.items.len;
}

fn treeChildAt(c: *const Component, index: usize) *Component {
    const bar: *const MenuBar = @fieldParentPtr("component", c);
    return &bar.menus.items[index].component;
}

fn install(_: *Component) !void {}
fn uninstall(_: *Component) void {}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const bar: *MenuBar = @fieldParentPtr("component", self);
    const sz = self.size;

    // Re-layout in case width changed (Window.redraw sets us to full window width).
    bar.relayout();

    // Background.
    g.setColor(self.theme.surface_window);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Bottom border.
    g.setColor(self.theme.border_soft);
    g.fillRect(.{ .x = 0, .y = sz.height - 1, .width = sz.width, .height = 1 });

    // Menu labels.
    for (bar.menus.items) |menu| menu.component.paintAt(g);
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    return self.min_size;
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
                        if (MenuBar.hoverSwitchTarget(bar.open_menu, menu)) |new| {
                            if (bar.open_menu) |cur| cur.hide();
                            if (bar.window) |w| {
                                const origin = new.component.absoluteOriginInWindow();
                                new.show(w, .{
                                    .x = origin.x,
                                    .y = origin.y + new.component.size.height,
                                }) catch |err|
                                    log.warn("menu", "show (bar press-switch) failed: {s}", .{@errorName(err)});
                                bar.open_menu = if (new.open) new else null;
                            }
                            ev.consume();
                            return;
                        }
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
                    if (MenuBar.hoverSwitchTarget(bar.open_menu, hovered)) |new| {
                        if (bar.open_menu) |cur| cur.hide();
                        if (bar.window) |w| {
                            const origin = new.component.absoluteOriginInWindow();
                            new.show(w, .{
                                .x = origin.x,
                                .y = origin.y + new.component.size.height,
                            }) catch |err|
                                log.warn("menu", "show (bar hover-switch) failed: {s}", .{@errorName(err)});
                            bar.open_menu = if (new.open) new else null;
                        }
                    }
                },
                .scroll => {},
            }
        },
        .key, .char, .focus, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const bar: *MenuBar = @fieldParentPtr("component", self);
    self.deinit();
    for (bar.menus.items) |menu| menu.component.vtable.destroy(&menu.component, allocator);
    bar.menus.deinit(allocator);
    allocator.destroy(bar);
}

test "menu bar hover switch only while another top menu is open" {
    var first: Menu = undefined;
    var second: Menu = undefined;

    try std.testing.expectEqual(@as(?*Menu, null), MenuBar.hoverSwitchTarget(null, &second));
    try std.testing.expectEqual(@as(?*Menu, null), MenuBar.hoverSwitchTarget(&first, null));
    try std.testing.expectEqual(@as(?*Menu, null), MenuBar.hoverSwitchTarget(&first, &first));
    try std.testing.expectEqual(@as(?*Menu, &second), MenuBar.hoverSwitchTarget(&first, &second));
}

test "menu bar dismiss clears only matching open menu" {
    var first: Menu = undefined;
    var second: Menu = undefined;
    var bar: MenuBar = undefined;

    bar.open_menu = &first;
    bar.clearOpenMenu(&second);
    try std.testing.expectEqual(@as(?*Menu, &first), bar.open_menu);

    bar.clearOpenMenu(&first);
    try std.testing.expectEqual(@as(?*Menu, null), bar.open_menu);
}
