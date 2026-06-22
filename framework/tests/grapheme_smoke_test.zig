//! Smoke test proving the vendored zg "Graphemes" module is wired into the
//! build and actually compiles/runs. Minimal groundwork for the future text
//! editor / JTextPane work. Pure logic: no GPU, no window.

const std = @import("std");
const G = @import("Graphemes");

const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
const sample = "a" ++ "e\u{0301}" ++ family;

test "forward iterator: combining mark and ZWJ do not split clusters" {
    var iter = G.iterator(sample);
    var count: usize = 0;
    var total_len: usize = 0;
    while (iter.next()) |gc| : (count += 1) {
        try std.testing.expect(gc.offset + gc.len <= sample.len);
        try std.testing.expect(gc.len > 0);
        const slice = gc.bytes(sample);
        try std.testing.expectEqual(@as(usize, gc.len), slice.len);
        total_len += gc.len;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(sample.len, total_len);
}

test "reverse iterator: same clusters and boundaries in reverse order" {
    var fwd_offsets: [8]usize = undefined;
    var fwd_lens: [8]usize = undefined;
    var fwd_count: usize = 0;
    {
        var iter = G.iterator(sample);
        while (iter.next()) |gc| : (fwd_count += 1) {
            fwd_offsets[fwd_count] = gc.offset;
            fwd_lens[fwd_count] = gc.len;
        }
    }
    var rev_offsets: [8]usize = undefined;
    var rev_lens: [8]usize = undefined;
    var rev_count: usize = 0;
    {
        var iter = G.reverseIterator(sample);
        while (iter.prev()) |gc| : (rev_count += 1) {
            rev_offsets[rev_count] = gc.offset;
            rev_lens[rev_count] = gc.len;
        }
    }
    try std.testing.expectEqual(fwd_count, rev_count);
    try std.testing.expectEqual(@as(usize, 3), rev_count);
    var i: usize = 0;
    while (i < fwd_count) : (i += 1) {
        const r = rev_count - 1 - i;
        try std.testing.expectEqual(fwd_offsets[i], rev_offsets[r]);
        try std.testing.expectEqual(fwd_lens[i], rev_lens[r]);
    }
}
