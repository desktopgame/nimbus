//! Unicode grapheme-cluster boundary helpers.

const std = @import("std");
const Graphemes = @import("Graphemes");

/// Return the byte offset of the previous grapheme-cluster boundary.
/// `from == 0` returns 0. Callers pass a contiguous UTF-8 slice.
pub fn prevGraphemeBoundary(bytes: []const u8, from: usize) usize {
    const end = @min(from, bytes.len);
    if (end == 0) return 0;

    var iter = Graphemes.reverseIterator(bytes[0..end]);
    if (iter.prev()) |gc| return gc.offset;
    return 0;
}

/// Return the byte offset of the next grapheme-cluster boundary.
/// `from >= bytes.len` returns `bytes.len`. Callers pass a contiguous UTF-8 slice.
pub fn nextGraphemeBoundary(bytes: []const u8, from: usize) usize {
    if (from >= bytes.len) return bytes.len;

    var iter = Graphemes.iterator(bytes);
    while (iter.next()) |gc| {
        const end = gc.offset + gc.len;
        if (from < end) return end;
    }
    return bytes.len;
}

fn expectClusterBoundaries(bytes: []const u8, boundaries: []const usize) !void {
    try std.testing.expect(boundaries.len >= 2);
    try std.testing.expectEqual(@as(usize, 0), boundaries[0]);
    try std.testing.expectEqual(bytes.len, boundaries[boundaries.len - 1]);

    var i: usize = 0;
    while (i + 1 < boundaries.len) : (i += 1) {
        const start = boundaries[i];
        const end = boundaries[i + 1];
        try std.testing.expectEqual(start, prevGraphemeBoundary(bytes, end));
        try std.testing.expectEqual(end, nextGraphemeBoundary(bytes, start));
    }
}

test "grapheme boundaries: combining mark" {
    const s = "e\u{0301}x";
    try expectClusterBoundaries(s, &.{ 0, "e\u{0301}".len, s.len });
}

test "grapheme boundaries: ZWJ family emoji" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const s = family ++ "x";
    try expectClusterBoundaries(s, &.{ 0, family.len, s.len });
}

test "grapheme boundaries: emoji skin tone modifier" {
    const thumbs = "\u{1F44D}\u{1F3FB}";
    const s = thumbs ++ "x";
    try expectClusterBoundaries(s, &.{ 0, thumbs.len, s.len });
}

test "grapheme boundaries: regional-indicator flag" {
    const flag = "\u{1F1EF}\u{1F1F5}";
    const s = flag ++ "x";
    try expectClusterBoundaries(s, &.{ 0, flag.len, s.len });
}

test "grapheme boundaries: odd regional-indicator sequence" {
    const flag = "\u{1F1EF}\u{1F1F5}";
    const third = "\u{1F1FA}";
    const s = flag ++ third ++ "x";
    try expectClusterBoundaries(s, &.{ 0, flag.len, flag.len + third.len, s.len });
}
