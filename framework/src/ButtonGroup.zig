//! Mutual-exclusion group for `ToggleButtonModel`. See
//! `framework/doc/button_group.md`.
//!
//! Add `*ToggleButtonModel`s with `add`; the group hooks each one's
//! change listener and clears the others when one becomes selected.
//! Also enforces "at most one selected at a time" on `add` (a model
//! that is already selected when added will deselect the previously
//! held selection).

const std = @import("std");
const ToggleButtonModel = @import("ToggleButtonModel.zig");
const ChangeListenerList = @import("ChangeListenerList.zig");
const Event = ChangeListenerList.Event;

const ButtonGroup = @This();

allocator: std.mem.Allocator,
members:   std.ArrayList(*ToggleButtonModel),
/// Per-member snapshot of `isSelected()` as of the previous change
/// notification. We use this in `onMemberChange` to figure out *which*
/// model just transitioned false→true (the ChangeListener signature
/// only passes the group, not the source model, so we have to deduce it
/// by diffing). Parallel to `members` (same index, same length).
prev_selected: std.ArrayList(bool),
/// True while we are programmatically clearing other members so their
/// resulting listener fires can early-out and avoid re-entry. UI thread
/// only — single bool is enough.
muting:    bool = false,

pub fn init(allocator: std.mem.Allocator) ButtonGroup {
    return .{
        .allocator = allocator,
        .members = .empty,
        .prev_selected = .empty,
    };
}

pub fn deinit(self: *ButtonGroup) void {
    // Detach every member still alive. A member destroyed before us (e.g.
    // its Window closed and Application.run tore down the widget tree)
    // already removed itself via the group hook, so it is no longer in
    // `members` and we never touch its freed listener list.
    while (self.members.items.len > 0) {
        self.detach(self.members.items[0]);
    }
    self.members.deinit(self.allocator);
    self.prev_selected.deinit(self.allocator);
}

pub fn create(allocator: std.mem.Allocator) !*ButtonGroup {
    const g = try allocator.create(ButtonGroup);
    g.* = ButtonGroup.init(allocator);
    return g;
}

/// Free a heap group (from `create`) in a single call: detach every member
/// (`deinit`) and release the allocation itself. A ButtonGroup is
/// caller-owned — it lives outside the widget tree and only borrows member
/// models — so the caller calls this exactly once when done. Use this
/// instead of the `deinit` + `allocator.destroy` pair. (Stack-allocated
/// groups from `init` use `deinit` directly.)
pub fn destroy(self: *ButtonGroup) void {
    const allocator = self.allocator;
    self.deinit();
    allocator.destroy(self);
}

/// Add `model` to the group. From this point on, when the model becomes
/// selected, all other group members are deselected automatically.
/// If `model` is already selected at the moment of add, every other
/// currently-selected member is cleared so the new addition wins.
pub fn add(self: *ButtonGroup, model: *ToggleButtonModel) !void {
    try self.members.append(self.allocator, model);
    errdefer _ = self.members.pop();
    try self.prev_selected.append(self.allocator, model.isSelected());
    errdefer _ = self.prev_selected.pop();
    try model.addChangeListener(ButtonGroup, onMemberChange, self);
    // Install the back-channel so the model can detach itself if it is
    // destroyed before the group (see ToggleButtonModel.GroupHook).
    model.setGroupHook(.{ .ctx = @ptrCast(self), .on_deinit = onMemberDeinit });

    if (model.isSelected()) {
        self.clearOthers(model);
    }
}

/// Remove `model` from the group. Idempotent.
pub fn remove(self: *ButtonGroup, model: *ToggleButtonModel) void {
    self.detach(model);
}

/// Drop `model` from the group: clear its hook, unsubscribe its change
/// listener, and remove the parallel `members` / `prev_selected` entries.
/// No-op if `model` is not a member. Safe to call from the model's own
/// `deinit` (listener lists are still valid at that point).
fn detach(self: *ButtonGroup, model: *ToggleButtonModel) void {
    var i: usize = 0;
    while (i < self.members.items.len) : (i += 1) {
        if (self.members.items[i] == model) {
            model.setGroupHook(null);
            model.removeChangeListener(ButtonGroup, onMemberChange, self);
            _ = self.members.orderedRemove(i);
            _ = self.prev_selected.orderedRemove(i);
            return;
        }
    }
}

