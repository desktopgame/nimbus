//! Shared text wrapping helper for widgets that lay out UTF-8 text.

const std = @import("std");
const Font = @import("Font.zig");
const grapheme = @import("grapheme.zig");

const MAX_OIDASHI = 2;

const latin_break_after = [_]u32{ ' ', '\t', '-', '/' };
const line_start_prohibited = [_]u32{
    ')',    ']',    '}',    0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B,
    0xFF09, 0xFF3D, 0xFF5D, 0xFF60, 0x30FB, 0x3001, 0x3002, 0xFF0C, 0xFF0E, 0xFF01, 0xFF1F, 0x309B,
    0x309C, 0xFF9E, 0xFF9F, 0x30FC, 0x2015, 0x2025, 0x2026, 0x30FD, 0x30FE, 0x309D, 0x309E, 0x3005,
    0x303B, 0xFF61, 0xFF64, 0xFF65, 0xFF63, 0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083,
    0x3085, 0x3087, 0x308E, 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7,
    0x30EE, 0x30F5, 0x30F6,
};
const line_end_prohibited = [_]u32{
    '(',    '[',    '{',    0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A,
    0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62,
};

const Cluster = struct {
    first: u32,
    last: u32,
};

/// Return the largest wrap position inside text[start..end] that fits wrap_w.
/// The returned offset is always a grapheme-cluster boundary. If no preferred
/// break opportunity fits, wrapping falls back to the nearest fitting cluster
/// boundary while still advancing by at least one cluster.
pub fn wrapSegment(face: Font, text: []const u8, start: usize, end: usize, wrap_w: f32) usize {
    const s = @min(start, text.len);
    const e = @min(@max(end, s), text.len);
    if (s >= e) return e;

    var forced = firstClusterEnd(text, s, e);
    var last_fit: usize = forced;
    var last_break: ?usize = null;
    var pos = s;
    var width: f32 = 0;

    while (pos < e) {
        const next = grapheme.nextGraphemeBoundary(text, pos);
        const cluster_end = @min(next, e);
        if (cluster_end <= pos) break;

        const cluster = decodeCluster(text, pos, cluster_end);
        width += face.advanceOfRange(text, pos, cluster_end);
        if (width > wrap_w and pos > s) break;

        forced = cluster_end;
        last_fit = cluster_end;
        if (isBreakOpportunity(text, cluster, cluster_end, e)) {
            last_break = cluster_end;
        }

        pos = cluster_end;
    }

    if (last_fit >= e) return e;
    const raw = last_break orelse forced;
    return avoidKinsoku(text, s, e, raw);
}

fn firstClusterEnd(text: []const u8, start: usize, end: usize) usize {
    const next = grapheme.nextGraphemeBoundary(text, start);
    return @min(@max(next, start + 1), end);
}

fn isBreakOpportunity(text: []const u8, cur: Cluster, boundary: usize, end: usize) bool {
    if (boundary >= end) return true;
    if (contains(&latin_break_after, cur.last)) return true;
    if (isCjk(cur.last)) return true;
    const next = grapheme.nextGraphemeBoundary(text, boundary);
    const after = decodeCluster(text, boundary, @min(next, end));
    if (isCjk(after.first)) return true;
    return false;
}

fn avoidKinsoku(text: []const u8, start: usize, end: usize, raw: usize) usize {
    var pos = raw;
    var moved: usize = 0;
    while (touchesKinsoku(text, start, end, pos)) {
        if (moved >= MAX_OIDASHI) return raw;
        const prev = grapheme.prevGraphemeBoundary(text, pos);
        if (prev <= start) return raw;
        pos = prev;
        moved += 1;
    }
    return pos;
}

fn touchesKinsoku(text: []const u8, start: usize, end: usize, pos: usize) bool {
    if (pos > start) {
        const prev = grapheme.prevGraphemeBoundary(text, pos);
        const before = decodeCluster(text, prev, pos);
        if (contains(&line_end_prohibited, before.last)) return true;
    }
    if (pos < end) {
        const next = grapheme.nextGraphemeBoundary(text, pos);
        const after = decodeCluster(text, pos, @min(next, end));
        if (contains(&line_start_prohibited, after.first)) return true;
    }
    return false;
}

fn decodeCluster(text: []const u8, start: usize, end: usize) Cluster {
    var first: u32 = 0;
    var last: u32 = 0;
    var i = start;
    while (i < end) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > end) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch text[i];
        if (first == 0) first = cp;
        last = cp;
        i += len;
    }
    if (first == 0) {
        first = text[start];
        last = first;
    }
    return .{ .first = first, .last = last };
}

fn contains(table: []const u32, cp: u32) bool {
    for (table) |item| {
        if (item == cp) return true;
    }
    return false;
}

fn isCjk(cp: u32) bool {
    return inRange(cp, 0x3040, 0x309F) or
        inRange(cp, 0x30A0, 0x30FF) or
        inRange(cp, 0x31F0, 0x31FF) or
        inRange(cp, 0x3400, 0x4DBF) or
        inRange(cp, 0x4E00, 0x9FFF) or
        inRange(cp, 0xF900, 0xFAFF) or
        inRange(cp, 0x20000, 0x2A6DF) or
        inRange(cp, 0x2A700, 0x2B73F) or
        inRange(cp, 0x2B740, 0x2B81F) or
        inRange(cp, 0x2B820, 0x2CEAF) or
        inRange(cp, 0x2F800, 0x2FA1F) or
        inRange(cp, 0x3000, 0x303F) or
        inRange(cp, 0xFF00, 0xFFEF);
}

fn inRange(cp: u32, lo: u32, hi: u32) bool {
    return lo <= cp and cp <= hi;
}
