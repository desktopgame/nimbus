//! Menu widget with two render modes (bar / item) and an item-list popup.
//! See `framework/doc/menu.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const listener = @import("listener.zig");
const ChangeEvent = listener.ChangeEvent;
const ActionEvent = listener.ActionEvent;
const Container = @import("Container.zig");
const ButtonModel = @import("ButtonModel.zig");
const MenuItem = @import("MenuItem.zig");
const Window = @import("Window.zig");
const keybinding = @import("keybinding.zig");
const log = @import("log.zig");

const Menu = @This();

pub const Mode = enum { bar, item };

const BAR_PADDING_X: f32 = 12;
const ROW_PADDING_X: f32 = 8;
const ROW_PADDING_Y: f32 = 6;
const ARROW_SLOT_W: f32 = 16;

// Popup colors come from `component.theme`: surface_input (background) and
// border (frame). See `framework/doc/theme.md`.

component: Component,
popup_root: Component,
text: []const u8,
icon: ?awt.Image,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
items: std.ArrayList(*Component),
model: *ButtonModel,
owns_model: bool,
mode: Mode,
open: bool,
open_child: ?*Menu,
window: ?*Window,
/// Byte index into `text` of the mnemonic character (underline paint),
/// or null. Matching uses `component.mnemonic` (Window's mnemonic scan).
mnemonic_index: ?usize,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

const popup_vtable = Component.VTable{
    .install = popupInstall,
    .uninstall = popupUninstall,
    .paint = popupPaint,
    .processEvent = popupProcessEvent,
    .destroy = popupDestroyNoop,
};

pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Menu {
    const model = try allocator.create(ButtonModel);
    errdefer allocator.destroy(model);
    model.* = ButtonModel.init(allocator);
    errdefer model.deinit();

    const menu = try allocator.create(Menu);
    errdefer allocator.destroy(menu);

    const text_dup = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dup);

    menu.* = .{
        .component = Component.init(allocator, &vtable),
        .popup_root = Component.init(allocator, &popup_vtable),
        .text = text_dup,
        .icon = null,
        .font = font,
        .color = color,
        .items = .empty,
        .model = model,
        .owns_model = true,
        .mode = .item,
        .open = false,
        .open_child = null,
        .window = null,
        .mnemonic_index = null,
        .allocator = allocator,
    };
    menu.component.role = .menu;
    menu.applyMetrics();
    try Menu.vtable.install(&menu.component);
    return menu;
}

fn applyMetrics(self: *Menu) void {
    const m = self.font.measureString(self.text);
    switch (self.mode) {
        .bar => {
            self.component.min_size = .{
                .width = m.width + BAR_PADDING_X * 2,
                .height = m.height + ROW_PADDING_Y * 2,
            };
            self.component.max_size = .{
                .width = self.component.min_size.width,
                .height = self.component.min_size.height,
            };
        },
        .item => {
            self.component.min_size = .{
                .width = MenuItem.ICON_SLOT_WIDTH + m.width + ARROW_SLOT_W + ROW_PADDING_X * 2,
                .height = m.height + MenuItem.PADDING_Y * 2,
            };
            self.component.max_size = .{
                .width = std.math.inf(f32),
                .height = self.component.min_size.height,
            };
        },
    }
}

pub fn setMode(self: *Menu, mode: Mode) void {
    if (self.mode == mode) return;
    self.mode = mode;
    self.applyMetrics();
    self.component.markLayoutDirty();
}

pub fn setWindow(self: *Menu, w: *Window) void {
    self.window = w;
    for (self.items.items) |item| {
        if (item.vtable == &Menu.vtable) {
            const sub: *Menu = @fieldParentPtr("component", item);
            sub.setWindow(w);
        }
    }
}

pub fn add(self: *Menu, child: *Component) !void {
    try self.items.append(self.allocator, child);
    child.parent = null; // will be set to popup_root on show
    if (child.vtable == &Menu.vtable) {
        const sub: *Menu = @fieldParentPtr("component", child);
        sub.setMode(.item);
        if (self.window) |w| sub.setWindow(w);
    } else if (modelOf(child)) |m| {
        // Auto-dismiss after item action.
        try m.addActionListener(Menu, onItemAction, self);
    }
}

