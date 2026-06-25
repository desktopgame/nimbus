//! IME preedit session state shared by text widgets.
//!
//! This module owns only transport-adjacent state: the current preedit bytes,
//! target clause range, composition-cleared notification, and OS caret
//! forwarding. It intentionally does not know about widgets, edit buffers, or
//! inline painting.

const std = @import("std");
const awt = @import("awt");

const ImeSession = @This();

pub const TargetRange = struct {
    start: usize,
    end: usize,
};

pub const CaretRect = struct {
    x: f32,
    y: f32,
    height: f32,
};

pub const ClearedHook = struct {
    fn_ptr: *const fn (user_data: *anyopaque) void,
    user_data: *anyopaque,

    fn thunk(comptime T: type, comptime f: fn (*T) void) *const fn (*anyopaque) void {
        return struct {
            fn call(p: *anyopaque) void {
                f(@ptrCast(@alignCast(p)));
            }
        }.call;
    }

    pub fn typed(comptime T: type, comptime f: fn (*T) void, user_data: *T) ClearedHook {
        return .{ .fn_ptr = thunk(T, f), .user_data = user_data };
    }

    fn fire(self: ClearedHook) void {
        self.fn_ptr(self.user_data);
    }
};

allocator: std.mem.Allocator,
/// Owned UTF-8 copy of the latest preedit. The backend string is borrowed only
/// for the dispatch callback, so update copies it immediately.
preedit: std.ArrayList(u8),
target_start: usize,
target_end: usize,
on_cleared: ?ClearedHook,

pub fn init(allocator: std.mem.Allocator) ImeSession {
    return .{
        .allocator = allocator,
        .preedit = .empty,
        .target_start = 0,
        .target_end = 0,
        .on_cleared = null,
    };
}

pub fn deinit(self: *ImeSession) void {
    self.preedit.deinit(self.allocator);
}

pub fn setOnCleared(self: *ImeSession, hook: ?ClearedHook) void {
    self.on_cleared = hook;
}

pub fn update(self: *ImeSession, ev: awt.Event.CompositionEvent) !void {
    if (ev.text.len == 0) {
        self.clear();
        return;
    }

    self.preedit.clearRetainingCapacity();
    try self.preedit.appendSlice(self.allocator, ev.text);
    self.target_start = ev.target_start;
    self.target_end = ev.target_end;
}

pub fn clear(self: *ImeSession) void {
    self.preedit.clearRetainingCapacity();
    self.target_start = 0;
    self.target_end = 0;
    if (self.on_cleared) |hook| hook.fire();
}

pub fn isComposing(self: ImeSession) bool {
    return self.preedit.items.len > 0;
}

pub fn preeditSlice(self: ImeSession) []const u8 {
    return self.preedit.items;
}

pub fn targetRange(self: ImeSession) TargetRange {
    return .{ .start = self.target_start, .end = self.target_end };
}

pub fn pushCaret(self: *ImeSession, window: ?*awt.Window, rect: CaretRect) void {
    _ = self;
    const aw = window orelse return;
    aw.setCompositionCursorPos(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.height),
    );
}

test "update owns preedit bytes and preserves target range" {
    var ime = ImeSession.init(std.testing.allocator);
    defer ime.deinit();

    const borrowed = try std.testing.allocator.dupe(u8, "abc");
    defer std.testing.allocator.free(borrowed);

    try ime.update(.{ .text = borrowed, .target_start = 1, .target_end = 3 });
    @memset(borrowed, 'x');

    try std.testing.expect(ime.isComposing());
    try std.testing.expectEqualStrings("abc", ime.preeditSlice());
    try std.testing.expectEqual(TargetRange{ .start = 1, .end = 3 }, ime.targetRange());
}

test "empty update clears and fires hook" {
    var ime = ImeSession.init(std.testing.allocator);
    defer ime.deinit();

    const Ctx = struct {
        count: u32 = 0,
        fn onCleared(self: *@This()) void {
            self.count += 1;
        }
    };
    var ctx = Ctx{};
    ime.setOnCleared(ClearedHook.typed(Ctx, Ctx.onCleared, &ctx));

    try ime.update(.{ .text = "preedit", .target_start = 0, .target_end = 7 });
    try std.testing.expect(ime.isComposing());

    try ime.update(.{ .text = "", .target_start = 9, .target_end = 9 });
    try std.testing.expect(!ime.isComposing());
    try std.testing.expectEqualStrings("", ime.preeditSlice());
    try std.testing.expectEqual(TargetRange{ .start = 0, .end = 0 }, ime.targetRange());
    try std.testing.expectEqual(@as(u32, 1), ctx.count);
}

test "sessions keep independent state" {
    var first = ImeSession.init(std.testing.allocator);
    defer first.deinit();
    var second = ImeSession.init(std.testing.allocator);
    defer second.deinit();

    try first.update(.{ .text = "one", .target_start = 0, .target_end = 3 });
    try second.update(.{ .text = "two", .target_start = 1, .target_end = 2 });
    first.clear();

    try std.testing.expect(!first.isComposing());
    try std.testing.expect(second.isComposing());
    try std.testing.expectEqualStrings("two", second.preeditSlice());
    try std.testing.expectEqual(TargetRange{ .start = 1, .end = 2 }, second.targetRange());
}
