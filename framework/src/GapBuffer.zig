//! UTF-8 gap buffer. See `framework/doc/gapbuffer.md`.
//!
//! Stores a byte sequence with a movable gap so that repeated edits clustered
//! at one position are cheap (amortized O(1) per byte once the gap is there),
//! instead of the O(n) memmove a flat array pays on every insert/delete. Used
//! by `TextArea`, which edits longer text than `TextField`.
//!
//! All public positions are *logical* byte offsets in `[0, len()]` — the gap is
//! invisible to callers. The buffer is encoding-agnostic; UTF-8 boundary logic
//! lives in `TextArea` (see its `*Boundary` helpers).

const std = @import("std");

const GapBuffer = @This();

/// Smallest gap we (re)open when growing, so a run of single-char inserts does
/// not realloc on every keystroke.
const MIN_GAP: usize = 64;

/// Backing storage. The gap occupies `[gap_start, gap_end)`; everything else is
/// live content. `buf.len - (gap_end - gap_start)` is the logical length.
buf: []u8,
gap_start: usize,
gap_end: usize,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) GapBuffer {
    return .{ .buf = &.{}, .gap_start = 0, .gap_end = 0, .allocator = allocator };
}

/// Initialize with `bytes` as the initial content (copied). Caret-side callers
/// pass the widget's initial text here.
pub fn initFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !GapBuffer {
    var gb = init(allocator);
    errdefer gb.deinit();
    try gb.insert(0, bytes);
    return gb;
}

pub fn deinit(self: *GapBuffer) void {
    if (self.buf.len > 0) self.allocator.free(self.buf);
    self.* = undefined;
}

/// Logical length (bytes of live content, gap excluded).
pub fn len(self: GapBuffer) usize {
    return self.buf.len - (self.gap_end - self.gap_start);
}

/// Physical index of a logical position. `logical == len()` maps to the first
/// byte after the content (== gap_start when the gap is at the end).
fn physical(self: GapBuffer, logical: usize) usize {
    return if (logical < self.gap_start) logical else logical + (self.gap_end - self.gap_start);
}

/// Byte at logical index `i`. Caller guarantees `i < len()` (else UB).
pub fn byteAt(self: GapBuffer, i: usize) u8 {
    return self.buf[self.physical(i)];
}

/// Copy logical range `[start, end)` into `dst` (which must be at least
/// `end - start` long). Handles a range that straddles the gap with two memcpys.
pub fn copyRange(self: GapBuffer, dst: []u8, start: usize, end: usize) void {
    std.debug.assert(end >= start and end <= self.len());
    if (end == start) return;
    if (end <= self.gap_start) {
        // Entirely before the gap.
        @memcpy(dst[0 .. end - start], self.buf[start..end]);
    } else if (start >= self.gap_start) {
        // Entirely after the gap.
        const ps = self.physical(start);
        @memcpy(dst[0 .. end - start], self.buf[ps .. ps + (end - start)]);
    } else {
        // Straddles: [start, gap_start) before, [gap_start, end) after.
        const left = self.gap_start - start;
        @memcpy(dst[0..left], self.buf[start..self.gap_start]);
        const right = end - self.gap_start;
        @memcpy(dst[left .. left + right], self.buf[self.gap_end .. self.gap_end + right]);
    }
}

/// Move the gap so `gap_start == pos` (logical). O(distance moved).
pub fn moveGap(self: *GapBuffer, pos: usize) void {
    std.debug.assert(pos <= self.len());
    if (pos < self.gap_start) {
        // Shift the run [pos, gap_start) to the high side of the gap.
        const n = self.gap_start - pos;
        std.mem.copyBackwards(u8, self.buf[self.gap_end - n .. self.gap_end], self.buf[pos..self.gap_start]);
        self.gap_start = pos;
        self.gap_end -= n;
    } else if (pos > self.gap_start) {
        // Shift the run after the gap down into the low side.
        const n = pos - self.gap_start;
        std.mem.copyForwards(u8, self.buf[self.gap_start .. self.gap_start + n], self.buf[self.gap_end .. self.gap_end + n]);
        self.gap_start += n;
        self.gap_end += n;
    }
}

