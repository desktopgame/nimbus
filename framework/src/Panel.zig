//! Container wrapper with optional background color and border.
//! See `framework/doc/panel.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");

const Panel = @This();

pub const Border = struct {
    thickness: f32,
    color:     awt.Graphics.Color,
};

container:  Container,
background: ?awt.Graphics.Color,
border:     ?Border,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn init(allocator: std.mem.Allocator) Panel {
    var p = Panel{
        .container  = Container.init(allocator),
        .background = null,
        .border     = null,
    };
    // Override the inner Container's vtable so paint hits Panel.paint
    // (which draws bg + border + children) instead of Container.paint.
    p.container.component.vtable = &vtable;
    return p;
}

pub fn create(allocator: std.mem.Allocator) !*Panel {
    const panel = try allocator.create(Panel);
    errdefer allocator.destroy(panel);
    panel.* = Panel.init(allocator);
    Panel.vtable.install(&panel.container.component);
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
    self.container.component.repaint();
}

pub fn asContainer(self: *Panel) *Container {
    return &self.container;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) void {
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

    // 1. background
    if (panel.background) |bg| {
        g.setColor(bg);
        g.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h });
    }

    // 2. children (paint each in its own clipped sub-graphics)
    for (cont.children.items) |elem| {
        elem.component.paintAt(g);
    }

    // 3. border (4 rectangles for top/bottom/left/right)
    if (panel.border) |b| {
        g.setColor(b.color);
        const t = b.thickness;
        // top
        g.fillRect(.{ .x = 0, .y = 0, .width = w, .height = t });
        // bottom
        g.fillRect(.{ .x = 0, .y = h - t, .width = w, .height = t });
        // left
        g.fillRect(.{ .x = 0, .y = t, .width = t, .height = h - 2 * t });
        // right
        g.fillRect(.{ .x = w - t, .y = t, .width = t, .height = h - 2 * t });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    // Delegate to Container's hit-test dispatch.
    const cont = self.container orelse return;
    switch (ev.payload) {
        .mouse => |m| {
            var i: usize = cont.children.items.len;
            while (i > 0) {
                i -= 1;
                const child = cont.children.items[i].component;
                if (child.containsWindowPoint(m.x, m.y)) {
                    child.vtable.processEvent(child, ev);
                    if (ev.isConsumed()) return;
                }
            }
        },
        .key => {
            for (cont.children.items) |elem| {
                elem.component.vtable.processEvent(elem.component, ev);
                if (ev.isConsumed()) return;
            }
        },
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cont: *Container = @fieldParentPtr("component", self);
    const panel: *Panel = @fieldParentPtr("container", cont);
    cont.deinit();   // frees children
    allocator.destroy(panel);
}
