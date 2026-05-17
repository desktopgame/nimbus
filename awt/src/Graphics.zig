//! High-level 2D drawing API. Component paint methods receive a `Graphics`
//! value and call drawing operations on it. See `awt/doc/graphics.md`.
//!
//! Coordinate system: top-left origin, x right, y down, pixel units (float).
//! Internally each draw call translates local → pixel (add `origin`) →
//! NDC (y up) → push to `VertexRing` → bind + draw.

const std = @import("std");
const Buffer = @import("Buffer.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const Font = @import("Font.zig");
const GlyphAtlas = @import("GlyphAtlas.zig");
const Image = @import("Image.zig");
const QuadIndexBuffer = @import("QuadIndexBuffer.zig");
const UniformBuffer = @import("UniformBuffer.zig");
const VertexRing = @import("VertexRing.zig");
const programs = @import("programs.zig");

const Graphics = @This();

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn right(self: Rect) f32 {
        return self.x + self.width;
    }
    pub fn bottom(self: Rect) f32 {
        return self.y + self.height;
    }
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }
    pub fn bytes(r: u8, g: u8, b: u8, a: u8) Color {
        const inv: f32 = 1.0 / 255.0;
        return .{
            .r = @as(f32, @floatFromInt(r)) * inv,
            .g = @as(f32, @floatFromInt(g)) * inv,
            .b = @as(f32, @floatFromInt(b)) * inv,
            .a = @as(f32, @floatFromInt(a)) * inv,
        };
    }

    fn asArray(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }
};

pub const TextFont = struct {
    face: Font,
    pixel_size: i32,

    pub fn measureString(self: TextFont, s: []const u8) Font.TextSize {
        return self.face.measureString(s, self.pixel_size);
    }
};

/// Long-lived rendering resources shared across all `Graphics` values for a
/// frame. The host (Application / hello main) owns these for the program's
/// lifetime; Graphics only borrows.
pub const Context = struct {
    vertex_ring: *VertexRing,
    uniforms: *UniformBuffer,
    quad_index: *QuadIndexBuffer,
    atlas: *GlyphAtlas,
    color_program: *programs.Color,
    image_program: *programs.Image,
    rrect_program: *programs.RoundedRect,
    text_program: *programs.Text,
};

cb: CommandBuffer,
ctx: *Context,

// Logical window dimensions (points) used for pixel → NDC conversion. User
// drawing coordinates are interpreted in these units, so a 100-pt rectangle
// renders the same physical size regardless of display DPI.
window_w: i32,
window_h: i32,

// Framebuffer pixel dimensions. Differs from `window_w/h` on HiDPI displays
// (e.g. Retina 2x → 2× the logical dimensions). Only the scissor path uses
// these — the GPU viewport spans the whole framebuffer, so NDC → pixel
// mapping happens for free.
fb_w: i32,
fb_h: i32,

// Translation accumulated through nested `clip` calls. local + origin = pixel.
origin_x: f32,
origin_y: f32,

// Clip rect in absolute logical coordinates (points), matching user inputs.
// `applyScissor` scales these to framebuffer pixels before binding.
clip_rect: Rect,

current_color: Color,
current_font: ?TextFont,

pub fn init(cb: CommandBuffer, ctx: *Context, window_w: i32, window_h: i32, fb_w: i32, fb_h: i32) Graphics {
    const ww: f32 = @floatFromInt(window_w);
    const wh: f32 = @floatFromInt(window_h);
    return .{
        .cb = cb,
        .ctx = ctx,
        .window_w = window_w,
        .window_h = window_h,
        .fb_w = fb_w,
        .fb_h = fb_h,
        .origin_x = 0,
        .origin_y = 0,
        .clip_rect = .{ .x = 0, .y = 0, .width = ww, .height = wh },
        .current_color = Color.rgba(0, 0, 0, 1),
        .current_font = null,
    };
}

