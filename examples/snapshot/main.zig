//! Offscreen snapshot example. Paints a shared `scenes.Scene` into an
//! offscreen render target and writes the result to a PNG file. No window
//! is opened. The scene is the same one used by the snapshot regression
//! tests, so this binary doubles as a visual inspection tool.
//!
//! Usage:
//!     zig build run-snapshot                          # writes tmp/snapshot.png
//!     zig build run-snapshot -- tmp/out.png           # custom output path
//!     zig build run-snapshot -- tmp/out.png <scene>   # pick a named scene

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const scenes = @import("scenes");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path: []const u8 = if (argv.len >= 2) argv[1] else "tmp/snapshot.png";
    const scene_name: ?[]const u8 = if (argv.len >= 3) argv[2] else null;

    const scene = pickScene(scene_name) orelse {
        std.debug.print("unknown scene: {s}\nknown scenes:\n", .{scene_name.?});
        for (scenes.all) |s| std.debug.print("  {s}\n", .{s.name});
        return error.UnknownScene;
    };

    try awt.init();
    defer awt.deinit();

    var device = try awt.Device.init();
    defer device.deinit();

    var font = try awt.Font.init(gpa, scenes.default_font_bytes, 0);
    defer font.deinit();

    var rt = try awt.RenderTarget.create(device, scene.width, scene.height);
    defer rt.deinit();

    var color_program = try awt.programs.Color.init(device);
    defer color_program.deinit();
    var rrect_program = try awt.programs.RoundedRect.init(device);
    defer rrect_program.deinit();
    var image_program = try awt.programs.Image.init(device);
    defer image_program.deinit();
    var gradient_program = try awt.programs.Gradient.init(device);
    defer gradient_program.deinit();
    var text_program = try awt.programs.Text.init(device);
    defer text_program.deinit();

    var vertex_ring = try awt.VertexRing.init(device, 64 * 1024);
    defer vertex_ring.deinit();
    var uniforms = try awt.UniformBuffer.init(device, 16 * 1024);
    defer uniforms.deinit();
    var quad_index = try awt.QuadIndexBuffer.init(gpa, device, 256);
    defer quad_index.deinit();
    var atlas = try awt.GlyphAtlas.init(gpa, device, 256);
    defer atlas.deinit();
    var scene_images: std.ArrayList(awt.Image) = .empty;
    defer {
        for (scene_images.items) |*image| image.deinit();
        scene_images.deinit(gpa);
    }

    var ctx = awt.Graphics.Context{
        .vertex_ring = &vertex_ring,
        .uniforms = &uniforms,
        .quad_index = &quad_index,
        .atlas = &atlas,
        .color_program = &color_program,
        .image_program = &image_program,
        .gradient_program = &gradient_program,
        .rrect_program = &rrect_program,
        .text_program = &text_program,
    };

    {
        const cb = try awt.CommandBuffer.acquire(device);
        defer cb.release();

        uniforms.reset();
        vertex_ring.reset();

        cb.begin();
        cb.bindRenderTarget(rt);
        cb.clearColor(scene.clear[0], scene.clear[1], scene.clear[2], scene.clear[3]);
        cb.clearStencil(0);

        var g = awt.Graphics.init(cb, &ctx, scene.width, scene.height, scene.width, scene.height);
        try scene.paint(.{
            .g = &g,
            .allocator = gpa,
            .device = device,
            .images = &scene_images,
            .font = font,
            .width = scene.width,
            .height = scene.height,
        });

        cb.end();
        cb.submit(device);
    }

    try rt.readbackToPng(gpa, io, scene.width, scene.height, out_path);

    device.waitIdle();
    std.debug.print(
        "Snapshot written: {s} (scene '{s}', {d}x{d})\n",
        .{ out_path, scene.name, scene.width, scene.height },
    );
}

fn pickScene(name: ?[]const u8) ?scenes.Scene {
    const requested = name orelse return scenes.basic_shapes;
    for (scenes.all) |s| {
        if (std.mem.eql(u8, s.name, requested)) return s;
    }
    return null;
}
