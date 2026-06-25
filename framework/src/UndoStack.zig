const std = @import("std");
const listener = @import("listener.zig");

const UndoStack = @This();

pub const Command = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        redo: *const fn (ctx: *anyopaque) anyerror!void,
        undo: *const fn (ctx: *anyopaque) anyerror!void,
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        tryMerge: ?*const fn (ctx: *anyopaque, next: Command) bool = null,
        displayName: ?*const fn (ctx: *anyopaque) []const u8 = null,
    };

    pub fn redo(self: Command) anyerror!void {
        try self.vtable.redo(self.ctx);
    }

    pub fn undo(self: Command) anyerror!void {
        try self.vtable.undo(self.ctx);
    }

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ctx, allocator);
    }

    pub fn tryMerge(self: Command, next: Command) bool {
        const f = self.vtable.tryMerge orelse return false;
        return f(self.ctx, next);
    }

    pub fn displayName(self: Command) ?[]const u8 {
        const f = self.vtable.displayName orelse return null;
        return f(self.ctx);
    }
};

pub const default_limit: usize = 200;

list: std.ArrayList(Command),
index: usize,
limit: usize,
allocator: std.mem.Allocator,
change_listeners: listener.ChangeListenerList,

pub fn init(allocator: std.mem.Allocator) UndoStack {
    return initWithLimit(allocator, default_limit);
}

pub fn initWithLimit(allocator: std.mem.Allocator, limit: usize) UndoStack {
    return .{
        .list = .empty,
        .index = 0,
        .limit = limit,
        .allocator = allocator,
        .change_listeners = listener.ChangeListenerList.init(allocator),
    };
}

pub fn deinit(self: *UndoStack) void {
    self.clear();
    self.list.deinit(self.allocator);
    self.change_listeners.deinit();
    self.* = undefined;
}

pub fn canUndo(self: UndoStack) bool {
    return self.index > 0;
}

pub fn canRedo(self: UndoStack) bool {
    return self.index < self.list.items.len;
}

pub fn addCanChangeListener(
    self: *UndoStack,
    comptime T: type,
    comptime f: fn (*T, *const listener.ChangeEvent) void,
    user_data: *T,
) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}

pub fn removeCanChangeListener(
    self: *UndoStack,
    comptime T: type,
    comptime f: fn (*T, *const listener.ChangeEvent) void,
    user_data: *T,
) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

pub fn push(self: *UndoStack, cmd: Command) !void {
    errdefer cmd.deinit(self.allocator);
    try self.list.ensureUnusedCapacity(self.allocator, 1);

    const before = self.canState();

    while (self.list.items.len > self.index) {
        const dropped = self.list.orderedRemove(self.index);
        dropped.deinit(self.allocator);
    }

    if (self.index > 0 and self.list.items[self.index - 1].tryMerge(cmd)) {
        cmd.deinit(self.allocator);
        self.fireIfChanged(before);
        return;
    }

    try self.list.append(self.allocator, cmd);
    self.index += 1;

    while (self.list.items.len > self.limit) {
        const dropped = self.list.orderedRemove(0);
        dropped.deinit(self.allocator);
        if (self.index > 0) self.index -= 1;
    }

    self.fireIfChanged(before);
}

pub fn undo(self: *UndoStack) !void {
    if (!self.canUndo()) return;
    const before = self.canState();

    self.index -= 1;
    errdefer self.index += 1;
    try self.list.items[self.index].undo();

    self.fireIfChanged(before);
}

pub fn redo(self: *UndoStack) !void {
    if (!self.canRedo()) return;
    const before = self.canState();

    // Keep index unchanged if redo fails.
    try self.list.items[self.index].redo();
    self.index += 1;

    self.fireIfChanged(before);
}

pub fn clear(self: *UndoStack) void {
    const before = self.canState();

    for (self.list.items) |cmd| {
        cmd.deinit(self.allocator);
    }
    self.list.clearRetainingCapacity();
    self.index = 0;

    self.fireIfChanged(before);
}

const CanState = struct {
    undo: bool,
    redo: bool,
};

fn canState(self: UndoStack) CanState {
    return .{ .undo = self.canUndo(), .redo = self.canRedo() };
}

fn fireIfChanged(self: *UndoStack, before: CanState) void {
    const after = self.canState();
    if (before.undo == after.undo and before.redo == after.redo) return;
    var event = listener.ChangeEvent{ .source = self };
    self.change_listeners.fire(&event);
}

