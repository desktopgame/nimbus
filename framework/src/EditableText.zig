//! Plain editable text core shared by text widgets.
//!
//! This module owns only logical text state: bytes, caret/selection, and
//! undo/redo. Widgets keep rendering, clipboard I/O, IME painting, and visual
//! line movement.

const std = @import("std");
const awt = @import("awt");
const GapBuffer = @import("GapBuffer.zig");
const UndoStack = @import("UndoStack.zig");
const Command = UndoStack.Command;

const EditableText = @This();

const Buffer = struct {
    gap: GapBuffer,

    fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .gap = GapBuffer.init(allocator) };
    }

    fn initFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !Buffer {
        return .{ .gap = try GapBuffer.initFromSlice(allocator, bytes) };
    }

    fn deinit(self: *Buffer) void {
        self.gap.deinit();
    }

    fn len(self: Buffer) usize {
        return self.gap.len();
    }

    fn byteAt(self: Buffer, i: usize) u8 {
        return self.gap.byteAt(i);
    }

    fn copyRange(self: Buffer, dst: []u8, start: usize, end: usize) void {
        self.gap.copyRange(dst, start, end);
    }

    fn replace(self: *Buffer, start: usize, count: usize, bytes: []const u8) !void {
        try self.gap.replace(start, count, bytes);
    }

    fn ensureReplaceCapacity(self: *Buffer, start: usize, count: usize, insert_len: usize) !void {
        try self.gap.ensureReplaceCapacity(start, count, insert_len);
    }

    fn replaceAssumeCapacity(self: *Buffer, start: usize, count: usize, bytes: []const u8) void {
        self.gap.replaceAssumeCapacity(start, count, bytes);
    }

    fn textSlice(self: *Buffer) []const u8 {
        self.gap.moveGap(self.gap.len());
        return self.gap.buf[0..self.gap.len()];
    }
};

pub const Selection = struct {
    start: usize,
    end: usize,
};

allocator: std.mem.Allocator,
buffer: Buffer,
caret: usize,
mark: usize,
undo_stack: UndoStack,
merge_generation: usize,

pub fn init(allocator: std.mem.Allocator) EditableText {
    return .{
        .allocator = allocator,
        .buffer = Buffer.init(allocator),
        .caret = 0,
        .mark = 0,
        .undo_stack = UndoStack.init(allocator),
        .merge_generation = 0,
    };
}

pub fn initFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !EditableText {
    const normalized = try normalizeLineEndings(allocator, bytes);
    defer allocator.free(normalized);

    var buffer = try Buffer.initFromSlice(allocator, normalized);
    errdefer buffer.deinit();

    return .{
        .allocator = allocator,
        .buffer = buffer,
        .caret = normalized.len,
        .mark = normalized.len,
        .undo_stack = UndoStack.init(allocator),
        .merge_generation = 0,
    };
}

pub fn deinit(self: *EditableText) void {
    self.undo_stack.deinit();
    self.buffer.deinit();
    self.* = undefined;
}

pub fn len(self: EditableText) usize {
    return self.buffer.len();
}

pub fn byteAt(self: EditableText, i: usize) u8 {
    return self.buffer.byteAt(i);
}

pub fn copyRange(self: EditableText, dst: []u8, start: usize, end: usize) void {
    self.buffer.copyRange(dst, start, end);
}

pub fn textSlice(self: *EditableText) []const u8 {
    return self.buffer.textSlice();
}

pub fn setText(self: *EditableText, bytes: []const u8) !void {
    const normalized = try normalizeLineEndings(self.allocator, bytes);
    defer self.allocator.free(normalized);

    var next = try Buffer.initFromSlice(self.allocator, normalized);
    errdefer next.deinit();

    self.undo_stack.clear();
    self.buffer.deinit();
    self.buffer = next;
    self.caret = self.len();
    self.mark = self.caret;
    self.breakCoalescing();
}

pub fn hasSelection(self: EditableText) bool {
    return self.caret != self.mark;
}

pub fn selectionStart(self: EditableText) usize {
    return @min(self.caret, self.mark);
}

pub fn selectionEnd(self: EditableText) usize {
    return @max(self.caret, self.mark);
}

pub fn selection(self: EditableText) Selection {
    return .{ .start = self.selectionStart(), .end = self.selectionEnd() };
}

