//! Toggle (checkbox / radio) state model. See `framework/doc/toggle_button_model.md`.
//!
//! Wraps a `ButtonModel` (for the press / armed / rollover / enabled
//! transitions every clickable widget needs) and adds a `selected` flag.
//! Selected changes fire through the underlying `ButtonModel`'s state
//! listeners — there is no separate listener list — so a single
//! `addChangeListener` registration sees the union of all transitions.

const std = @import("std");
const ButtonModel = @import("ButtonModel.zig");
const listener = @import("listener.zig");
const ChangeEvent = listener.ChangeEvent;
const ActionEvent = listener.ActionEvent;

const ToggleButtonModel = @This();

/// Hook a `ButtonGroup` installs so it can drop its reference to this
/// model the instant the model is torn down. Without this, a group that
/// outlives its member models (the usual case: the widget tree is freed
/// when its Window closes, but the group is a separate object freed later)
/// would touch already-freed listener lists in its own `deinit`.
/// Kept as an opaque ctx + fn pointer so the model doesn't import
/// `ButtonGroup` (same decoupling as DirtyNotify / FocusController).
pub const GroupHook = struct {
    ctx: *anyopaque,
    /// Invoked from `deinit`, before the underlying listener lists are
    /// freed, so the group can `removeChangeListener` + forget this model.
    on_deinit: *const fn (ctx: *anyopaque, model: *ToggleButtonModel) void,
};

/// Underlying press / armed / rollover / enabled state. Use
/// `model.button.setPressed(...)` etc. directly — there are no
/// delegation wrappers for these (Zig idiom, `component.md`「派生型から
/// Component メソッドへのアクセス」 と同じ方針).
button:     ButtonModel,
selected:   bool = false,
/// At most one group may own a model (Swing semantics). Null when the
/// model is not part of any `ButtonGroup`.
group_hook: ?GroupHook = null,

pub fn init(allocator: std.mem.Allocator) ToggleButtonModel {
    return .{
        .button = ButtonModel.init(allocator),
    };
}

pub fn deinit(self: *ToggleButtonModel) void {
    // Let an owning group detach first, while our listener lists are still
    // valid — otherwise the group's later deinit would touch freed memory.
    if (self.group_hook) |h| h.on_deinit(h.ctx, self);
    self.button.deinit();
}

/// Set (or clear, with null) the group hook. Called by `ButtonGroup` on
/// add / remove; not intended for general use.
pub fn setGroupHook(self: *ToggleButtonModel, hook: ?GroupHook) void {
    self.group_hook = hook;
}

pub fn isSelected(self: *const ToggleButtonModel) bool {
    return self.selected;
}

pub fn setSelected(self: *ToggleButtonModel, v: bool) void {
    if (self.selected == v) return;
    self.selected = v;
    // Reuse the button's change listeners — Swing also unifies selected
    // and pressed under one ChangeEvent, and it lets a widget register
    // once and react to both kinds of transitions in the same callback.
    // Source stays the ButtonModel (consistent with press/armed events).
    self.button.fireState();
}

// ── listener registration (delegation for ergonomics) ────────────────────
//
// You could equivalently call `model.button.addChangeListener(...)`
// directly; these are short wrappers so usage of the toggle model reads
// at the same level as Button / Slider.

pub fn addChangeListener(
    self: *ToggleButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void {
    try self.button.addChangeListener(T, f, user_data);
}

pub fn removeChangeListener(
    self: *ToggleButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void {
    self.button.removeChangeListener(T, f, user_data);
}

pub fn addActionListener(
    self: *ToggleButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ActionEvent) void,
    user_data: *T,
) !void {
    try self.button.addActionListener(T, f, user_data);
}

pub fn removeActionListener(
    self: *ToggleButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ActionEvent) void,
    user_data: *T,
) void {
    self.button.removeActionListener(T, f, user_data);
}

pub fn fireAction(self: *ToggleButtonModel) void {
    self.button.fireAction();
}

// ── tests ────────────────────────────────────────────────────────────────

test "setSelected changes value and fires through button listeners" {
    var fired: u32 = 0;
    const Cb = struct {
        fn run(counter: *u32, e: *const ChangeEvent) void {
            _ = e;
            counter.* += 1;
        }
    };

    var m = ToggleButtonModel.init(std.testing.allocator);
    defer m.deinit();

    try m.addChangeListener(u32, Cb.run, &fired);
    try std.testing.expect(!m.isSelected());

    m.setSelected(true);
    try std.testing.expect(m.isSelected());
    try std.testing.expectEqual(@as(u32, 1), fired);

    // Idempotent: setting to the same value does not fire again.
    m.setSelected(true);
    try std.testing.expectEqual(@as(u32, 1), fired);

    m.setSelected(false);
    try std.testing.expect(!m.isSelected());
    try std.testing.expectEqual(@as(u32, 2), fired);
}
