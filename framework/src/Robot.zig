//! Headless / deterministic UI driver. See `framework/doc/robot.md`.
//!
//! `Robot` is the meaning-agnostic primitive layer: it synthesizes input
//! events (act), steps the event loop one iteration without blocking (drive),
//! and reads the component tree / pixels back (observe). It borrows the
//! `Application` and a `Window`; it owns neither and must outlive neither.
//!
//! The semantic wrapper (`Driver.find` / `clickOn` by role + text) is a thin
//! layer on top and is not implemented yet (waits on `Component.A11y.name`).

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Window = @import("Window.zig");
const Application = @import("Application.zig");

const Robot = @This();

/// One node of the curated `tree` snapshot. `name` / `text` borrow the source
/// component's strings — valid only while that component is alive.
pub const NodeSnapshot = struct {
    role:      Component.Role,
    name:      ?[]const u8, // Component.name (debug name); null if unset
    text:      ?[]const u8, // accessible name via Component.a11y; null if unset
    rect:      Component.Rect, // window-local absolute rect
    focusable: bool,
    focused:   bool, // this component is the window's focus owner
    children:  []NodeSnapshot, // paint order (back → front)
};

app:    *Application, // borrowed
window: *Window,      // borrowed; the target window
/// Last synthesized cursor position (window-local). `mouseDown` / `mouseUp` /
/// `scroll` emit at this point; `moveMouse` / `click` update it.
cursor: Component.Point,

/// Initialize a Robot over `app` and `window`. No allocation, cannot fail.
pub fn init(app: *Application, window: *Window) Robot {
    return .{ .app = app, .window = window, .cursor = .{ .x = 0, .y = 0 } };
}

// ── act: synthetic input ──────────────────────────────────────────────────
// Every event takes the same path as real OS input (`postInput` →
// `EventQueue.postEvent` → `Window.dispatchInput`), dispatched on the next
// `pump`. A failed enqueue (OOM) drops the event, mirroring how the real OS
// input callbacks handle `postEvent` failure.

fn post(self: *Robot, payload: awt.Event.Payload) void {
    self.window.postInput(.{ .payload = payload }) catch {};
}

/// Move the cursor to (`x`, `y`) (window-local) via a synthetic `.move`.
pub fn moveMouse(self: *Robot, x: f32, y: f32) void {
    self.cursor = .{ .x = x, .y = y };
    self.post(.{ .mouse = .{ .x = x, .y = y, .action = .move } });
}

/// Press `button` at the current cursor position.
pub fn mouseDown(self: *Robot, button: awt.Event.MouseButton) void {
    self.post(.{ .mouse = .{ .x = self.cursor.x, .y = self.cursor.y, .button = button, .action = .press } });
}

/// Release `button` at the current cursor position.
pub fn mouseUp(self: *Robot, button: awt.Event.MouseButton) void {
    self.post(.{ .mouse = .{ .x = self.cursor.x, .y = self.cursor.y, .button = button, .action = .release } });
}

/// Move to (`x`, `y`) then press + release `button` — a full click.
pub fn click(self: *Robot, x: f32, y: f32, button: awt.Event.MouseButton) void {
    self.moveMouse(x, y);
    self.mouseDown(button);
    self.mouseUp(button);
}

/// Wheel scroll by `dy` at the current cursor position.
pub fn scroll(self: *Robot, dy: f32) void {
    self.post(.{ .mouse = .{ .x = self.cursor.x, .y = self.cursor.y, .action = .scroll, .wheel = dy } });
}

/// Press `code` with `mods` held. Goes to the focus owner (or container fan-out).
pub fn keyDown(self: *Robot, code: awt.Event.KeyCode, mods: awt.Event.Modifiers) void {
    self.post(.{ .key = .{ .code = code, .action = .press, .modifiers = mods } });
}

/// Release `code` with `mods` held.
pub fn keyUp(self: *Robot, code: awt.Event.KeyCode, mods: awt.Event.Modifiers) void {
    self.post(.{ .key = .{ .code = code, .action = .release, .modifiers = mods } });
}

