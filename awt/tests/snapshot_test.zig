//! Golden-image snapshot test runner.
//!
//! Each scene defined in `scenes.zig` is rendered into an offscreen render
//! target, read back as RGBA8, and compared against a fixture PNG under
//! `awt/tests/fixtures/` via `awt.snapshot`. When the fixture is missing
//! the actual image is written there and the test passes (first-run
//! bootstrap). To deliberately regenerate every fixture, set the env var
//! `NIMBUS_UPDATE_SNAPSHOTS=1`.
//!
//! On mismatch the actual image and an amplified diff image are written
//! under `tmp/snapshot_failures/` for manual inspection.

const std = @import("std");
const awt = @import("awt");
const scenes = @import("scenes");

const FIXTURE_DIR = "awt/tests/fixtures";
const FAILURE_DIR = "tmp/snapshot_failures";
/// Per-channel absolute tolerance (0..255). One LSB of jitter is normal
/// across GPU drivers.
const TOLERANCE: u8 = 1;

// AWT is process-wide state (GLFW global init); init lazily and never
// terminate. Test runners exit the process when done, so leaking is fine.
var awt_initialized: bool = false;

/// Test-quiet log: drop debug/info chatter, keep warn/error visible. Any
/// stderr from a passing test binary makes `zig build` print it under a
/// noisy "failed command:" banner, so the happy path must stay silent.
fn quietLog(level: awt.LogLevel, category: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level < awt.c.nmLogLevelWarn) return;
    const tag: []const u8 = if (level == awt.c.nmLogLevelWarn) "WARN" else "ERROR";
    const cat: [*:0]const u8 = category;
    const msg: [*:0]const u8 = message;
    std.debug.print("[{s}] [{s}] {s}\n", .{ tag, std.mem.span(cat), std.mem.span(msg) });
}

fn ensureAwt() !void {
    if (awt_initialized) return;
    awt.setLogCallback(quietLog, null);
    try awt.init();
    awt_initialized = true;
}

test "snapshot: basic_shapes" {
    try runScene(scenes.basic_shapes);
}

test "snapshot: vertical_gradient" {
    try runScene(scenes.vertical_gradient);
}

test "snapshot: layout_horizontal_buttons" {
    try runScene(scenes.layout_horizontal_buttons);
}

test "snapshot: layout_vertical_grow" {
    try runScene(scenes.layout_vertical_grow);
}

test "snapshot: layout_right_aligned" {
    try runScene(scenes.layout_right_aligned);
}

test "snapshot: layout_centered" {
    try runScene(scenes.layout_centered);
}

test "snapshot: layout_panel_decoration" {
    try runScene(scenes.layout_panel_decoration);
}

test "snapshot: layout_nested" {
    try runScene(scenes.layout_nested);
}

test "snapshot: layout_border_shell" {
    try runScene(scenes.layout_border_shell);
}

test "snapshot: menu_bar_closed" {
    try runScene(scenes.menu_bar_closed);
}

fn runScene(scene: scenes.Scene) !void {
    const allocator = std.testing.allocator;

    ensureAwt() catch return error.SkipZigTest;

    var device = awt.Device.init() catch return error.SkipZigTest;
    defer device.deinit();

    var font = try awt.Font.init(scenes.default_font_bytes, 0);
    defer font.deinit();

    const actual = try renderScene(allocator, device, font, scene);
    defer allocator.free(actual);

    try snapshotCompare(allocator, scene, actual);
}

fn renderScene(
    allocator: std.mem.Allocator,
    device: awt.Device,
    font: awt.Font,
    scene: scenes.Scene,
) ![]u8 {
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
    var quad_index = try awt.QuadIndexBuffer.init(allocator, device, 256);
    defer quad_index.deinit();
    var atlas = try awt.GlyphAtlas.init(allocator, device, 256);
    defer atlas.deinit();

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
            .allocator = allocator,
            .font = font,
            .width = scene.width,
            .height = scene.height,
        });

        cb.end();
        cb.submit(device);
    }

    device.waitIdle();

    const w: usize = @intCast(scene.width);
    const h: usize = @intCast(scene.height);
    const buf = try allocator.alloc(u8, w * h * 4);
    errdefer allocator.free(buf);
    try rt.readback(scene.width, scene.height, buf);
    return buf;
}

fn snapshotCompare(
    allocator: std.mem.Allocator,
    scene: scenes.Scene,
    actual: []const u8,
) !void {
    const w: usize = @intCast(scene.width);
    const h: usize = @intCast(scene.height);

    var path_buf: [256]u8 = undefined;
    const fixture_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}.png",
        .{ FIXTURE_DIR, scene.name },
    );

    if (shouldUpdate(allocator)) {
        try ensureDir(FIXTURE_DIR);
        try awt.snapshot.writePng(allocator, std.testing.io, fixture_path, actual, w, h);
        std.debug.print("[snapshot] updated: {s}\n", .{fixture_path});
        return;
    }

    const expected = awt.snapshot.readPng(allocator, std.testing.io, fixture_path, w, h) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureDir(FIXTURE_DIR);
            try awt.snapshot.writePng(allocator, std.testing.io, fixture_path, actual, w, h);
            std.debug.print(
                "[snapshot] created: {s} (first run — review and commit)\n",
                .{fixture_path},
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(expected);

    const result = awt.snapshot.compare(actual, expected, .{ .tolerance = TOLERANCE });
    if (!result.ok()) {
        std.debug.print(
            "[snapshot] {} channel(s) exceed tolerance +-{} (max diff {})\n",
            .{ result.mismatch_channels, TOLERANCE, result.max_diff },
        );
        writeFailureArtifacts(allocator, scene.name, actual, expected, w, h) catch {};
        std.debug.print(
            "[snapshot] mismatch '{s}'. artifacts under {s}/\n",
            .{ scene.name, FAILURE_DIR },
        );
        return error.SnapshotPixelMismatch;
    }
}

fn shouldUpdate(allocator: std.mem.Allocator) bool {
    const val = std.testing.environ.getAlloc(allocator, "NIMBUS_UPDATE_SNAPSHOTS") catch return false;
    defer allocator.free(val);
    return val.len > 0 and !std.mem.eql(u8, val, "0");
}

fn ensureDir(path: []const u8) !void {
    // `createDirPath` is a no-op when the directory already exists, so no
    // separate "already exists" branch is needed.
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
}

fn writeFailureArtifacts(
    allocator: std.mem.Allocator,
    name: []const u8,
    actual: []const u8,
    expected: []const u8,
    w: usize,
    h: usize,
) !void {
    try ensureDir(FAILURE_DIR);

    var path_buf: [256]u8 = undefined;
    {
        const path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}_actual.png",
            .{ FAILURE_DIR, name },
        );
        try awt.snapshot.writePng(allocator, std.testing.io, path, actual, w, h);
    }

    if (expected.len == actual.len) {
        const diff = try awt.snapshot.diffImage(allocator, actual, expected);
        defer allocator.free(diff);
        const path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}_diff.png",
            .{ FAILURE_DIR, name },
        );
        try awt.snapshot.writePng(allocator, std.testing.io, path, diff, w, h);
    }
}
