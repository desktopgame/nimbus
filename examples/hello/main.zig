const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;

const noto_sans_ttf = @embedFile("assets/noto-sans/NotoSansJP-Regular.ttf");
const example_png = @embedFile("assets/example.png");

const Renderer = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,

    // Programs.
    text_program: *awt.programs.Text,
    color_program: *awt.programs.Color,
    image_program: *awt.programs.Image,
    rrect_program: *awt.programs.RoundedRect,

    // Textures.
    glyph_texture: *awt.Texture,
    image_texture: *awt.Texture,

    // Top-row vertex buffers (Color / Image / Text).
    color_vbuf: *awt.Buffer,
    image_vbuf: *awt.Buffer,
    text_vbuf: *awt.Buffer,
    // Bottom-row vertex buffers (SDF shapes — all 100x100 px).
    rrect_fill_vbuf: *awt.Buffer,
    rrect_outline_vbuf: *awt.Buffer,
    circle_fill_vbuf: *awt.Buffer,
    circle_outline_vbuf: *awt.Buffer,

    ibuf: *awt.Buffer,
    uniforms: *awt.UniformBuffer,
};

fn renderFrame(r: *Renderer) void {
    // Acquire first: this blocks until the previous frame's GPU work has
    // completed, which is what makes it safe to overwrite uniform memory.
    const cb = awt.CommandBuffer.acquire(r.device.*) catch return;
    defer cb.release();

    // Time-driven uniform values.
    const t: f32 = @floatCast(awt.time());
    const text_color: [4]f32 = if ((@as(u64, @intFromFloat(t)) & 1) == 0)
        .{ 1.0, 0.0, 0.0, 1.0 }
    else
        .{ 0.0, 0.0, 0.0, 1.0 };
    const cycling_color: [4]f32 = .{
        0.5 + 0.5 * @sin(t),
        0.5 + 0.5 * @sin(t + 2.0),
        0.5 + 0.5 * @sin(t + 4.0),
        1.0,
    };

    // ── Push uniforms for all draws this frame. ─────────────────────
    r.uniforms.reset();
    const color_h = r.uniforms.push(awt.programs.Color.Uniforms{ .color = cycling_color }) catch return;
    const image_h = r.uniforms.push(awt.programs.Image.Uniforms{ .tint = .{ 1, 1, 1, 1 } }) catch return;
    const text_h = r.uniforms.push(awt.programs.Text.Uniforms{ .color = text_color }) catch return;

    // SDF shape uniforms (all 100x100 px → half_size = 50).
    const orange = [4]f32{ 0.95, 0.55, 0.20, 1.0 };
    const cyan   = [4]f32{ 0.20, 0.75, 0.95, 1.0 };
    const magenta = [4]f32{ 0.90, 0.30, 0.70, 1.0 };
    const yellow = [4]f32{ 0.95, 0.85, 0.20, 1.0 };

    const rrect_fill_h = r.uniforms.push(awt.programs.RoundedRect.Uniforms{
        .color = orange,
        .half_size = .{ 50, 50 },
        .corner_radius = 20,
        .thickness = 0,
    }) catch return;
    const rrect_outline_h = r.uniforms.push(awt.programs.RoundedRect.Uniforms{
        .color = cyan,
        .half_size = .{ 50, 50 },
        .corner_radius = 20,
        .thickness = 3,
    }) catch return;
    const circle_fill_h = r.uniforms.push(awt.programs.RoundedRect.Uniforms{
        .color = magenta,
        .half_size = .{ 50, 50 },
        .corner_radius = 50, // = half side → full circle
        .thickness = 0,
    }) catch return;
    const circle_outline_h = r.uniforms.push(awt.programs.RoundedRect.Uniforms{
        .color = yellow,
        .half_size = .{ 50, 50 },
        .corner_radius = 50,
        .thickness = 3,
    }) catch return;

    cb.begin();
    cb.bindRenderTarget(r.swapchain.getTarget());
    cb.clearColor(0.1, 0.1, 0.15, 1.0);
    cb.clearStencil(0);

    // ── Top row: Color / Image / Text ───────────────────────────────
    r.color_program.bind(cb);
    r.color_program.bindUniforms(cb, r.uniforms.*, color_h);
    cb.bindVertexBuffer(r.color_vbuf.*, 0, 2 * @sizeOf(f32), 0);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);
    cb.drawIndexed(6, 0, 0);

    r.image_program.bind(cb);
    r.image_program.bindUniforms(cb, r.uniforms.*, image_h);
    cb.bindTexture(r.image_texture.*, 0);
    cb.bindVertexBuffer(r.image_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);
    cb.drawIndexed(6, 0, 0);

    r.text_program.bind(cb);
    r.text_program.bindUniforms(cb, r.uniforms.*, text_h);
    cb.bindTexture(r.glyph_texture.*, 0);
    cb.bindVertexBuffer(r.text_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);
    cb.drawIndexed(6, 0, 0);

    // ── Bottom row: SDF rounded rects + circles (fill + outline each) ──
    r.rrect_program.bind(cb);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);

    r.rrect_program.bindUniforms(cb, r.uniforms.*, rrect_fill_h);
    cb.bindVertexBuffer(r.rrect_fill_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.drawIndexed(6, 0, 0);

    r.rrect_program.bindUniforms(cb, r.uniforms.*, rrect_outline_h);
    cb.bindVertexBuffer(r.rrect_outline_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.drawIndexed(6, 0, 0);

    r.rrect_program.bindUniforms(cb, r.uniforms.*, circle_fill_h);
    cb.bindVertexBuffer(r.circle_fill_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.drawIndexed(6, 0, 0);

    r.rrect_program.bindUniforms(cb, r.uniforms.*, circle_outline_h);
    cb.bindVertexBuffer(r.circle_outline_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.drawIndexed(6, 0, 0);

    cb.end();
    cb.submit(r.device.*);
    r.swapchain.present();
}

fn onResize(
    _: ?*c.struct_nmWindow,
    width: c_int,
    height: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const r: *Renderer = @ptrCast(@alignCast(user_data.?));
    r.swapchain.resize(@intCast(width), @intCast(height)) catch {};
    renderFrame(r);
}

fn onRefresh(
    _: ?*c.struct_nmWindow,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const r: *Renderer = @ptrCast(@alignCast(user_data.?));
    renderFrame(r);
}

/// CCW in NDC (y up): triangle 1 = TL→BL→BR, triangle 2 = TL→BR→TR.
const quad_indices: [6]u16 = .{ 0, 1, 2, 0, 2, 3 };

/// 4 unique vertices (x, y) only — no UV. Used by the Color program.
fn quadPos(out: *[8]f32, cx: f32, cy: f32, w: f32, h: f32) void {
    const x0 = cx - w / 2.0;
    const x1 = cx + w / 2.0;
    const y0 = cy - h / 2.0;
    const y1 = cy + h / 2.0;
    out.* = .{
        x0, y1, // TL
        x0, y0, // BL
        x1, y0, // BR
        x1, y1, // TR
    };
}

/// 4 unique vertices (x, y, u, v). UV is in [0, 1] over the quad — what
/// Text/Image want.
fn quadPosUv(out: *[16]f32, cx: f32, cy: f32, w: f32, h: f32) void {
    const x0 = cx - w / 2.0;
    const x1 = cx + w / 2.0;
    const y0 = cy - h / 2.0;
    const y1 = cy + h / 2.0;
    out.* = .{
        x0, y1, 0.0, 0.0, // TL
        x0, y0, 0.0, 1.0, // BL
        x1, y0, 1.0, 1.0, // BR
        x1, y1, 1.0, 0.0, // TR
    };
}

/// SDF quad: covers the shape's bounding box plus a margin so that outlines
/// (which extend thickness/2 outside the nominal radius) and the 1px AA fade
/// are not clipped at the cardinal edges. UV is scaled so `uv * half_size`
/// in the shader still gives pixel coords with origin at the shape center —
/// i.e., the nominal shape edge is at UV ±1, the quad corners go slightly past.
fn quadSdf(
    out: *[16]f32,
    cx_ndc: f32, cy_ndc: f32,
    half_w_px: f32, half_h_px: f32,
    margin_px: f32,
    window_w: i32, window_h: i32,
) void {
    const ww = @as(f32, @floatFromInt(window_w));
    const wh = @as(f32, @floatFromInt(window_h));
    const w_ndc = (half_w_px + margin_px) * 2.0 / ww;
    const h_ndc = (half_h_px + margin_px) * 2.0 / wh;
    const uv_x = (half_w_px + margin_px) / half_w_px;
    const uv_y = (half_h_px + margin_px) / half_h_px;
    const x0 = cx_ndc - w_ndc / 2.0;
    const x1 = cx_ndc + w_ndc / 2.0;
    const y0 = cy_ndc - h_ndc / 2.0;
    const y1 = cy_ndc + h_ndc / 2.0;
    out.* = .{
        x0, y1, -uv_x, -uv_y, // TL
        x0, y0, -uv_x,  uv_y, // BL
        x1, y0,  uv_x,  uv_y, // BR
        x1, y1,  uv_x, -uv_y, // TR
    };
}

fn pxToNdc(px: i32, window_px: i32) f32 {
    return @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(window_px)) * 2.0;
}

pub fn main() !void {
    std.debug.print("AWT backend: {s}\n", .{awt.backendVersion()});

    try awt.init();
    defer awt.deinit();

    var device = try awt.Device.init();
    defer device.deinit();

    const window_w: i32 = 800;
    const window_h: i32 = 600;
    var window = try awt.Window.init("hello nimbus", window_w, window_h);
    defer window.deinit();

    var swapchain = try awt.Swapchain.init(device, window);
    defer swapchain.deinit();

    // ── Font + glyph texture (R8) ──────────────────────────────────
    var font = try awt.Font.init(noto_sans_ttf, 0);
    defer font.deinit();
    font.setPixelSize(128);

    const glyph = try font.rasterize('A');
    std.debug.print(
        "Glyph 'A': {d}x{d}, bearing=({d}, {d}), advance={d:.2}\n",
        .{
            glyph.metrics.bitmap_width,
            glyph.metrics.bitmap_height,
            glyph.metrics.bearing_x,
            glyph.metrics.bearing_y,
            glyph.metrics.advance_x,
        },
    );

    var glyph_texture = try awt.Texture.init(
        device,
        glyph.metrics.bitmap_width,
        glyph.metrics.bitmap_height,
        .r8,
    );
    defer glyph_texture.deinit();
    glyph_texture.uploadRegion(
        0, 0,
        glyph.metrics.bitmap_width, glyph.metrics.bitmap_height,
        glyph.bitmap,
        @intCast(glyph.metrics.bitmap_pitch),
    );

    // ── Decode example.png via zigimg → RGBA8 texture ──────────────
    const png_allocator = std.heap.page_allocator;
    var img = try awt.zigimg.Image.fromMemory(png_allocator, example_png);
    defer img.deinit(png_allocator);
    try img.convert(png_allocator, .rgba32);
    std.debug.print("example.png: {d}x{d}, pixel_format={}\n",
        .{ img.width, img.height, img.pixelFormat() });

    var image_texture = try awt.Texture.init(
        device,
        @intCast(img.width),
        @intCast(img.height),
        .rgba8,
    );
    defer image_texture.deinit();
    image_texture.upload(img.rawBytes());

    // ── Programs ───────────────────────────────────────────────────
    var text_program = try awt.programs.Text.init(device);
    defer text_program.deinit();
    var color_program = try awt.programs.Color.init(device);
    defer color_program.deinit();
    var image_program = try awt.programs.Image.init(device);
    defer image_program.deinit();
    var rrect_program = try awt.programs.RoundedRect.init(device);
    defer rrect_program.deinit();

    // ── Top row: 3 panels at y=+0.4, each 150x200 px ───────────────
    const top_y: f32 = 0.4;
    const top_w_ndc: f32 = pxToNdc(150, window_w);
    const top_h_ndc: f32 = pxToNdc(200, window_h);

    var color_quad: [8]f32 = undefined;
    quadPos(&color_quad, -0.5, top_y, top_w_ndc, top_h_ndc);
    var color_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(color_quad)), .{ .vertex = true });
    defer color_vbuf.deinit();
    color_vbuf.upload(std.mem.sliceAsBytes(color_quad[0..]), 0);

    var image_quad: [16]f32 = undefined;
    quadPosUv(&image_quad, 0.0, top_y, top_w_ndc, top_h_ndc);
    var image_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(image_quad)), .{ .vertex = true });
    defer image_vbuf.deinit();
    image_vbuf.upload(std.mem.sliceAsBytes(image_quad[0..]), 0);

    var text_quad: [16]f32 = undefined;
    quadPosUv(
        &text_quad,
        0.5, top_y,
        pxToNdc(glyph.metrics.bitmap_width, window_w),
        pxToNdc(glyph.metrics.bitmap_height, window_h),
    );
    var text_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(text_quad)), .{ .vertex = true });
    defer text_vbuf.deinit();
    text_vbuf.upload(std.mem.sliceAsBytes(text_quad[0..]), 0);

    // ── Bottom row: 4 SDF shapes at y=-0.4, each nominal 100x100 px ──
    // Quad gets a 4px margin on each side so outlines (thickness/2 outside
    // the nominal edge) plus AA fade aren't clipped at the cardinal points.
    const bot_y: f32 = -0.4;
    const sdf_half_px: f32 = 50;
    const sdf_margin_px: f32 = 4;

    var rrect_fill_quad: [16]f32 = undefined;
    quadSdf(&rrect_fill_quad, -0.65, bot_y, sdf_half_px, sdf_half_px, sdf_margin_px, window_w, window_h);
    var rrect_fill_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(rrect_fill_quad)), .{ .vertex = true });
    defer rrect_fill_vbuf.deinit();
    rrect_fill_vbuf.upload(std.mem.sliceAsBytes(rrect_fill_quad[0..]), 0);

    var rrect_outline_quad: [16]f32 = undefined;
    quadSdf(&rrect_outline_quad, -0.22, bot_y, sdf_half_px, sdf_half_px, sdf_margin_px, window_w, window_h);
    var rrect_outline_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(rrect_outline_quad)), .{ .vertex = true });
    defer rrect_outline_vbuf.deinit();
    rrect_outline_vbuf.upload(std.mem.sliceAsBytes(rrect_outline_quad[0..]), 0);

    var circle_fill_quad: [16]f32 = undefined;
    quadSdf(&circle_fill_quad, 0.22, bot_y, sdf_half_px, sdf_half_px, sdf_margin_px, window_w, window_h);
    var circle_fill_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(circle_fill_quad)), .{ .vertex = true });
    defer circle_fill_vbuf.deinit();
    circle_fill_vbuf.upload(std.mem.sliceAsBytes(circle_fill_quad[0..]), 0);

    var circle_outline_quad: [16]f32 = undefined;
    quadSdf(&circle_outline_quad, 0.65, bot_y, sdf_half_px, sdf_half_px, sdf_margin_px, window_w, window_h);
    var circle_outline_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(circle_outline_quad)), .{ .vertex = true });
    defer circle_outline_vbuf.deinit();
    circle_outline_vbuf.upload(std.mem.sliceAsBytes(circle_outline_quad[0..]), 0);

    // Shared index buffer (same 6-index quad pattern for all draws).
    var ibuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(quad_indices)), .{ .index = true });
    defer ibuf.deinit();
    ibuf.upload(std.mem.sliceAsBytes(quad_indices[0..]), 0);

    // ── Shared uniform buffer (single ring allocator for all programs) ──
    var uniforms = try awt.UniformBuffer.init(device, 4096);
    defer uniforms.deinit();

    var renderer = Renderer{
        .device = &device,
        .swapchain = &swapchain,
        .text_program = &text_program,
        .color_program = &color_program,
        .image_program = &image_program,
        .rrect_program = &rrect_program,
        .glyph_texture = &glyph_texture,
        .image_texture = &image_texture,
        .color_vbuf = &color_vbuf,
        .image_vbuf = &image_vbuf,
        .text_vbuf = &text_vbuf,
        .rrect_fill_vbuf = &rrect_fill_vbuf,
        .rrect_outline_vbuf = &rrect_outline_vbuf,
        .circle_fill_vbuf = &circle_fill_vbuf,
        .circle_outline_vbuf = &circle_outline_vbuf,
        .ibuf = &ibuf,
        .uniforms = &uniforms,
    };
    window.setResizeCallback(onResize, &renderer);
    window.setRefreshCallback(onRefresh, &renderer);

    std.debug.print("Window opened. Close it to exit.\n", .{});
    while (!window.shouldClose()) {
        awt.pollEvents();
        renderFrame(&renderer);
    }

    // Drain the GPU before defers tear down resources still referenced by
    // the last submitted command list.
    device.waitIdle();
    std.debug.print("Bye.\n", .{});
}
