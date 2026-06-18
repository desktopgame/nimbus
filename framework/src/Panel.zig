//! Container wrapper with optional background color, border, and padding.
//! See `framework/doc/panel.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const BorderLayout = @import("BorderLayout.zig");
const PaddingLayout = @import("PaddingLayout.zig");
const Insets = PaddingLayout.Insets;

const Panel = @This();

pub const Border = struct {
    thickness: f32,
    color: awt.Graphics.Color,
};

container: Container,
content: *Container,
padding: Insets = .{},
background: ?awt.Graphics.Color = null,
border: ?Border = null,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub fn create(allocator: std.mem.Allocator) !*Panel {
    const panel = try allocator.create(Panel);
    errdefer allocator.destroy(panel);

    const content = try Container.create(allocator);
    errdefer content.component.vtable.destroy(&content.component, allocator);
    content.setLayout(BorderLayout.get());

    const layout = try PaddingLayout.create(allocator, Insets.zero);
    errdefer if (layout.vtable.deinit) |layout_deinit| layout_deinit(layout, allocator);

    panel.* = .{
        .container = Container.init(allocator),
        .content = content,
    };
    panel.container.component.vtable = &vtable;
    panel.container.component.role = .panel;
    panel.container.layout = layout;

    try Panel.vtable.install(&panel.container.component);
    errdefer panel.container.component.deinit();
    try panel.container.add(&content.component);

    return panel;
}

pub fn getBackground(self: Panel) ?awt.Graphics.Color {
    return self.background;
}

pub fn setBackground(self: *Panel, color: ?awt.Graphics.Color) void {
    self.background = color;
    self.container.component.repaint();
}

pub fn getBorder(self: Panel) ?Border {
    return self.border;
}

pub fn setBorder(self: *Panel, border: ?Border) void {
    self.border = border;
    self.updatePaddingLayout();
    self.container.component.markLayoutDirty();
    self.container.component.repaint();
}

pub fn getPadding(self: Panel) Insets {
    return self.padding;
}

pub fn setPadding(self: *Panel, padding: Insets) void {
    self.padding = padding;
    self.updatePaddingLayout();
    self.container.component.markLayoutDirty();
}

pub fn asComponent(self: *Panel) *Component {
    return &self.container.component;
}

pub fn asContainer(self: *Panel) *Container {
    return self.content;
}

fn updatePaddingLayout(self: *Panel) void {
    const t: f32 = if (self.border) |b| b.thickness else 0;
    const insets = Insets{
        .left = t + self.padding.left,
        .top = t + self.padding.top,
        .right = t + self.padding.right,
        .bottom = t + self.padding.bottom,
    };
    PaddingLayout.setInsets(self.container.layout.?, insets);
}

// 笏笏 vtable impl 笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏笏

fn install(self: *Component) !void {
    const cont: *Container = @fieldParentPtr("component", self);
    self.container = cont;
}

fn uninstall(self: *Component) void {
    self.container = null;
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const cont = self.container orelse return;
    const panel: *Panel = @fieldParentPtr("container", cont);

    const w = self.size.width;
    const h = self.size.height;

    if (panel.background) |bg| {
        g.setColor(bg);
        g.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h });
    }

    for (cont.children.items) |elem| {
        elem.component.paintAt(g);
    }

    if (panel.border) |b| {
        g.setColor(b.color);
        const t = b.thickness;
        g.fillRect(.{ .x = 0, .y = 0, .width = w, .height = t });
        g.fillRect(.{ .x = 0, .y = h - t, .width = w, .height = t });
        g.fillRect(.{ .x = 0, .y = t, .width = t, .height = h - 2 * t });
        g.fillRect(.{ .x = w - t, .y = t, .width = t, .height = h - 2 * t });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const cont = self.container orelse return;
    switch (ev.payload) {
        .mouse => |m| {
            var hovered: ?*Component = null;
            var i: usize = cont.children.items.len;
            while (i > 0) {
                i -= 1;
                const child = cont.children.items[i].component;
                if (child.containsWindowPoint(m.x, m.y)) {
                    if (hovered == null) hovered = child;
                    child.vtable.processEvent(child, ev);
                    if (ev.isConsumed()) break;
                }
            }
            if (m.action == .move) cont.updateHover(hovered, m.x, m.y);
        },
        .key, .char, .focus, .composition => {},
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cont: *Container = @fieldParentPtr("component", self);
    const panel: *Panel = @fieldParentPtr("container", cont);
    cont.deinit();
    allocator.destroy(panel);
}
