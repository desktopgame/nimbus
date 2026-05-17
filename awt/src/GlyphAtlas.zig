//! Single R8 texture that caches rasterized glyphs across fonts and pixel
//! sizes. Glyphs are packed left-to-right into horizontal shelves; when the
//! atlas fills up, it is cleared in one shot and starts re-packing from the
//! top-left. CLAUDE.md text-rendering section.
//!
//! Returned `GlyphInfo` values are only valid until the next `getOrRasterize`
//! that triggers a clear; in typical GUI usage the working glyph set is small
//! and clears are rare, but callers building per-frame vertex buffers should
//! re-query rather than caching across frames.

const std = @import("std");
const c = @import("c");
const Device = @import("Device.zig");
const Texture = @import("Texture.zig");
const Font = @import("Font.zig");

const GlyphAtlas = @This();

pub const GlyphInfo = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    bitmap_width: i32,
    bitmap_height: i32,
    bearing_x: f32,
    bearing_y: f32,
    advance_x: f32,
};

pub const Key = struct {
    face: *c.struct_nmFont,
    pixel_size: i32,
    codepoint: u32,
};

const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.face));
        h.update(std.mem.asBytes(&k.pixel_size));
        h.update(std.mem.asBytes(&k.codepoint));
        return h.final();
    }
    pub fn eql(_: KeyCtx, a: Key, b: Key) bool {
        return a.face == b.face and a.pixel_size == b.pixel_size and a.codepoint == b.codepoint;
    }
};

const Cache = std.HashMap(Key, GlyphInfo, KeyCtx, std.hash_map.default_max_load_percentage);

allocator: std.mem.Allocator,
texture: Texture,
size: i32,
cursor_x: i32,
cursor_y: i32,
shelf_height: i32,
cache: Cache,

pub fn init(allocator: std.mem.Allocator, device: Device, size: i32) !GlyphAtlas {
    var texture = try Texture.init(device, size, size, .r8);
    errdefer texture.deinit();
    return .{
        .allocator = allocator,
        .texture = texture,
        .size = size,
        .cursor_x = 0,
        .cursor_y = 0,
        .shelf_height = 0,
        .cache = Cache.init(allocator),
    };
}

pub fn deinit(self: *GlyphAtlas) void {
    self.cache.deinit();
    self.texture.deinit();
    self.* = undefined;
}

pub fn getOrRasterize(
    self: *GlyphAtlas,
    font: Font,
    pixel_size: i32,
    codepoint: u32,
) !GlyphInfo {
    const key = Key{
        .face = font.handle,
        .pixel_size = pixel_size,
        .codepoint = codepoint,
    };
    if (self.cache.get(key)) |info| return info;

    font.setPixelSize(pixel_size);
    const glyph = try font.rasterize(codepoint);
    const w = glyph.metrics.bitmap_width;
    const h = glyph.metrics.bitmap_height;

    const pos = self.alloc(w, h) orelse blk: {
        self.clear();
        break :blk self.alloc(w, h) orelse return error.GlyphTooLargeForAtlas;
    };

    if (w > 0 and h > 0) {
        self.texture.uploadRegion(
            pos.x,
            pos.y,
            w,
            h,
            glyph.bitmap,
            @intCast(glyph.metrics.bitmap_pitch),
        );
    }

    const size_f: f32 = @floatFromInt(self.size);
    const info = GlyphInfo{
        .u0 = @as(f32, @floatFromInt(pos.x)) / size_f,
        .v0 = @as(f32, @floatFromInt(pos.y)) / size_f,
        .u1 = @as(f32, @floatFromInt(pos.x + w)) / size_f,
        .v1 = @as(f32, @floatFromInt(pos.y + h)) / size_f,
        .bitmap_width = w,
        .bitmap_height = h,
        .bearing_x = @floatFromInt(glyph.metrics.bearing_x),
        .bearing_y = @floatFromInt(glyph.metrics.bearing_y),
        .advance_x = glyph.metrics.advance_x,
    };
    try self.cache.put(key, info);
    return info;
}

const Slot = struct { x: i32, y: i32 };

fn alloc(self: *GlyphAtlas, w: i32, h: i32) ?Slot {
    if (w > self.size or h > self.size) return null;
    if (self.cursor_x + w > self.size) {
        self.cursor_y += self.shelf_height;
        self.cursor_x = 0;
        self.shelf_height = 0;
    }
    if (self.cursor_y + h > self.size) return null;
    if (h > self.shelf_height) self.shelf_height = h;
    const result = Slot{ .x = self.cursor_x, .y = self.cursor_y };
    self.cursor_x += w;
    return result;
}

fn clear(self: *GlyphAtlas) void {
    self.cache.clearRetainingCapacity();
    self.cursor_x = 0;
    self.cursor_y = 0;
    self.shelf_height = 0;
    // Texture pixels keep whatever was there; they are overwritten the next
    // time a glyph is uploaded into the freshly-allocated region.
}