const testing = std.testing;

const TestCommandCtx = struct {
    value: *i32,
    delta: i32 = 1,
    deinit_count: *usize,
    merge: bool = false,
    merged_count: *usize,

    fn make(
        allocator: std.mem.Allocator,
        value: *i32,
        deinit_count: *usize,
        merged_count: *usize,
        merge: bool,
    ) !Command {
        const ctx = try allocator.create(TestCommandCtx);
        ctx.* = .{
            .value = value,
            .deinit_count = deinit_count,
            .merge = merge,
            .merged_count = merged_count,
        };
        return .{ .vtable = &vtable, .ctx = ctx };
    }

    fn from(ctx: *anyopaque) *TestCommandCtx {
        return @ptrCast(@alignCast(ctx));
    }

    fn redoCommand(ctx: *anyopaque) anyerror!void {
        const self = from(ctx);
        self.value.* += self.delta;
    }

    fn undoCommand(ctx: *anyopaque) anyerror!void {
        const self = from(ctx);
        self.value.* -= self.delta;
    }

    fn deinitCommand(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self = from(ctx);
        self.deinit_count.* += 1;
        allocator.destroy(self);
    }

    fn tryMergeCommand(ctx: *anyopaque, next: Command) bool {
        const self = from(ctx);
        const other = from(next.ctx);
        if (!self.merge or !other.merge) return false;
        self.delta += other.delta;
        self.merged_count.* += 1;
        return true;
    }

    const vtable = Command.VTable{
        .redo = redoCommand,
        .undo = undoCommand,
        .deinit = deinitCommand,
        .tryMerge = tryMergeCommand,
    };
};

fn makeTestCommand(
    value: *i32,
    deinit_count: *usize,
    merged_count: *usize,
    merge: bool,
) !Command {
    return TestCommandCtx.make(testing.allocator, value, deinit_count, merged_count, merge);
}

