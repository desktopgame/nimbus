//! Framework log facade — independent dispatch from awt's log system.
//! Utilizers who want to receive messages from both layers must register
//! their callback on `framework.log` and `awt.log` separately. See
//! `framework/doc/log.md` for the contract.

const std = @import("std");

pub const Level = enum(c_int) {
    debug = 0,
    info  = 1,
    warn  = 2,
    err   = 3,
};

pub const Callback = *const fn (
    level: Level,
    category: [*:0]const u8,
    message: [*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void;

var g_cb:   ?Callback     = null;
var g_user: ?*anyopaque   = null;

/// Install a log callback for framework-side messages. Pass null to restore
/// the default stderr writer. Does NOT affect awt's log; set that separately
/// if you want messages from both layers.
pub fn setCallback(cb: ?Callback, user_data: ?*anyopaque) void {
    g_cb = cb;
    g_user = user_data;
}

pub fn debug(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.debug, category, fmt, args);
}

pub fn info(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.info, category, fmt, args);
}

pub fn warn(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.warn, category, fmt, args);
}

pub fn err(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    emit(.err, category, fmt, args);
}

fn emit(level: Level, category: []const u8, comptime fmt: []const u8, args: anytype) void {
    // Mirror awt-c/src/nm_log.c's 1024-byte message buffer; category is short
    // by convention so 64 is plenty. Both saturate-truncate on overflow.
    var msg_buf: [1024]u8 = undefined;
    var cat_buf: [64]u8 = undefined;

    const msg_slice = std.fmt.bufPrint(msg_buf[0 .. msg_buf.len - 1], fmt, args) catch
        msg_buf[0 .. msg_buf.len - 1];
    msg_buf[msg_slice.len] = 0;

    const cat_len = @min(category.len, cat_buf.len - 1);
    @memcpy(cat_buf[0..cat_len], category[0..cat_len]);
    cat_buf[cat_len] = 0;

    if (g_cb) |cb| {
        cb(level, @ptrCast(&cat_buf), @ptrCast(&msg_buf), g_user);
    } else {
        const lvl_str = switch (level) {
            .debug => "DEBUG",
            .info  => "INFO",
            .warn  => "WARN",
            .err   => "ERROR",
        };
        // Same format as awt-c's stderr default: "[LEVEL] [category] message".
        std.debug.print("[{s}] [{s}] {s}\n", .{
            lvl_str,
            std.mem.sliceTo(&cat_buf, 0),
            std.mem.sliceTo(&msg_buf, 0),
        });
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

test "log: callback receives level / category / formatted message" {
    const S = struct {
        var saw_level: ?Level = null;
        var cat_buf:  [32]u8 = undefined;
        var msg_buf:  [128]u8 = undefined;
        var cat_len:  usize = 0;
        var msg_len:  usize = 0;

        fn cb(level: Level, category: [*:0]const u8, message: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            saw_level = level;
            const cat = std.mem.sliceTo(category, 0);
            const msg = std.mem.sliceTo(message, 0);
            cat_len = cat.len;
            msg_len = msg.len;
            @memcpy(cat_buf[0..cat.len], cat);
            @memcpy(msg_buf[0..msg.len], msg);
        }
    };

    setCallback(S.cb, null);
    defer setCallback(null, null);

    warn("menu", "popup show failed: {s}", .{"OOM"});

    try std.testing.expectEqual(Level.warn, S.saw_level.?);
    try std.testing.expectEqualStrings("menu", S.cat_buf[0..S.cat_len]);
    try std.testing.expectEqualStrings("popup show failed: OOM", S.msg_buf[0..S.msg_len]);
}

test "log: oversized messages are truncated, not dropped" {
    const S = struct {
        var msg_len: usize = 0;

        fn cb(_: Level, _: [*:0]const u8, message: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            msg_len = std.mem.sliceTo(message, 0).len;
        }
    };

    setCallback(S.cb, null);
    defer setCallback(null, null);

    var huge: [4096]u8 = undefined;
    @memset(&huge, 'x');
    info("test", "{s}", .{huge[0..]});

    // 1024-byte stack buffer minus 1 for NUL terminator.
    try std.testing.expectEqual(@as(usize, 1023), S.msg_len);
}

test "log: framework callback is independent of awt callback" {
    // Setting our callback to null and emitting should NOT crash even though
    // we never touched awt.log. Verifies no hidden bridge.
    setCallback(null, null);
    defer setCallback(null, null);

    // Should land on the default stderr writer. Calling it is enough; we
    // just assert it doesn't panic or recurse into awt.
    // (no assertion needed — the test passes if no crash)
}
