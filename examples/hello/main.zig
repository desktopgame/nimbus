const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;

const noto_sans_ttf = @embedFile("assets/noto-sans/NotoSansJP-Regular.ttf");
const example_png = @embedFile("assets/example.png");

const Renderer = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,

    text_program: *awt.programs.Text,
    color_program: *awt.programs.Color,
    image_program: *awt.programs.Image,

    glyph_texture: *awt.Texture,
    image_texture: *awt.Texture,

    color_vbuf: *awt.Buffer,
    image_vbuf: *awt.Buffer,
    text_vbuf: *awt.Buffer,
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

    // Push all uniform blocks into the shared ring buffer.
    r.uniforms.reset();
    const color_h = r.uniforms.push(awt.programs.Color.Uniforms{ .color = cycling_color }) catch return;
    const image_h = r.uniforms.push(awt.programs.Image.Uniforms{ .tint = .{ 1, 1, 1, 1 } }) catch return;
    const text_h = r.uniforms.push(awt.programs.Text.Uniforms{ .color = text_color }) catch return;

    cb.begin();
    cb.bindRenderTarget(r.swapchain.getTarget());
    cb.clearColor(0.1, 0.1, 0.15, 1.0);
    cb.clearStencil(0);

    // 1. Color quad (left): solid cycling color, no texture.
    r.color_program.bind(cb);
    r.color_program.bindUniforms(cb, r.uniforms.*, color_h);
    cb.bindVertexBuffer(r.color_vbuf.*, 0, 2 * @sizeOf(f32), 0);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);
    cb.drawIndexed(6, 0, 0);

    // 2. Image quad (middle): example.png with no tint.
    r.image_program.bind(cb);
    r.image_program.bindUniforms(cb, r.uniforms.*, image_h);
    cb.bindTexture(r.image_texture.*, 0);
    cb.bindVertexBuffer(r.image_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);
    cb.drawIndexed(6, 0, 0);

    // 3. Text glyph (right): 'A' in red/black, alternating every second.
    r.text_program.bind(cb);
    r.text_program.bindUniforms(cb, r.uniforms.*, text_h);
    cb.bindTexture(r.glyph_texture.*, 0);
    cb.bindVertexBuffer(r.text_vbuf.*, 0, 4 * @sizeOf(f32), 0);
    cb.bindIndexBuffer(r.ibuf.*, .u16, 0);
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

/// 4 unique vertices (x, y, u, v). Used by Text and Image programs.
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

    // ── Vertex buffers (3 quads, side by side) ─────────────────────
    // Each panel ~200px wide, ~300px tall, centered horizontally at -0.6 / 0 / +0.6 NDC.
    const panel_w_ndc: f32 = pxToNdc(200, window_w);
    const panel_h_ndc: f32 = pxToNdc(300, window_h);

    var color_quad: [8]f32 = undefined;
    quadPos(&color_quad, -0.6, 0.0, panel_w_ndc, panel_h_ndc);
    var color_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(color_quad)), .{ .vertex = true });
    defer color_vbuf.deinit();
    color_vbuf.upload(std.mem.sliceAsBytes(color_quad[0..]), 0);

    var image_quad: [16]f32 = undefined;
    quadPosUv(&image_quad, 0.0, 0.0, panel_w_ndc, panel_h_ndc);
    var image_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(image_quad)), .{ .vertex = true });
    defer image_vbuf.deinit();
    image_vbuf.upload(std.mem.sliceAsBytes(image_quad[0..]), 0);

    // Text quad sized to the actual glyph metrics, centered at +0.6 NDC.
    var text_quad: [16]f32 = undefined;
    quadPosUv(
        &text_quad,
        0.6, 0.0,
        pxToNdc(glyph.metrics.bitmap_width, window_w),
        pxToNdc(glyph.metrics.bitmap_height, window_h),
    );
    var text_vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(text_quad)), .{ .vertex = true });
    defer text_vbuf.deinit();
    text_vbuf.upload(std.mem.sliceAsBytes(text_quad[0..]), 0);

    // Shared index buffer (same 6-index quad pattern for all three).
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
        .glyph_texture = &glyph_texture,
        .image_texture = &image_texture,
        .color_vbuf = &color_vbuf,
        .image_vbuf = &image_vbuf,
        .text_vbuf = &text_vbuf,
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