/// Type `utf8` as a sequence of `.char` events (one per codepoint), the
/// committed-character path used for text input (not physical `.key`).
/// Invalid byte sequences are skipped.
pub fn typeText(self: *Robot, utf8: []const u8) void {
    var i: usize = 0;
    while (i < utf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > utf8.len) break;
        const cp = std.unicode.utf8Decode(utf8[i .. i + len]) catch {
            i += len;
            continue;
        };
        self.post(.{ .char = .{ .codepoint = cp } });
        i += len;
    }
}

/// Emit an IME composition (preedit) update. `text` is borrowed until the next
/// `pump` dispatches it, so keep it alive until then.
pub fn composition(self: *Robot, text: []const u8, target_start: usize, target_end: usize) void {
    self.post(.{ .composition = .{ .text = text, .target_start = target_start, .target_end = target_end } });
}

// ── drive: step the loop ──────────────────────────────────────────────────

/// Run one iteration of the event loop without blocking: fire due timers,
/// drain queued (synthetic) input, redraw dirty windows. Same body as
/// `Application.run`'s loop minus the OS wait.
pub fn pump(self: *Robot) void {
    self.app.tickOnce();
}

/// Advance the virtual clock by `ms` ms (headless apps only). Due timers do not
/// fire until the next `pump`.
pub fn advanceClock(self: *Robot, ms: u32) void {
    self.app.advanceClock(ms);
}

// ── observe: snapshots ────────────────────────────────────────────────────

/// Build a curated `NodeSnapshot` tree of the window's content (the container
/// subtree). `role` / `rect` / `focusable` / `focused` are always present;
/// `text` comes from `Component.a11y.name` (null until widgets wire it).
/// Free with `freeTree`.
pub fn snapshotTree(self: *Robot, allocator: std.mem.Allocator) !NodeSnapshot {
    return buildNode(allocator, self.window, &self.window.container.component);
}

/// Free a tree returned by `snapshotTree`. Borrowed strings are not freed.
pub fn freeTree(allocator: std.mem.Allocator, root: NodeSnapshot) void {
    var r = root;
    freeNode(allocator, &r);
}

fn buildNode(allocator: std.mem.Allocator, win: *Window, c: *Component) !NodeSnapshot {
    var children: []NodeSnapshot = &.{};
    if (c.container) |cont| {
        const kids = cont.children.items;
        const buf = try allocator.alloc(NodeSnapshot, kids.len);
        errdefer allocator.free(buf);
        var built: usize = 0;
        errdefer for (buf[0..built]) |*n| freeNode(allocator, n);
        for (kids) |elem| {
            buf[built] = try buildNode(allocator, win, elem.component);
            built += 1;
        }
        children = buf;
    }
    const origin = c.absoluteOriginInWindow();
    return .{
        .role = c.role,
        .name = c.name,
        .text = if (c.a11y) |a| a.name(c) else null,
        .rect = .{ .x = origin.x, .y = origin.y, .width = c.size.width, .height = c.size.height },
        .focusable = c.focusable,
        .focused = (win.focus_owner == c),
        .children = children,
    };
}

fn freeNode(allocator: std.mem.Allocator, n: *NodeSnapshot) void {
    for (n.children) |*ch| freeNode(allocator, ch);
    if (n.children.len > 0) allocator.free(n.children);
}

/// Read back the headless window's framebuffer as RGBA8 into `out_rgba`
/// (length must be `fb_w * fb_h * 4`). Headless only — a real swapchain window
/// returns `error.NotHeadless` (use the on-screen pixels instead). Call after a
/// `pump` so the latest frame is rendered.
pub fn snapshotPixels(self: *Robot, out_rgba: []u8) !void {
    const win = self.window;
    if (win.render_target) |*rt| {
        self.app.device.waitIdle();
        try rt.readback(win.fb_w, win.fb_h, out_rgba);
    } else return error.NotHeadless;
}

/// Convenience: snapshot the headless framebuffer straight to a PNG file.
pub fn snapshotPng(self: *Robot, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const win = self.window;
    const w: usize = @intCast(win.fb_w);
    const h: usize = @intCast(win.fb_h);
    const buf = try allocator.alloc(u8, w * h * 4);
    defer allocator.free(buf);
    try self.snapshotPixels(buf);
    try awt.snapshot.writePng(allocator, io, path, buf, w, h);
}