pub fn addSeparator(self: *Menu) !void {
    const MenuSeparator = @import("MenuSeparator.zig");
    const sep = try MenuSeparator.create(self.allocator);
    // Created internally (no Application factory in between): inherit this
    // menu's theme so a custom theme reaches the separator too.
    sep.component.theme = self.component.theme;
    try self.add(&sep.component);
}

pub fn getText(self: Menu) []const u8 {
    return self.text;
}

pub fn setText(self: *Menu, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.applyMetrics();
}

pub fn getIcon(self: Menu) ?awt.Image {
    return self.icon;
}

pub fn setIcon(self: *Menu, icon: ?awt.Image) void {
    self.icon = icon;
    self.component.repaint();
}

pub fn getModel(self: Menu) *ButtonModel {
    return self.model;
}

/// Programmatic activation. For a bar menu this toggles the popup (the
/// mnemonic / Alt+letter entry point); item-mode menus open on hover only,
/// so this is a no-op for them. No-op while disabled.
pub fn doClick(self: *Menu) void {
    if (!self.model.enabled) return;
    if (self.mode != .bar) return;
    if (self.open) {
        self.hide();
        return;
    }
    const w = self.window orelse return;
    const origin = self.component.absoluteOriginInWindow();
    self.show(w, .{ .x = origin.x, .y = origin.y + self.component.size.height }) catch |err|
        log.warn("menu", "show (doClick) failed: {s}", .{@errorName(err)});
}

/// Assign the mnemonic character (`Alt+ch` opens this bar menu; the matching
/// letter in the label is underlined). Stores only — resolution happens in
/// the Window's mnemonic scan stage.
pub fn setMnemonic(self: *Menu, ch: u8) void {
    self.component.mnemonic = std.ascii.toLower(ch);
    self.mnemonic_index = std.ascii.indexOfIgnoreCase(self.text, &[1]u8{ch});
    self.component.repaint();
}

// ── popup open/close ─────────────────────────────────────────────────────

