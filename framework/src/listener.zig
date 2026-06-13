//! Multi-listener registries used by Models. See `framework/doc/model.md`.
//!
//! Two semantic event types cross to listeners: `ChangeEvent` (a Model's state
//! changed) and `ActionEvent` (a discrete action happened — button click, field
//! submit / cancel). They are distinct types so a handler's signature states
//! which it expects (Swing's `ChangeEvent` / `ActionEvent` split). The matching
//! registries are `ChangeListenerList` / `ActionListenerList`.
//!
//! Both events carry only `source`: the object that fired it (the Model — models
//! are component-independent, so the source is the model, not a widget; mirrors
//! Swing's `EventObject.getSource`). The event pointer is transient: valid only
//! for the duration of the listener call — do not retain it. Distinct from
//! `awt.Event` (raw input); these are higher-level notifications.

const std = @import("std");

/// Delivered when a Model's state changes (Swing `ChangeEvent`).
pub const ChangeEvent = struct { source: *anyopaque };

/// Delivered on a discrete action (Swing `ActionEvent`).
pub const ActionEvent = struct { source: *anyopaque };

/// Returns a multi-listener registry that delivers `*const E` to each listener.
pub fn ListenerList(comptime E: type) type {
    return struct {
        const Self = @This();

        /// The event type this list delivers (`ChangeEvent` or `ActionEvent`).
        pub const Event = E;
        pub const ListenerFn = *const fn (user_data: *anyopaque, event: *const E) void;

        pub const Listener = struct {
            fn_ptr: ListenerFn,
            user_data: *anyopaque,
        };

        items: std.ArrayList(Listener),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .items = .empty, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Register a raw listener. Duplicates are NOT checked. Prefer `addTyped`,
        /// which removes the `*anyopaque` cast from the callback.
        pub fn add(self: *Self, fn_ptr: ListenerFn, user_data: *anyopaque) !void {
            try self.items.append(self.allocator, .{ .fn_ptr = fn_ptr, .user_data = user_data });
        }

        /// Remove the first listener that matches both `fn_ptr` and `user_data`.
        /// No-op if not found.
        pub fn remove(self: *Self, fn_ptr: ListenerFn, user_data: *anyopaque) void {
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
        /// doc/internal/typed_callbacks). Comptime-builds a thunk adapting a typed callback
        /// to the stored `ListenerFn`. The thunk has stable identity per (T, f), so
        /// `removeTyped` produces the same function pointer `addTyped` registered.
        fn thunk(comptime T: type, comptime f: fn (*T, *const E) void) ListenerFn {
            return struct {
                fn call(p: *anyopaque, e: *const E) void {
                    f(@ptrCast(@alignCast(p)), e);
                }
            }.call;
        }

        /// Register a type-safe listener: `f` receives `*T` directly (no cast) plus
        /// the event. This is the preferred registration path.
        pub fn addTyped(
            self: *Self,
            comptime T: type,
            comptime f: fn (*T, *const E) void,
            user_data: *T,
        ) !void {
            try self.add(thunk(T, f), user_data);
        }

        /// Remove a listener registered via `addTyped` (same `T`, `f`, `user_data`).
        pub fn removeTyped(
            self: *Self,
            comptime T: type,
            comptime f: fn (*T, *const E) void,
            user_data: *T,
        ) void {
            self.remove(thunk(T, f), user_data);
        }

        /// Invoke every registered listener in registration order, passing `event`.
        /// Listeners added/removed during fire are not reflected in this call.
        pub fn fire(self: *Self, event: *const E) void {
            // Iterate over a snapshot so add/remove during fire is safe (next fire reflects them).
            var i: usize = 0;
            const len = self.items.items.len;
            while (i < len) : (i += 1) {
                const l = self.items.items[i];
                l.fn_ptr(l.user_data, event);
            }
        }
    };
}

/// Registry for `ChangeEvent` listeners.
pub const ChangeListenerList = ListenerList(ChangeEvent);

/// Registry for `ActionEvent` listeners.
pub const ActionListenerList = ListenerList(ActionEvent);

test "addTyped / fire / removeTyped" {
    var l = ChangeListenerList.init(std.testing.allocator);
    defer l.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn cb(c: *@This(), e: *const ChangeEvent) void {
            _ = e;
            c.count += 1;
        }
    };
    var ctx = Ctx{};

    try l.addTyped(Ctx, Ctx.cb, &ctx);
    try l.addTyped(Ctx, Ctx.cb, &ctx); // duplicates allowed
    var ev = ChangeEvent{ .source = &ctx };
    l.fire(&ev);
    try std.testing.expectEqual(@as(u32, 2), ctx.count);

    l.removeTyped(Ctx, Ctx.cb, &ctx);
    l.fire(&ev);
    try std.testing.expectEqual(@as(u32, 3), ctx.count);
}