pub fn selectionSlice(self: EditableText, allocator: std.mem.Allocator) ![]u8 {
    const sel = self.selection();
    const out = try allocator.alloc(u8, sel.end - sel.start);
    self.copyRange(out, sel.start, sel.end);
    return out;
}

pub fn setCaret(self: *EditableText, pos: usize) void {
    self.caret = self.snapToBoundary(pos);
    self.mark = self.caret;
    self.breakCoalescing();
}

pub fn setSelection(self: *EditableText, caret: usize, mark: usize) void {
    self.caret = self.snapToBoundary(caret);
    self.mark = self.snapToBoundary(mark);
    self.breakCoalescing();
}

pub fn prevBoundary(self: *EditableText, from: usize) usize {
    const clamped = @min(from, self.len());
    const s = self.rangeSlice(0, clamped) catch return 0;
    defer self.allocator.free(s);
    return awt.grapheme.prevGraphemeBoundary(s, clamped);
}

pub fn nextBoundary(self: *EditableText, from: usize) usize {
    const total = self.len();
    const clamped = @min(from, total);
    const s = self.rangeSlice(0, total) catch return total;
    defer self.allocator.free(s);
    return awt.grapheme.nextGraphemeBoundary(s, clamped);
}

pub fn snapToBoundary(self: *EditableText, byte_pos: usize) usize {
    const total = self.len();
    const clamped = @min(byte_pos, total);
    const s = self.rangeSlice(0, total) catch return clamped;
    defer self.allocator.free(s);
    const prev = awt.grapheme.prevGraphemeBoundary(s, clamped);
    if (awt.grapheme.nextGraphemeBoundary(s, prev) == clamped) return clamped;
    return prev;
}

pub fn rangeSlice(self: EditableText, start: usize, end: usize) ![]u8 {
    const n = end - start;
    const out = try self.allocator.alloc(u8, n);
    self.copyRange(out, start, end);
    return out;
}

pub fn applyEdit(self: *EditableText, pos: usize, del_len: usize, new_bytes: []const u8) !bool {
    const start = @min(pos, self.len());
    const count = @min(del_len, self.len() - start);
    const normalized = try normalizeLineEndings(self.allocator, new_bytes);
    defer self.allocator.free(normalized);

    if (count == 0 and normalized.len == 0) {
        return false;
    }

    const old = try self.allocator.alloc(u8, count);
    errdefer self.allocator.free(old);
    self.copyRange(old, start, start + count);

    const new_capacity = commandByteCapacity(normalized);
    const new_storage = try self.allocator.alloc(u8, new_capacity);
    errdefer self.allocator.free(new_storage);
    @memcpy(new_storage[0..normalized.len], normalized);

    const caret_before = self.caret;
    const mark_before = self.mark;
    const caret_after = start + normalized.len;
    const mark_after = caret_after;

    const cmd_ctx = try self.allocator.create(ReplaceRange);
    errdefer self.allocator.destroy(cmd_ctx);
    cmd_ctx.* = .{
        .core = self,
        .allocator = self.allocator,
        .pos = start,
        .old_bytes = old,
        .new_bytes = new_storage[0..normalized.len],
        .new_capacity = new_capacity,
        .caret_before = caret_before,
        .mark_before = mark_before,
        .caret_after = caret_after,
        .mark_after = mark_after,
        .merge_generation = self.merge_generation,
        .mergeable_insert = isSingleGrapheme(normalized),
    };

    try self.undo_stack.ensureUnusedCapacity(1);
    try self.buffer.ensureReplaceCapacity(start, count, normalized.len);

    self.buffer.replaceAssumeCapacity(start, count, normalized);
    self.caret = caret_after;
    self.mark = mark_after;

    self.undo_stack.pushAssumeCapacity(.{ .vtable = &ReplaceRange.vtable, .ctx = cmd_ctx });
    return true;
}

pub fn insert(self: *EditableText, bytes: []const u8) !bool {
    if (self.hasSelection()) return self.replaceSelection(bytes);
    return self.applyEdit(self.caret, 0, bytes);
}

pub fn replaceSelection(self: *EditableText, bytes: []const u8) !bool {
    const sel = self.selection();
    return self.applyEdit(sel.start, sel.end - sel.start, bytes);
}