/// Return a new Graphics with origin translated to `(r.x, r.y)` in the
/// current local space, and clip intersected with `r` (in absolute pixels).
/// Java AWT `Graphics.create(x, y, w, h)` semantics. The parent Graphics is
/// unchanged.
pub fn clip(self: Graphics, r: Rect) Graphics {
    var child = self;
    child.origin_x = self.origin_x + r.x;
    child.origin_y = self.origin_y + r.y;
    // child clip in absolute pixels, intersected with parent clip.
    const ax = self.origin_x + r.x;
    const ay = self.origin_y + r.y;
    const ax2 = ax + r.width;
    const ay2 = ay + r.height;
    const px2 = self.clip_rect.right();
    const py2 = self.clip_rect.bottom();
    const cx = @max(ax, self.clip_rect.x);
    const cy = @max(ay, self.clip_rect.y);
    const cx2 = @min(ax2, px2);
    const cy2 = @min(ay2, py2);
    child.clip_rect = .{
        .x = cx,
        .y = cy,
        .width = @max(0, cx2 - cx),
        .height = @max(0, cy2 - cy),
    };
    return child;
}

pub fn setColor(self: *Graphics, color: Color) void {
    self.current_color = color;
}
pub fn getColor(self: Graphics) Color {
    return self.current_color;
}

pub fn setFont(self: *Graphics, font: TextFont) void {
    self.current_font = font;
}
pub fn getFont(self: Graphics) ?TextFont {
    return self.current_font;
}

// ─────────────────────────── internal helpers ────────────────────────────

fn applyScissor(self: Graphics) void {
    const sx = @as(f32, @floatFromInt(self.fb_w)) / @as(f32, @floatFromInt(self.window_w));
    const sy = @as(f32, @floatFromInt(self.fb_h)) / @as(f32, @floatFromInt(self.window_h));
    const x: i32 = @intFromFloat(@floor(self.clip_rect.x * sx));
    const y: i32 = @intFromFloat(@floor(self.clip_rect.y * sy));
    const w: i32 = @intFromFloat(@ceil(self.clip_rect.width * sx));
    const h: i32 = @intFromFloat(@ceil(self.clip_rect.height * sy));
    self.cb.setScissor(x, y, @max(0, w), @max(0, h));
}

fn pxToNdcX(self: Graphics, px: f32) f32 {
    return px / @as(f32, @floatFromInt(self.window_w)) * 2.0 - 1.0;
}
fn pxToNdcY(self: Graphics, px: f32) f32 {
    return 1.0 - px / @as(f32, @floatFromInt(self.window_h)) * 2.0;
}

// ─────────────────────────── draw API ────────────────────────────────────

pub fn fillRect(self: *Graphics, r: Rect) void {
    self.fillRectColor(r, self.current_color);
}

fn fillRectColor(self: *Graphics, r: Rect, color: Color) void {
    const left = self.origin_x + r.x;
    const top = self.origin_y + r.y;
    const right = left + r.width;
    const bottom = top + r.height;
    const x0 = self.pxToNdcX(left);
    const x1 = self.pxToNdcX(right);
    const y0 = self.pxToNdcY(top);
    const y1 = self.pxToNdcY(bottom);
    const verts = [_]f32{
        x0, y0, // TL
        x0, y1, // BL
        x1, y1, // BR
        x1, y0, // TR
    };
    const vh = self.ctx.vertex_ring.pushBytes(std.mem.sliceAsBytes(verts[0..])) catch return;
    const uh = self.ctx.uniforms.push(programs.Color.Uniforms{ .color = color.asArray() }) catch return;

    self.applyScissor();
    self.ctx.color_program.bind(self.cb);
    self.ctx.color_program.bindUniforms(self.cb, self.ctx.uniforms.*, uh);
    self.cb.bindVertexBuffer(self.ctx.vertex_ring.buffer, 0, 2 * @sizeOf(f32), vh.offset);
    self.cb.bindIndexBuffer(self.ctx.quad_index.buffer, .u16, 0);
    self.cb.drawIndexed(6, 0, 0);
}

