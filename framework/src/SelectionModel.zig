//! Multi-selection state shared by List and Table.
//! See framework/doc/selection_model.md.
//!
//! The widget translates input gestures into selectOnly / toggle / extendTo and
//! this model enforces the mode: in `.single` mode every mutation collapses to a
//! single row. Mutations return whether anything changed so the widget can fire
//! its ChangeEvent and repaint only when needed.
const std = @import("std");

const SelectionModel = @This();
const Allocator = std.mem.Allocator;

pub const Mode = enum { single, multiple };

mode: Mode,
/// Selected row indices, kept sorted ascending and unique.
items: std.ArrayList(usize),
/// Origin of a range gesture (shift). null when there is no selection.
anchor: ?usize,
/// Current row (focus / keyboard target). null when there is no selection.
lead: ?usize,
allocator: Allocator,

pub fn init(allocator: Allocator) SelectionModel {
    return .{ .mode = .single, .items = .empty, .anchor = null, .lead = null, .allocator = allocator };
}

pub fn deinit(self: *SelectionModel) void {
    self.items.deinit(self.allocator);
}

// ── queries ────────────────────────────────────────────────────────────────

pub fn isSelected(self: SelectionModel, i: usize) bool {
    return std.mem.indexOfScalar(usize, self.items.items, i) != null;
}

pub fn count(self: SelectionModel) usize {
    return self.items.items.len;
}

/// Borrowed view of the selected indices (sorted ascending). Valid until the
/// next mutation.
pub fn indices(self: SelectionModel) []const usize {
    return self.items.items;
}

pub fn getLead(self: SelectionModel) ?usize {
    return self.lead;
}

pub fn getAnchor(self: SelectionModel) ?usize {
    return self.anchor;
}

// ── mutations (return whether anything changed) ──────────────────────────────

pub fn clear(self: *SelectionModel) bool {
    if (self.items.items.len == 0 and self.anchor == null and self.lead == null) return false;
    self.items.clearRetainingCapacity();
    self.anchor = null;
    self.lead = null;
    return true;
}

/// Plain click / arrow move: select exactly `i` (clearing the rest). null clears
/// the whole selection.
pub fn selectOnly(self: *SelectionModel, i: ?usize) Allocator.Error!bool {
    const t = i orelse return self.clear();
    if (self.items.items.len == 1 and self.items.items[0] == t and self.lead == t and self.anchor == t)
        return false;
    self.items.clearRetainingCapacity();
    try self.items.append(self.allocator, t);
    self.anchor = t;
    self.lead = t;
    return true;
}

/// Ctrl+click: flip membership of `i`. In `.single` mode behaves like selectOnly.
pub fn toggle(self: *SelectionModel, i: usize) Allocator.Error!bool {
    if (self.mode == .single) return self.selectOnly(i);
    if (std.mem.indexOfScalar(usize, self.items.items, i)) |pos| {
        _ = self.items.orderedRemove(pos);
    } else {
        try self.insertSorted(i);
    }
    self.anchor = i;
    self.lead = i;
    return true;
}

/// Shift+click / shift+arrow: select the contiguous range between the anchor and
/// `i`, replacing the current selection. The anchor stays; the lead becomes `i`.
/// Without an anchor (or in `.single` mode) behaves like selectOnly.
pub fn extendTo(self: *SelectionModel, i: usize) Allocator.Error!bool {
    if (self.mode == .single or self.anchor == null) return self.selectOnly(i);
    const a = self.anchor.?;
    const lo = @min(a, i);
    const hi = @max(a, i);
    self.items.clearRetainingCapacity();
    var r = lo;
    while (r <= hi) : (r += 1) try self.items.append(self.allocator, r);
    self.lead = i;
    return true;
}

