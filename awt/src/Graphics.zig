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

pub const Insets = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
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

const Quad = struct {
    dst: Rect,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,

    fn empty() Quad {
        return .{
            .dst = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
        };
    }

    fn isEmpty(self: Quad) bool {
        return self.dst.width <= 0 or self.dst.height <= 0 or self.u0 >= self.u1 or self.v0 >= self.v1;
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
    gradient_program: *programs.Gradient,
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

/// True when the current clip would scissor everything away.
/// Draw methods use this to skip work entirely (DX12 logs a warning if
/// DrawIndexedInstanced is issued with an empty scissor — and the draw
/// produces no pixels anyway).
fn clipIsEmpty(self: Graphics) bool {
    return self.clip_rect.width <= 0 or self.clip_rect.height <= 0;
}

/// The visible (scissor) region expressed in this Graphics' *local* coordinate
/// space — i.e. the same space `drawString(s, x, y)` / `fillRect` take. A view
/// that draws many items (e.g. TextArea's lines) uses this to cull whatever
/// falls outside, so it doesn't push off-screen geometry into the shared
/// per-frame vertex ring (which is finite — overflowing it drops later draws).
pub fn clipLocalRect(self: Graphics) Rect {
    return .{
        .x = self.clip_rect.x - self.origin_x,
        .y = self.clip_rect.y - self.origin_y,
        .width = self.clip_rect.width,
        .height = self.clip_rect.height,
    };
}

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

fn clampedInsetsPair(a: f32, b: f32, limit: f32) struct { first: f32, second: f32 } {
    const first = @max(0, a);
    const second = @max(0, b);
    const total = first + second;
    if (limit <= 0 or total <= 0) return .{ .first = 0, .second = 0 };
    if (total <= limit) return .{ .first = first, .second = second };
    const scale = limit / total;
    return .{ .first = first * scale, .second = second * scale };
}

fn makeQuad(x0: f32, y0: f32, x1: f32, y1: f32, u_min: f32, v_min: f32, u_max: f32, v_max: f32) Quad {
    return .{
        .dst = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 },
        .u0 = u_min,
        .v0 = v_min,
        .u1 = u_max,
        .v1 = v_max,
    };
}

fn nineSliceRects(dst: Rect, insets: Insets, img_w: f32, img_h: f32) [9]Quad {
    if (dst.width <= 0 or dst.height <= 0 or img_w <= 0 or img_h <= 0) {
        return [_]Quad{Quad.empty()} ** 9;
    }

    const src_x = clampedInsetsPair(insets.left, insets.right, img_w);
    const src_y = clampedInsetsPair(insets.top, insets.bottom, img_h);
    const dst_x = clampedInsetsPair(src_x.first, src_x.second, dst.width);
    const dst_y = clampedInsetsPair(src_y.first, src_y.second, dst.height);

    const xs = [_]f32{ dst.x, dst.x + dst_x.first, dst.x + dst.width - dst_x.second, dst.x + dst.width };
    const ys = [_]f32{ dst.y, dst.y + dst_y.first, dst.y + dst.height - dst_y.second, dst.y + dst.height };
    const us = [_]f32{ 0, src_x.first / img_w, (img_w - src_x.second) / img_w, 1 };
    const vs = [_]f32{ 0, src_y.first / img_h, (img_h - src_y.second) / img_h, 1 };

    return .{
        makeQuad(xs[0], ys[0], xs[1], ys[1], us[0], vs[0], us[1], vs[1]),
        makeQuad(xs[1], ys[0], xs[2], ys[1], us[1], vs[0], us[2], vs[1]),
        makeQuad(xs[2], ys[0], xs[3], ys[1], us[2], vs[0], us[3], vs[1]),
        makeQuad(xs[0], ys[1], xs[1], ys[2], us[0], vs[1], us[1], vs[2]),
        makeQuad(xs[1], ys[1], xs[2], ys[2], us[1], vs[1], us[2], vs[2]),
        makeQuad(xs[2], ys[1], xs[3], ys[2], us[2], vs[1], us[3], vs[2]),
        makeQuad(xs[0], ys[2], xs[1], ys[3], us[0], vs[2], us[1], vs[3]),
        makeQuad(xs[1], ys[2], xs[2], ys[3], us[1], vs[2], us[2], vs[3]),
        makeQuad(xs[2], ys[2], xs[3], ys[3], us[2], vs[2], us[3], vs[3]),
    };
}

pub fn fillRect(self: *Graphics, r: Rect) void {
    self.fillRectColor(r, self.current_color);
}

pub fn fillGradientRect(self: *Graphics, r: Rect, top: Color, bottom: Color) void {
    if (self.clipIsEmpty()) return;
    const left = self.origin_x + r.x;
    const top_y = self.origin_y + r.y;
    const right = left + r.width;
    const bottom_y = top_y + r.height;
    const x0 = self.pxToNdcX(left);
    const x1 = self.pxToNdcX(right);
    const y0 = self.pxToNdcY(top_y);
    const y1 = self.pxToNdcY(bottom_y);
    const verts = [_]f32{
        x0, y0, 0, 0, // TL
        x0, y1, 0, 1, // BL
        x1, y1, 1, 1, // BR
        x1, y0, 1, 0, // TR
    };
    const vh = self.ctx.vertex_ring.pushBytes(std.mem.sliceAsBytes(verts[0..])) catch return;
    const uh = self.ctx.uniforms.push(programs.Gradient.Uniforms{
        .color0 = top.asArray(),
        .color1 = bottom.asArray(),
    }) catch return;

    self.applyScissor();
    self.ctx.gradient_program.bind(self.cb);
    self.ctx.gradient_program.bindUniforms(self.cb, self.ctx.uniforms.*, uh);
    self.cb.bindVertexBuffer(self.ctx.vertex_ring.buffer, 0, 4 * @sizeOf(f32), vh.offset);
    self.cb.bindIndexBuffer(self.ctx.quad_index.buffer, .u16, 0);
    self.cb.drawIndexed(6, 0, 0);
}

fn fillRectColor(self: *Graphics, r: Rect, color: Color) void {
    if (self.clipIsEmpty()) return;
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
    if (self.clipIsEmpty()) return;
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
        x1, y1, uv_x, uv_y, // BR
        x1, y0, uv_x, -uv_y, // TR
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
    self.drawImageScaled(
        image,
        x,
        y,
        @floatFromInt(image.width),
        @floatFromInt(image.height),
    );
}

/// Draw `image` into the rect (`x`, `y`, `w`, `h`). The full image
/// (UV 0..1) is sampled and the GPU's linear filter scales to fit.
/// Use when displaying the same image at different sizes (toolbar icon
/// vs menu icon vs preview) without preparing per-size assets.
pub fn drawImageScaled(self: *Graphics, image: Image, x: f32, y: f32, w: f32, h: f32) void {
    self.imageQuad(image, .{ .x = x, .y = y, .width = w, .height = h }, 0, 0, 1, 1, Color.rgba(1, 1, 1, 1));
}

/// Like `drawImageScaled`, but modulates the image by `tint`.
pub fn drawImageScaledTinted(self: *Graphics, image: Image, x: f32, y: f32, w: f32, h: f32, tint: Color) void {
    self.imageQuad(image, .{ .x = x, .y = y, .width = w, .height = h }, 0, 0, 1, 1, tint);
}

fn imageQuad(self: *Graphics, image: Image, dst: Rect, @"u0": f32, v0: f32, @"u1": f32, v1: f32, tint: Color) void {
    if (self.clipIsEmpty()) return;
    if (dst.width <= 0 or dst.height <= 0) return;
    const left = self.origin_x + dst.x;
    const top = self.origin_y + dst.y;
    const right = left + dst.width;
    const bottom = top + dst.height;
    const x0 = self.pxToNdcX(left);
    const x1 = self.pxToNdcX(right);
    const y0 = self.pxToNdcY(top);
    const y1 = self.pxToNdcY(bottom);
    const verts = [_]f32{
        x0, y0, @"u0", v0, // TL
        x0, y1, @"u0", v1, // BL
        x1, y1, @"u1", v1, // BR
        x1, y0, @"u1", v0, // TR
    };
    const vh = self.ctx.vertex_ring.pushBytes(std.mem.sliceAsBytes(verts[0..])) catch return;
    const uh = self.ctx.uniforms.push(programs.Image.Uniforms{ .tint = tint.asArray() }) catch return;

    self.applyScissor();
    self.ctx.image_program.bind(self.cb);
    self.ctx.image_program.bindUniforms(self.cb, self.ctx.uniforms.*, uh);
    self.cb.bindTexture(image.texture, 0);
    self.cb.bindVertexBuffer(self.ctx.vertex_ring.buffer, 0, 4 * @sizeOf(f32), vh.offset);
    self.cb.bindIndexBuffer(self.ctx.quad_index.buffer, .u16, 0);
    self.cb.drawIndexed(6, 0, 0);
}

pub fn drawTextureNineSlice(self: *Graphics, image: Image, dst: Rect, insets: Insets, tint: Color) void {
    const quads = nineSliceRects(dst, insets, @floatFromInt(image.width), @floatFromInt(image.height));
    for (quads) |quad| {
        if (!quad.isEmpty()) {
            self.imageQuad(image, quad.dst, quad.u0, quad.v0, quad.u1, quad.v1, tint);
        }
    }
}

/// Draw a single line of UTF-8 text. `(x, y)` is the top-left of the bounding
/// box (graphics.md: top-of-bbox派). `\n` is ignored; complex layout is the
/// caller's responsibility.
pub fn drawString(self: *Graphics, s: []const u8, x: f32, y: f32) void {
    if (self.clipIsEmpty()) return;
    const font = self.current_font orelse return;
    // Rasterize at framebuffer-pixel size for crisp HiDPI glyphs, then convert
    // glyph metrics back to logical points for positioning. `scale` is 1.0 on
    // 1x displays, 2.0 on Retina, 1.5 on Windows 150%, etc.
    const scale: f32 = @as(f32, @floatFromInt(self.fb_w)) / @as(f32, @floatFromInt(self.window_w));
    const inv_scale: f32 = if (scale > 0) 1.0 / scale else 1.0;
    const phys_size: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(font.pixel_size)) * scale))));
    font.face.setPixelSize(phys_size);
    const ascender = font.face.metrics().ascender * inv_scale;
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

        // Cache by phys_size so different scales don't collide.
        const info = self.ctx.atlas.getOrRasterize(font.face, phys_size, cp) catch continue;
        if (info.bitmap_width > 0 and info.bitmap_height > 0) {
            // Glyph metrics from the atlas are in physical pixels — scale
            // down to logical for quad placement; the GPU viewport will then
            // upscale during NDC → framebuffer mapping for an exact-pixel hit.
            const w_f: f32 = @as(f32, @floatFromInt(info.bitmap_width)) * inv_scale;
            const h_f: f32 = @as(f32, @floatFromInt(info.bitmap_height)) * inv_scale;
            const left = pen_px_x + info.bearing_x * inv_scale;
            const top = baseline_px_y - info.bearing_y * inv_scale;
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
        pen_px_x += info.advance_x * inv_scale;
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

fn expectRectEqual(expected: Rect, actual: Rect) !void {
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

test "nineSliceRects keeps corners one-to-one and stretches edges and center" {
    const quads = nineSliceRects(
        .{ .x = 10, .y = 20, .width = 20, .height = 12 },
        .{ .left = 2, .top = 2, .right = 2, .bottom = 2 },
        8,
        8,
    );

    try expectRectEqual(.{ .x = 10, .y = 20, .width = 2, .height = 2 }, quads[0].dst);
    try std.testing.expectEqual(@as(f32, 0), quads[0].u0);
    try std.testing.expectEqual(@as(f32, 0), quads[0].v0);
    try std.testing.expectEqual(@as(f32, 0.25), quads[0].u1);
    try std.testing.expectEqual(@as(f32, 0.25), quads[0].v1);

    try expectRectEqual(.{ .x = 12, .y = 20, .width = 16, .height = 2 }, quads[1].dst);
    try std.testing.expectEqual(@as(f32, 0.25), quads[1].u0);
    try std.testing.expectEqual(@as(f32, 0), quads[1].v0);
    try std.testing.expectEqual(@as(f32, 0.75), quads[1].u1);
    try std.testing.expectEqual(@as(f32, 0.25), quads[1].v1);

    try expectRectEqual(.{ .x = 12, .y = 22, .width = 16, .height = 8 }, quads[4].dst);
    try std.testing.expectEqual(@as(f32, 0.25), quads[4].u0);
    try std.testing.expectEqual(@as(f32, 0.25), quads[4].v0);
    try std.testing.expectEqual(@as(f32, 0.75), quads[4].u1);
    try std.testing.expectEqual(@as(f32, 0.75), quads[4].v1);

    try expectRectEqual(.{ .x = 28, .y = 30, .width = 2, .height = 2 }, quads[8].dst);
    for (quads) |quad| {
        try std.testing.expect(!quad.isEmpty());
    }
}

test "nineSliceRects proportionally clamps degenerate destination insets" {
    const quads = nineSliceRects(
        .{ .x = 0, .y = 0, .width = 3, .height = 10 },
        .{ .left = 2, .top = 2, .right = 4, .bottom = 2 },
        8,
        8,
    );

    try expectRectEqual(.{ .x = 0, .y = 0, .width = 1, .height = 2 }, quads[0].dst);
    try expectRectEqual(.{ .x = 1, .y = 0, .width = 0, .height = 2 }, quads[1].dst);
    try expectRectEqual(.{ .x = 1, .y = 0, .width = 2, .height = 2 }, quads[2].dst);
    try expectRectEqual(.{ .x = 1, .y = 2, .width = 0, .height = 6 }, quads[4].dst);

    try std.testing.expect(!quads[0].isEmpty());
    try std.testing.expect(quads[1].isEmpty());
    try std.testing.expect(!quads[2].isEmpty());
    try std.testing.expect(quads[4].isEmpty());
    try std.testing.expectEqual(@as(f32, 0.25), quads[1].u0);
    try std.testing.expectEqual(@as(f32, 0.5), quads[1].u1);
}
