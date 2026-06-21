//! Single-child border decorator.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const PaddingLayout = @import("PaddingLayout.zig");

const Border = @This();

container: Container,
color: awt.Graphics.Color,
thickness: f32 = 1,

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

pub fn create(allocator: std.mem.Allocator, child: *Component, color: awt.Graphics.Color) !*Border {
    const border = try allocator.create(Border);
    errdefer allocator.destroy(border);

    const layout = try PaddingLayout.create(allocator, PaddingLayout.Insets.zero);
    errdefer if (layout.vtable.deinit) |layout_deinit| layout_deinit(layout, allocator);

    border.* = .{
        .container = Container.init(allocator),
        .color = color,
    };
    border.container.component.vtable = &vtable;
    border.container.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    border.container.component.role = .panel;
    border.container.layout = layout;

    try Border.vtable.install(&border.container.component);
    errdefer border.container.component.deinit();

    try border.container.children.ensureTotalCapacity(allocator, 1);
    border.container.add(child) catch unreachable;
    border.container.component.setGrowX(child.getGrowX());
    border.container.component.setGrowY(child.getGrowY());

    return border;
}

pub fn asComponent(self: *Border) *Component {
    return &self.container.component;
}

pub fn asContainer(self: *Border) *Container {
    return &self.container;
}

pub fn setColor(self: *Border, color: awt.Graphics.Color) void {
    self.color = color;
    self.container.component.repaint();
}

fn install(self: *Component) !void {
    const cont: *Container = @fieldParentPtr("component", self);
    self.container = cont;
}

fn uninstall(self: *Component) void {
    self.container = null;
}

fn lookPaint(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn lookPaintOver(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const cont = self.container orelse return;
    const border: *Border = @fieldParentPtr("container", cont);

    const w = self.size.width;
    const h = self.size.height;
    const t = border.thickness;
    if (w <= 0 or h <= 0 or t <= 0) return;

    const owner = self.focusOwner();
    const focused = if (owner) |o| self.isSelfOrDescendant(o) else false;
    g.setColor(if (focused) self.theme.accent else border.color);
    g.fillRect(.{ .x = 0, .y = 0, .width = w, .height = t });
    g.fillRect(.{ .x = 0, .y = h - t, .width = w, .height = t });
    g.fillRect(.{ .x = 0, .y = t, .width = t, .height = @max(0, h - 2 * t) });
    g.fillRect(.{ .x = w - t, .y = t, .width = t, .height = @max(0, h - 2 * t) });
}

fn lookMeasureMinSize(_: *Component, _: *anyopaque) Component.Size {
    return .{ .width = 0, .height = 0 };
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    Container.vtable.processEvent(self, ev);
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const cont: *Container = @fieldParentPtr("component", self);
    const border: *Border = @fieldParentPtr("container", cont);
    cont.deinit();
    allocator.destroy(border);
}

const FocusStub = struct {
    owner: ?*Component = null,

    fn request(_: *anyopaque, _: ?*Component) void {}

    fn current(user_data: *anyopaque) ?*Component {
        const self: *FocusStub = @ptrCast(@alignCast(user_data));
        return self.owner;
    }

    fn controller(self: *FocusStub) Component.FocusController {
        return .{
            .user_data = @ptrCast(self),
            .request_focus_for = request,
            .current_owner = current,
        };
    }
};

test "border lays out child at same size" {
    const a = std.testing.allocator;
    const Panel = @import("Panel.zig");

    const child = try Panel.create(a);
    const border = try create(a, child.asComponent(), awt.Graphics.Color.rgb(0, 0, 0));
    defer border.asComponent().vtable.destroy(border.asComponent(), a);

    border.asComponent().setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 50 });
    border.asContainer().doLayout();

    const bounds = child.asComponent().getBounds();
    try std.testing.expectEqual(@as(f32, 0), bounds.x);
    try std.testing.expectEqual(@as(f32, 0), bounds.y);
    try std.testing.expectEqual(@as(f32, 100), bounds.width);
    try std.testing.expectEqual(@as(f32, 50), bounds.height);
}

test "focus owner reaches root controller and descendant checks" {
    const a = std.testing.allocator;
    const Panel = @import("Panel.zig");
    const ScrollPane = @import("ScrollPane.zig");

    var root = try Container.create(a);
    defer root.component.vtable.destroy(&root.component, a);

    var stub = FocusStub{};
    var controller = stub.controller();
    try root.component.putProperty(@typeName(Component.FocusController), @ptrCast(&controller), null);

    const view = try Panel.create(a);
    const scroll = try ScrollPane.create(a, view.asComponent());
    const border = try create(a, scroll.asComponent(), awt.Graphics.Color.rgb(0, 0, 0));
    try root.add(border.asComponent());

    stub.owner = view.asComponent();
    try std.testing.expectEqual(view.asComponent(), border.asComponent().focusOwner().?);
    try std.testing.expect(border.asComponent().isSelfOrDescendant(view.asComponent()));
    try std.testing.expect(scroll.asComponent().isSelfOrDescendant(view.asComponent()));

    stub.owner = null;
    try std.testing.expectEqual(@as(?*Component, null), border.asComponent().focusOwner());
    try std.testing.expect(!border.asComponent().isSelfOrDescendant(root.asComponent()));

    const outsider = try Panel.create(a);
    defer outsider.asComponent().vtable.destroy(outsider.asComponent(), a);
    stub.owner = outsider.asComponent();
    try std.testing.expect(!border.asComponent().isSelfOrDescendant(outsider.asComponent()));

    const orphan = try Panel.create(a);
    defer orphan.asComponent().vtable.destroy(orphan.asComponent(), a);
    try std.testing.expectEqual(@as(?*Component, null), orphan.asComponent().focusOwner());
}
