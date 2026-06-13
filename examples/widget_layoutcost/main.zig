//! Layout stress / benchmark example. Builds a deeply nested, high-fanout tree
//! of BoxLayout containers (orientation alternates per level), then (1) times a
//! batch of forced full re-layouts up front and prints the cost, and (2) forces
//! a full re-layout *every frame* via a repeating timer so the window visibly
//! stutters under layout load — the interactive way to feel the cost.
//! Intended as the benchmark scene called for in `doc/internal/optimize.md`.
//!
//! With no size cache (the current v1 design), each `doLayout` re-measures
//! every subtree from scratch, so cost grows with depth × node count. The
//! default tree is large on purpose (~30k nodes, tens of ms per relayout) so
//! the continuous relayout is janky out of the box.
//!
//! To keep *layout* the bottleneck (not rendering), only a sparse subset of
//! leaves is painted — otherwise tens of thousands of filled rects per frame
//! would dominate and mask the layout cost we want to demonstrate.
//!
//! Usage:
//!     zig build run-widget_layoutcost                  # defaults: depth=9 fanout=3 iters=20
//!     zig build run-widget_layoutcost -- 10 3 10       # heavier: ~88k nodes, ~100ms/relayout
//!     zig build run-widget_layoutcost -- 6 3 200       # light, to compare
//!
//! Total node count is fanout^0 + ... + fanout^depth, so raising either
//! argument grows the tree fast. Args are clamped (depth ≤ 12, fanout ≤ 8) to
//! avoid accidentally allocating an enormous tree.

const std = @import("std");
const nimbus = @import("nimbus");

const Color = nimbus.awt.Graphics.Color;

/// Paint roughly 1 leaf in PAINT_STRIDE. Keeps draw count low so rendering does
/// not become the bottleneck and mask the layout cost.
const PAINT_STRIDE = 37;

const Params = struct {
    depth: u32 = 9,
    fanout: u32 = 3,
    iters: u32 = 20,
};

fn parseArgs(argv: []const [:0]const u8) Params {
    var p = Params{};
    if (argv.len > 1) p.depth = std.fmt.parseInt(u32, argv[1], 10) catch p.depth;
    if (argv.len > 2) p.fanout = std.fmt.parseInt(u32, argv[2], 10) catch p.fanout;
    if (argv.len > 3) p.iters = std.fmt.parseInt(u32, argv[3], 10) catch p.iters;
    // Clamp so a typo cannot try to allocate billions of nodes.
    p.depth = @min(p.depth, 12);
    p.fanout = std.math.clamp(p.fanout, 1, 8);
    p.iters = @max(p.iters, 1);
    return p;
}

/// Build one subtree and return its root component. Internal nodes are plain
/// Containers carrying a BoxLayout whose orientation flips each level; leaves
/// are Panels with a fixed min size (only a sparse subset is painted, see
/// PAINT_STRIDE). `count` is incremented per node so the caller can report the
/// total. Children get a main-axis grow weight so the layout actually
/// distributes free space (exercising the division path).
fn buildSubtree(
    app: *nimbus.Application,
    depth: u32,
    fanout: u32,
    horizontal: bool,
    count: *usize,
) !*nimbus.Component {
    count.* += 1;

    if (depth == 0) {
        const leaf = try app.panel();
        leaf.container.component.setMinSize(.{ .width = 12, .height = 12 });
        if (count.* % PAINT_STRIDE == 0) {
            const n: f32 = @floatFromInt((count.* / PAINT_STRIDE) % 6);
            leaf.setBackground(Color.rgba(0.25 + n * 0.12, 0.45, 0.85 - n * 0.1, 1));
        }
        return &leaf.container.component;
    }

    const node = try app.container();
    node.setLayout(if (horizontal) nimbus.BoxLayout.horizontal() else nimbus.BoxLayout.vertical());

    var i: u32 = 0;
    while (i < fanout) : (i += 1) {
        const child = try buildSubtree(app, depth - 1, fanout, !horizontal, count);
        // Grow on the parent's main axis so siblings share the free space.
        if (horizontal) child.setGrowX(1) else child.setGrowY(1);
        try node.add(child);
    }
    return &node.component;
}

/// Repeating-timer callback: dirty the root each tick so the run loop performs
/// a full re-layout of the whole tree every frame. This is what makes the
/// window visibly stutter under layout load.
fn onTick(user_data: *anyopaque) void {
    const root: *nimbus.Container = @ptrCast(@alignCast(user_data));
    root.component.markLayoutDirty();
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const params = parseArgs(argv);

    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const W: u32 = 800;
    const H: u32 = 600;
    const frame = try app.frame("widget layoutcost", W, H);

    var node_count: usize = 0;
    const root = try buildSubtree(app, params.depth, params.fanout, true, &node_count);
    try nimbus.BorderLayout.add(&frame.window.container, .center, root);

    // Give the tree a real size to distribute, then time a batch of full
    // re-layouts. setBounds itself runs one layout pass; the loop adds `iters`
    // more. doLayout has no dirty short-circuit, so each call pays full cost.
    frame.window.container.setBounds(.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(W),
        .height = @floatFromInt(H),
    });

    const t0 = std.Io.Timestamp.now(init.io, .awake);
    var i: u32 = 0;
    while (i < params.iters) : (i += 1) {
        frame.window.container.doLayout();
    }
    const t1 = std.Io.Timestamp.now(init.io, .awake);
    const elapsed_ns: u64 = @intCast(@max(0, t1.nanoseconds - t0.nanoseconds));

    const per_iter_us =
        @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(params.iters)) / 1000.0;
    std.debug.print(
        \\layout cost benchmark
        \\  depth      : {d}
        \\  fanout     : {d}
        \\  nodes      : {d}
        \\  iterations : {d}
        \\  total      : {d:.3} ms
        \\  per relayout: {d:.3} us  (~{d:.0} fps if relayouting every frame)
        \\
        \\Re-laying out the whole tree every frame — the window should stutter.
        \\Resize it to feel it too. Close the window to exit.
        \\
    , .{
        params.depth,
        params.fanout,
        node_count,
        params.iters,
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
        per_iter_us,
        if (per_iter_us > 0) 1_000_000.0 / per_iter_us else 0,
    });

    // Force a full relayout every frame so the cost is sustained and visible,
    // not just on resize. 1 ms period → fires as fast as the loop can keep up.
    _ = try app.setInterval(1, onTick, @ptrCast(&frame.window.container));

    try app.run();
}
