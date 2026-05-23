//! Nested event loop primitive. See `awt/doc/secondary_loop.md`.
//!
//! `exec()` blocks running the event loop until `exit(code)` is called from
//! somewhere (typically an event handler). Useful for modal dialogs and
//! "block this thread but keep events flowing" use cases.

const std = @import("std");
const awt_root = @import("root.zig");
const c = @import("c");

const SecondaryLoop = @This();

pub const TickFn = *const fn (*anyopaque) void;

tick:           ?TickFn,
tick_user_data: ?*anyopaque,
exit_requested: bool,
exit_code:      i32,

pub fn init(tick: ?TickFn, tick_user_data: ?*anyopaque) SecondaryLoop {
    return .{
        .tick           = tick,
        .tick_user_data = tick_user_data,
        .exit_requested = false,
        .exit_code      = 0,
    };
}

/// Block running events until `exit(code)` is called. Returns the exit code.
pub fn exec(self: *SecondaryLoop) i32 {
    self.exit_requested = false;
    while (!self.exit_requested) {
        c.nmWaitEvents();
        if (self.tick) |t| t(self.tick_user_data.?);
    }
    return self.exit_code;
}

/// Request the loop to exit at the next iteration. Safe from any thread —
/// wakes the UI thread if it is blocked in `waitEvents`.
pub fn exit(self: *SecondaryLoop, code: i32) void {
    self.exit_code = code;
    self.exit_requested = true;
    awt_root.postEmptyEvent();
}
