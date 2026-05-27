//! Drop-down list box (read-only, string items only).
//! See `framework/doc/combobox.md`.
//!
//! Visual: a bordered cell showing the currently-selected item plus a
//! down-pointing chevron on the right edge. Clicking opens a popup
//! (registered as a Window overlay) listing every item; clicking an item
//! commits the selection and dismisses the popup. ↑ / ↓ keys move the
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
const ChangeListenerList = @import("ChangeListenerList.zig");
const log = @import("log.zig");

const ComboBox = @This();

const PADDING_X: f32      = 8;
const PADDING_Y: f32      = 4;
const CHEVRON_W: f32      = 16;
const ITEM_PADDING_Y: f32 = 4;
const BORDER_WIDTH: f32   = 1;

const FIELD_BG          = awt.Graphics.Color.rgb(1.0, 1.0, 1.0);
const FIELD_BG_DISABLED = awt.Graphics.Color.rgb(0.93, 0.93, 0.93);
const BORDER_COLOR      = awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
const FOCUS_BORDER      = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);
const CHEVRON_COLOR     = awt.Graphics.Color.rgb(0.30, 0.30, 0.30);
const POPUP_BG          = awt.Graphics.Color.rgb(1.0, 1.0, 1.0);
const POPUP_BORDER      = awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
const ITEM_HOVER_BG     = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);
const ITEM_HOVER_FG     = awt.Graphics.Color.rgb(1.0, 1.0, 1.0);

component:        Component,
/// Standalone Component used as the popup root. Lives inside ComboBox
/// itself (not in a Container), registered with Window.addOverlay when
/// the popup opens.
popup_root:       Component,
items:            std.ArrayList([]const u8),  // owned UTF-8 dups
selected_index:   usize,
hovered_index:    ?usize,
open:             bool,
window:           ?*Window,
has_focus:        bool,
enabled:          bool,
font:             awt.Graphics.TextFont,
color:            awt.Graphics.Color,
change_listeners: ChangeListenerList,
allocator:        std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

const popup_vtable = Component.VTable{
    .install      = popupInstall,
    .uninstall    = popupUninstall,
    .paint        = popupPaint,
    .processEvent = popupProcessEvent,
    .destroy      = popupDestroyNoop,
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
        .has_focus = false,
        .enabled = true,
        .font = font,
        .color = color,
        .change_listeners = ChangeListenerList.init(allocator),
        .allocator = allocator,
    };
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
    self.change_listeners.fire();
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
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) !void {
    try self.change_listeners.add(fn_ptr, user_data);
}

pub fn removeChangeListener(
    self: *ComboBox,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) void {
    self.change_listeners.remove(fn_ptr, user_data);
}

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *ComboBox) void {
    // Closed-state width = max item label width + chevron + paddings.
    var max_w: f32 = 0;
    for (self.items.items) |s| {
        const m = self.font.measureString(s);
        if (m.width > max_w) max_w = m.width;
    }
    const line_h = self.font.face.metrics().line_height;
    const min_w = max_w + PADDING_X * 2 + CHEVRON_W;
    const min_h = line_h + PADDING_Y * 2;
    self.component.min_size = .{ .width = min_w, .height = min_h };
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min_h };
}

fn itemHeight(self: ComboBox) f32 {
    return self.font.face.metrics().line_height + ITEM_PADDING_Y * 2;
}

// ── show / hide ──────────────────────────────────────────────────────────

fn show(self: *ComboBox, w: *Window) !void {
    const origin = self.component.absoluteOriginInWindow();
    const item_h = self.itemHeight();
    const popup_w = self.component.size.width;
    const popup_h = item_h * @as(f32, @floatFromInt(self.items.items.len));
    self.popup_root.position = .{
        .x = origin.x,
        .y = origin.y + self.component.size.height,
    };
    self.popup_root.size = .{ .width = popup_w, .height = popup_h };
    self.hovered_index = self.selected_index;
    self.open = true;
    self.window = w;
    try w.overlays.add(&self.popup_root, @ptrCast(self), onOverlayDismiss);
    self.component.repaint();
}

