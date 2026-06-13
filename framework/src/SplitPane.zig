//! Split pane. See `framework/doc/split_pane.md`.
//!
//! Two owned panes side by side (or stacked), separated by a draggable
//! divider. Built like `ScrollPane`: it embeds a `Container` (children =
//! `first` + `second`), overrides that container's vtable to paint the
//! divider and handle the drag, and supplies its own `LayoutManager` that
//! places the panes around `divider_location`. Layout is continuous during
//! the drag — each move event updates the location and requests a relayout
//! of this subtree only.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const LayoutManager = @import("LayoutManager.zig");

const SplitPane = @This();

pub const Orientation = enum { horizontal, vertical };

pub const DragState = struct {
    /// Distance from the divider's leading edge to the cursor at grab time
    /// (main-axis px), so the divider doesn't jump on the first move.
    grab: f32,
};

const DEFAULT_DIVIDER_SIZE: f32 = 6;

// `container` MUST be the first field: the public Component is
// `container.component`, and methods recover `*SplitPane` via
// `@fieldParentPtr("container", ...)`.
container: Container,
layout: SplitLayout,
first: *Component, // owned (left / top pane)
second: *Component, // owned (right / bottom pane)
orientation: Orientation,
/// Main-axis size of `first` in px. Null until the first layout, which seeds
/// it from `first.effectiveMinSize()`. Always re-clamped by the layout so a
/// value set before the pane has a size is applied (clamped) on first layout.
divider_location: ?f32,
divider_size: f32,
/// Share of a container resize delta given to `first` (see doc). 0 keeps
/// `first` at its px size (sidebar default), 1 gives it the whole delta.
resize_weight: f32,
drag: ?DragState,
rollover: bool,
/// Main-axis space (minus divider) at the previous layout; the delta against
/// the current space is what `resize_weight` distributes.
last_main: ?f32,
allocator: std.mem.Allocator,

const SplitLayout = struct {
    base: LayoutManager,
};

pub const vtable = Component.VTable{
    .install = Container.vtable.install,
    .uninstall = Container.vtable.uninstall,
    .paint = paint,
    .processEvent = processEvent,
    .destroy = destroy,
};

const split_layout_vtable = LayoutManager.VTable{
    .doLayout = layoutDoLayout,
    .computeMinSize = layoutComputeMinSize,
    .computeMaxSize = layoutComputeMaxSize,
};

pub fn create(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    first: *Component,
    second: *Component,
) !*SplitPane {
    // Ownership of the panes transfers even on error (doc'd contract), so any
    // failure below must destroy them — the caller has nothing to clean up.
    errdefer first.vtable.destroy(first, allocator);
    errdefer second.vtable.destroy(second, allocator);

    const sp = try allocator.create(SplitPane);
    errdefer allocator.destroy(sp);

    sp.* = .{
        .container = Container.init(allocator),
        .layout = .{ .base = .{ .vtable = &split_layout_vtable } },
        .first = first,
        .second = second,
        .orientation = orientation,
        .divider_location = null,
        .divider_size = DEFAULT_DIVIDER_SIZE,
        .resize_weight = 0,
        .drag = null,
        .rollover = false,
        .last_main = null,
        .allocator = allocator,
    };
    // Wire the embedded container to behave as the SplitPane component.
    sp.container.component.vtable = &vtable;
    sp.container.component.role = .split_pane;
    sp.container.component.container = &sp.container;
    sp.container.layout = &sp.layout.base;

    try sp.container.children.ensureTotalCapacity(allocator, 2);

    // ── commit: no failures past this point ──────────────────────────────
    sp.container.add(first) catch unreachable;
    sp.container.add(second) catch unreachable;
    return sp;
}

// ── public API ───────────────────────────────────────────────────────────

/// The public Component (for `setGrowX/Y`, adding to a parent, etc.).
pub fn asComponent(self: *SplitPane) *Component {
    return &self.container.component;
}

pub fn getFirst(self: SplitPane) *Component {
    return self.first;
}

pub fn getSecond(self: SplitPane) *Component {
    return self.second;
}

pub fn getDividerLocation(self: SplitPane) ?f32 {
    return self.divider_location;
}

/// Set `first`'s main-axis size in px. Clamped immediately when the pane
/// already has a size; a value set before the first layout is kept and
/// clamp-applied then (no call-order trap).
pub fn setDividerLocation(self: *SplitPane, px: f32) void {
    const avail = self.availableMain();
    self.divider_location = if (avail > 0) self.clampLocation(px, avail) else px;
    self.container.component.markLayoutDirty();
}

pub fn setDividerSize(self: *SplitPane, px: f32) void {
    self.divider_size = @max(0, px);
    self.container.component.markLayoutDirty();
}

/// Clamped to [0, 1]. Affects future resizes only (no relayout now).
pub fn setResizeWeight(self: *SplitPane, weight: f32) void {
    self.resize_weight = std.math.clamp(weight, 0, 1);
}

// ── geometry ───────────────────────────────────────────────────────────────

fn fromComponent(self: *Component) *SplitPane {
    const c: *Container = @fieldParentPtr("component", self);
    return @fieldParentPtr("container", c);
}

fn mainAxis(self: *const SplitPane, size: Component.Size) f32 {
    return switch (self.orientation) {
        .horizontal => size.width,
        .vertical => size.height,
    };
}

/// Main-axis space left for the two panes (container size minus divider).
fn availableMain(self: *const SplitPane) f32 {
    return @max(0, self.mainAxis(self.container.component.size) - self.divider_size);
}

/// Divider leading edge = the laid-out main-axis size of `first` (visual
/// truth, even while `divider_location` holds a not-yet-applied value).
fn dividerStart(self: *const SplitPane) f32 {
    return self.mainAxis(self.first.size);
}

