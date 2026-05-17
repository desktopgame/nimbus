const std = @import("std");
const builtin = @import("builtin");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;

const noto_sans_ttf = @embedFile("assets/noto-sans/NotoSansJP-Regular.ttf");

const text_hlsl =
    \\struct VsOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv : TEXCOORD0;
    \\};
    \\
    \\VsOut vsMain(float2 in_pos : POSITION, float2 in_uv : TEXCOORD0) {
    \\    VsOut o;
    \\    o.pos = float4(in_pos, 0.0, 1.0);
    \\    o.uv = in_uv;
    \\    return o;
    \\}
    \\
    \\Texture2D    g_tex  : register(t0);
    \\SamplerState g_samp : register(s0);  // s0 = LinearClamp (built-in)
    \\
    \\float4 psMain(VsOut i) : SV_Target {
    \\    float a = g_tex.Sample(g_samp, i.uv).r;
    \\    return float4(1.0, 1.0, 1.0, a);
    \\}
;

const text_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VsIn {
    \\    float2 pos [[attribute(0)]];
    \\    float2 uv  [[attribute(1)]];
    \\};
    \\struct VsOut {
    \\    float4 pos [[position]];
    \\    float2 uv;
    \\};
    \\
    \\vertex VsOut vsMain(VsIn in [[stage_in]]) {
    \\    VsOut o;
    \\    o.pos = float4(in.pos, 0.0, 1.0);
    \\    o.uv = in.uv;
    \\    return o;
    \\}
    \\
    \\fragment float4 psMain(VsOut in [[stage_in]],
    \\                       texture2d<float> tex [[texture(0)]],
    \\                       sampler samp [[sampler(0)]]) {
    \\    float a = tex.sample(samp, in.uv).r;
    \\    return float4(1.0, 1.0, 1.0, a);
    \\}
;

const text_shader = if (builtin.target.os.tag == .macos) text_msl else text_hlsl;

const Renderer = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,
    pipeline: *awt.Pipeline,
    texture: *awt.Texture,
    vbuf: *awt.Buffer,
    ibuf: *awt.Buffer,
};

fn renderFrame(r: *Renderer) void {
    const cb = awt.CommandBuffer.acquire(r.device.*) catch return;
    defer cb.release();

    cb.begin();
    cb.bindRenderTarget(r.swapchain.getTarget());
    cb.clearColor(0.1, 0.1, 0.15, 1.0);
    cb.clearStencil(0);

    cb.bindPipeline(r.pipeline.*);
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

    // ── Shaders + RootSig + Pipeline ────────────────────────────────
    var vs = try awt.Shader.compile(.vertex, text_shader);
    defer vs.deinit();
    var ps = try awt.Shader.compile(.pixel, text_shader);
    defer ps.deinit();

    var root_sig = try awt.RootSignature.init(device, &.{
        .{ .type = .texture, .stage = .pixel, .slot = 0 },
    });
    defer root_sig.deinit();

    var pipeline = try awt.Pipeline.init(device, .{
        .root_signature = root_sig,
        .vertex_shader = vs,
        .pixel_shader = ps,
        .vertex_layout = .vertex_texcoord_2d,
        .topology = .triangle_list,
        .blend = .alpha,
        .color_write_enable = true,
    });
    defer pipeline.deinit();

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

    var renderer = Renderer{
        .device = &device,
        .swapchain = &swapchain,
        .pipeline = &pipeline,
        .texture = &texture,
        .vbuf = &vbuf,
        .ibuf = &ibuf,
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