fn hide(self: *ComboBox) void {
    if (!self.open) return;
    if (self.window) |w| w.overlays.remove(@ptrCast(self));
    self.open = false;
    self.hovered_index = null;
    self.component.repaint();
}

fn onOverlayDismiss(user_data: *anyopaque) void {
    const self: *ComboBox = @ptrCast(@alignCast(user_data));
    self.open = false;
    self.hovered_index = null;
    self.component.repaint();
}

// ── vtable: closed field ─────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);

    // Cache the Window so `show` does not have to walk every time.
    var node: ?*Component = self;
    while (node) |cur| {
        if (cur.parent == null) {
            // The root container's parent Window. Skip — `show` resolves
            // at click time via the Window pointer we cache then.
            break;
        }
        node = cur.parent;
    }
}

fn uninstall(self: *Component) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    if (cb.open) cb.hide();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const cb: *ComboBox = @fieldParentPtr("component", self);
    const sz = self.size;
    const bg = if (cb.enabled) FIELD_BG else FIELD_BG_DISABLED;
    g.setColor(bg);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Border (focus tinted).
    const border = if (cb.has_focus) FOCUS_BORDER else BORDER_COLOR;
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
    drawChevron(g, sz.width - CHEVRON_W, 0, CHEVRON_W, sz.height);
}

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
fn drawChevron(g: *awt.Graphics, x: f32, y: f32, w: f32, h: f32) void {
    g.setColor(CHEVRON_COLOR);
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
    if (!cb.enabled) return;

    switch (ev.payload) {
        .mouse => |m| {
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

fn popupPaint(self: *Component, g: *awt.Graphics) void {
    const cb: *ComboBox = @fieldParentPtr("popup_root", self);
    const sz = self.size;
    const item_h = cb.itemHeight();

    g.setColor(POPUP_BG);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Items.
    g.setFont(cb.font);
    for (cb.items.items, 0..) |s, idx| {
        const y_top: f32 = @as(f32, @floatFromInt(idx)) * item_h;
        const is_hover = cb.hovered_index == idx;
        if (is_hover) {
            g.setColor(ITEM_HOVER_BG);
            g.fillRect(.{ .x = 0, .y = y_top, .width = sz.width, .height = item_h });
        }
        g.setColor(if (is_hover) ITEM_HOVER_FG else cb.color);
        g.drawString(s, PADDING_X, y_top + ITEM_PADDING_Y);
    }

    // Outer border.
    g.setColor(POPUP_BORDER);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = sz.height - 1, .width = sz.width, .height = 1 });
    g.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = sz.height });
    g.fillRect(.{ .x = sz.width - 1, .y = 0, .width = 1, .height = sz.height });
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
            const inside_x = lx >= 0 and lx < self.size.width;
            const idx_f: f32 = ly / item_h;
            const idx: ?usize = if (inside_x and ly >= 0 and idx_f < @as(f32, @floatFromInt(cb.items.items.len)))
                @intFromFloat(idx_f)
            else
                null;

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
                        cb.hide();
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
                    cb.hide();
                    ev.consume();
                },
                .arrow_down => {
                    const cur = cb.hovered_index orelse cb.selected_index;
                    if (cur + 1 < cb.items.items.len) {
                        cb.hovered_index = cur + 1;
                        cb.popup_root.repaint();
                    }
                    ev.consume();
                },
                .arrow_up => {
                    const cur = cb.hovered_index orelse cb.selected_index;
                    if (cur > 0) {
                        cb.hovered_index = cur - 1;
                        cb.popup_root.repaint();
                    }
                    ev.consume();
                },
                .enter, .space => {
                    if (cb.hovered_index) |i| {
                        cb.setSelectedIndex(i);
                        cb.hide();
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
