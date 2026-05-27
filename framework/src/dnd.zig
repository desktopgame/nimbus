//! Drag and drop primitives. See `framework/doc/dnd.md`.
//!
//! v1 scope: in-app drag and drop only. The capability structs (`DragSource`
//! / `DropTarget`) are stored as optional fields on `Component`, so a widget
//! participates by having them set — the `Component.VTable` does not grow. The
//! drag lifecycle is driven by `Window` (it owns mouse capture / hit-test).
//!
//! OS file drop is a later, additive layer: `Flavor.files` / `.text` are
//! reserved now so it can be added without changing these signatures (a
//! file-accepting target checks `flavor == .files`; object-only targets ignore
//! it). See `dnd.md`「OS ドロップを後付けする」.

const Component = @import("Component.zig");

/// What kind of data a transfer carries. `files` / `text` are reserved for the
/// future OS-drop layer (unused in v1) so adding them stays additive.
pub const Flavor = enum {
    object, // in-app: app-defined object, discriminated by `type_tag`
    files, // reserved: list of UTF-8 paths (OS file drop)
    text, // reserved: UTF-8 text
};

/// Requested action. Modifier-driven in principle; v1 always uses `.move`
/// (move events do not carry modifiers, so copy/move switching is deferred —
/// see `dnd.md`「機能要望」).
pub const Action = enum { copy, move };

/// Opaque, identity-compared token for the concrete type behind a `.object`
/// transfer. Mint one per draggable type with `tagOf`.
pub const TypeTag = *const anyopaque;

/// A unique token per type `T`. Uses the type-name string's address, which is
/// stable and distinct per distinct type, so tags compare by identity.
pub fn tagOf(comptime T: type) TypeTag {
    return @typeName(T).ptr;
}

/// The payload moved by a drag. The convergence point of in-app and (future)
/// OS drops — a drop target only ever sees data through this.
pub const Transfer = struct {
    flavor: Flavor,
    /// Backing data, interpreted per `flavor` (and per producer).
    ctx: *anyopaque,
    /// For `.object`: identifies the concrete type. Null otherwise.
    type_tag: ?TypeTag = null,
    /// The component the drag started from (null for OS-originated drags).
    /// Lets a target detect "this came from me" (self-drop / reorder).
    source: ?*Component = null,

    /// Typed accessor for `.object`. Caller asserts the flavor.
    pub fn object(self: *const Transfer) *anyopaque {
        return self.ctx;
    }
};

/// Delivered to a drop target's callbacks. `x` / `y` are in the target's local
/// coordinates (the controller translates from window coords).
pub const DragEvent = struct {
    x: f32,
    y: f32,
    transfer: *const Transfer,
    action: Action,
};

/// Capability a component sets to receive drops. Held as an optional field on
/// `Component` (opt-in; does not touch the VTable). `user_data` is typically
/// the outer widget itself (recovered via `@fieldParentPtr`), or a controller.
pub const DropTarget = struct {
    /// Optional: the drag entered this target (once). Drop-zone highlight, etc.
    onEnter: ?*const fn (self: *anyopaque, e: *const DragEvent) void = null,
    /// Called every drag-move while the cursor is over this target. Update
    /// position-tracking feedback (e.g. an insertion line) here and return
    /// whether a drop is acceptable at this point. The return value drives the
    /// cursor and whether `onDrop` will fire. The body runs even when returning
    /// false (so a "no drop" state can be shown). Subsumes a separate predicate.
    onOver: *const fn (self: *anyopaque, e: *const DragEvent) bool,
    /// Optional: the drag left this target (once). Clear feedback.
    onLeave: ?*const fn (self: *anyopaque) void = null,
    /// The drop committed: fired once, on release over a target whose last
    /// `onOver` returned true.
    onDrop: *const fn (self: *anyopaque, e: *const DragEvent) void,
    user_data: *anyopaque,
};

/// Capability a component sets to be a drag source. In-app only (OS drags have
/// an external source). Held as an optional field on `Component`.
pub const DragSource = struct {
    /// A drag gesture was recognized on this component at local (`x`, `y`).
    /// Build and return the transfer to carry, or null to suppress the drag.
    onDragStart: *const fn (self: *anyopaque, x: f32, y: f32) ?Transfer,
    /// Optional: called every move while the drag is active, with the cursor in
    /// **window** coordinates. The per-move hook for the source side (symmetric
    /// with `DropTarget.onOver`). Use it to drive a ghost: nimbus draws none —
    /// a source that wants one registers a `passthrough` overlay in
    /// `onDragStart`, repositions it here, and removes it in `onDragDone`. See
    /// `dnd.md`「描画 (ゴースト / 挿入先)」.
    onDrag: ?*const fn (self: *anyopaque, x: f32, y: f32) void = null,
    /// Optional: the drag finished. `performed` is the action actually carried
    /// out, or null if no drop happened (cancelled / not accepted) — a move
    /// source then keeps its original.
    onDragDone: ?*const fn (self: *anyopaque, performed: ?Action) void = null,
    user_data: *anyopaque,
};
