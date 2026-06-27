//! Drop-down list box (read-only, string items only).
//! See `framework/doc/combobox.md`.
//!
//! Visual: a bordered cell showing the currently-selected item plus a
//! down-pointing chevron on the right edge. Clicking opens a popup
//! (registered as a Window overlay) listing every item; clicking an item
//! commits the selection and dismisses the popup. ↁE/ ↁEkeys move the
//! selection when focused; Enter / Space toggles the popup.
//!
//! v1 scope (per textfield-plan-style decisions): string items only,
//! not editable, no custom renderer. Future-additive extensions for
//! editable / typed items / custom cell renderer are noted in the doc.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const Window = @import("Window.zig");
const Application = @import("Application.zig");
const BorderLayout = @import("BorderLayout.zig");
const PopupWindow = @import("PopupWindow.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;
const log = @import("log.zig");

const ComboBox = @This();

const PADDING_X: f32 = 8;
const PADDING_Y: f32 = 4;
const CHEVRON_W: f32 = 16;
const ITEM_PADDING_Y: f32 = 4;
const BORDER_WIDTH: f32 = 1;

// Colors come from `component.theme`: field/popup bg = surface_input
// (surface_disabled when disabled), frame = border (accent when focused),
// chevron = text, hovered item = accent bg + text_on_accent fg.

component: Component,
/// Standalone Component used as the popup root. Lives inside ComboBox
/// itself (not in a Container), registered with Window.addOverlay when
/// the popup opens.
popup_root: Component,
items: std.ArrayList([]const u8), // owned UTF-8 dups
selected_index: usize,
hovered_index: ?usize,
open: bool,
window: ?*Window,
popup_window: ?*PopupWindow,
has_focus: bool,
enabled: bool,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
change_listeners: ChangeListenerList,
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

const popup_vtable = Component.VTable{
    .install = popupInstall,
    .uninstall = popupUninstall,
    .processEvent = popupProcessEvent,
    .destroy = popupDestroyNoop,
};

pub const popup_look_vtable = Component.LookVTable{
    .paint = popupLookPaint,
    .paintOver = popupLookPaintOver,
    .measureMinSize = popupLookMeasureMinSize,
};

pub fn create(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*ComboBox {
    const cb = try allocator.create(ComboBox);
    errdefer allocator.destroy(cb);

    var items_owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items_owned.items) |s| allocator.free(s);
        items_owned.deinit(allocator);
    }
    try items_owned.ensureTotalCapacity(allocator, items.len);
    for (items) |s| {
        const d = try allocator.dupe(u8, s);
        items_owned.appendAssumeCapacity(d);
    }

    cb.* = .{
        .component = Component.init(allocator, &vtable),
        .popup_root = Component.init(allocator, &popup_vtable),
        .items = items_owned,
        .selected_index = 0,
        .hovered_index = null,
        .open = false,
        .window = null,
        .popup_window = null,
        .has_focus = false,
        .enabled = true,
        .font = font,
        .color = color,
        .change_listeners = ChangeListenerList.init(allocator),
        .allocator = allocator,
    };
    cb.component.role = .combobox;
    cb.component.detached_look_roots = .{ .count = detachedLookRootCount, .at = detachedLookRootAt };
    cb.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    cb.popup_root.setFocusable(true);
    cb.popup_root.ui = .{ .vtable = &popup_look_vtable, .ctx = &Component.default_look_context };
    cb.applyMetrics();
    try ComboBox.vtable.install(&cb.component);
    return cb;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getSelectedIndex(self: ComboBox) usize {
    return self.selected_index;
}

pub fn setSelectedIndex(self: *ComboBox, idx: usize) void {
    if (idx >= self.items.items.len) return;
    if (self.selected_index == idx) return;
    self.selected_index = idx;
    self.change_listeners.fire(&.{ .source = self });
    self.component.repaint();
}

pub fn getSelectedItem(self: ComboBox) ?[]const u8 {
    if (self.items.items.len == 0) return null;
    if (self.selected_index >= self.items.items.len) return null;
    return self.items.items[self.selected_index];
}

pub fn getItemCount(self: ComboBox) usize {
    return self.items.items.len;
}

pub fn getItem(self: ComboBox, idx: usize) ?[]const u8 {
    if (idx >= self.items.items.len) return null;
    return self.items.items[idx];
}

pub fn setItems(self: *ComboBox, items: []const []const u8) !void {
    var next: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (next.items) |s| self.allocator.free(s);
        next.deinit(self.allocator);
    }
    try next.ensureTotalCapacity(self.allocator, items.len);
    for (items) |s| next.appendAssumeCapacity(try self.allocator.dupe(u8, s));

    for (self.items.items) |s| self.allocator.free(s);
    self.items.deinit(self.allocator);
    self.items = next;
    self.selected_index = 0;
    if (self.open) self.hide();
    self.applyMetrics();
    self.change_listeners.fire(&.{ .source = self });
    self.component.markLayoutDirty();
}

