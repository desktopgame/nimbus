//! Bounded range model (Slider state). See `framework/doc/slider.md`.

const std = @import("std");
const ChangeListenerList = @import("ChangeListenerList.zig");

const BoundedRangeModel = @This();

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
    self.change_listeners.fire();
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
    self.change_listeners.fire();
}

pub fn setExtent(self: *BoundedRangeModel, extent: i32) void {
    const e = if (extent < 0) 0 else if (self.value + extent > self.max) self.max - self.value else extent;
    if (e == self.extent) return;
    self.extent = e;
    self.change_listeners.fire();
}

pub fn addChangeListener(
    self: *BoundedRangeModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) !void {
    try self.change_listeners.add(fn_ptr, user_data);
}

pub fn removeChangeListener(
    self: *BoundedRangeModel,
    fn_ptr: ChangeListenerList.ListenerFn,
    user_data: *anyopaque,
) void {
    self.change_listeners.remove(fn_ptr, user_data);
}

test "setValue clamps and fires" {
    var m = BoundedRangeModel.init(std.testing.allocator, 0, 50, 100);
    defer m.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn cb(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.count += 1;
        }
    };
    var ctx = Ctx{};
    try m.addChangeListener(Ctx.cb, &ctx);

    m.setValue(75);
    try std.testing.expectEqual(@as(i32, 75), m.getValue());
    try std.testing.expectEqual(@as(u32, 1), ctx.count);

    m.setValue(75); // no change
    try std.testing.expectEqual(@as(u32, 1), ctx.count);

    m.setValue(200); // clamp to max
    try std.testing.expectEqual(@as(i32, 100), m.getValue());
    try std.testing.expectEqual(@as(u32, 2), ctx.count);
}