pub fn paste(self: *EditableText, bytes: []const u8) !bool {
    self.breakCoalescing();
    const changed = try self.replaceSelection(bytes);
    self.breakCoalescing();
    return changed;
}

pub fn cutSelection(self: *EditableText, allocator: std.mem.Allocator) !?[]u8 {
    if (!self.hasSelection()) return null;
    const out = try self.selectionSlice(allocator);
    errdefer allocator.free(out);
    self.breakCoalescing();
    _ = try self.deleteSelection();
    self.breakCoalescing();
    return out;
}

pub fn deleteSelection(self: *EditableText) !bool {
    const sel = self.selection();
    return self.applyEdit(sel.start, sel.end - sel.start, "");
}

pub fn deleteBackward(self: *EditableText) !bool {
    if (self.hasSelection()) return self.deleteSelection();
    if (self.caret == 0) return false;
    const prev = self.prevBoundary(self.caret);
    return self.applyEdit(prev, self.caret - prev, "");
}

pub fn deleteForward(self: *EditableText) !bool {
    if (self.hasSelection()) return self.deleteSelection();
    if (self.caret >= self.len()) return false;
    const next = self.nextBoundary(self.caret);
    return self.applyEdit(self.caret, next - self.caret, "");
}

pub fn undo(self: *EditableText) !bool {
    if (!self.undo_stack.canUndo()) return false;
    try self.undo_stack.undo();
    self.breakCoalescing();
    return true;
}

pub fn redo(self: *EditableText) !bool {
    if (!self.undo_stack.canRedo()) return false;
    try self.undo_stack.redo();
    self.breakCoalescing();
    return true;
}

pub fn canUndo(self: EditableText) bool {
    return self.undo_stack.canUndo();
}

pub fn canRedo(self: EditableText) bool {
    return self.undo_stack.canRedo();
}

pub fn breakCoalescing(self: *EditableText) void {
    self.merge_generation +%= 1;
}

pub fn lineStartAtByte(self: EditableText, byte: usize) usize {
    var i = @min(byte, self.len());
    while (i > 0) {
        if (self.byteAt(i - 1) == '\n') break;
        i -= 1;
    }
    return i;
}

pub fn byteAtLine(self: EditableText, line: usize) usize {
    if (line == 0) return 0;
    var cur_line: usize = 0;
    var i: usize = 0;
    while (i < self.len()) : (i += 1) {
        if (self.byteAt(i) == '\n') {
            cur_line += 1;
            if (cur_line == line) return i + 1;
        }
    }
    return self.len();
}

