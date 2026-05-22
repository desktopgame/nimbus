//! Offscreen snapshot example. Paints a fixed scene into an offscreen render
//! target and writes the result to a PNG file. No window is opened.
//!
//! Usage:
//!     zig build run-snapshot                  # writes tmp/snapshot.png
//!     zig build run-snapshot -- tmp/out.png   # writes to the given path

const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

const WIDTH: i32 = 400;
const HEIGHT: i32 = 300;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Resolve output path. argv[1] if supplied, otherwise default.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path: []const u8 = if (argv.len >= 2) argv[1] else "tmp/snapshot.png";

    try awt.init();
    defer awt.deinit();

    var device = try awt.Device.init();
    defer device.deinit();

    var rt = try awt.RenderTarget.create(device, WIDTH, HEIGHT);
    defer rt.deinit();

    // Programs. We instantiate all four so Graphics.Context is fully formed;
    // only Color + RoundedRect are actually used by this scene.
    var color_program = try awt.programs.Color.init(device);
    defer color_program.deinit();
    var rrect_program = try awt.programs.RoundedRect.init(device);
    defer rrect_program.deinit();
    var image_program = try awt.programs.Image.init(device);
    defer image_program.deinit();
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

    var ctx = awt.Graphics.Context{
        .vertex_ring = &vertex_ring,
        .uniforms = &uniforms,
        .quad_index = &quad_index,
        .atlas = &atlas,
        .color_program = &color_program,
        .image_program = &image_program,
        .rrect_program = &rrect_program,
        .text_program = &text_program,
    };

    // ── paint one frame ──
    {
        const cb = try awt.CommandBuffer.acquire(device);
        defer cb.release();

        uniforms.reset();
        vertex_ring.reset();

        cb.begin();
        cb.bindRenderTarget(rt);
        cb.clearColor(0.10, 0.10, 0.15, 1.0);
        cb.clearStencil(0);

        var g = awt.Graphics.init(cb, &ctx, WIDTH, HEIGHT, WIDTH, HEIGHT);

        // Two filled rects (Color program).
        g.setColor(awt.Graphics.Color.rgb(0.95, 0.30, 0.30));
        g.fillRect(.{ .x = 20, .y = 20, .width = 100, .height = 60 });
        g.setColor(awt.Graphics.Color.rgb(0.30, 0.95, 0.50));
        g.fillRect(.{ .x = 140, .y = 20, .width = 100, .height = 60 });

        // Rounded rect + circle (RoundedRect program / SDF).
        g.setColor(awt.Graphics.Color.rgb(0.30, 0.60, 0.95));
        g.fillRoundRect(.{ .x = 20, .y = 110, .width = 100, .height = 100 }, 20);
        g.setColor(awt.Graphics.Color.rgb(0.95, 0.85, 0.30));
        g.fillCircle(.{ .x = 140, .y = 110, .width = 100, .height = 100 });

        // 1px outlines.
        g.setColor(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));
        g.drawRect(.{ .x = 260, .y = 20, .width = 120, .height = 90 });
        g.drawRoundRect(.{ .x = 260, .y = 130, .width = 120, .height = 80 }, 16);

        cb.end();
        cb.submit(device);
    }

    // ── readback → PNG ──
    try rt.readbackToPng(gpa, io, WIDTH, HEIGHT, out_path);

    device.waitIdle();
    std.debug.print("Snapshot written: {s} ({d}x{d})\n", .{ out_path, WIDTH, HEIGHT });
}