// ── tests ─────────────────────────────────────────────────────────────────

fn treeHasRole(node: NodeSnapshot, role: Component.Role) bool {
    if (node.role == role) return true;
    for (node.children) |ch| if (treeHasRole(ch, role)) return true;
    return false;
}

test "headless robot: click reaches the button; tree exposes its role" {
    const gpa = std.testing.allocator;
    const ActionEvent = @import("listener.zig").ActionEvent;

    // Headless app (no OS window; virtual clock). Skip where no GPU is available.
    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 200, 120);
    // Manual placement so our setBounds sticks (no BorderLayout reflow).
    frame.window.container.setLayout(null);

    const Ctx = struct { fired: bool = false };
    var ctx: Ctx = .{};
    const btn = try app.button("Go");
    btn.component.setBounds(.{ .x = 10, .y = 10, .width = 80, .height = 30 });
    try btn.getModel().addActionListener(Ctx, struct {
        fn f(c: *Ctx, _: *const ActionEvent) void {
            c.fired = true;
        }
    }.f, &ctx);
    try frame.window.add(&btn.component);

    var robot = Robot.init(app, &frame.window);
    robot.pump(); // initial layout + paint

    try std.testing.expect(!ctx.fired);
    robot.click(50, 25, .left); // inside the button rect
    robot.pump(); // drains move + press + release
    try std.testing.expect(ctx.fired);

    // Structural snapshot sees the button by role (text is null until a11y.name).
    const tree = try robot.snapshotTree(gpa);
    defer Robot.freeTree(gpa, tree);
    try std.testing.expect(treeHasRole(tree, .button));
}

test "headless robot: button rollover / press / release+action / un-hover" {
    const gpa = std.testing.allocator;
    const ActionEvent = @import("listener.zig").ActionEvent;

    const app = Application.initHeadless(gpa, std.testing.io) catch return error.SkipZigTest;
    defer app.deinit();

    const frame = try app.frameHeadless("t", 200, 120);
    frame.window.container.setLayout(null); // manual placement so bounds stick

    const Ctx = struct { actions: u32 = 0 };
    var ctx: Ctx = .{};
    const btn = try app.button("Go");
    btn.component.setBounds(.{ .x = 10, .y = 10, .width = 80, .height = 30 });
    const model = btn.getModel();
    try model.addActionListener(Ctx, struct {
        fn f(c: *Ctx, _: *const ActionEvent) void {
            c.actions += 1;
        }
    }.f, &ctx);
    try frame.window.add(&btn.component);

    var robot = Robot.init(app, &frame.window);
    robot.pump();

    // Idle to start.
    try std.testing.expect(!model.isRollover());
    try std.testing.expect(!model.isPressed());
    try std.testing.expect(!model.isArmed());

    // Hover onto the button (50,25 is inside [10,10,80,30]) → rollover, nothing else.
    robot.moveMouse(50, 25);
    robot.pump();
    try std.testing.expect(model.isRollover());
    try std.testing.expect(!model.isPressed());
    try std.testing.expect(!model.isArmed());
    try std.testing.expectEqual(@as(u32, 0), ctx.actions);

    // Press at the cursor → pressed + armed, no action yet.
    robot.mouseDown(.left);
    robot.pump();
    try std.testing.expect(model.isPressed());
    try std.testing.expect(model.isArmed());
    try std.testing.expectEqual(@as(u32, 0), ctx.actions);

    // Release inside → un-press, un-arm, ActionEvent fires exactly once.
    robot.mouseUp(.left);
    robot.pump();
    try std.testing.expect(!model.isPressed());
    try std.testing.expect(!model.isArmed());
    try std.testing.expectEqual(@as(u32, 1), ctx.actions);
    try std.testing.expect(model.isRollover()); // cursor still over the button

    // Move off the button → rollover clears (Container.updateHover notifies it).
    robot.moveMouse(150, 100);
    robot.pump();
    try std.testing.expect(!model.isRollover());
    try std.testing.expectEqual(@as(u32, 1), ctx.actions); // no extra action
}
