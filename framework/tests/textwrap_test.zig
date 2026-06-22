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
    var f = try nimbus.awt.Font.init(nimbus.noto.noto_sans_jp_regular, 0);
    f.setPixelSize(16);
    return f;
}

fn widthOf(f: nimbus.awt.Font, s: []const u8, end: usize) f32 {
    return f.advanceOfRange(s, 0, end);
}

fn midWidth(f: nimbus.awt.Font, s: []const u8, low: usize, high: usize) f32 {
    return (widthOf(f, s, low) + widthOf(f, s, high)) / 2.0;
}

test "textwrap Latin breaks only after space tab hyphen slash" {
    var f = try initTestFont();
    defer f.deinit();

    const space = "hello world";
    try std.testing.expectEqual("hello ".len, nimbus.awt.textwrap.wrapSegment(f, space, 0, space.len, midWidth(f, space, "hello ".len, "hello w".len)));

    const tab = "hello\tworld";
    try std.testing.expectEqual("hello\t".len, nimbus.awt.textwrap.wrapSegment(f, tab, 0, tab.len, midWidth(f, tab, "hello\t".len, "hello\tw".len)));

    const hyphen = "alpha-beta";
    try std.testing.expectEqual("alpha-".len, nimbus.awt.textwrap.wrapSegment(f, hyphen, 0, hyphen.len, midWidth(f, hyphen, "alpha-".len, "alpha-b".len)));

    const slash = "src/main";
    try std.testing.expectEqual("src/".len, nimbus.awt.textwrap.wrapSegment(f, slash, 0, slash.len, midWidth(f, slash, "src/".len, "src/m".len)));

    const dotted = "file report.txt";
    try std.testing.expectEqual("file ".len, nimbus.awt.textwrap.wrapSegment(f, dotted, 0, dotted.len, midWidth(f, dotted, "file report.".len, "file report.t".len)));

    const decimal = "v 3.14";
    try std.testing.expectEqual("v ".len, nimbus.awt.textwrap.wrapSegment(f, decimal, 0, decimal.len, midWidth(f, decimal, "v 3.".len, "v 3.1".len)));
}

test "textwrap CJK breaks at grapheme boundaries without spaces" {
    var f = try initTestFont();
    defer f.deinit();

    const s = "日本語入力";
    const p = "日本".len;
    try std.testing.expectEqual(p, nimbus.awt.textwrap.wrapSegment(f, s, 0, s.len, midWidth(f, s, p, "日本語".len)));

    const mixed = "abc日本";
    try std.testing.expectEqual("abc".len, nimbus.awt.textwrap.wrapSegment(f, mixed, 0, mixed.len, midWidth(f, mixed, "abc".len, "abc日".len)));
}

test "textwrap never splits combining ZWJ or regional indicator clusters" {
    var f = try initTestFont();
    defer f.deinit();

    const combining_cases = [_]struct { text: []const u8, partial: usize, full: usize }{
        .{ .text = "a" ++ "e\u{0301}" ++ "b", .partial = "ae".len, .full = "ae\u{0301}".len },
        .{ .text = "a" ++ "e\u{20DD}" ++ "b", .partial = "ae".len, .full = "ae\u{20DD}".len },
        .{ .text = "a" ++ "\u{0915}\u{093E}" ++ "b", .partial = "a\u{0915}".len, .full = "a\u{0915}\u{093E}".len },
        .{ .text = "a" ++ "\u{0915}\u{093F}" ++ "b", .partial = "a\u{0915}".len, .full = "a\u{0915}\u{093F}".len },
    };
    var covered_combining = false;
    for (combining_cases) |case| {
        if (widthOf(f, case.text, case.partial) < widthOf(f, case.text, case.full)) {
            try std.testing.expectEqual("a".len, nimbus.awt.textwrap.wrapSegment(f, case.text, 0, case.text.len, midWidth(f, case.text, case.partial, case.full)));
            covered_combining = true;
            break;
        }
    }
    try std.testing.expect(covered_combining);

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const zwj = "a" ++ family ++ "b";
    try std.testing.expectEqual("a".len, nimbus.awt.textwrap.wrapSegment(f, zwj, 0, zwj.len, midWidth(f, zwj, "a".len + "\u{1F468}".len, "a".len + family.len)));

    const flag = "\u{1F1EF}\u{1F1F5}";
    const flags = "a" ++ flag ++ "b";
    try std.testing.expectEqual("a".len, nimbus.awt.textwrap.wrapSegment(f, flags, 0, flags.len, midWidth(f, flags, "a".len + "\u{1F1EF}".len, "a".len + flag.len)));
}

test "textwrap forced break still advances at least one cluster" {
    var f = try initTestFont();
    defer f.deinit();

    const s = "\u{65E5}\u{672C}";
    try std.testing.expectEqual("\u{65E5}".len, nimbus.awt.textwrap.wrapSegment(f, s, 0, s.len, 1.0));
}

test "textwrap oidashi avoids line-start closing punctuation" {
    var f = try initTestFont();
    defer f.deinit();

    const s = "あい、う";
    const raw = "あい".len;
    try std.testing.expectEqual("あ".len, nimbus.awt.textwrap.wrapSegment(f, s, 0, s.len, midWidth(f, s, raw, "あい、".len)));
}

test "textwrap oidashi avoids line-end opening punctuation" {
    var f = try initTestFont();
    defer f.deinit();

    const s = "あ（い";
    const raw = "あ（".len;
    try std.testing.expectEqual("あ".len, nimbus.awt.textwrap.wrapSegment(f, s, 0, s.len, midWidth(f, s, raw, s.len)));
}

test "textwrap oidashi gives up after MAX_OIDASHI clusters" {
    var f = try initTestFont();
    defer f.deinit();

    const s = "あ）））い";
    const raw = "あ））".len;
    try std.testing.expectEqual(raw, nimbus.awt.textwrap.wrapSegment(f, s, 0, s.len, midWidth(f, s, raw, "あ）））".len)));
}
