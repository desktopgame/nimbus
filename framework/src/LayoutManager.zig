//! Pluggable layout strategy used by Container. See `framework/doc/layout.md`.

const std = @import("std");
const Component = @import("Component.zig");

const Container = @import("Container.zig");
const LayoutManager = @This();

pub const VTable = struct {
    /// Assign bounds to each direct child of `container`.
    doLayout: *const fn (*LayoutManager, *Container) void,
    /// Smallest size this container can be under this layout.
    computeMinSize: *const fn (*LayoutManager, *const Container) Component.Size,
    /// Largest size this container will grow to.
    /// Use `std.math.inf(f32)` for unbounded axes.
    computeMaxSize: *const fn (*LayoutManager, *const Container) Component.Size,
    /// Optional cleanup; null for singletons.
    deinit: ?*const fn (*LayoutManager, std.mem.Allocator) void = null,
};

vtable: *const VTable,
