//! Golden-image snapshot helpers. Compare a freshly-rendered RGBA8 buffer
//! against a PNG fixture with a configurable per-channel tolerance, and
//! produce an amplified diff image on mismatch. Used by awt / framework /
//! application tests; harness policy (fixture dir, env-var update mode,
//! first-run bootstrap) lives in the caller.

const std = @import("std");
const zigimg = @import("zigimg");

const Snapshot = @This();

pub const CompareOptions = struct {
    /// Per-channel absolute tolerance (0..255). Differences ≤ this are
    /// counted as a match. Default 1 LSB absorbs cross-driver rounding.
    tolerance: u8 = 1,
};

pub const CompareResult = struct {
    /// Number of channel-level differences exceeding `tolerance`.
    /// 0 ⇔ images match within tolerance.
    mismatch_channels: usize,
    /// Largest per-channel deviation observed (regardless of tolerance).
    /// Useful for diagnostic messages even when the result is ok().
    max_diff: u8,

    pub fn ok(self: CompareResult) bool {
        return self.mismatch_channels == 0;
    }
};

/// Compare two RGBA8 buffers per-channel. Caller must ensure both buffers
/// describe images of the same dimensions (so equal length). No I/O.
pub fn compare(actual: []const u8, expected: []const u8, opts: CompareOptions) CompareResult {
    std.debug.assert(actual.len == expected.len);
    var result = CompareResult{ .mismatch_channels = 0, .max_diff = 0 };
    for (actual, expected) |a, e| {
        const d: u8 = if (a > e) a - e else e - a;
        if (d > result.max_diff) result.max_diff = d;
        if (d > opts.tolerance) result.mismatch_channels += 1;
    }
    return result;
}

/// Read an RGBA8 PNG into an owned `[]u8` of `expected_w * expected_h * 4`
/// bytes. Returns `error.SnapshotSizeMismatch` if the file dimensions don't
/// match the caller's expectation.
pub fn readPng(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    expected_w: usize,
    expected_h: usize,
) ![]u8 {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var img = try zigimg.Image.fromFilePath(allocator, io, path, read_buffer[0..]);
    defer img.deinit(allocator);

    if (img.width != expected_w or img.height != expected_h) {
        return error.SnapshotSizeMismatch;
    }

    try img.convert(allocator, .rgba32);
    const bytes = img.rawBytes();
    const out = try allocator.alloc(u8, bytes.len);
    @memcpy(out, bytes);
    return out;
}

/// Write an RGBA8 buffer to a PNG file. The parent directory must exist.
pub fn writePng(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    rgba: []const u8,
    w: usize,
    h: usize,
) !void {
    var img = try zigimg.Image.fromRawPixels(allocator, w, h, rgba, .rgba32);
    defer img.deinit(allocator);

    var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try img.writeToFilePath(allocator, io, path, write_buffer[0..], .{ .png = .{} });
}

/// Per-channel |actual - expected| amplified 5× (clamped to 255) with alpha
/// forced opaque. The output reads as black where matching, bright where
/// divergent — useful for spotting where two renders differ at a glance.
/// Returns an owned `[]u8` buffer the caller frees.
pub fn diffImage(
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
) ![]u8 {
    std.debug.assert(actual.len == expected.len);
    const out = try allocator.alloc(u8, actual.len);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i + 3 < actual.len) : (i += 4) {
        out[i] = amp(absDiff(actual[i], expected[i]));
        out[i + 1] = amp(absDiff(actual[i + 1], expected[i + 1]));
        out[i + 2] = amp(absDiff(actual[i + 2], expected[i + 2]));
        out[i + 3] = 255;
    }
    return out;
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

fn amp(d: u8) u8 {
    const scaled: u32 = @as(u32, d) * 5;
    return if (scaled > 255) 255 else @intCast(scaled);
}

test "compare: identical buffers report no mismatch" {
    const a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const r = compare(a[0..], a[0..], .{});
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 0), r.mismatch_channels);
    try std.testing.expectEqual(@as(u8, 0), r.max_diff);
}

test "compare: within tolerance matches" {
    const a = [_]u8{ 10, 20, 30, 255 };
    const b = [_]u8{ 11, 19, 31, 255 };
    const r = compare(a[0..], b[0..], .{ .tolerance = 1 });
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(u8, 1), r.max_diff);
}

test "compare: above tolerance fails" {
    const a = [_]u8{ 10, 20, 30, 255 };
    const b = [_]u8{ 10, 20, 35, 255 };
    const r = compare(a[0..], b[0..], .{ .tolerance = 1 });
    try std.testing.expect(!r.ok());
    try std.testing.expectEqual(@as(usize, 1), r.mismatch_channels);
    try std.testing.expectEqual(@as(u8, 5), r.max_diff);
}

test "compare: tolerance 0 catches single-LSB difference" {
    const a = [_]u8{ 100, 100, 100, 255 };
    const b = [_]u8{ 100, 101, 100, 255 };
    const r = compare(a[0..], b[0..], .{ .tolerance = 0 });
    try std.testing.expect(!r.ok());
}