pub fn isEnabled(self: ComboBox) bool {
    return self.enabled;
}

pub fn setEnabled(self: *ComboBox, v: bool) void {
    if (self.enabled == v) return;
    self.enabled = v;
    if (!v and self.open) self.hide();
    self.component.repaint();
}

pub fn addChangeListener(
    self: *ComboBox,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}

pub fn removeChangeListener(
    self: *ComboBox,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *ComboBox) void {
    const ui = self.component.ui;
    const min = ui.vtable.measureMinSize(&self.component, ui.ctx);
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    // Closed-state width = max item label width + chevron + paddings.
    var max_w: f32 = 0;
    for (cb.items.items) |s| {
        const m = cb.font.measureString(s);
        if (m.width > max_w) max_w = m.width;
    }
    const line_h = cb.font.face.metrics().line_height;
    const min_w = max_w + PADDING_X * 2 + CHEVRON_W;
    const min_h = line_h + PADDING_Y * 2;
    return .{ .width = min_w, .height = min_h };
}

fn itemHeight(self: ComboBox) f32 {
    return self.font.face.metrics().line_height + ITEM_PADDING_Y * 2;
}

// ── show / hide ──────────────────────────────────────────────────────────

fn show(self: *ComboBox, w: *Window) !void {
    if (self.open) return;
    const popup = try self.ensurePopupWindow(w);
    const origin = self.component.absoluteOriginInWindow();
    const item_h = self.itemHeight();
    const popup_w = self.component.size.width;
    const popup_h = item_h * @as(f32, @floatFromInt(self.items.items.len));
    self.popup_root.position = .{
        .x = 0,
        .y = 0,
    };
    self.popup_root.size = .{ .width = popup_w, .height = popup_h };
    self.hovered_index = self.selected_index;
    self.window = w;
    try popup.showAtLocal(
        .{ .x = origin.x, .y = origin.y, .width = self.component.size.width, .height = self.component.size.height },
        .{ .width = @intFromFloat(@ceil(popup_w)), .height = @intFromFloat(@ceil(popup_h)) },
    );
    self.open = true;
    self.component.repaint();
}

fn hide(self: *ComboBox) void {
    if (!self.open) return;
    if (self.popup_window) |popup| {
        popup.dismiss();
    } else {
        self.finishDismiss();
    }
}

fn onPopupDismiss(user_data: *anyopaque) void {
    const self: *ComboBox = @ptrCast(@alignCast(user_data));
    self.finishDismiss();
}

fn finishDismiss(self: *ComboBox) void {
    self.open = false;
    self.hovered_index = null;
    self.component.repaint();
}

fn ensurePopupWindow(self: *ComboBox, owner: *Window) !*PopupWindow {
    if (self.popup_window) |popup| return popup;
    const app: *Application = @ptrCast(@alignCast(owner.app));
    const popup = try app.popupWindow(owner, "ComboBox", 1, 1);
    errdefer popup.destroy();
    popup.onDismiss(@ptrCast(self), onPopupDismiss);
    try BorderLayout.add(&popup.window.container, .center, &self.popup_root);
    self.popup_window = popup;
    return popup;
}

fn destroyPopupWindow(self: *ComboBox) void {
    const popup = self.popup_window orelse return;
    if (self.open) popup.dismiss();
    popup.window.container.remove(&self.popup_root);
    popup.destroy();
    self.popup_window = null;
}

