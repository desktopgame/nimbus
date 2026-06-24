const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;
const Label = nimbus.Label;
const Container = nimbus.Container;

const noto_sans_ttf = nimbus.noto.noto_sans_jp_regular;
const example_png = @embedFile("assets/example.png");

const Renderer = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,
    window: *awt.Window,
    ctx: *awt.Graphics.Context,
    image: *awt.Image,
    font: awt.Font,
    // Logical window size (points). User drawing coordinates are in these units.
    window_w: i32,
    window_h: i32,
    // Framebuffer pixel size. Differs from window size on HiDPI displays.
    fb_w: i32,
    fb_h: i32,
    // Framework widgets driven through Component / Container / Label vtable.
    fw_label: *Label,
    fw_container: *Container,
};

fn renderFrame(r: *Renderer) void {
    const cb = awt.CommandBuffer.acquire(r.device.*) catch return;
    defer cb.release();

    r.ctx.uniforms.reset();
    r.ctx.vertex_ring.reset();

    cb.begin();
    cb.bindRenderTarget(r.swapchain.getTarget());
    cb.clearColor(0.1, 0.1, 0.15, 1.0);
    cb.clearStencil(0);

    var g = awt.Graphics.init(cb, r.ctx, r.window_w, r.window_h, r.fb_w, r.fb_h);
    g.setFont(.{ .face = r.font, .pixel_size = 32 });

    const t: f32 = @floatCast(awt.time());

    // ── Top row: a cycling color rect, an image, a string ──────────
    g.setColor(awt.Graphics.Color.rgb(
        0.5 + 0.5 * @sin(t),
        0.5 + 0.5 * @sin(t + 2.0),
        0.5 + 0.5 * @sin(t + 4.0),
    ));
    g.fillRect(.{ .x = 30, .y = 30, .width = 180, .height = 180 });

    g.drawImage(r.image.*, 230, 30);

    const text = "Hello こんにちは!";
    const text_color: awt.Graphics.Color = if ((@as(u64, @intFromFloat(t)) & 1) == 0)
        awt.Graphics.Color.rgb(1, 0, 0)
    else
        awt.Graphics.Color.rgb(0, 0, 0);
    g.setColor(text_color);
    // Top-of-bounding-box at (30, 220), roughly underneath the color rect.
    g.drawString(text, 30, 220);

    // ── Bottom row: SDF rounded rect (fill + outline), circle (fill + outline) ──
    const y_row: f32 = 320;
    const side: f32 = 100;
    const gap: f32 = 40;
    g.setColor(awt.Graphics.Color.rgb(0.95, 0.55, 0.20));
    g.fillRoundRect(.{ .x = 30, .y = y_row, .width = side, .height = side }, 20);

    g.setColor(awt.Graphics.Color.rgb(0.20, 0.75, 0.95));
    g.drawRoundRect(.{ .x = 30 + side + gap, .y = y_row, .width = side, .height = side }, 20);

    g.setColor(awt.Graphics.Color.rgb(0.90, 0.30, 0.70));
    g.fillCircle(.{ .x = 30 + 2 * (side + gap), .y = y_row, .width = side, .height = side });

    g.setColor(awt.Graphics.Color.rgb(0.95, 0.85, 0.20));
    g.drawCircle(.{ .x = 30 + 3 * (side + gap), .y = y_row, .width = side, .height = side });

    // ── A rectangle outline + a clipped child draw to exercise drawRect / clip ──
    g.setColor(awt.Graphics.Color.rgb(0.7, 0.7, 0.7));
    g.drawRect(.{ .x = 30, .y = 460, .width = 740, .height = 100 });

    var inner = g.clip(.{ .x = 40, .y = 470, .width = 720, .height = 80 });
    inner.setColor(awt.Graphics.Color.rgb(0.3, 0.5, 0.9));
    inner.fillRect(.{ .x = 0, .y = 0, .width = 720, .height = 80 });
    inner.setColor(awt.Graphics.Color.rgb(1, 1, 1));
    inner.setFont(.{ .face = r.font, .pixel_size = 24 });
    inner.drawString("clip()されたGraphicsで子コンテナを描画", 10, 10);

    // ── framework Component / Container / Label の動作確認 ───────────
    // 直接 paint (Container を介さない leaf Label)。
    r.fw_label.component.paintAt(&g);
    // Container 経由で paint (子 2 個を再帰描画)。
    r.fw_container.component.paintAt(&g);

    cb.end();
    cb.submit(r.device.*);
    r.swapchain.present();
}