const FailingUndoCommandCtx = struct {
    deinit_count: *usize,

    fn make(allocator: std.mem.Allocator, deinit_count: *usize) !Command {
        const ctx = try allocator.create(FailingUndoCommandCtx);
        ctx.* = .{ .deinit_count = deinit_count };
        return .{ .vtable = &vtable, .ctx = ctx };
    }

    fn from(ctx: *anyopaque) *FailingUndoCommandCtx {
        return @ptrCast(@alignCast(ctx));
    }

    fn redoCommand(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn undoCommand(ctx: *anyopaque) anyerror!void {
        _ = ctx;
        return error.OutOfMemory;
    }

    fn deinitCommand(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self = from(ctx);
        self.deinit_count.* += 1;
        allocator.destroy(self);
    }

    const vtable = Command.VTable{
        .redo = redoCommand,
        .undo = undoCommand,
        .deinit = deinitCommand,
    };
};

fn makeFailingUndoCommand(deinit_count: *usize) !Command {
    return FailingUndoCommandCtx.make(testing.allocator, deinit_count);
}

test "push undo redo order" {
    var stack = UndoStack.init(testing.allocator);
    defer stack.deinit();
    var value: i32 = 0;
    var deinits: usize = 0;
    var merges: usize = 0;

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try testing.expectEqual(@as(i32, 2), value);

    try stack.undo();
    try testing.expectEqual(@as(i32, 1), value);
    try stack.undo();
    try testing.expectEqual(@as(i32, 0), value);
    try stack.redo();
    try testing.expectEqual(@as(i32, 1), value);
    try stack.redo();
    try testing.expectEqual(@as(i32, 2), value);
}

test "undo error restores index and does not fire listener" {
    var stack = UndoStack.init(testing.allocator);
    defer stack.deinit();
    var deinits: usize = 0;

    const ListenerCtx = struct {
        count: usize = 0,

        fn cb(self: *@This(), event: *const listener.ChangeEvent) void {
            _ = event;
            self.count += 1;
        }
    };
    var ctx = ListenerCtx{};
    try stack.addCanChangeListener(ListenerCtx, ListenerCtx.cb, &ctx);

    try stack.push(try makeFailingUndoCommand(&deinits));
    try testing.expectEqual(@as(usize, 1), ctx.count);

    const before_index = stack.index;
    try testing.expectError(error.OutOfMemory, stack.undo());
    try testing.expectEqual(before_index, stack.index);
    try testing.expect(stack.canUndo());
    try testing.expect(!stack.canRedo());
    try testing.expectEqual(@as(usize, 1), ctx.count);
}

test "push truncates redo tail and drops tail commands once" {
    var stack = UndoStack.init(testing.allocator);
    defer stack.deinit();
    var value: i32 = 0;
    var deinits: usize = 0;
    var merges: usize = 0;

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try stack.undo();
    try testing.expect(stack.canRedo());

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try testing.expect(!stack.canRedo());
    try testing.expectEqual(@as(usize, 1), deinits);
    try testing.expectEqual(@as(usize, 2), stack.list.items.len);
}

test "can undo redo transitions" {
    var stack = UndoStack.init(testing.allocator);
    defer stack.deinit();
    var value: i32 = 0;
    var deinits: usize = 0;
    var merges: usize = 0;

    try testing.expect(!stack.canUndo());
    try testing.expect(!stack.canRedo());
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try testing.expect(stack.canUndo());
    try testing.expect(!stack.canRedo());
    try stack.undo();
    try testing.expect(!stack.canUndo());
    try testing.expect(stack.canRedo());
    try stack.redo();
    try testing.expect(stack.canUndo());
    try testing.expect(!stack.canRedo());
}

test "can change listener fires only on state transitions" {
    var stack = UndoStack.init(testing.allocator);
    defer stack.deinit();
    var value: i32 = 0;
    var deinits: usize = 0;
    var merges: usize = 0;

    const ListenerCtx = struct {
        count: usize = 0,
        sources_match: usize = 0,
        expected_source: *UndoStack,

        fn cb(self: *@This(), event: *const listener.ChangeEvent) void {
            self.count += 1;
            if (event.source == @as(*anyopaque, @ptrCast(self.expected_source))) self.sources_match += 1;
        }
    };
    var ctx = ListenerCtx{ .expected_source = &stack };
    try stack.addCanChangeListener(ListenerCtx, ListenerCtx.cb, &ctx);

    try stack.undo();
    try stack.redo();
    try testing.expectEqual(@as(usize, 0), ctx.count);

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try testing.expectEqual(@as(usize, 1), ctx.count);

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try testing.expectEqual(@as(usize, 1), ctx.count);

    try stack.undo();
    try testing.expectEqual(@as(usize, 2), ctx.count);

    try stack.undo();
    try testing.expectEqual(@as(usize, 3), ctx.count);

    try stack.redo();
    try testing.expectEqual(@as(usize, 4), ctx.count);

    stack.clear();
    try testing.expectEqual(@as(usize, 5), ctx.count);
    try testing.expectEqual(ctx.count, ctx.sources_match);
}

test "bounded eviction drops oldest commands and adjusts index" {
    var stack = UndoStack.initWithLimit(testing.allocator, 2);
    defer stack.deinit();
    var value: i32 = 0;
    var deinits: usize = 0;
    var merges: usize = 0;

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));

    try testing.expectEqual(@as(usize, 2), stack.list.items.len);
    try testing.expectEqual(@as(usize, 2), stack.index);
    try testing.expectEqual(@as(usize, 1), deinits);

    try stack.undo();
    try stack.undo();
    try testing.expectEqual(@as(i32, 1), value);
    try testing.expect(!stack.canUndo());
    try testing.expect(stack.canRedo());
}

test "tryMerge folds true commands and keeps false commands separate" {
    var stack = UndoStack.init(testing.allocator);
    defer stack.deinit();
    var value: i32 = 0;
    var deinits: usize = 0;
    var merges: usize = 0;

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, true));
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, true));
    try testing.expectEqual(@as(usize, 1), stack.list.items.len);
    try testing.expectEqual(@as(usize, 1), stack.index);
    try testing.expectEqual(@as(usize, 1), merges);
    try testing.expectEqual(@as(usize, 1), deinits);

    try stack.undo();
    try testing.expectEqual(@as(i32, 0), value);
    try stack.redo();
    try testing.expectEqual(@as(i32, 2), value);

    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    value += 1;
    try stack.push(try makeTestCommand(&value, &deinits, &merges, false));
    try testing.expectEqual(@as(usize, 3), stack.list.items.len);
    try testing.expectEqual(@as(usize, 3), stack.index);
}