// ── vtable: closed field ─────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    self.focus_query = .{ .isEligible = focusEligible };

    // Cache the Window so `show` does not have to walk every time.
    var node: ?*Component = self;
    while (node) |cur| {
        if (cur.parent == null) {
            // The root container's parent Window. Skip  E`show` resolves
            // at click time via the Window pointer we cache then.
            break;
        }
        node = cur.parent;
    }
}

fn uninstall(self: *Component) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    // Focus goes to null when its owner is torn down (keybinding.md).
    if (cb.has_focus) self.releaseFocus();
    if (cb.open) cb.hide();
    cb.destroyPopupWindow();
}

fn focusEligible(c: *const Component) bool {
    const cb: *const ComboBox = @fieldParentPtr("component", c);
    return cb.enabled;
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    const t = self.theme;
    const sz = self.size;
    const bg = if (cb.enabled) t.surface_input else t.surface_disabled;
    g.setColor(bg);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Border (focus tinted).
    const border = if (cb.has_focus) t.accent else t.border;
    drawBorder(g, 0, 0, sz.width, sz.height, border);

    // Selected item text (left side, vertically centered).
    if (cb.getSelectedItem()) |s| {
        const m = cb.font.measureString(s);
        const text_y = (sz.height - m.height) / 2;
        g.setFont(cb.font);
        g.setColor(cb.color);
        g.drawString(s, PADDING_X, text_y);
    }

    // Chevron in the right slot.
    drawChevron(g, sz.width - CHEVRON_W, 0, CHEVRON_W, sz.height, t.text);
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn drawBorder(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    g.fillRect(.{ .x = x, .y = y, .width = w, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = x, .y = y + h - BORDER_WIDTH, .width = w, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = x, .y = y, .width = BORDER_WIDTH, .height = h });
    g.fillRect(.{ .x = x + w - BORDER_WIDTH, .y = y, .width = BORDER_WIDTH, .height = h });
}

/// Down-pointing chevron rendered as a stack of horizontal strips. No
/// triangle primitive in awt, so we approximate with shrinking-width
/// rectangles centered in the chevron slot.
fn drawChevron(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32, color: awt.Graphics.Color) void {
    g.setColor(color);
    const center_x = x + w / 2;
    const triangle_h: f32 = 5;
    const triangle_w: f32 = 8;
    const top_y = y + (h - triangle_h) / 2;
    var row: i32 = 0;
    while (row < @as(i32, @intFromFloat(triangle_h))) : (row += 1) {
        const rf: f32 = @floatFromInt(row);
        const strip_w = triangle_w - rf * 2;
        if (strip_w <= 0) break;
        g.fillRect(.{
            .x = center_x - strip_w / 2,
            .y = top_y + rf,
            .width = strip_w,
            .height = 1,
        });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);

    switch (ev.payload) {
        .mouse => |m| {
            if (!cb.enabled) return;
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const inside = lx >= 0 and lx < self.size.width and ly >= 0 and ly < self.size.height;
            if (m.action == .press and m.button == .left and inside) {
                self.requestFocus();
                if (cb.open) {
                    cb.hide();
                } else {
                    // Resolve window via parent chain.
                    const w = parentWindow(self);
                    if (w) |win| {
                        cb.show(win) catch |err|
                            log.warn("combobox", "show failed: {s}", .{@errorName(err)});
                    }
                }
                ev.consume();
            }
        },
        .key => |k| {
            if (!cb.enabled) return;
            if (k.action != .press and k.action != .repeat) return;
            switch (k.code) {
                .arrow_down => {
                    if (cb.items.items.len == 0) return;
                    const next = if (cb.selected_index + 1 < cb.items.items.len)
                        cb.selected_index + 1
                    else
                        cb.selected_index;
                    cb.setSelectedIndex(next);
                    ev.consume();
                },
                .arrow_up => {
                    if (cb.selected_index > 0) cb.setSelectedIndex(cb.selected_index - 1);
                    ev.consume();
                },
                .enter, .space => {
                    if (cb.open) {
                        cb.hide();
                    } else {
                        if (parentWindow(self)) |win| {
                            cb.show(win) catch |err|
                                log.warn("combobox", "show failed: {s}", .{@errorName(err)});
                        }
                    }
                    ev.consume();
                },
                .escape => {
                    if (cb.open) {
                        cb.hide();
                        ev.consume();
                    }
                },
                else => {},
            }
        },
        .focus => |f| {
            cb.has_focus = f.gained;
            cb.component.repaint();
        },
        .char, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    if (cb.open) cb.hide();
    self.deinit();
    // popup_root is a standalone Component embedded in ComboBox (not in any
    // Container), so nothing else tears it down. `addOverlay` lazily
    // allocates its property map (DirtyNotify / FocusController) the first
    // time the popup opens; deinit here to free that map.
    cb.destroyPopupWindow();
    cb.popup_root.deinit();
    for (cb.items.items) |s| allocator.free(s);
    cb.items.deinit(allocator);
    cb.change_listeners.deinit();
    allocator.destroy(cb);
}

// ── vtable: popup ────────────────────────────────────────────────────────

fn popupInstall(_: *Component) !void {}
fn popupUninstall(_: *Component) void {}
fn popupDestroyNoop(_: *Component, _: std.mem.Allocator) void {}

fn popupLookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const cb: *ComboBox = @fieldParentPtr("popup_root", self);
    const sz = self.size;
    const item_h = cb.itemHeight();
    // The popup root never goes through a factory  Eread the owner's theme.
    const t = cb.component.theme;

    g.setColor(t.surface_input);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Items.
    g.setFont(cb.font);
    for (cb.items.items, 0..) |s, idx| {
        const y_top: f32 = @as(f32, @floatFromInt(idx)) * item_h;
        const is_hover = cb.hovered_index == idx;
        if (is_hover) {
            g.setColor(t.accent);
            g.fillRect(.{ .x = 0, .y = y_top, .width = sz.width, .height = item_h });
        }
        g.setColor(if (is_hover) t.text_on_accent else cb.color);
        g.drawString(s, PADDING_X, y_top + ITEM_PADDING_Y);
    }

    // Outer border.
    g.setColor(t.border);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = sz.height - 1, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = sz.height });
    g.fillRect(.{ .x = sz.width - 1, .y = 0, .width = 1, .height = sz.height });
}