/// GroupHook callback: a member model is being destroyed. Detach it so a
/// later `ButtonGroup.deinit` (or any group operation) never dereferences
/// the freed model.
fn onMemberDeinit(ctx: *anyopaque, model: *ToggleButtonModel) void {
    const self: *ButtonGroup = @ptrCast(@alignCast(ctx));
    self.detach(model);
}

/// Currently-selected member, or null if none.
pub fn getSelected(self: ButtonGroup) ?*ToggleButtonModel {
    for (self.members.items) |m| {
        if (m.isSelected()) return m;
    }
    return null;
}

// ── internal ─────────────────────────────────────────────────────────────

fn clearOthers(self: *ButtonGroup, winner: *ToggleButtonModel) void {
    // Mute so cascading listener firings do not re-enter and cause O(n²)
    // clears (and unneeded ChangeListener noise).
    self.muting = true;
    defer self.muting = false;
    for (self.members.items, 0..) |m, i| {
        if (m != winner and m.isSelected()) {
            m.setSelected(false);
        }
        // Snapshot stays in sync with the post-clear state.
        self.prev_selected.items[i] = m.isSelected();
    }
}

fn onMemberChange(self: *ButtonGroup, _: *const Event) void {
    if (self.muting) return;

    // Listeners fire for any state change (pressed/armed/rollover/selected).
    // Detect a false→true transition by diffing against the snapshot; that
    // identifies the newly-selected winner regardless of array order.
    var winner: ?*ToggleButtonModel = null;
    for (self.members.items, 0..) |m, i| {
        const curr = m.isSelected();
        if (curr and !self.prev_selected.items[i]) {
            winner = m;
        }
    }

    if (winner) |w| {
        // clearOthers also refreshes prev_selected for every member.
        self.clearOthers(w);
    } else {
        // No new selection — refresh snapshot only (a member may have
        // gone true→false on its own).
        for (self.members.items, 0..) |m, i| {
            self.prev_selected.items[i] = m.isSelected();
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────

test "selecting a member deselects others" {
    const a = std.testing.allocator;

    // Either teardown order is safe (see the "member destroyed before the
    // group" test); here the models simply outlive the group.
    var m1 = ToggleButtonModel.init(a);
    defer m1.deinit();
    var m2 = ToggleButtonModel.init(a);
    defer m2.deinit();
    var m3 = ToggleButtonModel.init(a);
    defer m3.deinit();

    var g = ButtonGroup.init(a);
    defer g.deinit();

    try g.add(&m1);
    try g.add(&m2);
    try g.add(&m3);

    m1.setSelected(true);
    try std.testing.expect(m1.isSelected());
    try std.testing.expect(!m2.isSelected());
    try std.testing.expect(!m3.isSelected());

    m2.setSelected(true);
    try std.testing.expect(!m1.isSelected());
    try std.testing.expect(m2.isSelected());
    try std.testing.expect(!m3.isSelected());

    try std.testing.expectEqual(@as(?*ToggleButtonModel, &m2), g.getSelected());
}

test "member destroyed before the group detaches itself (no use-after-free)" {
    const a = std.testing.allocator;

    // Reverse of the usual order: the group is declared FIRST, so its
    // `defer deinit` runs LAST — after the models are gone. This mirrors a
    // real app where Application.run frees the widget tree on window close
    // while the ButtonGroup lives in the caller's stack frame. The group
    // hook must keep this from touching freed listener lists.
    var g = ButtonGroup.init(a);
    defer g.deinit();

    {
        var m1 = ToggleButtonModel.init(a);
        defer m1.deinit();
        var m2 = ToggleButtonModel.init(a);
        defer m2.deinit();

        try g.add(&m1);
        try g.add(&m2);
        m1.setSelected(true);

        // m1, m2 deinit here (LIFO) — each detaches from g via the hook.
    }

    // Both members have unhooked themselves; the group is now empty and its
    // deinit is a plain free.
    try std.testing.expectEqual(@as(usize, 0), g.members.items.len);
    try std.testing.expectEqual(@as(?*ToggleButtonModel, null), g.getSelected());
}

test "adding a pre-selected member clears previous selection" {
    const a = std.testing.allocator;

    var m1 = ToggleButtonModel.init(a);
    defer m1.deinit();
    var m2 = ToggleButtonModel.init(a);
    defer m2.deinit();

    var g = ButtonGroup.init(a);
    defer g.deinit();

    m1.setSelected(true);
    try g.add(&m1);
    m2.setSelected(true);
    try g.add(&m2);

    try std.testing.expect(!m1.isSelected());
    try std.testing.expect(m2.isSelected());
}
