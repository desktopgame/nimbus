const std = @import("std");
const nimbus = @import("nimbus");

var awt_initialized: bool = false;

fn ensureAwt() !void {
    if (awt_initialized) return;
    try nimbus.awt.init();
    awt_initialized = true;
}

fn initTestFont() !nimbus.awt.Font {
    try ensureAwt();
    var f = try nimbus.awt.Font.init(std.testing.allocator, nimbus.noto.noto_sans_jp_regular, 0);
    f.setPixelSize(16);
    return f;
}

test "font advance cache is shared by value copies and keyed by pixel size" {
    var f = try initTestFont();
    defer f.deinit();

    const copied = f;
    const small = f.glyphAdvance('A');
    try std.testing.expectEqual(small, f.glyphAdvance('A'));

    copied.setPixelSize(32);
    const large = f.glyphAdvance('A');
    try std.testing.expect(large > small);
    try std.testing.expectEqual(large, copied.glyphAdvance('A'));

    f.setPixelSize(16);
    try std.testing.expectEqual(small, copied.glyphAdvance('A'));
}

test "incremental cluster advances match from-start width" {
    var f = try initTestFont();
    defer f.deinit();

    const s = "Nimbus wraps text \u{65E5}\u{672C}\u{8A9E} UI";
    var pos: usize = 0;
    var incremental: f32 = 0;
    while (pos < s.len) {
        const next = nimbus.awt.grapheme.nextGraphemeBoundary(s, pos);
        const cluster_end = @min(next, s.len);
        incremental += f.advanceOfRange(s, pos, cluster_end);
        pos = cluster_end;
    }

    try std.testing.expectEqual(f.advanceOfRange(s, 0, s.len), incremental);
}