/// Ensure the gap holds at least `need` bytes, growing the backing buffer if
/// not. After growth the gap is preserved at its current logical position.
fn ensureGap(self: *GapBuffer, need: usize) !void {
    const cur = self.gap_end - self.gap_start;
    if (cur >= need) return;

    const content = self.len();
    const new_cap = content + @max(need, MIN_GAP);
    const new_buf = try self.allocator.alloc(u8, new_cap);

    // Copy the two live segments into the new buffer, leaving the gap between.
    const before = self.gap_start;
    const after = self.buf.len - self.gap_end;
    @memcpy(new_buf[0..before], self.buf[0..before]);
    @memcpy(new_buf[new_cap - after .. new_cap], self.buf[self.gap_end..]);

    if (self.buf.len > 0) self.allocator.free(self.buf);
    self.buf = new_buf;
    self.gap_start = before;
    self.gap_end = new_cap - after;
}

/// Insert `bytes` at logical `pos`.
pub fn insert(self: *GapBuffer, pos: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try self.ensureGap(bytes.len);
    self.moveGap(pos);
    @memcpy(self.buf[self.gap_start .. self.gap_start + bytes.len], bytes);
    self.gap_start += bytes.len;
}

/// Delete `count` bytes starting at logical `pos`. Clamps to available length.
pub fn delete(self: *GapBuffer, pos: usize, count: usize) void {
    const n = @min(count, self.len() - pos);
    if (n == 0) return;
    self.moveGap(pos);
    self.gap_end += n; // absorb the n bytes after the gap into the gap
}

/// Replace `[start, start+count)` with `bytes` in one step (caret math is
/// simpler than separate delete+insert at call sites).
pub fn replace(self: *GapBuffer, start: usize, count: usize, bytes: []const u8) !void {
    self.delete(start, count);
    try self.insert(start, bytes);
}

/// Drop all content (keeps the backing allocation for reuse).
pub fn clear(self: *GapBuffer) void {
    self.gap_start = 0;
    self.gap_end = self.buf.len;
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectContent(gb: *GapBuffer, expected: []const u8) !void {
    const dst = try testing.allocator.alloc(u8, gb.len());
    defer testing.allocator.free(dst);
    gb.copyRange(dst, 0, gb.len());
    try testing.expectEqualStrings(expected, dst);
}

test "insert at end, middle, front" {
    var gb = GapBuffer.init(testing.allocator);
    defer gb.deinit();
    try gb.insert(0, "hello");
    try expectContent(&gb, "hello");
    try gb.insert(5, " world");
    try expectContent(&gb, "hello world");
    try gb.insert(5, ",");
    try expectContent(&gb, "hello, world");
    try gb.insert(0, ">> ");
    try expectContent(&gb, ">> hello, world");
}

test "delete across gap positions" {
    var gb = try GapBuffer.initFromSlice(testing.allocator, "abcdefgh");
    defer gb.deinit();
    gb.delete(2, 3); // remove "cde"
    try expectContent(&gb, "abfgh");
    gb.delete(0, 1); // remove "a"
    try expectContent(&gb, "bfgh");
    gb.delete(3, 10); // clamp
    try expectContent(&gb, "bfg");
}

test "byteAt and copyRange straddling the gap" {
    var gb = try GapBuffer.initFromSlice(testing.allocator, "0123456789");
    defer gb.deinit();
    gb.moveGap(5); // gap sits between '4' and '5'
    try testing.expectEqual(@as(u8, '4'), gb.byteAt(4));
    try testing.expectEqual(@as(u8, '5'), gb.byteAt(5));
    const dst = try testing.allocator.alloc(u8, 4);
    defer testing.allocator.free(dst);
    gb.copyRange(dst, 3, 7); // straddles gap → "3456"
    try testing.expectEqualStrings("3456", dst);
}

test "multibyte content preserved" {
    var gb = try GapBuffer.initFromSlice(testing.allocator, "あい");
    defer gb.deinit();
    try gb.insert(3, "う"); // between あ and い (3 bytes each)
    try expectContent(&gb, "あうい");
    try testing.expectEqual(@as(usize, 9), gb.len());
}

test "replace" {
    var gb = try GapBuffer.initFromSlice(testing.allocator, "the cat sat");
    defer gb.deinit();
    try gb.replace(4, 3, "dog"); // "cat" -> "dog"
    try expectContent(&gb, "the dog sat");
}