pub fn drawRect(self: *Graphics, r: Rect) void {
    const t: f32 = 1.0;
    const color = self.current_color;
    // top / bottom span the full width; left / right span only the interior
    // to avoid double-painting corners.
    self.fillRectColor(.{ .x = r.x, .y = r.y, .width = r.width, .height = t }, color);
    self.fillRectColor(.{ .x = r.x, .y = r.y + r.height - t, .width = r.width, .height = t }, color);
    self.fillRectColor(.{ .x = r.x, .y = r.y + t, .width = t, .height = r.height - 2 * t }, color);
    self.fillRectColor(.{ .x = r.x + r.width - t, .y = r.y + t, .width = t, .height = r.height - 2 * t }, color);
}

// ─── SDF helpers ─────────────────────────────────────────────────────────

const sdf_margin: f32 = 4.0;

fn sdfQuad(self: *Graphics, r: Rect, color: Color, corner_radius: f32, thickness: f32) void {
    const half_w = r.width / 2.0;
    const half_h = r.height / 2.0;
    const cx = self.origin_x + r.x + half_w;
    const cy = self.origin_y + r.y + half_h;
    // Pad with margin so AA fade + outline tail (thickness/2 outside the
    // nominal edge) are not clipped at the cardinal points.
    const m = sdf_margin;
    const left = cx - half_w - m;
    const right = cx + half_w + m;
    const top = cy - half_h - m;
    const bottom = cy + half_h + m;
    const x0 = self.pxToNdcX(left);
    const x1 = self.pxToNdcX(right);
    const y0 = self.pxToNdcY(top);
    const y1 = self.pxToNdcY(bottom);
    // UV is scaled so the nominal shape edge is at ±1 and the margin extends
    // slightly past — matching the SDF shader's `uv * half_size` convention.
    const uv_x = (half_w + m) / half_w;
    const uv_y = (half_h + m) / half_h;
    const verts = [_]f32{
        x0, y0, -uv_x, -uv_y, // TL
        x0, y1, -uv_x, uv_y, // BL
        x1, y1, uv_x,  uv_y, // BR
        x1, y0, uv_x,  -uv_y, // TR
    };
    const vh = self.ctx.vertex_ring.pushBytes(std.mem.sliceAsBytes(verts[0..])) catch return;
    const uh = self.ctx.uniforms.push(programs.RoundedRect.Uniforms{
        .color = color.asArray(),
        .half_size = .{ half_w, half_h },
        .corner_radius = corner_radius,
        .thickness = thickness,
    }) catch return;

    self.applyScissor();
    self.ctx.rrect_program.bind(self.cb);
    self.ctx.rrect_program.bindUniforms(self.cb, self.ctx.uniforms.*, uh);
    self.cb.bindVertexBuffer(self.ctx.vertex_ring.buffer, 0, 4 * @sizeOf(f32), vh.offset);
    self.cb.bindIndexBuffer(self.ctx.quad_index.buffer, .u16, 0);
    self.cb.drawIndexed(6, 0, 0);
}

pub fn fillRoundRect(self: *Graphics, r: Rect, corner_radius: f32) void {
    self.sdfQuad(r, self.current_color, corner_radius, 0);
}

pub fn drawRoundRect(self: *Graphics, r: Rect, corner_radius: f32) void {
    self.sdfQuad(r, self.current_color, corner_radius, 1.0);
}

pub fn fillCircle(self: *Graphics, r: Rect) void {
    const radius = @min(r.width, r.height) / 2.0;
    self.sdfQuad(r, self.current_color, radius, 0);
}

pub fn drawCircle(self: *Graphics, r: Rect) void {
    const radius = @min(r.width, r.height) / 2.0;
    self.sdfQuad(r, self.current_color, radius, 1.0);
}

// ─── Image / text ────────────────────────────────────────────────────────

