//! Snapshot test scenes. Each `Scene` is a deterministic paint sequence
//! that the snapshot test runner renders into an offscreen render target
//! and compares against a fixture PNG. The same scenes are usable from
//! `examples/snapshot` for visual inspection.

const awt = @import("awt");

pub const Scene = struct {
    /// Stable identifier; used as the fixture file basename.
    name: []const u8,
    /// Render target size (pixels).
    width: i32,
    height: i32,
    /// Clear color applied before `paint`.
    clear: [4]f32 = .{ 0.10, 0.10, 0.15, 1.0 },
    paint: *const fn (g: *awt.Graphics) void,
};

pub const basic_shapes = Scene{
    .name = "basic_shapes",
    .width = 400,
    .height = 300,
    .paint = paintBasicShapes,
};

fn paintBasicShapes(g: *awt.Graphics) void {
    // Two filled rects (Color program).
    g.setColor(awt.Graphics.Color.rgb(0.95, 0.30, 0.30));
    g.fillRect(.{ .x = 20, .y = 20, .width = 100, .height = 60 });
    g.setColor(awt.Graphics.Color.rgb(0.30, 0.95, 0.50));
    g.fillRect(.{ .x = 140, .y = 20, .width = 100, .height = 60 });

    // Rounded rect + circle (RoundedRect / SDF).
    g.setColor(awt.Graphics.Color.rgb(0.30, 0.60, 0.95));
    g.fillRoundRect(.{ .x = 20, .y = 110, .width = 100, .height = 100 }, 20);
    g.setColor(awt.Graphics.Color.rgb(0.95, 0.85, 0.30));
    g.fillCircle(.{ .x = 140, .y = 110, .width = 100, .height = 100 });

    // 1px outlines.
    g.setColor(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));
    g.drawRect(.{ .x = 260, .y = 20, .width = 120, .height = 90 });
    g.drawRoundRect(.{ .x = 260, .y = 130, .width = 120, .height = 80 }, 16);
}

/// All scenes the snapshot runner should cover. Add entries here when
/// introducing a new scene; the runner generates one test per entry.
pub const all = [_]Scene{
    basic_shapes,
};