/// Switch mode. Switching to `.single` collapses an existing multi-selection to
/// the lead row (or the first selected row).
pub fn setMode(self: *SelectionModel, mode: Mode) Allocator.Error!bool {
    if (self.mode == mode) return false;
    self.mode = mode;
    if (mode == .single and self.items.items.len > 1) {
        const keep = self.lead orelse self.items.items[0];
        _ = try self.selectOnly(keep);
        return true;
    }
    return false;
}

/// Drop indices that are out of range after the data model shrank, and clamp
/// lead / anchor. v1 does not shift indices on insert / remove — out-of-range
/// entries are simply dropped (matching the previous single-selection behavior).
pub fn clampToSize(self: *SelectionModel, size: usize) bool {
    var changed = false;
    var w: usize = 0;
    for (self.items.items) |v| {
        if (v < size) {
            self.items.items[w] = v;
            w += 1;
        } else {
            changed = true;
        }
    }
    self.items.shrinkRetainingCapacity(w);
    if (self.lead) |l| if (l >= size) {
        self.lead = if (self.items.items.len > 0) self.items.items[self.items.items.len - 1] else null;
        changed = true;
    };
    if (self.anchor) |a| if (a >= size) {
        self.anchor = self.lead;
        changed = true;
    };
    return changed;
}

fn insertSorted(self: *SelectionModel, i: usize) Allocator.Error!void {
    var idx: usize = 0;
    while (idx < self.items.items.len and self.items.items[idx] < i) idx += 1;
    try self.items.insert(self.allocator, idx, i);
}

// ── tests ────────────────────────────────────────────────────────────────────

test "selectOnly replaces the selection" {
    var s = SelectionModel.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(try s.selectOnly(2));
    try std.testing.expectEqualSlices(usize, &.{2}, s.indices());
    try std.testing.expectEqual(@as(?usize, 2), s.getLead());
    try std.testing.expect(try s.selectOnly(5));
    try std.testing.expectEqualSlices(usize, &.{5}, s.indices());
    try std.testing.expect(!(try s.selectOnly(5))); // unchanged
    try std.testing.expect(try s.selectOnly(null)); // clears
    try std.testing.expectEqual(@as(usize, 0), s.count());
}

test "toggle adds and removes in multiple mode" {
    var s = SelectionModel.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.setMode(.multiple);
    _ = try s.selectOnly(1);
    _ = try s.toggle(5);
    _ = try s.toggle(3);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 5 }, s.indices()); // kept sorted
    _ = try s.toggle(3);
    try std.testing.expectEqualSlices(usize, &.{ 1, 5 }, s.indices());
}

test "toggle collapses to one in single mode" {
    var s = SelectionModel.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.selectOnly(1);
    _ = try s.toggle(3); // single mode: behaves like selectOnly
    try std.testing.expectEqualSlices(usize, &.{3}, s.indices());
}

test "extendTo selects the inclusive range from the anchor" {
    var s = SelectionModel.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.setMode(.multiple);
    _ = try s.selectOnly(2); // anchor = 2
    _ = try s.extendTo(5);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 4, 5 }, s.indices());
    _ = try s.extendTo(0); // anchor still 2
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, s.indices());
}

test "setMode to single collapses to the lead" {
    var s = SelectionModel.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.setMode(.multiple);
    _ = try s.selectOnly(1);
    _ = try s.toggle(4);
    try std.testing.expectEqual(@as(usize, 2), s.count());
    _ = try s.setMode(.single);
    try std.testing.expectEqualSlices(usize, &.{4}, s.indices()); // lead kept
}

test "clampToSize drops out-of-range indices" {
    var s = SelectionModel.init(std.testing.allocator);
    defer s.deinit();
    _ = try s.setMode(.multiple);
    _ = try s.selectOnly(1);
    _ = try s.toggle(4);
    _ = try s.toggle(7);
    try std.testing.expect(s.clampToSize(5)); // 7 is dropped
    try std.testing.expectEqualSlices(usize, &.{ 1, 4 }, s.indices());
    try std.testing.expect(!s.clampToSize(5)); // already in range
}
