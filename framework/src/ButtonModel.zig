//! Button state model. See `framework/doc/button.md`.

const std = @import("std");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ActionListenerList = listener.ActionListenerList;
const ChangeEvent = listener.ChangeEvent;
const ActionEvent = listener.ActionEvent;

const ButtonModel = @This();

/// Fire the state-change listeners (also used by `ToggleButtonModel` for its
/// `selected` transition, so the event source stays consistently the ButtonModel).
pub fn fireState(self: *ButtonModel) void {
    self.state_listeners.fire(&.{ .source = self });
}

pressed:  bool = false,
armed:    bool = false,
rollover: bool = false,
enabled:  bool = true,
state_listeners:  ChangeListenerList,
action_listeners: ActionListenerList,

pub fn init(allocator: std.mem.Allocator) ButtonModel {
    return .{
        .state_listeners  = ChangeListenerList.init(allocator),
        .action_listeners = ActionListenerList.init(allocator),
    };
}

pub fn deinit(self: *ButtonModel) void {
    self.state_listeners.deinit();
    self.action_listeners.deinit();
}

// ── state flag setters / getters ─────────────────────────────────────────

pub fn setPressed(self: *ButtonModel, v: bool) void {
    if (self.pressed == v) return;
    self.pressed = v;
    self.fireState();
}
pub fn isPressed(self: *const ButtonModel) bool { return self.pressed; }

pub fn setArmed(self: *ButtonModel, v: bool) void {
    if (self.armed == v) return;
    self.armed = v;
    self.fireState();
}
pub fn isArmed(self: *const ButtonModel) bool { return self.armed; }

pub fn setRollover(self: *ButtonModel, v: bool) void {
    if (self.rollover == v) return;
    self.rollover = v;
    self.fireState();
}
pub fn isRollover(self: *const ButtonModel) bool { return self.rollover; }

pub fn setEnabled(self: *ButtonModel, v: bool) void {
    if (self.enabled == v) return;
    self.enabled = v;
    self.fireState();
}
pub fn isEnabled(self: *const ButtonModel) bool { return self.enabled; }

// `selected` lives on `ToggleButtonModel` (which embeds this one). Plain
// momentary buttons do not have a selected state, so keeping that flag
// here previously was an unused field that confused widget authors.

// ── action ───────────────────────────────────────────────────────────────

pub fn fireAction(self: *ButtonModel) void {
    self.action_listeners.fire(&.{ .source = self });
}

// ── listener registration ────────────────────────────────────────────────

pub fn addChangeListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void {
    try self.state_listeners.addTyped(T, f, user_data);
}

pub fn removeChangeListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void {
    self.state_listeners.removeTyped(T, f, user_data);
}

pub fn addActionListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ActionEvent) void,
    user_data: *T,
) !void {
    try self.action_listeners.addTyped(T, f, user_data);
}

pub fn removeActionListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ActionEvent) void,
    user_data: *T,
) void {
    self.action_listeners.removeTyped(T, f, user_data);
}
