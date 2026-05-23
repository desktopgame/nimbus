//! Base widget type. See `framework/doc/component.md`.

const std = @import("std");
const awt = @import("awt");

const Component = @This();

pub const Point = struct { x: f32, y: f32 };
pub const Size = struct {
    width: f32,
    height: f32,

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }
};
/// Alias to awt.Graphics.Rect so Component / Graphics share the same Rect type
/// and `g.clip(comp.getBounds())` type-checks without conversion.
pub const Rect = awt.Graphics.Rect;

/// Re-export awt.Event so widgets can write `*Event` in vtable signatures
/// without an explicit awt import.
pub const Event = awt.Event;

/// Cross-axis alignment used by layouts (e.g. BoxLayout reads this on each
/// child when assigning the cross-axis position). Semantics:
/// * `stretch` — fill the container's cross dimension (clamped by min/max)
/// * `start`   — pin to the cross-axis low edge (top / left), size = min
/// * `center`  — center on the cross axis, size = min
/// * `end`     — pin to the cross-axis high edge (bottom / right), size = min
pub const Alignment = enum { start, center, end, stretch };

pub const VTable = struct {
    /// One-time setup after the component is placed in its container (or for
    /// the root, immediately after construction). May fail if it allocates
    /// (listener registration, property insertion, etc.). `create()` factories
    /// propagate this error so the half-built widget is freed cleanly.
    install:      *const fn (self: *Component) anyerror!void,
    /// Tear down whatever `install` set up. Conceptually a destructor — only
    /// releases resources, never fails. Callers do not need to handle errors.
    uninstall:    *const fn (self: *Component) void,
    paint:        *const fn (self: *Component, g: *awt.Graphics) void,
    /// Mutable Event pointer; consumption is via `ev.consume()`. See
    /// `awt/doc/event.md` for the consumption model.
    processEvent: *const fn (self: *Component, ev: *Event) void,
    /// Free the concrete widget's memory (sizeof Label / Button / ... not sizeof Component).
    /// Called by Container.deinit after `uninstall` + property cleanup. The implementation
    /// is expected to `@fieldParentPtr` back to the outer type and call `allocator.destroy`.
    destroy:      *const fn (self: *Component, allocator: std.mem.Allocator) void,
};

pub const Property = struct {
    value:   *anyopaque,
    destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
};

// Forward declaration so `container` field can reference Container.
const Container = @import("Container.zig");

vtable:     *const VTable,
position:   Point,
size:       Size,
min_size:   Size,
max_size:   Size,
grow_x:     f32,
grow_y:     f32,
align_x:    Alignment,
align_y:    Alignment,
parent:     ?*Component,
container:  ?*Container,
/// True if this component can receive keyboard focus. Default false:
/// Button / Label / Slider don't take focus in v1 (mouse only). Widgets
/// that consume text input (TextField, TextArea) set this to true.
focusable:  bool,
name:       ?[]const u8,
properties: ?std.StringHashMap(Property),
allocator:  std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) Component {
    return .{
        .vtable     = vtable,
        .position   = .{ .x = 0, .y = 0 },
        .size       = .{ .width = 0, .height = 0 },
        .min_size   = .{ .width = 0, .height = 0 },
        .max_size   = .{ .width = std.math.inf(f32), .height = std.math.inf(f32) },
        .grow_x     = 0,
        .grow_y     = 0,
        .align_x    = .stretch,
        .align_y    = .stretch,
        .parent     = null,
        .container  = null,
        .focusable  = false,
        .name       = null,
        .properties = null,
        .allocator  = allocator,
    };
}

/// Run vtable.uninstall and free property values. Does NOT free the outer
/// widget's memory — vtable.destroy is responsible for that.
pub fn deinit(self: *Component) void {
    self.vtable.uninstall(self);
    if (self.properties) |*props| {
        var it = props.iterator();
        while (it.next()) |entry| {
            const prop = entry.value_ptr.*;
            if (prop.destroy) |destroy| destroy(prop.value, self.allocator);
        }
        props.deinit();
        self.properties = null;
    }
    if (self.name) |n| {
        self.allocator.free(n);
        self.name = null;
    }
}

pub fn getBounds(self: Component) Rect {
    return .{
        .x = self.position.x,
        .y = self.position.y,
        .width = self.size.width,
        .height = self.size.height,
    };
}