fn onResize(
    _: ?*c.struct_nmWindow,
    fb_width: c_int,
    fb_height: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const r: *Renderer = @ptrCast(@alignCast(user_data.?));
    r.swapchain.resize(@intCast(fb_width), @intCast(fb_height)) catch {};
    r.fb_w = @intCast(fb_width);
    r.fb_h = @intCast(fb_height);
    const sz = r.window.size();
    r.window_w = sz.width;
    r.window_h = sz.height;
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

    var window = try awt.Window.init("hello nimbus", 800, 700);
    defer window.deinit();

    var swapchain = try awt.Swapchain.init(device, window);
    defer swapchain.deinit();

    // Seed both logical (points) and framebuffer (pixels) sizes — they differ
    // on HiDPI displays (Retina 2x → fb is 2× logical). GLFW does not fire the
    // framebuffer-size callback on creation, so the initial values are queried
    // here; subsequent updates land in `onResize`.
    const win_size = window.size();
    const fb_size = window.framebufferSize();

    const gpa = std.heap.page_allocator;

    var font = try awt.Font.init(gpa, noto_sans_ttf, 0);
    defer font.deinit();

    var atlas = try awt.GlyphAtlas.init(gpa, device, 2048);
    defer atlas.deinit();

    var image = try awt.Image.fromMemory(gpa, device, example_png);
    defer image.deinit();
    std.debug.print("example.png: {d}x{d}\n", .{ image.width, image.height });

    // Programs (long-lived).
    var color_program = try awt.programs.Color.init(device);
    defer color_program.deinit();
    var image_program = try awt.programs.Image.init(device);
    defer image_program.deinit();
    var gradient_program = try awt.programs.Gradient.init(device);
    defer gradient_program.deinit();
    var rrect_program = try awt.programs.RoundedRect.init(device);
    defer rrect_program.deinit();
    var text_program = try awt.programs.Text.init(device);
    defer text_program.deinit();

    // Ring buffers + static quad index buffer.
    var vertex_ring = try awt.VertexRing.init(device, 256 * 1024);
    defer vertex_ring.deinit();
    var uniforms = try awt.UniformBuffer.init(device, 64 * 1024);
    defer uniforms.deinit();
    var quad_index = try awt.QuadIndexBuffer.init(gpa, device, 1024);
    defer quad_index.deinit();

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

    // ── framework widgets ──────────────────────────────────────────
    // 既存の awt 直叩き描画はウィンドウ上半分 (y < 600) を占有しているので、
    // framework widget は底辺 100px のエリア (y = 600〜700) に配置する。

    // Standalone Label: 黄色テキスト、左下に配置。
    const fw_label = try Label.create(
        gpa,
        "framework Label (direct paint)",
        .{ .face = font, .pixel_size = 24 },
        awt.Graphics.Color.rgb(1, 1, 0),
    );
    // vtable.destroy handles deinit + allocator.destroy in one call.
    defer fw_label.component.vtable.destroy(&fw_label.component, gpa);
    fw_label.component.setBounds(.{ .x = 30, .y = 610, .width = 400, .height = 32 });

    // Container + 子 Label 2 個、右下に配置。Container.create handles
    // alloc + init + install in one shot.
    const fw_container = try Container.create(gpa);
    fw_container.component.setBounds(.{ .x = 430, .y = 605, .width = 350, .height = 60 });
    // Destroys the container and (recursively) any children added below.
    defer fw_container.component.vtable.destroy(&fw_container.component, gpa);

    const child_a = try Label.create(
        gpa,
        "container child A (green)",
        .{ .face = font, .pixel_size = 20 },
        awt.Graphics.Color.rgb(0, 1, 0),
    );
    child_a.component.setBounds(.{ .x = 0, .y = 0, .width = 380, .height = 24 });
    try fw_container.add(&child_a.component);

    const child_b = try Label.create(
        gpa,
        "container child B (cyan)",
        .{ .face = font, .pixel_size = 20 },
        awt.Graphics.Color.rgb(0, 1, 1),
    );
    child_b.component.setBounds(.{ .x = 0, .y = 28, .width = 380, .height = 24 });
    try fw_container.add(&child_b.component);

    var renderer = Renderer{
        .device = &device,
        .swapchain = &swapchain,
        .window = &window,
        .ctx = &ctx,
        .image = &image,
        .font = font,
        .window_w = win_size.width,
        .window_h = win_size.height,
        .fb_w = fb_size.width,
        .fb_h = fb_size.height,
        .fw_label = fw_label,
        .fw_container = fw_container,
    };
    window.setResizeCallback(onResize, &renderer);
    window.setRefreshCallback(onRefresh, &renderer);

    std.debug.print("Window opened. Close it to exit.\n", .{});
    while (!window.shouldClose()) {
        awt.pollEvents();
        renderFrame(&renderer);
    }

    device.waitIdle();
    std.debug.print("Bye.\n", .{});
}
