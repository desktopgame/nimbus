const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;

const noto_sans_ttf = @embedFile("assets/noto-sans/NotoSansJP-Regular.ttf");

const Renderer = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,
    program: *awt.programs.Text,
    texture: *awt.Texture,
    vbuf: *awt.Buffer,
    ibuf: *awt.Buffer,
    uniforms: *awt.UniformBuffer,
};

fn renderFrame(r: *Renderer) void {
    // Acquire first: this blocks until the previous frame's GPU work has
    // completed, which is what makes it safe to overwrite uniform memory.
    const cb = awt.CommandBuffer.acquire(r.device.*) catch return;
    defer cb.release();

    // Rewind and push this frame's uniform blocks.
    r.uniforms.reset();
    const elapsed_s: u64 = @intFromFloat(awt.time());
    const is_red = (elapsed_s & 1) == 0;
    const color_handle = r.uniforms.push(awt.programs.Text.Uniforms{
        .color = if (is_red) .{ 1.0, 0.0, 0.0, 1.0 } else .{ 0.0, 0.0, 0.0, 1.0 },
    }) catch return;

    cb.begin();
    cb.bindRenderTarget(r.swapchain.getTarget());
    cb.clearColor(0.1, 0.1, 0.15, 1.0);
    cb.clearStencil(0);

    r.program.bind(cb);
    r.program.bindUniforms(cb, r.uniforms.*, color_handle);
    cb.bindTexture(r.texture.*, 0);
    cb.bindVertexBuffer(r.vbuf.*, 0, 4 * @sizeOf(f32), 0);
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

/// Build a CCW quad of the glyph at the window center.
/// 4 unique vertices (TL, BL, BR, TR), each = (x, y, u, v) in NDC + texture UV.
/// Paired with `quad_indices` to form two CCW triangles.
fn buildQuad(
    out: *[16]f32,
    glyph_w: i32,
    glyph_h: i32,
    window_w: i32,
    window_h: i32,
) void {
    const w_ndc: f32 = @as(f32, @floatFromInt(glyph_w)) / @as(f32, @floatFromInt(window_w)) * 2.0;
    const h_ndc: f32 = @as(f32, @floatFromInt(glyph_h)) / @as(f32, @floatFromInt(window_h)) * 2.0;
    const x0 = -w_ndc / 2.0;
    const x1 = w_ndc / 2.0;
    const y0 = -h_ndc / 2.0; // bottom
    const y1 = h_ndc / 2.0;  // top
    out.* = .{
        x0, y1, 0.0, 0.0, // 0: TL
        x0, y0, 0.0, 1.0, // 1: BL
        x1, y0, 1.0, 1.0, // 2: BR
        x1, y1, 1.0, 0.0, // 3: TR
    };
}

/// CCW in NDC (y up): triangle 1 = TL→BL→BR, triangle 2 = TL→BR→TR.
const quad_indices: [6]u16 = .{ 0, 1, 2, 0, 2, 3 };

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

    // ── Font ────────────────────────────────────────────────────────
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

    // ── Texture (R8, glyph-sized) ──────────────────────────────────
    var texture = try awt.Texture.init(
        device,
        glyph.metrics.bitmap_width,
        glyph.metrics.bitmap_height,
        .r8,
    );
    defer texture.deinit();
    texture.uploadRegion(
        0, 0,
        glyph.metrics.bitmap_width, glyph.metrics.bitmap_height,
        glyph.bitmap,
        @intCast(glyph.metrics.bitmap_pitch),
    );

    // ── Program (encapsulates shaders + root sig + pipeline) ───────
    var program = try awt.programs.Text.init(device);
    defer program.deinit();

    // ── Vertex / index buffers (one textured quad, indexed) ────────
    var quad: [16]f32 = undefined;
    buildQuad(&quad, glyph.metrics.bitmap_width, glyph.metrics.bitmap_height,
              window_w, window_h);

    var vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(quad)), .{ .vertex = true });
    defer vbuf.deinit();
    vbuf.upload(std.mem.sliceAsBytes(quad[0..]), 0);

    var ibuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(quad_indices)), .{ .index = true });
    defer ibuf.deinit();
    ibuf.upload(std.mem.sliceAsBytes(quad_indices[0..]), 0);

    // ── Shared uniform buffer (single ring allocator for all programs) ──
    var uniforms = try awt.UniformBuffer.init(device, 4096);
    defer uniforms.deinit();

    var renderer = Renderer{
        .device = &device,
        .swapchain = &swapchain,
        .program = &program,
        .texture = &texture,
        .vbuf = &vbuf,
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
