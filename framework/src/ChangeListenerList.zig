//! Multi-listener registry used by Models. See `framework/doc/model.md`.

const std = @import("std");

const ChangeListenerList = @This();

/// Semantic event delivered to every listener on `fire`. `source` is the object
/// that fired it (the Model — models are component-independent, so the source is
/// the model, not a widget; mirrors Swing's `ChangeEvent.getSource`). `kind`
/// discriminates change vs action so one handler can tell them apart. Transient:
/// valid only for the duration of the listener call — do not retain the pointer.
/// Distinct from `awt.Event` (raw input); this is a higher-level notification.
pub const Event = struct {
    source: *anyopaque,
    kind: Kind,

    pub const Kind = enum { change, action };
};

pub const ListenerFn = *const fn (user_data: *anyopaque, event: *const Event) void;

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

/// Register a raw listener. Duplicates are NOT checked. Prefer `addTyped`,
/// which removes the `*anyopaque` cast from the callback.
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

/// The one place the `*anyopaque` -> `*T` cast is written (see
/// doc/typed_callbacks). Comptime-builds a thunk adapting a typed callback to
/// the stored `ListenerFn`. The thunk has stable identity per (T, f), so
/// `removeTyped` produces the same function pointer `addTyped` registered.
fn thunk(comptime T: type, comptime f: fn (*T, *const Event) void) ListenerFn {
    return struct {
        fn call(p: *anyopaque, e: *const Event) void {
            f(@ptrCast(@alignCast(p)), e);
        }
    }.call;
}

/// Register a type-safe listener: `f` receives `*T` directly (no cast) plus the
/// event. This is the preferred registration path.
pub fn addTyped(
    self: *ChangeListenerList,
    comptime T: type,
    comptime f: fn (*T, *const Event) void,
    user_data: *T,
) !void {
    try self.add(thunk(T, f), user_data);
}

/// Remove a listener registered via `addTyped` (same `T`, `f`, `user_data`).
pub fn removeTyped(
    self: *ChangeListenerList,
    comptime T: type,
    comptime f: fn (*T, *const Event) void,
    user_data: *T,
) void {
    self.remove(thunk(T, f), user_data);
}

/// Invoke every registered listener in registration order, passing `event`.
/// Listeners added/removed during fire are not reflected in this call.
pub fn fire(self: *ChangeListenerList, event: *const Event) void {
    // Iterate over a snapshot so add/remove during fire is safe (next fire reflects them).
    var i: usize = 0;
    const len = self.items.items.len;
    while (i < len) : (i += 1) {
        const l = self.items.items[i];
        l.fn_ptr(l.user_data, event);
    }
}

test "addTyped / fire / removeTyped" {
    var l = ChangeListenerList.init(std.testing.allocator);
    defer l.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn cb(c: *@This(), e: *const Event) void {
            _ = e;
            c.count += 1;
        }
    };
    var ctx = Ctx{};

    try l.addTyped(Ctx, Ctx.cb, &ctx);
    try l.addTyped(Ctx, Ctx.cb, &ctx); // duplicates allowed
    var ev = Event{ .source = &ctx, .kind = .change };
    l.fire(&ev);
    try std.testing.expectEqual(@as(u32, 2), ctx.count);

    l.removeTyped(Ctx, Ctx.cb, &ctx);
    l.fire(&ev);
    try std.testing.expectEqual(@as(u32, 3), ctx.count);
}
