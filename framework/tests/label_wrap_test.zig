const std = @import("std");
const nimbus = @import("nimbus");

var awt_initialized: bool = false;

fn ensureAwt() !void {
    if (awt_initialized) return;
    try nimbus.awt.init();
    awt_initialized = true;
}

fn initTestFont() !nimbus.awt.Graphics.TextFont {
    try ensureAwt();
    return .{
        .face = try nimbus.awt.Font.init(nimbus.noto.noto_sans_jp_regular, 0),
        .pixel_size = 16,
    };
}

fn deinitTestFont(font: *nimbus.awt.Graphics.TextFont) void {
    font.face.deinit();
}

fn widthOf(font: nimbus.awt.Graphics.TextFont, text: []const u8, end: usize) f32 {
    font.face.setPixelSize(font.pixel_size);
    return font.face.advanceOfRange(text, 0, end);
}

fn midWidth(font: nimbus.awt.Graphics.TextFont, text: []const u8, low: usize, high: usize) f32 {
    return (widthOf(font, text, low) + widthOf(font, text, high)) / 2.0;
}

fn expectApprox(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.001);
}

test "Label line_wrap exposes height-for-width and grows when narrowed" {
    var font = try initTestFont();
    defer deinitTestFont(&font);

    const text = "alpha beta beta";
    const label = try nimbus.Label.create(std.testing.allocator, text, font, nimbus.Theme.default.text);
    defer label.component.vtable.destroy(&label.component, std.testing.allocator);

    try std.testing.expect(!label.getLineWrap());
    try std.testing.expect(label.component.size_query == null);
    try std.testing.expect(label.component.scrollable == null);

    const one_line_h = label.component.min_size.height;
    label.setLineWrap(true);
    try std.testing.expect(label.getLineWrap());
    try std.testing.expect(label.component.size_query != null);
    try std.testing.expect(label.component.scrollable.?.tracks_viewport_width);

    const wide_h = label.component.size_query.?.minHeightForWidth(&label.component, label.component.min_size.width);
    const narrow_w = midWidth(font, text, "alpha ".len, "alpha b".len);
    const narrow_h = label.component.size_query.?.minHeightForWidth(&label.component, narrow_w);

    try expectApprox(one_line_h, wide_h);
    try std.testing.expect(narrow_h > wide_h);
}

test "Label line_wrap reports expected visual line count for known width" {
    var font = try initTestFont();
    defer deinitTestFont(&font);

    const text = "alpha beta beta";
    const label = try nimbus.Label.create(std.testing.allocator, text, font, nimbus.Theme.default.text);
    defer label.component.vtable.destroy(&label.component, std.testing.allocator);
    label.setLineWrap(true);

    font.face.setPixelSize(font.pixel_size);
    const line_h = font.face.metrics().line_height;
    const wrap_w = midWidth(font, text, "alpha ".len, "alpha b".len);
    const h = label.component.size_query.?.minHeightForWidth(&label.component, wrap_w);

    try expectApprox(line_h * 3, h);
}

test "Label no-wrap default keeps single-line measurement" {
    var font = try initTestFont();
    defer deinitTestFont(&font);

    const text = "alpha beta gamma";
    const label = try nimbus.Label.create(std.testing.allocator, text, font, nimbus.Theme.default.text);
    defer label.component.vtable.destroy(&label.component, std.testing.allocator);

    const measured = font.measureString(text);
    try expectApprox(measured.width, label.component.min_size.width);
    try expectApprox(measured.height, label.component.min_size.height);
    try std.testing.expect(!label.getLineWrap());
    try std.testing.expect(label.component.size_query == null);
    try std.testing.expect(label.component.scrollable == null);
}
