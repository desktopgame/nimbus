//! Button state model. See `framework/doc/button.md`.

const std = @import("std");
const ChangeListenerList = @import("ChangeListenerList.zig");

const ButtonModel = @This();

pressed:  bool = false,
armed:    bool = false,
rollover: bool = false,
enabled:  bool = true,
selected: bool = false,
state_listeners:  ChangeListenerList,
action_listeners: ChangeListenerList,

pub fn init(allocator: std.mem.Allocator) ButtonModel {
    return .{
        .state_listeners  = ChangeListenerList.init(allocator),
        .action_listeners = ChangeListenerList.init(allocator),
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
    self.state_listeners.fire();
}
pub fn isPressed(self: *const ButtonModel) bool { return self.pressed; }

pub fn setArmed(self: *ButtonModel, v: bool) void {
    if (self.armed == v) return;
    self.armed = v;
    self.state_listeners.fire();
}
pub fn isArmed(self: *const ButtonModel) bool { return self.armed; }

pub fn setRollover(self: *ButtonModel, v: bool) void {
    if (self.rollover == v) return;
    self.rollover = v;
    self.state_listeners.fire();
}
pub fn isRollover(self: *const ButtonModel) bool { return self.rollover; }

pub fn setEnabled(self: *ButtonModel, v: bool) void {
    if (self.enabled == v) return;
    self.enabled = v;
    self.state_listeners.fire();
}
pub fn isEnabled(self: *const ButtonModel) bool { return self.enabled; }

pub fn setSelected(self: *ButtonModel, v: bool) void {
    if (self.selected == v) return;
    self.selected = v;
    self.state_listeners.fire();
}
pub fn isSelected(self: *const ButtonModel) bool { return self.selected; }

// ── action ───────────────────────────────────────────────────────────────

pub fn fireAction(self: *ButtonModel) void {
    self.action_listeners.fire();
}

// ── listener registration ────────────────────────────────────────────────

pub fn addChangeListener(
    self: *ButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) !void {
    try self.state_listeners.add(fn_ptr, user_data);
}

pub fn removeChangeListener(
    self: *ButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) void {
    self.state_listeners.remove(fn_ptr, user_data);
}

pub fn addActionListener(
    self: *ButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) !void {
    try self.action_listeners.add(fn_ptr, user_data);
}

pub fn removeActionListener(
    self: *ButtonModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) void {
    self.action_listeners.remove(fn_ptr, user_data);
}
