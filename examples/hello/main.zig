const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;

const triangle_hlsl =
    \\struct VsOut {
    \\    float4 pos : SV_Position;
    \\};
    \\
    \\VsOut vsMain(float2 in_pos : POSITION) {
    \\    VsOut o;
    \\    o.pos = float4(in_pos, 0.0, 1.0);
    \\    return o;
    \\}
    \\
    \\float4 psMain() : SV_Target {
    \\    return float4(1.0, 0.5, 0.2, 1.0);
    \\}
;

const triangle_vertices = [_]f32{
     0.0,  0.5,
     0.5, -0.5,
    -0.5, -0.5,
};

const Renderer = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,
    pipeline: *awt.Pipeline,
    vbuf: *awt.Buffer,
};

fn renderFrame(r: *Renderer) void {
    const cb = awt.CommandBuffer.acquire(r.device.*) catch return;
    defer cb.release();

    cb.begin();
    cb.bindRenderTarget(r.swapchain.getTarget());
    cb.clearColor(0.5, 0.7, 1.0, 1.0);
    cb.clearStencil(0);

    cb.bindPipeline(r.pipeline.*);
    cb.bindVertexBuffer(r.vbuf.*, 0, 2 * @sizeOf(f32), 0);
    cb.draw(3, 0);

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

pub fn main() !void {
    std.debug.print("AWT backend: {s}\n", .{awt.backendVersion()});

    try awt.init();
    defer awt.deinit();

    var device = try awt.Device.init();
    defer device.deinit();

    var window = try awt.Window.init("hello nimbus", 800, 600);
    defer window.deinit();

    var swapchain = try awt.Swapchain.init(device, window);
    defer swapchain.deinit();

    var vs = try awt.Shader.compile(.vertex, triangle_hlsl);
    defer vs.deinit();
    var ps = try awt.Shader.compile(.pixel, triangle_hlsl);
    defer ps.deinit();

    var root_sig = try awt.RootSignature.init(device, &.{});
    defer root_sig.deinit();

    var pipeline = try awt.Pipeline.init(device, .{
        .root_signature = root_sig,
        .vertex_shader = vs,
        .pixel_shader = ps,
        .vertex_layout = .vertex_2d,
        .topology = .triangle_list,
        .blend = .none,
        .color_write_enable = true,
    });
    defer pipeline.deinit();

    var vbuf = try awt.Buffer.init(device, @sizeOf(@TypeOf(triangle_vertices)), .{ .vertex = true });
    defer vbuf.deinit();
    vbuf.upload(std.mem.sliceAsBytes(triangle_vertices[0..]), 0);

    var renderer = Renderer{
        .device = &device,
        .swapchain = &swapchain,
        .pipeline = &pipeline,
        .vbuf = &vbuf,
    };
    window.setResizeCallback(onResize, &renderer);
    window.setRefreshCallback(onRefresh, &renderer);

    std.debug.print("Window opened. Close it to exit.\n", .{});
    while (!window.shouldClose()) {
        awt.pollEvents();
        renderFrame(&renderer);
    }
    std.debug.print("Bye.\n", .{});
}
