//! Cross-thread task queue for posting work to the UI thread.
//! See `awt/doc/event_queue.md`.
//!
//! Two ways to post:
//! * `invokeLater(fn, data)` — fire-and-forget, returns immediately
//! * `invokeAndWait(fn, data)` — blocks until the UI thread runs the task
//!
//! The UI thread drains the queue via `drain()` inside its event loop.
//! `glfwPostEmptyEvent` (via `awt.postEmptyEvent`) wakes the UI thread if it
//! is blocked in `waitEvents`.

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
    mutex:    std.Thread.Mutex = .{},
    cond:     std.Thread.Condition = .{},
    finished: bool = false,
};

allocator: std.mem.Allocator,
mutex:     std.Thread.Mutex,
queue:     std.ArrayList(Task),
ui_thread: ?std.Thread.Id,

/// Allocate and initialize a new EventQueue.
/// Returned pointer is owned by the caller; free with `deinit`.
pub fn init(allocator: std.mem.Allocator) !*EventQueue {
    const q = try allocator.create(EventQueue);
    errdefer allocator.destroy(q);
    q.* = .{
        .allocator = allocator,
        .mutex     = .{},
        .queue     = .empty,
        .ui_thread = null,
    };
    return q;
}

pub fn deinit(self: *EventQueue) void {
    self.queue.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// Record which thread is the UI thread. Called by Application before `run`.
/// Used to validate invokeAndWait callers.
pub fn setUiThread(self: *EventQueue, tid: std.Thread.Id) void {
    self.ui_thread = tid;
}

/// Post a task to be executed on the UI thread. Returns immediately.
/// Safe to call from any thread.
pub fn invokeLater(self: *EventQueue, fn_ptr: TaskFn, user_data: *anyopaque) !void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(self.allocator, .{
            .fn_ptr = fn_ptr,
            .user_data = user_data,
            .done = null,
        });
    }
    awt_root.postEmptyEvent();
}

/// Post a task and block until the UI thread runs it. Must NOT be called from
/// the UI thread (would deadlock — debug asserts).
pub fn invokeAndWait(self: *EventQueue, fn_ptr: TaskFn, user_data: *anyopaque) !void {
    if (self.ui_thread) |tid| {
        if (std.Thread.getCurrentId() == tid) {
            std.debug.assert(false); // invokeAndWait called from UI thread (would deadlock)
            return;
        }
    }

    var sync = Sync{};

    {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(self.allocator, .{
            .fn_ptr = fn_ptr,
            .user_data = user_data,
            .done = &sync,
        });
    }
    awt_root.postEmptyEvent();

    sync.mutex.lock();
    defer sync.mutex.unlock();
    while (!sync.finished) sync.cond.wait(&sync.mutex);
}

/// Execute every task that was queued at the time of this call.
/// Tasks queued during drain are NOT picked up — they wait for the next drain.
/// Must be called from the UI thread.
pub fn drain(self: *EventQueue) void {
    // Snapshot the queue under lock, then run tasks unlocked so that
    // invokeLater called from within a task doesn't deadlock on the mutex.
    var local: std.ArrayList(Task) = .empty;
    defer local.deinit(self.allocator);

    {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.mem.swap(std.ArrayList(Task), &self.queue, &local);
    }

    for (local.items) |task| {
        task.fn_ptr(task.user_data);
        if (task.done) |s| {
            s.mutex.lock();
            defer s.mutex.unlock();
            s.finished = true;
            s.cond.signal();
        }
    }
}

test "invokeLater enqueues and drains" {
    var q = try EventQueue.init(std.testing.allocator);
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

    // Re-draining with no new tasks is a no-op.
    q.drain();
    try std.testing.expectEqual(@as(u32, 3), ctx.count);
}

test "invokeAndWait blocks until drained" {
    var q = try EventQueue.init(std.testing.allocator);
    defer q.deinit();

    // Pretend the test thread is the UI thread so the worker thread is "other".
    const main_tid = std.Thread.getCurrentId();
    q.setUiThread(main_tid);

    const Ctx = struct {
        ran: bool = false,
        fn cb(user_data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(user_data));
            self.ran = true;
        }
    };
    var ctx = Ctx{};

    const Worker = struct {
        fn run(qq: *EventQueue, cc: *Ctx) !void {
            try qq.invokeAndWait(Ctx.cb, cc);
        }
    };

    var t = try std.Thread.spawn(.{}, Worker.run, .{ q, &ctx });
    // Give the worker time to post and start waiting.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(!ctx.ran);

    q.drain();
    t.join();
    try std.testing.expect(ctx.ran);
}