fn normalizeLineEndings(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r') {
            try out.append(allocator, '\n');
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
        } else {
            try out.append(allocator, bytes[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

const ReplaceRange = struct {
    core: *EditableText,
    allocator: std.mem.Allocator,
    pos: usize,
    old_bytes: []u8,
    new_bytes: []u8,
    new_capacity: usize,
    caret_before: usize,
    mark_before: usize,
    caret_after: usize,
    mark_after: usize,
    merge_generation: usize,
    mergeable_insert: bool,

    fn from(ctx: *anyopaque) *ReplaceRange {
        return @ptrCast(@alignCast(ctx));
    }

    fn redoCommand(ctx: *anyopaque) anyerror!void {
        const self = from(ctx);
        try self.core.buffer.replace(self.pos, self.old_bytes.len, self.new_bytes);
        self.core.caret = self.caret_after;
        self.core.mark = self.mark_after;
    }

    fn undoCommand(ctx: *anyopaque) anyerror!void {
        const self = from(ctx);
        try self.core.buffer.replace(self.pos, self.new_bytes.len, self.old_bytes);
        self.core.caret = self.caret_before;
        self.core.mark = self.mark_before;
    }

    fn deinitCommand(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self = from(ctx);
        self.allocator.free(self.old_bytes);
        self.allocator.free(self.new_bytes.ptr[0..self.new_capacity]);
        allocator.destroy(self);
    }

    fn tryMergeCommand(ctx: *anyopaque, next: Command) bool {
        if (next.vtable != &vtable) return false;
        const self = from(ctx);
        const other = from(next.ctx);
        if (!self.canMergeInsertGroup() or !other.canMergeSingleInsert()) return false;
        if (self.merge_generation != other.merge_generation) return false;
        if (self.pos + self.new_bytes.len != other.pos) return false;

        const old_len = self.new_bytes.len;
        const new_len = old_len + other.new_bytes.len;
        if (new_len > self.new_capacity) {
            const old_storage = self.new_bytes.ptr[0..self.new_capacity];
            const new_capacity = commandByteCapacityForLen(new_len);
            const merged = self.allocator.realloc(old_storage, new_capacity) catch return false;
            self.new_bytes = merged[0..old_len];
            self.new_capacity = merged.len;
        }
        @memcpy(self.new_bytes.ptr[old_len..new_len], other.new_bytes);
        self.new_bytes = self.new_bytes.ptr[0..new_len];
        self.caret_after = other.caret_after;
        self.mark_after = other.mark_after;
        return true;
    }

    fn canMergeInsertGroup(self: ReplaceRange) bool {
        if (self.old_bytes.len != 0) return false;
        if (self.new_bytes.len == 0) return false;
        if (!self.mergeable_insert) return false;
        if (std.mem.indexOfScalar(u8, self.new_bytes, '\n') != null) return false;
        if (self.caret_before != self.mark_before or self.caret_before != self.pos) return false;
        if (self.caret_after != self.mark_after or self.caret_after != self.pos + self.new_bytes.len) return false;
        return true;
    }

    fn canMergeSingleInsert(self: ReplaceRange) bool {
        if (!self.canMergeInsertGroup()) return false;
        return isSingleGrapheme(self.new_bytes);
    }

    const vtable = Command.VTable{
        .redo = redoCommand,
        .undo = undoCommand,
        .deinit = deinitCommand,
        .tryMerge = tryMergeCommand,
    };
};

fn isSingleGrapheme(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    return awt.grapheme.nextGraphemeBoundary(bytes, 0) == bytes.len;
}

fn commandByteCapacity(bytes: []const u8) usize {
    if (!isSingleGrapheme(bytes)) return bytes.len;
    if (std.mem.indexOfScalar(u8, bytes, '\n') != null) return bytes.len;
    return commandByteCapacityForLen(bytes.len);
}

fn commandByteCapacityForLen(used_len: usize) usize {
    return used_len + 64;
}

const testing = std.testing;

fn expectText(et: *EditableText, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, et.textSlice());
}

fn expectState(et: *EditableText, expected: []const u8, caret: usize, mark: usize, can_undo: bool, can_redo: bool) !void {
    try expectText(et, expected);
    try testing.expectEqual(caret, et.caret);
    try testing.expectEqual(mark, et.mark);
    try testing.expectEqual(can_undo, et.canUndo());
    try testing.expectEqual(can_redo, et.canRedo());
}

test "insert delete and selection replacement update text and caret" {
    var et = try EditableText.initFromSlice(testing.allocator, "ab");
    defer et.deinit();

    et.setCaret(1);
    try testing.expect(try et.insert("X"));
    try expectText(&et, "aXb");
    try testing.expectEqual(@as(usize, 2), et.caret);
    try testing.expectEqual(et.caret, et.mark);

    try testing.expect(try et.deleteBackward());
    try expectText(&et, "ab");
    try testing.expectEqual(@as(usize, 1), et.caret);

    try testing.expect(try et.deleteForward());
    try expectText(&et, "a");
    try testing.expectEqual(@as(usize, 1), et.caret);

    try et.setText("hello");
    et.setSelection(4, 1);
    try testing.expect(try et.replaceSelection("i"));
    try expectText(&et, "hio");
    try testing.expectEqual(@as(usize, 2), et.caret);
    try testing.expect(!et.hasSelection());
}

test "undo redo restores text caret and selection through edit sequence" {
    var et = try EditableText.initFromSlice(testing.allocator, "abc");
    defer et.deinit();

    et.setSelection(1, 3);
    try testing.expect(try et.replaceSelection("X"));
    try expectText(&et, "aX");
    try testing.expectEqual(@as(usize, 2), et.caret);

    try testing.expect(try et.insert("Y"));
    try expectText(&et, "aXY");

    try testing.expect(try et.undo());
    try expectText(&et, "aX");
    try testing.expectEqual(@as(usize, 2), et.caret);
    try testing.expectEqual(@as(usize, 2), et.mark);

    try testing.expect(try et.undo());
    try expectText(&et, "abc");
    try testing.expectEqual(@as(usize, 1), et.caret);
    try testing.expectEqual(@as(usize, 3), et.mark);

    try testing.expect(try et.redo());
    try expectText(&et, "aX");
    try testing.expectEqual(@as(usize, 2), et.caret);
    try testing.expectEqual(@as(usize, 2), et.mark);
}

test "selection slice and grapheme boundary movement" {
    const thumbs = "\u{1F44D}\u{1F3FB}";
    var et = try EditableText.initFromSlice(testing.allocator, "a" ++ thumbs ++ "b");
    defer et.deinit();

    const start = "a".len;
    const end = "a".len + thumbs.len;
    try testing.expectEqual(end, et.nextBoundary(start));
    try testing.expectEqual(start, et.prevBoundary(end));
    try testing.expectEqual(start, et.snapToBoundary(start + "\u{1F44D}".len));

    et.setSelection(end, start);
    const selected = try et.selectionSlice(testing.allocator);
    defer testing.allocator.free(selected);
    try testing.expectEqualStrings(thumbs, selected);
}

test "coalescing joins adjacent single cluster inserts" {
    var et = EditableText.init(testing.allocator);
    defer et.deinit();

    try testing.expect(try et.insert("a"));
    try testing.expect(try et.insert("b"));
    try testing.expect(try et.insert("c"));
    try expectText(&et, "abc");

    try testing.expect(try et.undo());
    try expectText(&et, "");
    try testing.expect(!et.canUndo());

    try testing.expect(try et.redo());
    try expectText(&et, "abc");
}

test "coalescing breaks on newline delete selection paste and caret jump" {
    var et = EditableText.init(testing.allocator);
    defer et.deinit();

    try testing.expect(try et.insert("a"));
    try testing.expect(try et.insert("\n"));
    try expectText(&et, "a\n");
    try testing.expect(try et.undo());
    try expectText(&et, "a");
    try testing.expect(try et.undo());
    try expectText(&et, "");

    try testing.expect(try et.insert("a"));
    try testing.expect(try et.deleteBackward());
    try expectText(&et, "");
    try testing.expect(try et.undo());
    try expectText(&et, "a");
    try testing.expect(try et.undo());
    try expectText(&et, "");

    try et.setText("");
    try testing.expect(try et.insert("a"));
    et.setSelection(0, 1);
    try testing.expect(try et.replaceSelection("b"));
    try expectText(&et, "b");
    try testing.expect(try et.undo());
    try expectText(&et, "a");
    try testing.expect(try et.undo());
    try expectText(&et, "");

    try et.setText("");
    try testing.expect(try et.insert("a"));
    try testing.expect(try et.paste("b"));
    try expectText(&et, "ab");
    try testing.expect(try et.undo());
    try expectText(&et, "a");
    try testing.expect(try et.undo());
    try expectText(&et, "");

    try testing.expect(try et.insert("a"));
    et.setCaret(0);
    try testing.expect(try et.insert("b"));
    try expectText(&et, "ba");
    try testing.expect(try et.undo());
    try expectText(&et, "a");
}

test "cut and paste undo restore text and split paste from typing" {
    var et = try EditableText.initFromSlice(testing.allocator, "abc");
    defer et.deinit();

    et.setSelection(3, 1);
    const cut = (try et.cutSelection(testing.allocator)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(cut);
    try testing.expectEqualStrings("bc", cut);
    try expectText(&et, "a");

    try testing.expect(try et.undo());
    try expectText(&et, "abc");
    try testing.expectEqual(@as(usize, 3), et.caret);
    try testing.expectEqual(@as(usize, 1), et.mark);

    try testing.expect(try et.redo());
    try expectText(&et, "a");

    et.setCaret(1);
    try testing.expect(try et.paste(cut));
    try expectText(&et, "abc");
    try testing.expect(try et.undo());
    try expectText(&et, "a");

    try et.setText("");
    try testing.expect(try et.insert("a"));
    try testing.expect(try et.paste("b"));
    try expectText(&et, "ab");
    try testing.expect(try et.undo());
    try expectText(&et, "a");
    try testing.expect(try et.undo());
    try expectText(&et, "");
}

test "delete noops and undo restore delete caret" {
    var et = try EditableText.initFromSlice(testing.allocator, "ab");
    defer et.deinit();

    et.setCaret(1);
    try testing.expect(try et.deleteBackward());
    try expectState(&et, "b", 0, 0, true, false);
    try testing.expect(try et.undo());
    try expectState(&et, "ab", 1, 1, false, true);

    try et.setText("ab");
    et.setCaret(0);
    try testing.expect(!(try et.deleteBackward()));
    try expectState(&et, "ab", 0, 0, false, false);

    et.setCaret(et.len());
    try testing.expect(!(try et.deleteForward()));
    try expectState(&et, "ab", 2, 2, false, false);

    try testing.expect(!(try et.applyEdit(1, 0, "")));
    try expectState(&et, "ab", 2, 2, false, false);
}

test "crlf normalization and setText reset undo history" {
    var et = EditableText.init(testing.allocator);
    defer et.deinit();

    try testing.expect(try et.insert("a\r\nb\rc"));
    try expectText(&et, "a\nb\nc");
    try testing.expect(et.canUndo());

    try et.setText("x\r\ny");
    try expectText(&et, "x\ny");
    try testing.expect(!et.canUndo());
    try testing.expect(!et.canRedo());
}

const OomEditCase = enum {
    insert,
    delete,
    selection_replace,
    merge,
};

fn checkApplyEditAllOrNothing(allocator: std.mem.Allocator, edit_case: OomEditCase) !void {
    switch (edit_case) {
        .insert => {
            var et = try EditableText.initFromSlice(allocator, "ab");
            defer et.deinit();
            et.setCaret(1);
            const result = et.insert("X");
            if (result) |changed| {
                try testing.expect(changed);
                try expectState(&et, "aXb", 2, 2, true, false);
            } else |err| switch (err) {
                error.OutOfMemory => {
                    try expectState(&et, "ab", 1, 1, false, false);
                    return error.OutOfMemory;
                },
            }
        },
        .delete => {
            var et = try EditableText.initFromSlice(allocator, "abc");
            defer et.deinit();
            et.setCaret(2);
            const result = et.deleteBackward();
            if (result) |changed| {
                try testing.expect(changed);
                try expectState(&et, "ac", 1, 1, true, false);
            } else |err| switch (err) {
                error.OutOfMemory => {
                    try expectState(&et, "abc", 2, 2, false, false);
                    return error.OutOfMemory;
                },
            }
        },
        .selection_replace => {
            var et = try EditableText.initFromSlice(allocator, "abcd");
            defer et.deinit();
            et.setSelection(3, 1);
            const result = et.replaceSelection("X");
            if (result) |changed| {
                try testing.expect(changed);
                try expectState(&et, "aXd", 2, 2, true, false);
            } else |err| switch (err) {
                error.OutOfMemory => {
                    try expectState(&et, "abcd", 3, 1, false, false);
                    return error.OutOfMemory;
                },
            }
        },
        .merge => {
            var et = EditableText.init(allocator);
            defer et.deinit();
            try testing.expect(try et.insert("a"));
            const result = et.insert("b");
            if (result) |changed| {
                try testing.expect(changed);
                try expectState(&et, "ab", 2, 2, true, false);
                try testing.expect(try et.undo());
                try expectState(&et, "", 0, 0, false, true);
            } else |err| switch (err) {
                error.OutOfMemory => {
                    try expectState(&et, "a", 1, 1, true, false);
                    return error.OutOfMemory;
                },
            }
        },
    }
}

test "applyEdit allocation failures leave text caret and undo unchanged" {
    try testing.checkAllAllocationFailures(testing.allocator, checkApplyEditAllOrNothing, .{OomEditCase.insert});
    try testing.checkAllAllocationFailures(testing.allocator, checkApplyEditAllOrNothing, .{OomEditCase.delete});
    try testing.checkAllAllocationFailures(testing.allocator, checkApplyEditAllOrNothing, .{OomEditCase.selection_replace});
    try testing.checkAllAllocationFailures(testing.allocator, checkApplyEditAllOrNothing, .{OomEditCase.merge});
}
