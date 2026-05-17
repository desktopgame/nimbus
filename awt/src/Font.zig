//! Font face. Thin wrapper over freetype FT_Face — exposes per-glyph
//! rasterization and metrics. Atlas / text layout / drawing is the caller's
//! responsibility.

const c = @import("c");

const Font = @This();

pub const GlyphMetrics = struct {
    bitmap_width: i32,
    bitmap_height: i32,
    bitmap_pitch: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance_x: f32,
};

pub const FontMetrics = struct {
    ascender: f32,
    descender: f32,
    line_gap: f32,
    line_height: f32,
};

handle: *c.struct_nmFont,

/// `data` must outlive the font (freetype holds the pointer internally).
/// `@embedFile` output is fine since it lives in `.rodata` for the program's life.
pub fn init(data: []const u8, face_index: i32) !Font {
    const h = c.nmCreateFont(data.ptr, data.len, face_index)
        orelse return error.FontCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Font) void {
    c.nmDestroyFont(self.handle);
    self.handle = undefined;
}

pub fn setPixelSize(self: Font, pixel_size: i32) void {
    c.nmSetFontPixelSize(self.handle, pixel_size);
}

pub fn metrics(self: Font) FontMetrics {
    var m: c.nmFontMetrics = undefined;
    c.nmGetFontMetrics(self.handle, &m);
    return .{
        .ascender = m.ascender,
        .descender = m.descender,
        .line_gap = m.line_gap,
        .line_height = m.line_height,
    };
}

/// Returned bitmap slice points into the font's internal freetype scratch
/// buffer. It is invalidated by the next `rasterize` call on the same font.
/// Caller must copy out before that.
pub fn rasterize(self: Font, codepoint: u32) !struct {
    metrics: GlyphMetrics,
    bitmap: []const u8,
} {
    var m: c.nmGlyphMetrics = undefined;
    var bmp: [*c]const u8 = null;
    if (c.nmRasterizeGlyph(self.handle, codepoint, &m, &bmp) != 0) {
        return error.GlyphRasterizeFailed;
    }
    // Use pitch (not width) for the buffer span — freetype may pad rows.
    const len: usize = @intCast(m.bitmap_pitch * m.bitmap_height);
    const slice: []const u8 = if (len == 0) &.{} else bmp[0..len];
    return .{
        .metrics = .{
            .bitmap_width = m.bitmap_width,
            .bitmap_height = m.bitmap_height,
            .bitmap_pitch = m.bitmap_pitch,
            .bearing_x = m.bearing_x,
            .bearing_y = m.bearing_y,
            .advance_x = m.advance_x,
        },
        .bitmap = slice,
    };
}

pub fn glyphAdvance(self: Font, codepoint: u32) f32 {
    return c.nmGetGlyphAdvance(self.handle, codepoint);
}

pub fn hasGlyph(self: Font, codepoint: u32) bool {
    return c.nmFontHasGlyph(self.handle, codepoint);
}