fn popupLookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn popupLookMeasureMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = 0 };
}

fn popupProcessEvent(self: *Component, ev: *Component.Event) void {
    const cb: *ComboBox = @fieldParentPtr("popup_root", self);
    if (!cb.open) return;

    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            const item_h = cb.itemHeight();
            const idx = popupIndexAt(cb.items.items.len, item_h, self.size.width, lx, ly);

            switch (m.action) {
                .move => {
                    if (cb.hovered_index != idx) {
                        cb.hovered_index = idx;
                        cb.popup_root.repaint();
                    }
                },
                .press => {
                    if (idx) |i| {
                        cb.setSelectedIndex(i);
                        if (cb.popup_window) |popup| popup.dismissFromSelection() else cb.hide();
                        ev.consume();
                    }
                },
                else => {},
            }
        },
        .key => |k| {
            if (k.action != .press) return;
            switch (k.code) {
                .escape => {
                    if (cb.popup_window) |popup| popup.dismissFromEscape() else cb.hide();
                    ev.consume();
                },
                .arrow_down => {
                    const next = moveHoverIndex(cb.items.items.len, cb.hovered_index, cb.selected_index, 1);
                    if (next != cb.hovered_index) {
                        cb.hovered_index = next;
                        cb.popup_root.repaint();
                    }
                    ev.consume();
                },
                .arrow_up => {
                    const next = moveHoverIndex(cb.items.items.len, cb.hovered_index, cb.selected_index, -1);
                    if (next != cb.hovered_index) {
                        cb.hovered_index = next;
                        cb.popup_root.repaint();
                    }
                    ev.consume();
                },
                .enter, .space => {
                    if (cb.hovered_index) |i| {
                        cb.setSelectedIndex(i);
                        if (cb.popup_window) |popup| popup.dismissFromSelection() else cb.hide();
                        ev.consume();
                    }
                },
                else => {},
            }
        },
        .char, .focus, .composition => {},
    }
}