pub fn show(self: *Menu, w: *Window, anchor: Component.Point) !void {
    if (self.open) return;
    self.window = w;

    // Compute popup size: width = max item min_width, height = sum of mins.
    var popup_w: f32 = 0;
    var popup_h: f32 = 0;
    for (self.items.items) |item| {
        if (item.min_size.width > popup_w) popup_w = item.min_size.width;
        popup_h += item.min_size.height;
    }
    popup_w = @max(popup_w, 80);
    popup_h += 2; // border

    // Clamp to window (v1: simple reposition).
    const win_size = w.getSize();
    const win_w: f32 = @floatFromInt(win_size.width);
    const win_h: f32 = @floatFromInt(win_size.height);
    var x = anchor.x;
    var y = anchor.y;
    if (x + popup_w > win_w) x = @max(0, win_w - popup_w);
    if (y + popup_h > win_h) y = @max(0, win_h - popup_h);

    self.popup_root.position = .{ .x = x, .y = y };
    self.popup_root.size = .{ .width = popup_w, .height = popup_h };

    // Layout items vertically inside popup (with 1px top border offset).
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

pub fn hide(self: *Menu) void {
    if (!self.open) return;
    if (self.open_child) |child| {
        child.hide();
        self.open_child = null;
    }
    if (self.window) |w| w.overlays.remove(@ptrCast(self));
    self.open = false;
    // Clear child parents so they don't dangle.
    for (self.items.items) |item| item.parent = null;
}

fn onOverlayDismiss(user_data: *anyopaque) void {
    const self: *Menu = @ptrCast(@alignCast(user_data));
    // Don't call overlays.remove (dismissAll already popped us).
    if (self.open_child) |child| {
        child.hide();
        self.open_child = null;
    }
    self.open = false;
    for (self.items.items) |item| item.parent = null;
}

fn onItemAction(self: *Menu, _: *const ActionEvent) void {
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

// ── keyboard navigation (popup-local) ────────────────────────────────────
// Highlight reuses ButtonModel.rollover (案A in framework_backlog #6b): one
// truth for "this row is hot", keyboard and mouse sharing it — the most
// recent input wins. Disabled rows are navigable (highlight stops on them;
// activation is what doClick guards). Separators have no model and are skipped.

/// Button model of a navigable popup row: MenuItem / CheckBoxMenuItem /
/// submenu Menu. Null for separators (not navigable).
fn navModel(c: *Component) ?*ButtonModel {
    if (c.vtable == &Menu.vtable) {
        const sub: *Menu = @fieldParentPtr("component", c);
        return sub.model;
    }
    return modelOf(c);
}

/// Index of the highlighted row (the one whose model has rollover), or null.
fn highlightedIndex(self: *Menu) ?usize {
    for (self.items.items, 0..) |item, i| {
        if (navModel(item)) |m| {
            if (m.rollover) return i;
        }
    }
    return null;
}

/// Highlight exactly row `idx`, clearing every other row.
fn setHighlight(self: *Menu, idx: usize) void {
    for (self.items.items, 0..) |item, i| {
        if (navModel(item)) |m| m.setRollover(i == idx);
    }
}

/// Highlight the first navigable row. Called when a popup is opened from the
/// keyboard (mnemonic / → / Enter on a submenu); mouse-opened popups start
/// with no highlight (Windows style).
pub fn highlightFirst(self: *Menu) void {
    for (self.items.items, 0..) |item, i| {
        if (navModel(item) != null) {
            self.setHighlight(i);
            return;
        }
    }
}

/// Move the highlight by `dir` rows, skipping separators, wrapping at the
/// ends. With no current highlight, ↓ lands on the first row and ↑ on the last.
fn moveHighlight(self: *Menu, dir: i32) void {
    const items = self.items.items;
    const n = items.len;
    if (n == 0) return;
    var idx: usize = self.highlightedIndex() orelse (if (dir > 0) n - 1 else 0);
    var probes: usize = 0;
    while (probes < n) : (probes += 1) {
        idx = if (dir > 0) (idx + 1) % n else (idx + n - 1) % n;
        if (navModel(items[idx]) != null) {
            self.setHighlight(idx);
            return;
        }
    }
}

/// Open submenu `sub` beside this popup. Shared geometry for every entry
/// point: hover, menu-local mnemonic, → and Enter.
fn openSubmenu(self: *Menu, sub: *Menu) void {
    if (sub.open) return;
    const w = self.window orelse return;
    const ox = self.popup_root.position.x + self.popup_root.size.width;
    const oy = self.popup_root.position.y + sub.component.position.y;
    sub.show(w, .{ .x = ox, .y = oy }) catch |err|
        log.warn("menu", "show (submenu) failed: {s}", .{@errorName(err)});
    self.open_child = sub;
}

/// Activate the highlighted row (Enter): leaves click (doClick carries the
/// disabled guard — a disabled row stays highlighted but does nothing),
/// submenus open with their first row highlighted.
fn activateHighlighted(self: *Menu) void {
    const idx = self.highlightedIndex() orelse return;
    self.activateItem(self.items.items[idx]);
}

// ── vtable: label / row ──────────────────────────────────────────────────

fn install(self: *Component) !void {
    const menu: *Menu = @fieldParentPtr("component", self);
    try menu.model.addChangeListener(Component, onModelChange, self);
}

fn uninstall(self: *Component) void {
    const menu: *Menu = @fieldParentPtr("component", self);
    menu.model.removeChangeListener(Component, onModelChange, self);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const menu: *Menu = @fieldParentPtr("component", self);
    const sz = self.size;

    // Background: bar mode = accent when open, soft tint when hover.
    // Item mode = accent when armed/rollover.
    const t = self.theme;
    const enabled = menu.model.enabled;
    const highlight = enabled and (menu.open or menu.model.rollover or menu.model.armed);
    if (highlight) {
        const c = if (menu.open or (menu.model.armed and menu.model.pressed))
            t.accent
        else
            t.accent_soft;
        g.setColor(c);
        g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });
    }

    const text_color = blk: {
        if (!enabled) break :blk t.text_disabled;
        if (menu.open or (menu.model.armed and menu.model.pressed))
            break :blk t.text_on_accent;
        break :blk menu.color;
    };
    g.setFont(menu.font);
    g.setColor(text_color);

    const m = menu.font.measureString(menu.text);
    switch (menu.mode) {
        .bar => {
            const tx = (sz.width - m.width) / 2;
            const ty = (sz.height - m.height) / 2;
            g.drawString(menu.text, tx, ty);
            drawMnemonicUnderline(menu, g, tx, ty, m.height);
        },
        .item => {
            const tx = ROW_PADDING_X + MenuItem.ICON_SLOT_WIDTH;
            const ty = (sz.height - m.height) / 2;
            g.drawString(menu.text, tx, ty);
            drawMnemonicUnderline(menu, g, tx, ty, m.height);
            // Submenu arrow on right.
            const ax = sz.width - ARROW_SLOT_W - ROW_PADDING_X / 2;
            const ay = (sz.height - 8) / 2;
            drawArrow(g, ax, ay, text_color);
        },
    }
}

