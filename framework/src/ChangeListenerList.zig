//! Multi-listener registry used by Models. See `framework/doc/model.md`.

const std = @import("std");

const ChangeListenerList = @This();

pub const ListenerFn = *const fn (*anyopaque) void;

pub const Listener = struct {
    fn_ptr:    ListenerFn,
    user_data: *anyopaque,
};

items:     std.ArrayList(Listener),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) ChangeListenerList {
    return .{ .items = .empty, .allocator = allocator };
}

pub fn deinit(self: *ChangeListenerList) void {
    self.items.deinit(self.allocator);
}

/// Register a listener. Duplicates are NOT checked.
pub fn add(self: *ChangeListenerList, fn_ptr: ListenerFn, user_data: *anyopaque) !void {
    try self.items.append(self.allocator, .{ .fn_ptr = fn_ptr, .user_data = user_data });
}

/// Remove the first listener that matches both `fn_ptr` and `user_data`.
/// No-op if not found.
pub fn remove(self: *ChangeListenerList, fn_ptr: ListenerFn, user_data: *anyopaque) void {
    var i: usize = 0;
    while (i < self.items.items.len) : (i += 1) {
        const l = self.items.items[i];
        if (l.fn_ptr == fn_ptr and l.user_data == user_data) {
            _ = self.items.orderedRemove(i);
            return;
        }
    }
}

/// Invoke every registered listener in registration order.
/// Listeners added/removed during fire are not reflected in this call.
pub fn fire(self: *ChangeListenerList) void {
    // Iterate over a snapshot so add/remove during fire is safe (next fire reflects them).
    var i: usize = 0;
    const len = self.items.items.len;
    while (i < len) : (i += 1) {
        const l = self.items.items[i];
        l.fn_ptr(l.user_data);
    }
}

test "add / fire / remove" {
    var l = ChangeListenerList.init(std.testing.allocator);
    defer l.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn cb(p: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.count += 1;
        }
    };
    var ctx = Ctx{};

    try l.add(Ctx.cb, &ctx);
    try l.add(Ctx.cb, &ctx);  // duplicates allowed
    l.fire();
    try std.testing.expectEqual(@as(u32, 2), ctx.count);

    l.remove(Ctx.cb, &ctx);
    l.fire();
    try std.testing.expectEqual(@as(u32, 3), ctx.count);
}