// ── helpers ──────────────────────────────────────────────────────────────

fn popupIndexAt(item_count: usize, item_h: f32, width: f32, x: f32, y: f32) ?usize {
    if (item_count == 0 or item_h <= 0) return null;
    if (x < 0 or x >= width or y < 0) return null;
    const idx_f: f32 = y / item_h;
    if (idx_f >= @as(f32, @floatFromInt(item_count))) return null;
    return @intFromFloat(idx_f);
}

fn moveHoverIndex(item_count: usize, hovered: ?usize, selected: usize, delta: i32) ?usize {
    if (item_count == 0) return null;
    const last = item_count - 1;
    const base = @min(hovered orelse selected, last);
    if (delta > 0) return @min(base + 1, last);
    if (delta < 0) return if (base == 0) 0 else base - 1;
    return base;
}

fn parentWindow(c: *Component) ?*Window {
    var node: ?*Component = c;
    while (node) |cur| {
        if (cur.parent == null) {
            const cont = cur.container orelse return null;
            return @fieldParentPtr("container", cont);
        }
        node = cur.parent;
    }
    return null;
}

fn detachedLookRootCount(_: *const Component) usize {
    return 1;
}

fn detachedLookRootAt(c: *const Component, index: usize) *Component {
    std.debug.assert(index == 0);
    const cb: *const ComboBox = @fieldParentPtr("component", c);
    return @constCast(&cb.popup_root);
}

test "popupIndexAt hit-tests items without a window backend" {
    try std.testing.expectEqual(@as(?usize, 0), popupIndexAt(3, 20, 100, 5, 0));
    try std.testing.expectEqual(@as(?usize, 1), popupIndexAt(3, 20, 100, 99, 39));
    try std.testing.expectEqual(@as(?usize, null), popupIndexAt(3, 20, 100, 100, 10));
    try std.testing.expectEqual(@as(?usize, null), popupIndexAt(3, 20, 100, 10, 60));
}

test "moveHoverIndex clamps arrow navigation without a window backend" {
    try std.testing.expectEqual(@as(?usize, 2), moveHoverIndex(4, null, 1, 1));
    try std.testing.expectEqual(@as(?usize, 3), moveHoverIndex(4, 3, 1, 1));
    try std.testing.expectEqual(@as(?usize, 1), moveHoverIndex(4, 2, 1, -1));
    try std.testing.expectEqual(@as(?usize, 0), moveHoverIndex(4, 0, 1, -1));
    try std.testing.expectEqual(@as(?usize, null), moveHoverIndex(0, null, 0, 1));
}

test "setSelectedIndex commits selection and fires change listeners" {
    const Ctx = struct {
        count: usize = 0,
        source: ?*ComboBox = null,

        fn changed(self: *@This(), ev: *const ChangeEvent) void {
            self.count += 1;
            self.source = @ptrCast(@alignCast(ev.source));
        }
    };

    var cb = ComboBox{
        .component = Component.init(std.testing.allocator, &ComboBox.vtable),
        .popup_root = Component.init(std.testing.allocator, &popup_vtable),
        .items = .empty,
        .selected_index = 0,
        .hovered_index = null,
        .open = false,
        .window = null,
        .popup_window = null,
        .has_focus = false,
        .enabled = true,
        .font = undefined,
        .color = undefined,
        .change_listeners = ChangeListenerList.init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer cb.change_listeners.deinit();
    defer cb.component.deinit();
    defer cb.popup_root.deinit();
    try cb.items.append(std.testing.allocator, "a");
    try cb.items.append(std.testing.allocator, "b");
    defer cb.items.deinit(std.testing.allocator);

    var ctx = Ctx{};
    try cb.addChangeListener(Ctx, Ctx.changed, &ctx);

    cb.setSelectedIndex(1);
    try std.testing.expectEqual(@as(usize, 1), cb.getSelectedIndex());
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
    try std.testing.expect(ctx.source == &cb);

    cb.setSelectedIndex(1);
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
}