/// Underline the mnemonic letter (always shown in v1; Alt-reveal deferred).
/// Uses the color currently set on `g` (= the label's text color).
fn drawMnemonicUnderline(menu: *Menu, g: *awt.Graphics, tx: f32, ty: f32, text_h: f32) void {
    const mi = menu.mnemonic_index orelse return;
    if (mi >= menu.text.len) return;
    const prefix_w = menu.font.measureString(menu.text[0..mi]).width;
    const ch_w = menu.font.measureString(menu.text[mi .. mi + 1]).width;
    g.fillRect(.{ .x = tx + prefix_w, .y = ty + text_h - 1, .width = ch_w, .height = 1 });
}

/// A simple right-pointing triangle approximated as 4 horizontal lines.
fn drawArrow(g: *awt.Graphics, x: f32, y: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    const t: f32 = 1.5;
    g.fillRect(.{ .x = x, .y = y, .width = 1, .height = t });
    g.fillRect(.{ .x = x + 2, .y = y + 2, .width = 1, .height = t });
    g.fillRect(.{ .x = x + 4, .y = y + 4, .width = 1, .height = t });
    g.fillRect(.{ .x = x + 2, .y = y + 6, .width = 1, .height = t });
    g.fillRect(.{ .x = x, .y = y + 8, .width = 1, .height = t });
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const menu: *Menu = @fieldParentPtr("component", self);
    if (!menu.model.enabled) return;

    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const inside = lx >= 0 and lx < self.size.width and ly >= 0 and ly < self.size.height;

            switch (m.action) {
                .press => {
                    if (m.button == .left and inside) {
                        if (menu.mode == .bar) {
                            // Toggle popup
                            if (menu.open) {
                                menu.hide();
                            } else if (menu.window) |w| {
                                menu.show(w, .{ .x = origin.x, .y = origin.y + self.size.height }) catch |err|
                                    log.warn("menu", "show (bar click) failed: {s}", .{@errorName(err)});
                            }
                            ev.consume();
                        }
                    }
                },
                .release => {},
                .move => {
                    menu.model.setRollover(inside);
                },
                .scroll => {},
            }
        },
        .key, .char, .focus, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const menu: *Menu = @fieldParentPtr("component", self);
    if (menu.open) menu.hide();
    self.deinit();
    menu.popup_root.deinit();
    for (menu.items.items) |item| item.vtable.destroy(item, allocator);
    menu.items.deinit(allocator);
    allocator.free(menu.text);
    if (menu.owns_model) {
        menu.model.deinit();
        allocator.destroy(menu.model);
    }
    allocator.destroy(menu);
}

// ── popup_root vtable ────────────────────────────────────────────────────

fn popupInstall(_: *Component) !void {}
fn popupUninstall(_: *Component) void {}
fn popupDestroyNoop(_: *Component, _: std.mem.Allocator) void {}

fn popupPaint(self: *Component, g: *awt.Graphics) void {
    const menu: *Menu = @fieldParentPtr("popup_root", self);
    const sz = self.size;
    // The popup root never goes through a factory — read the owning Menu's theme.
    const t = menu.component.theme;

    // Background.
    g.setColor(t.surface_input);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Items.
    for (menu.items.items) |item| item.paintAt(g);

    // Border (1px) drawn last so item hover backgrounds don't overlap the
    // left/right edges.
    g.setColor(t.border);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = sz.height - 1, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = sz.height });
    g.fillRect(.{ .x = sz.width - 1, .y = 0, .width = 1, .height = sz.height });
}

