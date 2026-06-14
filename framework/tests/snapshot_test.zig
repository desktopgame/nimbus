//! Framework-level golden-image snapshot tests.
//!
//! Same harness as `awt/tests/snapshot_test.zig` (compares offscreen
//! renders against PNG fixtures via `awt.snapshot`), but the scenes here
//! come from the framework's widget tree. Fixtures live under
//! `framework/tests/fixtures/`; mismatches drop artifacts in
//! `tmp/snapshot_failures/`. Set `NIMBUS_UPDATE_SNAPSHOTS=1` to
//! regenerate every fixture.

const std = @import("std");
const awt = @import("awt");
const scenes = @import("framework_scenes");

const FIXTURE_DIR = "framework/tests/fixtures";
const FAILURE_DIR = "tmp/snapshot_failures";
const TOLERANCE: u8 = 1;

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

test "snapshot: box_horizontal_pack" {
    try runScene(scenes.box_horizontal_pack);
}

test "snapshot: box_horizontal_grow_weights" {
    try runScene(scenes.box_horizontal_grow_weights);
}

test "snapshot: box_vertical_align_cross" {
    try runScene(scenes.box_vertical_align_cross);
}

test "snapshot: border_five_regions" {
    try runScene(scenes.border_five_regions);
}

test "snapshot: toggle_checkboxes" {
    try runScene(scenes.toggle_checkboxes);
}

test "snapshot: toggle_radios" {
    try runScene(scenes.toggle_radios);
}

test "snapshot: toggle_combobox_closed" {
    try runScene(scenes.toggle_combobox_closed);
}

test "snapshot: tabbed_pane" {
    try runScene(scenes.tabbed_pane);
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
