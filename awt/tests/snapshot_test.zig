//! Golden-image snapshot test runner.
//!
//! Each scene defined in `scenes.zig` is rendered into an offscreen render
//! target, read back as RGBA8, and compared against a fixture PNG under
//! `awt/tests/fixtures/`. When the fixture is missing the actual image is
//! written there and the test passes (first-run bootstrap). To deliberately
//! regenerate every fixture, set the env var `NIMBUS_UPDATE_SNAPSHOTS=1`.
//!
//! On mismatch the actual image and an amplified diff image are written
//! under `tmp/snapshot_failures/` for manual inspection.

const std = @import("std");
const awt = @import("awt");
const zigimg = @import("zigimg");
const scenes = @import("scenes");

const FIXTURE_DIR = "awt/tests/fixtures";
const FAILURE_DIR = "tmp/snapshot_failures";
/// Per-channel absolute tolerance (0..255). One LSB of jitter is normal
/// across GPU drivers.
const TOLERANCE: u8 = 1;
const READ_BUFFER_SIZE = zigimg.io.DEFAULT_BUFFER_SIZE;

// AWT is process-wide state (GLFW global init); init lazily and never
// terminate. Test runners exit the process when done, so leaking is fine.
var awt_initialized: bool = false;

fn ensureAwt() !void {
    if (awt_initialized) return;
    try awt.init();
    awt_initialized = true;
}

test "snapshot: basic_shapes" {
    try runScene(scenes.basic_shapes);
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
        try writePng(allocator, fixture_path, actual, w, h);
        std.debug.print("[snapshot] updated: {s}\n", .{fixture_path});
        return;
    }

    const expected = readPng(allocator, fixture_path, w, h) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureDir(FIXTURE_DIR);
            try writePng(allocator, fixture_path, actual, w, h);
            std.debug.print(
                "[snapshot] created: {s} (first run — review and commit)\n",
                .{fixture_path},
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(expected);

    comparePixels(actual, expected, TOLERANCE) catch |err| {
        writeFailureArtifacts(allocator, scene.name, actual, expected, w, h) catch {};
        std.debug.print(
            "[snapshot] mismatch '{s}'. artifacts under {s}/\n",
            .{ scene.name, FAILURE_DIR },
        );
        return err;
    };
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

fn comparePixels(actual: []const u8, expected: []const u8, tolerance: u8) !void {
    if (actual.len != expected.len) {
        std.debug.print(
            "[snapshot] size mismatch: actual={} expected={}\n",
            .{ actual.len, expected.len },
        );
        return error.SnapshotSizeMismatch;
    }
    var max_diff: u8 = 0;
    var mismatch_count: usize = 0;
    for (actual, expected) |a, e| {
        const d: u8 = if (a > e) a - e else e - a;
        if (d > tolerance) {
            mismatch_count += 1;
            if (d > max_diff) max_diff = d;
        }
    }
    if (mismatch_count > 0) {
        std.debug.print(
            "[snapshot] {} channel(s) exceed tolerance +-{} (max diff {})\n",
            .{ mismatch_count, tolerance, max_diff },
        );
        return error.SnapshotPixelMismatch;
    }
}

fn writePng(
    allocator: std.mem.Allocator,
    path: []const u8,
    rgba: []const u8,
    w: usize,
    h: usize,
) !void {
    var img = try zigimg.Image.fromRawPixels(allocator, w, h, rgba, .rgba32);
    defer img.deinit(allocator);

    var write_buffer: [READ_BUFFER_SIZE]u8 = undefined;
    try img.writeToFilePath(
        allocator,
        std.testing.io,
        path,
        write_buffer[0..],
        .{ .png = .{} },
    );
}

fn readPng(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_w: usize,
    expected_h: usize,
) ![]u8 {
    var read_buffer: [READ_BUFFER_SIZE]u8 = undefined;
    var img = try zigimg.Image.fromFilePath(allocator, std.testing.io, path, read_buffer[0..]);
    defer img.deinit(allocator);

    if (img.width != expected_w or img.height != expected_h) {
        std.debug.print(
            "[snapshot] fixture {s} has size {}x{}, expected {}x{}\n",
            .{ path, img.width, img.height, expected_w, expected_h },
        );
        return error.SnapshotSizeMismatch;
    }

    try img.convert(allocator, .rgba32);

    const bytes = img.rawBytes();
    const out = try allocator.alloc(u8, bytes.len);
    @memcpy(out, bytes);
    return out;
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
        try writePng(allocator, path, actual, w, h);
    }

    // Diff image: per-channel |a-e| amplified 5x and clamped, alpha forced
    // opaque. Reads as black where matching, bright where divergent.
    const diff = try allocator.alloc(u8, actual.len);
    defer allocator.free(diff);
    if (expected.len == actual.len) {
        var i: usize = 0;
        while (i + 3 < actual.len) : (i += 4) {
            const dr: u8 = if (actual[i] > expected[i]) actual[i] - expected[i] else expected[i] - actual[i];
            const dg: u8 = if (actual[i + 1] > expected[i + 1]) actual[i + 1] - expected[i + 1] else expected[i + 1] - actual[i + 1];
            const db: u8 = if (actual[i + 2] > expected[i + 2]) actual[i + 2] - expected[i + 2] else expected[i + 2] - actual[i + 2];
            diff[i] = amp(dr);
            diff[i + 1] = amp(dg);
            diff[i + 2] = amp(db);
            diff[i + 3] = 255;
        }
        const path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}_diff.png",
            .{ FAILURE_DIR, name },
        );
        try writePng(allocator, path, diff, w, h);
    }
}

fn amp(d: u8) u8 {
    const scaled: u32 = @as(u32, d) * 5;
    return if (scaled > 255) 255 else @intCast(scaled);
}
