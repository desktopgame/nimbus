//! Bounded range model (Slider state). See `framework/doc/slider.md`.

const std = @import("std");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;

const BoundedRangeModel = @This();

fn fireChange(self: *BoundedRangeModel) void {
    self.change_listeners.fire(&.{ .source = self });
}

min:    i32,
value:  i32,
max:    i32,
extent: i32,
change_listeners: ChangeListenerList,

pub fn init(allocator: std.mem.Allocator, min: i32, value: i32, max: i32) BoundedRangeModel {
    return .{
        .min = min,
        .value = std.math.clamp(value, min, max),
        .max = max,
        .extent = 0,
        .change_listeners = ChangeListenerList.init(allocator),
    };
}

pub fn deinit(self: *BoundedRangeModel) void {
    self.change_listeners.deinit();
}

pub fn getValue(self: *const BoundedRangeModel) i32 {
    return self.value;
}

pub fn setValue(self: *BoundedRangeModel, v: i32) void {
    const upper = self.max - self.extent;
    const clamped = if (v < self.min) self.min else if (v > upper) upper else v;
    if (clamped == self.value) return;
    self.value = clamped;
    self.fireChange();
}

pub fn getMin(self: *const BoundedRangeModel) i32 { return self.min; }
pub fn getMax(self: *const BoundedRangeModel) i32 { return self.max; }
pub fn getExtent(self: *const BoundedRangeModel) i32 { return self.extent; }

pub fn setRange(self: *BoundedRangeModel, min: i32, max: i32) void {
    if (self.min == min and self.max == max) return;
    self.min = min;
    self.max = max;
    if (self.value < min) self.value = min;
    if (self.value + self.extent > max) {
        self.extent = @max(0, max - self.value);
    }
    self.fireChange();
}

pub fn setExtent(self: *BoundedRangeModel, extent: i32) void {
    const e = if (extent < 0) 0 else if (self.value + extent > self.max) self.max - self.value else extent;
    if (e == self.extent) return;
    self.extent = e;
    self.fireChange();
}

/// Atomically update all four properties (min / value / max / extent) with
/// constraints applied once at the end: `min ≤ value`, `value + extent ≤ max`,
/// `extent ≥ 0`. Use this when several of these change together (e.g. a
/// `ScrollPane` re-layout after content size changed) — calling
/// `setRange` / `setValue` / `setExtent` in sequence can leave intermediate
/// invalid states that the individual setters don't recover from (notably:
/// `setRange` does not clamp `value` *down* when `max` shrinks, so a stale
/// large `value` survives and forces `extent` to collapse). Swing's
/// `DefaultBoundedRangeModel.setRangeProperties` plays the same role.
pub fn setRangeProperties(self: *BoundedRangeModel, min: i32, value: i32, max: i32, extent: i32) void {
    const new_min = min;
    const new_max = @max(min, max);
    const new_extent = std.math.clamp(extent, 0, new_max - new_min);
    const new_value = std.math.clamp(value, new_min, new_max - new_extent);
    if (self.min == new_min and self.max == new_max and self.value == new_value and self.extent == new_extent) return;
    self.min = new_min;
    self.max = new_max;
    self.value = new_value;
    self.extent = new_extent;
    self.fireChange();
}

pub fn addChangeListener(
    self: *BoundedRangeModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}

pub fn removeChangeListener(
    self: *BoundedRangeModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

test "setValue clamps and fires" {
    var m = BoundedRangeModel.init(std.testing.allocator, 0, 50, 100);
    defer m.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn cb(self: *@This(), e: *const ChangeEvent) void {
            _ = e;
            self.count += 1;
        }
    };
    var ctx = Ctx{};
    try m.addChangeListener(Ctx, Ctx.cb, &ctx);

    m.setValue(75);
    try std.testing.expectEqual(@as(i32, 75), m.getValue());
    try std.testing.expectEqual(@as(u32, 1), ctx.count);

    m.setValue(75); // no change
    try std.testing.expectEqual(@as(u32, 1), ctx.count);

    m.setValue(200); // clamp to max
    try std.testing.expectEqual(@as(i32, 100), m.getValue());
    try std.testing.expectEqual(@as(u32, 2), ctx.count);
}

test "setRangeProperties clamps stale value when max shrinks" {
    // Regression: ScrollPane re-layout after view content shrinks (user
    // deletes lines that had grown beyond the viewport). The old
    // setExtent(0) + setRange + setExtent sequence left `value` stuck at the
    // pre-shrink position because setRange does not clamp value down.
    var m = BoundedRangeModel.init(std.testing.allocator, 0, 0, 800);
    defer m.deinit();
    m.setExtent(388);
    m.setValue(412); // scrolled to bottom (= max - extent)
    try std.testing.expectEqual(@as(i32, 412), m.getValue());
    try std.testing.expectEqual(@as(i32, 388), m.getExtent());

    // Simulate content shrinking from 800 to 500 while viewport stays 388.
    m.setRangeProperties(0, m.getValue(), 500, 388);
    // value must clamp to new (max - extent) = 112; extent must stay 388.
    try std.testing.expectEqual(@as(i32, 112), m.getValue());
    try std.testing.expectEqual(@as(i32, 388), m.getExtent());
    try std.testing.expectEqual(@as(i32, 500), m.getMax());
}

test "setRangeProperties shrinks extent when range too small for it" {
    var m = BoundedRangeModel.init(std.testing.allocator, 0, 0, 100);
    defer m.deinit();
    m.setRangeProperties(0, 0, 50, 200);
    try std.testing.expectEqual(@as(i32, 50), m.getExtent()); // capped to range
    try std.testing.expectEqual(@as(i32, 0), m.getValue());
}