fn popupProcessEvent(self: *Component, ev: *Component.Event) void {
    const menu: *Menu = @fieldParentPtr("popup_root", self);
    switch (ev.payload) {
        .mouse => |m| {
            // For move: track hovered Menu and update submenu state.
            if (m.action == .move) {
                var hovered_menu: ?*Menu = null;
                for (menu.items.items) |item| {
                    if (item.containsWindowPoint(m.x, m.y) and item.vtable == &Menu.vtable) {
                        hovered_menu = @fieldParentPtr("component", item);
                        break;
                    }
                }
                // Close open submenu if user moved elsewhere.
                if (menu.open_child) |open_sub| {
                    if (hovered_menu != open_sub) {
                        open_sub.hide();
                        menu.open_child = null;
                    }
                }
                // Dispatch move to all items (so rollover updates correctly).
                for (menu.items.items) |item| {
                    item.vtable.processEvent(item, ev);
                }
                // Open submenu for newly-hovered Menu (no highlight inside:
                // the mouse path starts cold, unlike keyboard entry).
                if (hovered_menu) |sub| menu.openSubmenu(sub);
                return;
            }
            // press / release: hit-test top-down.
            var i: usize = menu.items.items.len;
            while (i > 0) {
                i -= 1;
                const item = menu.items.items[i];
                if (item.containsWindowPoint(m.x, m.y)) {
                    item.vtable.processEvent(item, ev);
                    if (ev.isConsumed()) return;
                }
            }
        },
        .key => |k| {
            // This popup is the top modal overlay and receives keys first.
            // Keyboard navigation per `menu.md`「キーボード操作」; ESC is NOT
            // handled here — it falls through to Window's staged dismissTop.
            const pressed = k.action == .press;
            const press_or_repeat = pressed or k.action == .repeat;
            if (press_or_repeat and k.code == .arrow_down) {
                menu.moveHighlight(1);
                ev.consume();
                return;
            }
            if (press_or_repeat and k.code == .arrow_up) {
                menu.moveHighlight(-1);
                ev.consume();
                return;
            }
            if (press_or_repeat and k.code == .arrow_right) {
                // Meaningful only on a highlighted submenu; eaten either way
                // (arrows never leak out of an open menu).
                if (menu.highlightedIndex()) |idx| {
                    const item = menu.items.items[idx];
                    if (item.vtable == &Menu.vtable) {
                        const sub: *Menu = @fieldParentPtr("component", item);
                        menu.openSubmenu(sub);
                        if (sub.open) sub.highlightFirst();
                    }
                }
                ev.consume();
                return;
            }
            if (pressed and k.code == .arrow_left) {
                // One level back: a submenu closes itself (keys then route to
                // the parent popup, the new top overlay). A top-level popup
                // stays — menubar ←/→ switching is future work.
                if (menu.mode == .item) menu.hide();
                ev.consume();
                return;
            }
            if (pressed and k.code == .enter) {
                menu.activateHighlighted();
                ev.consume();
                return;
            }
            // Menu-local mnemonics: a *plain* letter (no modifiers — Windows
            // convention inside an open menu) activates the first item whose
            // mnemonic matches. Window-wide Alt+letter mnemonics never apply
            // to MenuItems (see narrative/keybinding.md).
            if (pressed and
                !k.modifiers.ctrl and !k.modifiers.alt and !k.modifiers.meta)
            {
                if (keybinding.letterOf(k.code)) |ch| {
                    for (menu.items.items) |item| {
                        if (item.mnemonic) |m2| {
                            if (m2 == ch) {
                                activateItem(menu, item);
                                ev.consume();
                                return;
                            }
                        }
                    }
                }
            }
        },
        .char, .focus, .composition => {},
    }
}

/// Activate `item` (menu-local mnemonic match or Enter on the highlight):
/// leaf items click, submenus open beside this popup with their first row
/// highlighted (keyboard flow continues into the submenu).
fn activateItem(menu: *Menu, item: *Component) void {
    const CheckBoxMenuItem = @import("CheckBoxMenuItem.zig");
    if (item.vtable == &MenuItem.vtable) {
        const mi: *MenuItem = @fieldParentPtr("component", item);
        mi.doClick();
    } else if (item.vtable == &CheckBoxMenuItem.vtable) {
        const cmi: *CheckBoxMenuItem = @fieldParentPtr("component", item);
        cmi.doClick();
    } else if (item.vtable == &Menu.vtable) {
        const sub: *Menu = @fieldParentPtr("component", item);
        menu.openSubmenu(sub);
        if (sub.open) sub.highlightFirst();
    }
}
