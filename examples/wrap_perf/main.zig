//! CPU-only text wrapping benchmark for `awt.textwrap.wrapSegment`.
//! Opens no window, creates no device, and does no rendering.

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

const wrap_width: f32 = 300.0;
const wrap_repetitions: usize = 5;
const advance_iterations: usize = 1_000_000;

const cluster_pattern = [_][]const u8{
    "N", "i", "m",        "b",        "u",        "s",        " ",
    "w", "r", "a",        "p",        "s",        " ",        "t",
    "e", "x", "t",        " ",        "a",        "c",        "r",
    "o", "s", "s",        " ",        "\u{65E5}", "\u{672C}", "\u{8A9E}",
    " ", "U", "I",        " ",        "p",        "a",        "n",
    "e", "l", "s",        " ",        "w",        "i",        "t",
    "h", " ", "\u{30E9}", "\u{30D9}", "\u{30EB}", " ",        "r",
    "e", "s", "i",        "z",        "e",        " ",
};

const advance_codepoints = [_]u32{
    'A',
    'w',
    ' ',
    0x65E5,
    0x672C,
    0x8A9E,
    0x30E9,
    0x30D9,
    0x30EB,
    0x3002,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    try awt.init();
    defer awt.deinit();

    var font = try awt.Font.init(gpa, nimbus.noto.noto_sans_jp_regular, 0);
    defer font.deinit();
    font.setPixelSize(16);

    std.debug.print("wrap_perf: CPU-only, no window/device/rendering\n", .{});
    std.debug.print("font: noto_sans_jp_regular, pixel_size=16\n", .{});
    std.debug.print("wrap width: {d:.1}px\n\n", .{wrap_width});

    try benchReflow(gpa, font);
    std.debug.print("\n", .{});
    benchGlyphAdvance(font);
}

fn benchReflow(allocator: std.mem.Allocator, font: awt.Font) !void {
    const sizes = [_]usize{ 256, 512, 1024, 2048, 4096 };
    var previous_ns: ?u64 = null;

    std.debug.print("A: full-line reflow via wrapSegment\n", .{});
    std.debug.print("clusters\tbytes\tvisual_lines\tbest_ms\tratio\n", .{});

    for (sizes) |cluster_count| {
        const text = try makeParagraph(allocator, cluster_count);
        defer allocator.free(text);

        var best_ns: u64 = std.math.maxInt(u64);
        var best_lines: usize = 0;
        var checksum: usize = 0;

        for (0..wrap_repetitions) |_| {
            const started = awt.time();
            const lines = reflowOnce(font, text, &checksum);
            const elapsed: u64 = @intFromFloat((awt.time() - started) * std.time.ns_per_s);
            if (elapsed < best_ns) {
                best_ns = elapsed;
                best_lines = lines;
            }
        }

        std.mem.doNotOptimizeAway(checksum);
        const ms = @as(f64, @floatFromInt(best_ns)) / std.time.ns_per_ms;
        if (previous_ns) |prev| {
            const ratio = @as(f64, @floatFromInt(best_ns)) / @as(f64, @floatFromInt(prev));
            std.debug.print("{d}\t{d}\t{d}\t{d:.3}\t{d:.2}x\n", .{ cluster_count, text.len, best_lines, ms, ratio });
        } else {
            std.debug.print("{d}\t{d}\t{d}\t{d:.3}\t-\n", .{ cluster_count, text.len, best_lines, ms });
        }
        previous_ns = best_ns;
    }
}

fn reflowOnce(font: awt.Font, text: []const u8, checksum: *usize) usize {
    var start: usize = 0;
    var lines: usize = 0;
    while (start < text.len) {
        const next = awt.textwrap.wrapSegment(font, text, start, text.len, wrap_width);
        if (next <= start) @panic("wrapSegment did not advance");
        checksum.* +%= next - start;
        start = next;
        lines += 1;
    }
    return lines;
}

fn benchGlyphAdvance(font: awt.Font) void {
    const started = awt.time();
    var sum: f32 = 0;
    for (0..advance_iterations) |i| {
        sum += font.glyphAdvance(advance_codepoints[i % advance_codepoints.len]);
    }
    const elapsed: u64 = @intFromFloat((awt.time() - started) * std.time.ns_per_s);
    std.mem.doNotOptimizeAway(sum);

    const ns_per_call = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(advance_iterations));
    std.debug.print("B: glyphAdvance hot loop\n", .{});
    std.debug.print("calls\tcodepoints\ttotal_ms\tns_per_call\n", .{});
    std.debug.print(
        "{d}\t{d}\t{d:.3}\t{d:.1}\n",
        .{
            advance_iterations,
            advance_codepoints.len,
            @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms,
            ns_per_call,
        },
    );
}

fn makeParagraph(allocator: std.mem.Allocator, cluster_count: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);

    var n: usize = 0;
    while (n < cluster_count) {
        for (cluster_pattern) |cluster| {
            if (n >= cluster_count) break;
            try text.appendSlice(allocator, cluster);
            n += 1;
        }
    }

    return text.toOwnedSlice(allocator);
}
