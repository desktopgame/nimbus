//! Single-child padding layout. See `framework/doc/padding_layout.md`.

const std = @import("std");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const LayoutManager = @import("LayoutManager.zig");

const PaddingLayout = @This();

pub const Insets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub const zero: Insets = .{};

    pub fn all(v: f32) Insets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }

    pub fn symmetric(horizontal: f32, vertical: f32) Insets {
        return .{
            .left = horizontal,
            .right = horizontal,
            .top = vertical,
            .bottom = vertical,
        };
    }

    pub fn horizontalTotal(self: Insets) f32 {
        return self.left + self.right;
    }

    pub fn verticalTotal(self: Insets) f32 {
        return self.top + self.bottom;
    }
};

base: LayoutManager,
insets: Insets,

pub const vtable = LayoutManager.VTable{
    .doLayout = doLayout,
    .computeMinSize = computeMinSize,
    .computeMaxSize = computeMaxSize,
    .deinit = deinit,
};

pub fn create(allocator: std.mem.Allocator, insets: Insets) !*LayoutManager {
    const layout = try allocator.create(PaddingLayout);
    layout.* = .{
        .base = .{ .vtable = &vtable },
        .insets = insets,
    };
    return &layout.base;
}

pub fn getInsets(self: *const LayoutManager) Insets {
    const this: *const PaddingLayout = @fieldParentPtr("base", self);
    return this.insets;
}

pub fn setInsets(self: *LayoutManager, insets: Insets) void {
    const this: *PaddingLayout = @fieldParentPtr("base", self);
    this.insets = insets;
}

fn deinit(self: *LayoutManager, allocator: std.mem.Allocator) void {
    const this: *PaddingLayout = @fieldParentPtr("base", self);
    allocator.destroy(this);
}

fn doLayout(self: *LayoutManager, container: *Container) void {
    const this: *PaddingLayout = @fieldParentPtr("base", self);
    if (container.children.items.len == 0) return;

    const child = container.children.items[0].component;
    const insets = this.insets;
    const size = container.component.size;
    child.setBounds(.{
        .x = insets.left,
        .y = insets.top,
        .width = @max(0, size.width - insets.horizontalTotal()),
        .height = @max(0, size.height - insets.verticalTotal()),
    });
}

fn computeMinSize(self: *LayoutManager, container: *const Container) Component.Size {
    const this: *PaddingLayout = @fieldParentPtr("base", self);
    const insets = this.insets;
    const child_size = if (container.children.items.len > 0)
        container.children.items[0].component.effectiveMinSize()
    else
        Component.Size{ .width = 0, .height = 0 };
    return .{
        .width = child_size.width + insets.horizontalTotal(),
        .height = child_size.height + insets.verticalTotal(),
    };
}

fn computeMaxSize(self: *LayoutManager, container: *const Container) Component.Size {
    const this: *PaddingLayout = @fieldParentPtr("base", self);
    const insets = this.insets;
    const child_size = if (container.children.items.len > 0)
        container.children.items[0].component.effectiveMaxSize()
    else
        Component.Size{ .width = 0, .height = 0 };
    return .{
        .width = child_size.width + insets.horizontalTotal(),
        .height = child_size.height + insets.verticalTotal(),
    };
}