pub fn setBounds(self: *Component, r: Rect) void {
    const moved =
        self.position.x != r.x or self.position.y != r.y or
        self.size.width != r.width or self.size.height != r.height;
    self.position = .{ .x = r.x, .y = r.y };
    self.size = .{ .width = r.width, .height = r.height };
    if (moved) self.markLayoutDirty();
}

// ── layout attributes ────────────────────────────────────────────────────

pub fn getMinSize(self: *const Component) Size {
    return self.min_size;
}

pub fn setMinSize(self: *Component, s: Size) void {
    if (Size.eql(self.min_size, s)) return;
    self.min_size = s;
    self.markLayoutDirty();
}

pub fn getMaxSize(self: *const Component) Size {
    return self.max_size;
}

pub fn setMaxSize(self: *Component, s: Size) void {
    if (Size.eql(self.max_size, s)) return;
    self.max_size = s;
    self.markLayoutDirty();
}

/// Min size that layouts should use when measuring a child. For plain
/// components this is `min_size`; for containers it combines the field
/// with the layout-computed value (so a nested Container reports a size
/// derived from its own children, instead of the default zero).
///
/// Layouts should prefer this over reading `min_size` directly. Costs
/// O(n) per call where n = subtree size, since computing a container's
/// size walks its children — keep an eye on this if the tree gets deep
/// (no caching in v1).
pub fn effectiveMinSize(self: *const Component) Size {
    if (self.container) |c| return c.getMinSize();
    return self.min_size;
}

/// Max size counterpart of `effectiveMinSize`. Containers combine
/// `component.max_size` with the layout-computed value by taking the
/// minimum (symmetric with `getMinSize` taking the maximum), so an
/// explicit `setMaxSize` on a container caps the layout's reported max.
pub fn effectiveMaxSize(self: *const Component) Size {
    if (self.container) |c| return c.getMaxSize();
    return self.max_size;
}

pub fn getGrowX(self: *const Component) f32 {
    return self.grow_x;
}

pub fn setGrowX(self: *Component, w: f32) void {
    if (self.grow_x == w) return;
    self.grow_x = w;
    self.markLayoutDirty();
}

pub fn getGrowY(self: *const Component) f32 {
    return self.grow_y;
}

pub fn setGrowY(self: *Component, w: f32) void {
    if (self.grow_y == w) return;
    self.grow_y = w;
    self.markLayoutDirty();
}

pub fn getAlignX(self: *const Component) Alignment {
    return self.align_x;
}

pub fn setAlignX(self: *Component, a: Alignment) void {
    if (self.align_x == a) return;
    self.align_x = a;
    self.markLayoutDirty();
}

pub fn getAlignY(self: *const Component) Alignment {
    return self.align_y;
}

pub fn setAlignY(self: *Component, a: Alignment) void {
    if (self.align_y == a) return;
    self.align_y = a;
    self.markLayoutDirty();
}

// ── focus ────────────────────────────────────────────────────────────────

pub fn isFocusable(self: *const Component) bool {
    return self.focusable;
}

pub fn setFocusable(self: *Component, v: bool) void {
    self.focusable = v;
}

/// Ask the owning Window to make this component the focus owner.
/// Walks the parent chain to a root that carries a `FocusController`
/// property (installed by Window). No-op if the component is not
/// attached to a focus-aware root (e.g. orphan during construction).
pub fn requestFocus(self: *Component) void {
    var node: ?*Component = self;
    while (node) |cur| {
        if (cur.parent == null) {
            if (cur.getTyped(FocusController)) |fc| {
                fc.request_focus_for(fc.user_data, self);
            }
            return;
        }
        node = cur.parent;
    }
}

/// Property type that Window installs on each root Component so that
/// `Component.requestFocus()` can bubble up and reach the Window's
/// focus-owner state without a direct framework→framework dependency
/// cycle. Same pattern as `DirtyNotify`.
pub const FocusController = struct {
    user_data:         *anyopaque,
    request_focus_for: *const fn (*anyopaque, ?*Component) void,
};

// ── name (debug) ─────────────────────────────────────────────────────────

pub fn setName(self: *Component, name: ?[]const u8) void {
    if (self.name) |old| self.allocator.free(old);
    self.name = if (name) |n| self.allocator.dupe(u8, n) catch null else null;
}

pub fn getName(self: Component) ?[]const u8 {
    return self.name;
}

