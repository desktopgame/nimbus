//! Top-tabbed container. See `framework/doc/tabbed_pane.md`.
//!
//! Owns a list of tab titles and content components. Built like `SplitPane`:
//! it embeds a `Container` as the first field, overrides that container's
//! vtable to paint the tab strip and handle selection, and supplies a private
//! `LayoutManager` that gives bounds only to the selected tab content.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const LayoutManager = @import("LayoutManager.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;

pub const TabbedPane = @This();

const DEFAULT_TAB_HEIGHT: f32 = 26;
const TAB_HPAD: f32 = 12;

const Tab = struct {
    title: []u8,
    content: *Component,
};

const TabLayout = struct {
    base: LayoutManager,
};

pub const ChangeListener = ChangeListenerList.Listener;

// `container` MUST be the first field: the public Component is
// `container.component`, and methods recover `*TabbedPane` via
// `@fieldParentPtr("container", ...)`.
container: Container,
layout: TabLayout,
tabs: std.ArrayListUnmanaged(Tab),
selected: ?usize,
font: awt.Graphics.TextFont,
change_listeners: ChangeListenerList,
allocator: std.mem.Allocator,
rollover_tab: ?usize,

pub const vtable = Component.VTable{
    .install = Container.vtable.install,
    .uninstall = Container.vtable.uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

const tab_layout_vtable = LayoutManager.VTable{
    .doLayout = layoutDoLayout,
    .computeMinSize = layoutComputeMinSize,
    .computeMaxSize = layoutComputeMaxSize,
};

pub fn create(allocator: std.mem.Allocator, font: awt.Graphics.TextFont) !*TabbedPane {
    const tp = try allocator.create(TabbedPane);
    errdefer allocator.destroy(tp);

    tp.* = .{
        .container = Container.init(allocator),
        .layout = .{ .base = .{ .vtable = &tab_layout_vtable } },
        .tabs = .empty,
        .selected = null,
        .font = font,
        .change_listeners = ChangeListenerList.init(allocator),
        .allocator = allocator,
        .rollover_tab = null,
    };
    errdefer tp.change_listeners.deinit();

    tp.container.component.vtable = &vtable;
    tp.container.component.role = .tabbed_pane;
    tp.container.component.container = &tp.container;
    tp.container.layout = &tp.layout.base;
    return tp;
}

// ── public API ─────────────────────────────────────────────────────────────

pub fn asComponent(self: *TabbedPane) *Component {
    return &self.container.component;
}

/// `title` is copied; `content` ownership transfers even on error.
pub fn addTab(self: *TabbedPane, title: []const u8, content: *Component) !void {
    errdefer content.vtable.destroy(content, self.allocator);

    const title_dup = try self.allocator.dupe(u8, title);
    errdefer self.allocator.free(title_dup);

    try self.container.add(content);
    errdefer self.container.remove(content);
    applyTheme(content, self.container.component.theme);
    try self.tabs.append(self.allocator, .{ .title = title_dup, .content = content });

    if (self.tabs.items.len == 1) {
        self.selected = 0;
        self.change_listeners.fire(&.{ .source = self });
    }
    self.container.component.markLayoutDirty();
    self.container.component.repaint();
}

/// Destroys the content at `index` transitively. Out-of-range is a no-op.
pub fn removeTab(self: *TabbedPane, index: usize) void {
    if (index >= self.tabs.items.len) return;

    const old_selected = self.selected;
    const tab = self.tabs.items[index];
    self.container.remove(tab.content);
    tab.content.vtable.destroy(tab.content, self.allocator);
    self.allocator.free(tab.title);
    _ = self.tabs.orderedRemove(index);

    self.selected = clampAfterRemove(old_selected, index, self.tabs.items.len);
    if (self.rollover_tab) |r| {
        self.rollover_tab = if (r == index)
            null
        else if (r > index)
            r - 1
        else
            r;
    }
    self.change_listeners.fire(&.{ .source = self });
    self.container.component.markLayoutDirty();
    self.container.component.repaint();
}

pub fn count(self: TabbedPane) usize {
    return self.tabs.items.len;
}

pub fn getTitleAt(self: TabbedPane, index: usize) []const u8 {
    return self.tabs.items[index].title;
}

pub fn getContentAt(self: TabbedPane, index: usize) *Component {
    return self.tabs.items[index].content;
}

pub fn getSelectedIndex(self: TabbedPane) ?usize {
    return self.selected;
}

pub fn setSelectedIndex(self: *TabbedPane, index: usize) void {
    if (self.tabs.items.len == 0) {
        if (self.selected != null) {
            self.selected = null;
            self.change_listeners.fire(&.{ .source = self });
            self.container.component.markLayoutDirty();
            self.container.component.repaint();
        }
        return;
    }
    const clamped = @min(index, self.tabs.items.len - 1);
    if (self.selected != null and self.selected.? == clamped) return;

    self.selected = clamped;
    self.change_listeners.fire(&.{ .source = self });
    self.container.component.markLayoutDirty();
    self.container.component.repaint();
}

pub fn addChangeListener(self: *TabbedPane, l: *ChangeListener) void {
    self.change_listeners.add(l.fn_ptr, l.user_data) catch return;
}

// ── helpers ────────────────────────────────────────────────────────────────

fn fromComponent(self: *Component) *TabbedPane {
    const c: *Container = @fieldParentPtr("component", self);
    return @fieldParentPtr("container", c);
}

fn clampAfterRemove(old: ?usize, removed: usize, len: usize) ?usize {
    if (len == 0) return null;
    const s = old orelse return 0;
    if (s == removed) return @min(removed, len - 1);
    if (s > removed) return s - 1;
    return s;
}

fn applyTheme(c: *Component, theme: *const @import("theme.zig").Theme) void {
    c.theme = theme;
    if (c.container) |cont| {
        for (cont.children.items) |elem| applyTheme(elem.component, theme);
    }
}

fn tabWidth(self: *const TabbedPane, title: []const u8) f32 {
    return self.font.measureString(title).width + 2 * TAB_HPAD;
}

fn stripWidth(self: *const TabbedPane) f32 {
    var w: f32 = 0;
    for (self.tabs.items) |tab| w += self.tabWidth(tab.title);
    return w;
}

fn tabAt(self: *const TabbedPane, x: f32, y: f32) ?usize {
    if (y < 0 or y >= DEFAULT_TAB_HEIGHT or x < 0) return null;
    var tx: f32 = 0;
    for (self.tabs.items, 0..) |tab, i| {
        const w = self.tabWidth(tab.title);
        if (x >= tx and x < tx + w) return i;
        tx += w;
    }
    return null;
}

// ── layout (TabLayout vtable) ──────────────────────────────────────────────

fn layoutDoLayout(_: *LayoutManager, container: *Container) void {
    const self: *TabbedPane = @fieldParentPtr("container", container);
    const W = container.component.size.width;
    const H = container.component.size.height;
    const content_h = @max(0, H - DEFAULT_TAB_HEIGHT);

    for (self.tabs.items, 0..) |tab, i| {
        if (self.selected != null and self.selected.? == i) {
            tab.content.setBounds(.{ .x = 0, .y = DEFAULT_TAB_HEIGHT, .width = W, .height = content_h });
        } else {
            tab.content.setBounds(.{ .x = 0, .y = DEFAULT_TAB_HEIGHT, .width = 0, .height = 0 });
        }
    }
}

fn layoutComputeMinSize(_: *LayoutManager, container: *const Container) Component.Size {
    const self: *const TabbedPane = @fieldParentPtr("container", @constCast(container));
    var content_min: Component.Size = .{ .width = 0, .height = 0 };
    for (self.tabs.items) |tab| {
        const m = tab.content.effectiveMinSize();
        content_min.width = @max(content_min.width, m.width);
        content_min.height = @max(content_min.height, m.height);
    }
    return .{
        .width = @max(self.stripWidth(), content_min.width),
        .height = DEFAULT_TAB_HEIGHT + content_min.height,
    };
}

fn layoutComputeMaxSize(_: *LayoutManager, _: *const Container) Component.Size {
    return .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
}

// ── vtable impl ────────────────────────────────────────────────────────────

fn paint(self: *Component, g: *awt.Graphics) void {
    const tp = fromComponent(self);
    const sz = self.size;
    const t = self.theme;

    g.setColor(t.surface_window);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = DEFAULT_TAB_HEIGHT });

    g.setFont(tp.font);
    var x: f32 = 0;
    for (tp.tabs.items, 0..) |tab, i| {
        const w = tp.tabWidth(tab.title);
        const selected = tp.selected != null and tp.selected.? == i;

        g.setColor(if (selected) t.surface_input else t.surface_window);
        g.fillRect(.{ .x = x, .y = 0, .width = w, .height = DEFAULT_TAB_HEIGHT });

        g.setColor(t.border_soft);
        g.fillRect(.{ .x = x + w - 1, .y = 0, .width = 1, .height = DEFAULT_TAB_HEIGHT });

        const m = tp.font.measureString(tab.title);
        const ty = (DEFAULT_TAB_HEIGHT - m.height) / 2;
        g.setColor(t.text);
        g.drawString(tab.title, x + TAB_HPAD, ty);

        if (selected) {
            g.setColor(t.accent);
            g.fillRect(.{ .x = x, .y = DEFAULT_TAB_HEIGHT - 2, .width = w, .height = 2 });
        }
        x += w;
    }

    g.setColor(t.border_soft);
    g.fillRect(.{ .x = 0, .y = DEFAULT_TAB_HEIGHT - 1, .width = sz.width, .height = 1 });

    if (tp.selected) |idx| {
        if (idx < tp.tabs.items.len) tp.tabs.items[idx].content.paintAt(g);
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const tp = fromComponent(self);
    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const lx = m.x - origin.x;
            const ly = m.y - origin.y;
            switch (m.action) {
                .press => {
                    if ((m.button orelse .left) == .left and ly < DEFAULT_TAB_HEIGHT) {
                        if (tp.tabAt(lx, ly)) |hit| {
                            tp.setSelectedIndex(hit);
                            ev.consume();
                            return;
                        }
                    }
                },
                .move => {
                    const hit = tp.tabAt(lx, ly);
                    if (hit != tp.rollover_tab) {
                        tp.rollover_tab = hit;
                        self.repaint();
                    }
                },
                .release, .scroll => {},
            }
        },
        .key, .char, .focus, .composition => {},
    }
    Container.vtable.processEvent(self, ev);
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const c: *Container = @fieldParentPtr("component", self);
    const tp: *TabbedPane = @fieldParentPtr("container", c);
    for (tp.tabs.items) |tab| allocator.free(tab.title);
    tp.tabs.deinit(allocator);
    tp.change_listeners.deinit();
    c.deinit();
    allocator.destroy(tp);
}