fn overDivider(self: *const SplitPane, main: f32) bool {
    const start = self.dividerStart();
    return main >= start and main < start + self.divider_size;
}

/// Clamp a divider location to [first's min, avail - second's min]. When the
/// range is empty (both mins + divider exceed the space), `first` wins its
/// minimum and `second` takes whatever remains.
fn clampLocation(self: *const SplitPane, loc: f32, avail: f32) f32 {
    const lo = self.mainAxis(self.first.effectiveMinSize());
    const hi = @max(lo, avail - self.mainAxis(self.second.effectiveMinSize()));
    return @max(lo, @min(loc, hi));
}

// ── layout (SplitLayout vtable) ────────────────────────────────────────────

fn layoutDoLayout(_: *LayoutManager, container: *Container) void {
    const self: *SplitPane = @fieldParentPtr("container", container);
    const W = container.component.size.width;
    const H = container.component.size.height;
    const avail = self.availableMain();

    var loc: f32 = undefined;
    if (self.divider_location) |dl| {
        loc = dl;
        // Distribute the resize delta per resize_weight (0 → first keeps px).
        if (self.last_main) |lm| {
            if (avail != lm) loc += (avail - lm) * self.resize_weight;
        }
    } else {
        // First layout with no explicit location: first opens at its natural
        // (minimum) size — the sidebar default.
        loc = self.mainAxis(self.first.effectiveMinSize());
    }
    loc = self.clampLocation(loc, avail);
    self.divider_location = loc;
    self.last_main = avail;

    const second_len = @max(0, avail - loc);
    switch (self.orientation) {
        .horizontal => {
            self.first.setBounds(.{ .x = 0, .y = 0, .width = loc, .height = H });
            self.second.setBounds(.{ .x = loc + self.divider_size, .y = 0, .width = second_len, .height = H });
        },
        .vertical => {
            self.first.setBounds(.{ .x = 0, .y = 0, .width = W, .height = loc });
            self.second.setBounds(.{ .x = 0, .y = loc + self.divider_size, .width = W, .height = second_len });
        },
    }
}

fn layoutComputeMinSize(_: *LayoutManager, container: *const Container) Component.Size {
    const self: *const SplitPane = @fieldParentPtr("container", @constCast(container));
    const a = self.first.effectiveMinSize();
    const b = self.second.effectiveMinSize();
    return switch (self.orientation) {
        .horizontal => .{
            .width = a.width + self.divider_size + b.width,
            .height = @max(a.height, b.height),
        },
        .vertical => .{
            .width = @max(a.width, b.width),
            .height = a.height + self.divider_size + b.height,
        },
    };
}

fn layoutComputeMaxSize(_: *LayoutManager, _: *const Container) Component.Size {
    return .{ .width = std.math.inf(f32), .height = std.math.inf(f32) };
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn paint(self: *Component, g: *awt.Graphics) void {
    const sp = fromComponent(self);
    const sz = self.size;
    if (sz.width > 0 and sz.height > 0 and sp.divider_size > 0) {
        const t = self.theme;
        const start = sp.dividerStart();
        const strip: Component.Rect = switch (sp.orientation) {
            .horizontal => .{ .x = start, .y = 0, .width = sp.divider_size, .height = sz.height },
            .vertical => .{ .x = 0, .y = start, .width = sz.width, .height = sp.divider_size },
        };
        g.setColor(t.surface_window);
        g.fillRect(strip);
        // Center grip line; stronger while grabbed / hovered (no resize
        // cursor support in awt yet, so this is the only affordance).
        g.setColor(if (sp.drag != null or sp.rollover) t.border else t.separator);
        const line: Component.Rect = switch (sp.orientation) {
            .horizontal => .{ .x = start + sp.divider_size / 2 - 0.5, .y = 0, .width = 1, .height = sz.height },
            .vertical => .{ .x = 0, .y = start + sp.divider_size / 2 - 0.5, .width = sz.width, .height = 1 },
        };
        g.fillRect(line);
    }
    Container.vtable.paint(self, g); // panes (disjoint rects, order moot)
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const sp = fromComponent(self);
    switch (ev.payload) {
        .mouse => |m| {
            const origin = self.absoluteOriginInWindow();
            const main: f32 = switch (sp.orientation) {
                .horizontal => m.x - origin.x,
                .vertical => m.y - origin.y,
            };
            switch (m.action) {
                .press => {
                    if (m.button == .left and sp.overDivider(main)) {
                        sp.drag = .{ .grab = main - sp.dividerStart() };
                        ev.requestCapture(@ptrCast(self));
                        self.repaint();
                        ev.consume();
                        return;
                    }
                },
                .move => {
                    if (sp.drag) |d| {
                        // Continuous layout: relayout this subtree every move.
                        sp.setDividerLocation(main - d.grab);
                        ev.consume();
                        return;
                    }
                    const over = sp.overDivider(main);
                    if (over != sp.rollover) {
                        sp.rollover = over;
                        self.repaint();
                    }
                },
                .release => {
                    if (m.button == .left and sp.drag != null) {
                        sp.drag = null;
                        self.repaint();
                        ev.consume();
                        return;
                    }
                },
                .scroll => {},
            }
        },
        .key, .char, .focus, .composition => {},
    }
    Container.vtable.processEvent(self, ev);
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const c: *Container = @fieldParentPtr("component", self);
    const sp: *SplitPane = @fieldParentPtr("container", c);
    // container.deinit destroys the children (first, second) and runs
    // component.deinit → uninstall.
    c.deinit();
    allocator.destroy(sp);
}
