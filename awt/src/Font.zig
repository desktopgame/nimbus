//! Font face. Thin wrapper over freetype FT_Face — exposes per-glyph
//! rasterization and metrics. Atlas / text layout / drawing is the caller's
//! responsibility.

const std = @import("std");
const c = @import("c");

const Font = @This();

const advance_cache_capacity = 16 * 1024;

const AdvanceEntry = struct {
    valid: bool = false,
    pixel_size: i32 = 0,
    codepoint: u32 = 0,
    advance: f32 = 0,
};

const AdvanceCache = struct {
    allocator: std.mem.Allocator,
    pixel_size: i32 = 0,
    entries: [advance_cache_capacity]AdvanceEntry = [_]AdvanceEntry{.{}} ** advance_cache_capacity,

    fn init(allocator: std.mem.Allocator) AdvanceCache {
        return .{ .allocator = allocator };
    }

    fn getOrLoad(self: *AdvanceCache, handle: *c.struct_nmFont, codepoint: u32) f32 {
        const idx = cacheIndex(self.pixel_size, codepoint);
        const entry = &self.entries[idx];
        if (entry.valid and entry.pixel_size == self.pixel_size and entry.codepoint == codepoint) {
            return entry.advance;
        }

        const advance = c.nmGetGlyphAdvance(handle, codepoint);
        entry.* = .{
            .valid = true,
            .pixel_size = self.pixel_size,
            .codepoint = codepoint,
            .advance = advance,
        };
        return advance;
    }
};

fn cacheIndex(pixel_size: i32, codepoint: u32) usize {
    const size_bits: u32 = @bitCast(pixel_size);
    var h = codepoint *% 16_777_619;
    h ^= size_bits *% 2_166_136_261;
    h ^= h >> 16;
    return @as(usize, h) & (advance_cache_capacity - 1);
}

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

pub const TextSize = struct {
    width: f32,
    height: f32,
};

handle: *c.struct_nmFont,
adv_cache: *AdvanceCache,

/// `data` must outlive the font (freetype holds the pointer internally).
/// `@embedFile` output is fine since it lives in `.rodata` for the program's life.
pub fn init(allocator: std.mem.Allocator, data: []const u8, face_index: i32) !Font {
    const h = c.nmCreateFont(data.ptr, data.len, face_index) orelse return error.FontCreateFailed;
    errdefer c.nmDestroyFont(h);

    const cache = try allocator.create(AdvanceCache);
    cache.* = AdvanceCache.init(allocator);
    return .{ .handle = h, .adv_cache = cache };
}

pub fn deinit(self: *Font) void {
    const allocator = self.adv_cache.allocator;
    allocator.destroy(self.adv_cache);
    c.nmDestroyFont(self.handle);
    self.handle = undefined;
    self.adv_cache = undefined;
}

pub fn setPixelSize(self: Font, pixel_size: i32) void {
    c.nmSetFontPixelSize(self.handle, pixel_size);
    self.adv_cache.pixel_size = pixel_size;
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
    return self.adv_cache.getOrLoad(self.handle, codepoint);
}

/// Sum glyph advances for the UTF-8 byte range [start, end). This preserves
/// the current per-codepoint measurement model while centralizing the seam for
/// future shaping-backed measurement.
pub fn advanceOfRange(self: Font, bytes: []const u8, start: usize, end: usize) f32 {
    const a = @min(start, bytes.len);
    const b = @min(@max(end, a), bytes.len);

    var x: f32 = 0;
    var i = a;
    while (i < b) {
        const byte_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > b) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + byte_len]) catch {
            i += byte_len;
            continue;
        };
        x += self.glyphAdvance(cp);
        i += byte_len;
    }
    return x;
}

/// Return the byte offset selected by x using the existing half-advance split
/// behavior. The returned offset is a UTF-8 codepoint boundary; callers that
/// need grapheme-cluster carets should snap it separately.
pub fn byteAtX(self: Font, bytes: []const u8, x: f32) usize {
    var cur_x: f32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + byte_len]) catch {
            i += byte_len;
            continue;
        };
        const adv = self.glyphAdvance(cp);
        if (x < cur_x + adv * 0.5) return i;
        cur_x += adv;
        i += byte_len;
    }
    return bytes.len;
}

pub fn hasGlyph(self: Font, codepoint: u32) bool {
    return c.nmFontHasGlyph(self.handle, codepoint);
}

/// Single-line width + font line_height. `\n` is ignored (CLAUDE.md: text
/// layout / wrapping lives above this layer). Bytes must be valid UTF-8;
/// invalid sequences are skipped.
pub fn measureString(self: Font, s: []const u8, pixel_size: i32) TextSize {
    self.setPixelSize(pixel_size);
    var width: f32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + byte_len]) catch {
            i += byte_len;
            continue;
        };
        if (cp != '\n') width += self.glyphAdvance(cp);
        i += byte_len;
    }
    return .{ .width = width, .height = self.metrics().line_height };
}
