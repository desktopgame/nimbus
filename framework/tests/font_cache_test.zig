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

test "wrapSegment measures incremental width from nonzero segment start" {
    var f = try initTestFont();
    defer f.deinit();

    const prefix = "wide prefix wide prefix ";
    const segment = "a e\u{0301} b";
    const text = prefix ++ segment;
    const start = prefix.len;
    const expected = start + "a e\u{0301} ".len;
    const too_far = text.len;
    const wrap_w = (f.advanceOfRange(text, start, expected) + f.advanceOfRange(text, start, too_far)) / 2.0;

    try std.testing.expectEqual(expected, nimbus.awt.textwrap.wrapSegment(f, text, start, text.len, wrap_w));
}
