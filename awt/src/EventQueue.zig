//! Cross-thread task queue for posting work to the UI thread.
//! See `awt/doc/event_queue.md`.

const std = @import("std");
const awt_root = @import("root.zig");

const EventQueue = @This();

pub const TaskFn = *const fn (*anyopaque) void;

const Task = struct {
    fn_ptr:    TaskFn,
    user_data: *anyopaque,
    /// For invokeAndWait, the poster waits on `done` after appending.
    /// `null` means fire-and-forget.
    done: ?*Sync = null,
};

const Sync = struct {
    mutex:    std.Io.Mutex = .init,
    cond:     std.Io.Condition = .init,
    finished: bool = false,
};

allocator: std.mem.Allocator,
io:        std.Io,
mutex:     std.Io.Mutex,
queue:     std.ArrayList(Task),
ui_thread: ?std.Thread.Id,

/// Allocate and initialize a new EventQueue. Caller owns the returned pointer.
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*EventQueue {
    const q = try allocator.create(EventQueue);
    errdefer allocator.destroy(q);
    q.* = .{
        .allocator = allocator,
        .io        = io,
        .mutex     = .init,
        .queue     = .empty,
        .ui_thread = null,
    };
    return q;
}

pub fn deinit(self: *EventQueue) void {
    self.queue.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn setUiThread(self: *EventQueue, tid: std.Thread.Id) void {
    self.ui_thread = tid;
}

/// Post a task to be executed on the UI thread. Returns immediately.
/// Safe to call from any thread.
pub fn invokeLater(self: *EventQueue, fn_ptr: TaskFn, user_data: *anyopaque) !void {
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.queue.append(self.allocator, .{
            .fn_ptr = fn_ptr,
            .user_data = user_data,
            .done = null,
        });
    }
    awt_root.postEmptyEvent();
}

/// Post a task and block until the UI thread runs it. Must NOT be called
/// from the UI thread (would deadlock — debug asserts).
pub fn invokeAndWait(self: *EventQueue, fn_ptr: TaskFn, user_data: *anyopaque) !void {
    if (self.ui_thread) |tid| {
        if (std.Thread.getCurrentId() == tid) {
            std.debug.assert(false); // invokeAndWait called from UI thread (would deadlock)
            return;
        }
    }

    var sync = Sync{};

    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.queue.append(self.allocator, .{
            .fn_ptr = fn_ptr,
            .user_data = user_data,
            .done = &sync,
        });
    }
    awt_root.postEmptyEvent();

    sync.mutex.lockUncancelable(self.io);
    defer sync.mutex.unlock(self.io);
    while (!sync.finished) sync.cond.waitUncancelable(self.io, &sync.mutex);
}

/// Execute every task that was queued at the time of this call.
/// Tasks queued during drain are NOT picked up — they wait for the next drain.
/// Must be called from the UI thread.
pub fn drain(self: *EventQueue) void {
    var local: std.ArrayList(Task) = .empty;
    defer local.deinit(self.allocator);

    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.mem.swap(std.ArrayList(Task), &self.queue, &local);
    }

    for (local.items) |task| {
        task.fn_ptr(task.user_data);
        if (task.done) |s| {
            s.mutex.lockUncancelable(self.io);
            defer s.mutex.unlock(self.io);
            s.finished = true;
            s.cond.signal(self.io);
        }
    }
}

test "invokeLater enqueues and drains" {
    var q = try EventQueue.init(std.testing.allocator, std.testing.io);
    defer q.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn cb(user_data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(user_data));
            self.count += 1;
        }
    };
    var ctx = Ctx{};

    try q.invokeLater(Ctx.cb, &ctx);
    try q.invokeLater(Ctx.cb, &ctx);
    try q.invokeLater(Ctx.cb, &ctx);

    q.drain();
    try std.testing.expectEqual(@as(u32, 3), ctx.count);

    q.drain();
    try std.testing.expectEqual(@as(u32, 3), ctx.count);
}