pub fn drawImage(self: *Graphics, image: Image, x: f32, y: f32) void {
    const left = self.origin_x + x;
    const top = self.origin_y + y;
    const right = left + @as(f32, @floatFromInt(image.width));
    const bottom = top + @as(f32, @floatFromInt(image.height));
    const x0 = self.pxToNdcX(left);
    const x1 = self.pxToNdcX(right);
    const y0 = self.pxToNdcY(top);
    const y1 = self.pxToNdcY(bottom);
    const verts = [_]f32{
        x0, y0, 0, 0, // TL
        x0, y1, 0, 1, // BL
        x1, y1, 1, 1, // BR
        x1, y0, 1, 0, // TR
    };
    const vh = self.ctx.vertex_ring.pushBytes(std.mem.sliceAsBytes(verts[0..])) catch return;
    const uh = self.ctx.uniforms.push(programs.Image.Uniforms{ .tint = .{ 1, 1, 1, 1 } }) catch return;

    self.applyScissor();
    self.ctx.image_program.bind(self.cb);
    self.ctx.image_program.bindUniforms(self.cb, self.ctx.uniforms.*, uh);
    self.cb.bindTexture(image.texture, 0);
    self.cb.bindVertexBuffer(self.ctx.vertex_ring.buffer, 0, 4 * @sizeOf(f32), vh.offset);
    self.cb.bindIndexBuffer(self.ctx.quad_index.buffer, .u16, 0);
    self.cb.drawIndexed(6, 0, 0);
}

/// Draw a single line of UTF-8 text. `(x, y)` is the top-left of the bounding
/// box (graphics.md: top-of-bbox派). `\n` is ignored; complex layout is the
/// caller's responsibility.
pub fn drawString(self: *Graphics, s: []const u8, x: f32, y: f32) void {
    const font = self.current_font orelse return;
    font.face.setPixelSize(font.pixel_size);
    const ascender = font.face.metrics().ascender;
    const baseline_px_y = self.origin_y + y + ascender;
    const pen_px_x_start = self.origin_x + x;

    var stage_verts: [16]f32 = undefined;
    var pen_px_x: f32 = pen_px_x_start;
    var emitted: u32 = 0;
    const ring = self.ctx.vertex_ring;
    var first_vh: ?VertexRing.Handle = null;

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
        i += byte_len;
        if (cp == '\n') continue;

        const info = self.ctx.atlas.getOrRasterize(font.face, font.pixel_size, cp) catch continue;
        if (info.bitmap_width > 0 and info.bitmap_height > 0) {
            const w_f: f32 = @floatFromInt(info.bitmap_width);
            const h_f: f32 = @floatFromInt(info.bitmap_height);
            const left = pen_px_x + info.bearing_x;
            const top = baseline_px_y - info.bearing_y;
            const x0 = self.pxToNdcX(left);
            const x1 = self.pxToNdcX(left + w_f);
            const y0 = self.pxToNdcY(top);
            const y1 = self.pxToNdcY(top + h_f);
            stage_verts = .{
                x0, y0, info.u0, info.v0,
                x0, y1, info.u0, info.v1,
                x1, y1, info.u1, info.v1,
                x1, y0, info.u1, info.v0,
            };
            const vh = ring.pushBytes(std.mem.sliceAsBytes(stage_verts[0..])) catch break;
            if (first_vh == null) first_vh = vh;
            emitted += 1;
            if (emitted >= self.ctx.quad_index.max_quads) break;
        }
        pen_px_x += info.advance_x;
    }
    if (emitted == 0) return;

    const uh = self.ctx.uniforms.push(programs.Text.Uniforms{ .color = self.current_color.asArray() }) catch return;
    self.applyScissor();
    self.ctx.text_program.bind(self.cb);
    self.ctx.text_program.bindUniforms(self.cb, self.ctx.uniforms.*, uh);
    self.cb.bindTexture(self.ctx.atlas.texture, 0);
    self.cb.bindVertexBuffer(self.ctx.vertex_ring.buffer, 0, 4 * @sizeOf(f32), first_vh.?.offset);
    self.cb.bindIndexBuffer(self.ctx.quad_index.buffer, .u16, 0);
    self.cb.drawIndexed(@intCast(emitted * 6), 0, 0);
}
