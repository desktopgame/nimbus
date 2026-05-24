//! Toggle (checkbox / radio) state model. See `framework/doc/toggle_button_model.md`.
//!
//! Wraps a `ButtonModel` (for the press / armed / rollover / enabled
//! transitions every clickable widget needs) and adds a `selected` flag.
//! Selected changes fire through the underlying `ButtonModel`'s state
//! listeners — there is no separate listener list — so a single
//! `addChangeListener` registration sees the union of all transitions.

const std = @import("std");
const ButtonModel = @import("ButtonModel.zig");
const ChangeListenerList = @import("ChangeListenerList.zig");

const ToggleButtonModel = @This();

/// Underlying press / armed / rollover / enabled state. Use
/// `model.button.setPressed(...)` etc. directly — there are no
/// delegation wrappers for these (Zig idiom, `component.md`「派生型から
/// Component メソッドへのアクセス」 と同じ方針).
button:   ButtonModel,
selected: bool = false,

pub fn init(allocator: std.mem.Allocator) ToggleButtonModel {
    return .{
        .button = ButtonModel.init(allocator),
    };
}

pub fn deinit(self: *ToggleButtonModel) void {
    self.button.deinit();
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
    self.button.state_listeners.fire();
}

// ── listener registration (delegation for ergonomics) ────────────────────
//
// You could equivalently call `model.button.addChangeListener(...)`
// directly; these are short wrappers so usage of the toggle model reads
// at the same level as Button / Slider.

pub fn addChangeListener(
    self: *ToggleButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) !void {
    try self.button.addChangeListener(fn_ptr, user_data);
}

pub fn removeChangeListener(
    self: *ToggleButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) void {
    self.button.removeChangeListener(fn_ptr, user_data);
}

pub fn addActionListener(
    self: *ToggleButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) !void {
    try self.button.addActionListener(fn_ptr, user_data);
}

pub fn removeActionListener(
    self: *ToggleButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) void {
    self.button.removeActionListener(fn_ptr, user_data);
}

pub fn fireAction(self: *ToggleButtonModel) void {
    self.button.fireAction();
}

// ── tests ────────────────────────────────────────────────────────────────

test "setSelected changes value and fires through button listeners" {
    var fired: u32 = 0;
    const Cb = struct {
        fn run(ud: *anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(ud));
            counter.* += 1;
        }
    };

    var m = ToggleButtonModel.init(std.testing.allocator);
    defer m.deinit();

    try m.addChangeListener(Cb.run, @ptrCast(&fired));
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