/// Swap to a new vtable. uninstall the old, swap, install the new — atomic
/// only on success. If the new install fails, the component is left in the
/// uninstalled state (old vtable already torn down); caller's responsibility
/// to roll back if needed.
pub fn setVTable(self: *Component, new_vt: *const VTable) !void {
    self.vtable.uninstall(self);
    self.vtable = new_vt;
    try self.vtable.install(self);
}

/// Mark dirty for repaint. Walks up parent chain to the root Window which
/// holds the actual dirty flags. Currently the root just marks via
/// `markDirtyOnRoot` set up by Window on install.
pub fn repaint(self: *Component) void {
    markDirty(self, .paint);
}

pub fn repaintRect(self: *Component, r: Rect) void {
    _ = r;
    markDirty(self, .paint);
}

pub fn markLayoutDirty(self: *Component) void {
    markDirty(self, .layout);
}

const DirtyKind = enum { paint, layout };

fn markDirty(c: *Component, kind: DirtyKind) void {
    // Walk up to the root component; that's where dirty flags live (Frame).
    var node: ?*Component = c;
    while (node) |cur| {
        if (cur.parent == null) {
            // Root reached. Check whether it has the dirty notify property.
            if (cur.getTyped(DirtyNotify)) |notify| {
                switch (kind) {
                    .paint  => notify.paint(notify.user_data),
                    .layout => notify.layout(notify.user_data),
                }
            }
            return;
        }
        node = cur.parent;
    }
}

/// Property type that Frame/Window install on its root Component so that
/// `repaint` / `markLayoutDirty` calls can bubble up and notify the owning
/// Frame/Application of pending work.
pub const DirtyNotify = struct {
    user_data: *anyopaque,
    paint:     *const fn (*anyopaque) void,
    layout:    *const fn (*anyopaque) void,
};

/// Helper: build a child Graphics clipped to self.getBounds and dispatch
/// vtable.paint. Used by Container to paint children and by the root caller
/// to paint the root component without manual clip plumbing.
pub fn paintAt(self: *Component, parent_g: *awt.Graphics) void {
    var g = parent_g.clip(self.getBounds());
    self.vtable.paint(self, &g);
}

/// Walk parent chain to compute the absolute origin of `self` within the
/// window. Sums each ancestor's `position`, including the root's. The root
/// is typically Window's container (position 0,0), or an overlay's popup
/// root which has a non-zero window-local position. By always summing
/// (no special-case for root), overlay subtrees hit-test correctly without
/// further coordinate translation.
pub fn absoluteOriginInWindow(self: *const Component) Point {
    var p: Point = .{ .x = 0, .y = 0 };
    var node: ?*const Component = self;
    while (node) |cur| {
        p.x += cur.position.x;
        p.y += cur.position.y;
        node = cur.parent;
    }
    return p;
}

/// True if window-local point falls inside `self`'s absolute bounds.
pub fn containsWindowPoint(self: *const Component, x: f32, y: f32) bool {
    const o = self.absoluteOriginInWindow();
    return x >= o.x and x < o.x + self.size.width and
        y >= o.y and y < o.y + self.size.height;
}

// ── client properties (Swing JComponent.putClientProperty 相当) ───────────

pub fn putProperty(
    self: *Component,
    key: []const u8,
    value: *anyopaque,
    destroy: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !void {
    if (self.properties == null) {
        self.properties = std.StringHashMap(Property).init(self.allocator);
    }
    try self.properties.?.put(key, .{ .value = value, .destroy = destroy });
}

pub fn getProperty(self: Component, key: []const u8) ?*anyopaque {
    const props = self.properties orelse return null;
    const prop = props.get(key) orelse return null;
    return prop.value;
}

pub fn removeProperty(self: *Component, key: []const u8) void {
    if (self.properties) |*props| {
        if (props.fetchRemove(key)) |entry| {
            if (entry.value.destroy) |destroy| destroy(entry.value.value, self.allocator);
        }
    }
}

pub fn putTyped(self: *Component, comptime T: type, value: *T) !void {
    const dtor = struct {
        fn d(p: *anyopaque, a: std.mem.Allocator) void {
            a.destroy(@as(*T, @ptrCast(@alignCast(p))));
        }
    }.d;
    try self.putProperty(@typeName(T), @ptrCast(value), dtor);
}

pub fn getTyped(self: Component, comptime T: type) ?*T {
    const ptr = self.getProperty(@typeName(T)) orelse return null;
    return @ptrCast(@alignCast(ptr));
}
