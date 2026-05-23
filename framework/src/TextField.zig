//! TextField widget. See `framework/doc/textfield.md`.
//!
//! Single-line, LTR, codepoint-granularity editing. State machine:
//!   - selection = [min(caret,mark), max(caret,mark))
//!   - char input replaces selection (or inserts at caret if empty)
//!   - key input: arrows / Home / End / Backspace / Del / Ctrl+A/C/X/V
//!   - mouse: press sets caret + mark; drag extends selection (capture)
//!   - caret blinks via Application.setInterval(500ms) while focused

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Application = @import("Application.zig");

const TextField = @This();

const PADDING_X: f32 = 6;
const PADDING_Y: f32 = 4;
const CARET_WIDTH: f32 = 1;
const DEFAULT_COLUMNS: f32 = 20;
const BLINK_PERIOD_MS: u32 = 500;
const BORDER_WIDTH: f32 = 1;

const SELECTION_BG    = awt.Graphics.Color.rgba(0.30, 0.55, 0.95, 0.40);
const BORDER_COLOR    = awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
const FOCUS_BORDER    = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);

component:      Component,
app:            *Application,
/// UTF-8 internal buffer. caret_byte / mark_byte are byte offsets into
/// this slice. Public APIs (setCaretAtCodepoint etc.) accept codepoint
/// indices so the byte representation is not contract surface.
text:           std.ArrayList(u8),
caret_byte:     usize,
mark_byte:      usize,
font:           awt.Graphics.TextFont,
color:          awt.Graphics.Color,
background:     awt.Graphics.Color,
caret_color:    awt.Graphics.Color,
caret_visible:  bool,
blink_timer_id: ?Application.TimerId,
has_focus:      bool,
allocator:      std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

pub fn create(
    allocator: std.mem.Allocator,
    app: *Application,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
    initial_text: []const u8,
) !*TextField {
    const tf = try allocator.create(TextField);
    errdefer allocator.destroy(tf);

    var text_buf: std.ArrayList(u8) = .empty;
    errdefer text_buf.deinit(allocator);
    try text_buf.appendSlice(allocator, initial_text);

    tf.* = .{
        .component      = Component.init(allocator, &vtable),
        .app            = app,
        .text           = text_buf,
        .caret_byte     = text_buf.items.len,
        .mark_byte      = text_buf.items.len,
        .font           = font,
        .color          = color,
        .background     = awt.Graphics.Color.rgb(1.0, 1.0, 1.0),
        .caret_color    = color,
        .caret_visible  = true,
        .blink_timer_id = null,
        .has_focus      = false,
        .allocator      = allocator,
    };
    tf.applyMetrics();
    try TextField.vtable.install(&tf.component);
    return tf;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getText(self: TextField) []const u8 {
    return self.text.items;
}

pub fn setText(self: *TextField, new_text: []const u8) !void {
    self.text.clearRetainingCapacity();
    try self.text.appendSlice(self.allocator, new_text);
    self.caret_byte = self.text.items.len;
    self.mark_byte = self.text.items.len;
    self.applyMetrics();
    self.component.repaint();
}

pub fn getCaretColor(self: TextField) awt.Graphics.Color {
    return self.caret_color;
}

pub fn setCaretColor(self: *TextField, c: awt.Graphics.Color) void {
    self.caret_color = c;
    self.component.repaint();
}

pub fn getBackground(self: TextField) awt.Graphics.Color {
    return self.background;
}

pub fn setBackground(self: *TextField, c: awt.Graphics.Color) void {
    self.background = c;
    self.component.repaint();
}

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *TextField) void {
    // setPixelSize MUST come first — both metrics() and glyphAdvance read
    // freetype state that is only valid for the most recently-set size.
    self.font.face.setPixelSize(self.font.pixel_size);
    const line_h = self.font.face.metrics().line_height;
    // Use 'M' as the canonical column-width sample (a common Western
    // convention; CJK columns naturally take ~2x this in advance units,
    // which is fine for a baseline).
    const sample_adv = self.font.face.glyphAdvance('M');
    const w = sample_adv * DEFAULT_COLUMNS + PADDING_X * 2;
    const h = line_h + PADDING_Y * 2;
    self.component.min_size = .{ .width = w, .height = h };
    self.component.max_size = .{ .width = std.math.inf(f32), .height = h };
    // grow_x defaults to 0 (Swing JTextField semantics): the widget reports
    // its preferred width (DEFAULT_COLUMNS * 'M' advance) and stays at that
    // size unless the caller opts in via `setGrowX(1)` or wraps it in a
    // container that distributes leftover space differently.
    self.component.grow_x = 0;
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);

    const tf: *TextField = @fieldParentPtr("component", self);
    // Caret blink: 500ms toggles `caret_visible` while focused. We register
    // unconditionally so blink continues to drive repaint even when
    // unfocused (the paint code skips drawing the caret then anyway).
    tf.blink_timer_id = try tf.app.setInterval(BLINK_PERIOD_MS, blinkTick, @ptrCast(tf));
}

fn uninstall(self: *Component) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    if (tf.blink_timer_id) |id| tf.app.clearTimer(id);
    tf.blink_timer_id = null;

    // Best-effort: if we're the focus owner, clear focus on the way out so
    // future input does not target freed memory. Parent chain may already
    // be torn (when destroy fires inside Container.deinit), in which case
    // requestFocus is a no-op — acceptable.
    if (tf.has_focus) self.requestFocus(); // will route to null via cleared focus_owner if root lost? — guarded below
    // Direct safety: walk to a root FocusController if any and request null
    // so window state stays consistent even when has_focus snapshot lies.
    var node: ?*Component = self;
    while (node) |cur| {
        if (cur.parent == null) {
            if (cur.getTyped(Component.FocusController)) |fc| {
                fc.request_focus_for(fc.user_data, null);
            }
            break;
        }
        node = cur.parent;
    }
}

fn blinkTick(user_data: *anyopaque) void {
    const tf: *TextField = @ptrCast(@alignCast(user_data));
    tf.caret_visible = !tf.caret_visible;
    // Only the caret region truly changes, but v1 has no partial repaint;
    // full widget repaint is acceptable per CLAUDE.md「ステップ D」.
    tf.component.repaint();
}

fn paint(self: *Component, g: *awt.Graphics) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    const sz = self.size;

    // Background.
    g.setColor(tf.background);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Border (1px). Blue when focused for keyboard-focus feedback,
    // mid-grey otherwise. Drawn as four edge strips so we don't need a
    // stroke primitive.
    g.setColor(if (tf.has_focus) FOCUS_BORDER else BORDER_COLOR);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = 0, .y = sz.height - BORDER_WIDTH, .width = sz.width, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = 0, .y = 0, .width = BORDER_WIDTH, .height = sz.height });
    g.fillRect(.{ .x = sz.width - BORDER_WIDTH, .y = 0, .width = BORDER_WIDTH, .height = sz.height });

    // Selection highlight (if non-empty).
    const sel_start = tf.selectionStartByte();
    const sel_end = tf.selectionEndByte();
    if (sel_end > sel_start) {
        const x0 = tf.xAtByte(sel_start);
        const x1 = tf.xAtByte(sel_end);
        g.setColor(SELECTION_BG);
        g.fillRect(.{
            .x = x0,
            .y = PADDING_Y,
            .width = x1 - x0,
            .height = sz.height - PADDING_Y * 2,
        });
    }

    // Text. `drawString` takes the top-left of the bbox (graphics.md: top-of-bbox派).
    g.setFont(tf.font);
    g.setColor(tf.color);
    g.drawString(tf.text.items, PADDING_X, PADDING_Y);

    // Caret (only when focused and currently visible during blink).
    if (tf.has_focus and tf.caret_visible) {
        const cx = tf.xAtByte(tf.caret_byte);
        g.setColor(tf.caret_color);
        g.fillRect(.{
            .x = cx,
            .y = PADDING_Y,
            .width = CARET_WIDTH,
            .height = sz.height - PADDING_Y * 2,
        });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    switch (ev.payload) {
        .mouse => |m| handleMouse(tf, ev, m),
        .key   => |k| handleKey(tf, ev, k),
        .char  => |ch| handleChar(tf, ev, ch),
        .focus => |f| {
            tf.has_focus = f.gained;
            // Restart blink at "visible" so the caret appears immediately
            // on focus gain (no awkward off→on flicker).
            tf.caret_visible = true;
            tf.component.repaint();
        },
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    self.deinit();
    tf.text.deinit(allocator);
    allocator.destroy(tf);
}

// ── input handlers ───────────────────────────────────────────────────────

fn handleMouse(tf: *TextField, ev: *Component.Event, m: awt.Event.MouseEvent) void {
    const origin = tf.component.absoluteOriginInWindow();
    const lx = m.x - origin.x;
    const ly = m.y - origin.y;
    const inside = lx >= 0 and lx < tf.component.size.width and ly >= 0 and ly < tf.component.size.height;

    switch (m.action) {
        .press => {
            if (m.button == .left and inside) {
                const pos = tf.hitTestByteAt(lx);
                tf.caret_byte = pos;
                tf.mark_byte = pos;
                ev.requestCapture(@ptrCast(&tf.component));
                tf.component.requestFocus();
                tf.caret_visible = true;
                tf.component.repaint();
                ev.consume();
            }
        },
        .release => {
            if (m.button == .left) ev.consume();
        },
        .move => {
            // Drag extends selection — caret moves, mark stays.
            // We get here either via capture (drag started inside) or
            // via plain hover; only treat as drag if mark != caret already
            // (i.e. we own a press).
            if (tf.has_focus) {
                const pos = tf.hitTestByteAt(lx);
                if (pos != tf.caret_byte) {
                    tf.caret_byte = pos;
                    tf.caret_visible = true;
                    tf.component.repaint();
                }
            }
        },
        .scroll => {},
    }
}

fn handleKey(tf: *TextField, ev: *Component.Event, k: awt.Event.KeyEvent) void {
    if (k.action != .press and k.action != .repeat) return;

    const shift = k.modifiers.shift;
    const ctrl  = k.modifiers.ctrl;

    switch (k.code) {
        .arrow_left => {
            const new_caret = prevCodepointBoundary(tf.text.items, tf.caret_byte);
            tf.caret_byte = new_caret;
            if (!shift) tf.mark_byte = tf.caret_byte;
            tf.afterEdit(ev);
        },
        .arrow_right => {
            const new_caret = nextCodepointBoundary(tf.text.items, tf.caret_byte);
            tf.caret_byte = new_caret;
            if (!shift) tf.mark_byte = tf.caret_byte;
            tf.afterEdit(ev);
        },
        .home => {
            tf.caret_byte = 0;
            if (!shift) tf.mark_byte = tf.caret_byte;
            tf.afterEdit(ev);
        },
        .end => {
            tf.caret_byte = tf.text.items.len;
            if (!shift) tf.mark_byte = tf.caret_byte;
            tf.afterEdit(ev);
        },
        .backspace => {
            if (tf.hasSelection()) {
                tf.deleteSelection() catch {};
            } else if (tf.caret_byte > 0) {
                const prev = prevCodepointBoundary(tf.text.items, tf.caret_byte);
                tf.text.replaceRange(tf.allocator, prev, tf.caret_byte - prev, &.{}) catch {};
                tf.caret_byte = prev;
                tf.mark_byte = prev;
            }
            tf.afterEdit(ev);
        },
        .delete => {
            if (tf.hasSelection()) {
                tf.deleteSelection() catch {};
            } else if (tf.caret_byte < tf.text.items.len) {
                const next = nextCodepointBoundary(tf.text.items, tf.caret_byte);
                tf.text.replaceRange(tf.allocator, tf.caret_byte, next - tf.caret_byte, &.{}) catch {};
            }
            tf.afterEdit(ev);
        },
        .a => if (ctrl) {
            tf.mark_byte = 0;
            tf.caret_byte = tf.text.items.len;
            tf.afterEdit(ev);
        },
        .c => if (ctrl) {
            tf.copyToClipboard();
            ev.consume();
        },
        .x => if (ctrl) {
            tf.copyToClipboard();
            if (tf.hasSelection()) tf.deleteSelection() catch {};
            tf.afterEdit(ev);
        },
        .v => if (ctrl) {
            tf.pasteFromClipboard() catch {};
            tf.afterEdit(ev);
        },
        .enter => {
            // v1: single-line; ignore. Future: fire `submit` ActionListener.
        },
        else => {},
    }
}

fn handleChar(tf: *TextField, ev: *Component.Event, ch: awt.Event.CharEvent) void {
    if (tf.hasSelection()) {
        tf.deleteSelection() catch return;
    }
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(ch.codepoint), &buf) catch return;
    tf.text.insertSlice(tf.allocator, tf.caret_byte, buf[0..n]) catch return;
    tf.caret_byte += n;
    tf.mark_byte = tf.caret_byte;
    tf.afterEdit(ev);
}

fn afterEdit(tf: *TextField, ev: *Component.Event) void {
    tf.caret_visible = true;
    tf.component.repaint();
    ev.consume();
}

// ── selection / edit helpers ─────────────────────────────────────────────

fn hasSelection(self: TextField) bool {
    return self.caret_byte != self.mark_byte;
}

fn selectionStartByte(self: TextField) usize {
    return @min(self.caret_byte, self.mark_byte);
}

fn selectionEndByte(self: TextField) usize {
    return @max(self.caret_byte, self.mark_byte);
}

fn selectionSlice(self: TextField) []const u8 {
    return self.text.items[self.selectionStartByte()..self.selectionEndByte()];
}

fn deleteSelection(self: *TextField) !void {
    const start = self.selectionStartByte();
    const end = self.selectionEndByte();
    if (end == start) return;
    try self.text.replaceRange(self.allocator, start, end - start, &.{});
    self.caret_byte = start;
    self.mark_byte = start;
}

fn copyToClipboard(self: *TextField) void {
    if (!self.hasSelection()) return;
    // Need a sentinel-terminated copy for the C clipboard API.
    const slice = self.selectionSlice();
    const tmp = self.allocator.allocSentinel(u8, slice.len, 0) catch return;
    defer self.allocator.free(tmp);
    @memcpy(tmp[0..slice.len], slice);
    // Reach the parent Window via parent chain to scope the clipboard call.
    if (self.parentWindow()) |w| w.awt_window.setClipboardString(tmp);
}

fn pasteFromClipboard(self: *TextField) !void {
    const w = self.parentWindow() orelse return;
    const got = w.awt_window.getClipboardString() orelse return;
    if (self.hasSelection()) try self.deleteSelection();
    try self.text.insertSlice(self.allocator, self.caret_byte, got);
    self.caret_byte += got.len;
    self.mark_byte = self.caret_byte;
}

fn parentWindow(self: *TextField) ?*@import("Window.zig") {
    // Walk parent chain to the root Container, then `@fieldParentPtr` back
    // to Window. Returns null for orphan widgets (not attached to a Window).
    var node: ?*Component = &self.component;
    while (node) |cur| {
        if (cur.parent == null) {
            const cont = cur.container orelse return null;
            return @fieldParentPtr("container", cont);
        }
        node = cur.parent;
    }
    return null;
}

// ── byte ↔ pixel mapping ─────────────────────────────────────────────────

/// Return the byte position whose left edge is closest to `x_local`
/// (widget-local pixels). When `x_local` falls inside a glyph, we split at
/// the half-width — so clicking the right half of a character places the
/// caret after it. Returns text.items.len if `x_local` is past every glyph.
fn hitTestByteAt(self: TextField, x_local: f32) usize {
    self.font.face.setPixelSize(self.font.pixel_size);
    var cur_x: f32 = PADDING_X;
    var i: usize = 0;
    while (i < self.text.items.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(self.text.items[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > self.text.items.len) break;
        const cp = std.unicode.utf8Decode(self.text.items[i .. i + byte_len]) catch {
            i += byte_len;
            continue;
        };
        const adv = self.font.face.glyphAdvance(cp);
        if (x_local < cur_x + adv * 0.5) return i;
        cur_x += adv;
        i += byte_len;
    }
    return self.text.items.len;
}

/// Return the widget-local x pixel position of the left edge of the
/// glyph starting at `byte_pos`. `byte_pos == text.items.len` returns the
/// position after the last glyph (where the trailing caret sits).
fn xAtByte(self: TextField, byte_pos: usize) f32 {
    self.font.face.setPixelSize(self.font.pixel_size);
    var x: f32 = PADDING_X;
    var i: usize = 0;
    while (i < byte_pos and i < self.text.items.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(self.text.items[i]) catch {
            i += 1;
            continue;
        };
        if (i + byte_len > self.text.items.len) break;
        const cp = std.unicode.utf8Decode(self.text.items[i .. i + byte_len]) catch {
            i += byte_len;
            continue;
        };
        x += self.font.face.glyphAdvance(cp);
        i += byte_len;
    }
    return x;
}

// ── UTF-8 codepoint boundary helpers (free funcs for testability) ────────

/// Returns the byte index of the start of the previous codepoint.
/// `from == 0` returns 0 (already at start).
fn prevCodepointBoundary(buf: []const u8, from: usize) usize {
    if (from == 0) return 0;
    var i: usize = from - 1;
    // Continuation bytes are 10xxxxxx (0x80..0xBF). Skip them.
    while (i > 0 and (buf[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Returns the byte index of the start of the next codepoint, or
/// `buf.len` when `from` is at or past the end.
fn nextCodepointBoundary(buf: []const u8, from: usize) usize {
    if (from >= buf.len) return buf.len;
    const len = std.unicode.utf8ByteSequenceLength(buf[from]) catch return from + 1;
    return @min(from + len, buf.len);
}

// ── tests ────────────────────────────────────────────────────────────────

test "prev/next codepoint boundary — ASCII" {
    const s = "abc";
    try std.testing.expectEqual(@as(usize, 0), prevCodepointBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 1), prevCodepointBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 1), nextCodepointBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 2), nextCodepointBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 3), nextCodepointBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 3), nextCodepointBoundary(s, 3));
}

test "prev/next codepoint boundary — multi-byte" {
    // "あ" = 0xE3 0x81 0x82 (3 bytes), "ab" = 0x61 0x62
    const s = "あab";
    try std.testing.expectEqual(@as(usize, 3), nextCodepointBoundary(s, 0));
    try std.testing.expectEqual(@as(usize, 4), nextCodepointBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 5), nextCodepointBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 0), prevCodepointBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 3), prevCodepointBoundary(s, 4));
    try std.testing.expectEqual(@as(usize, 4), prevCodepointBoundary(s, 5));
}

test "selection range — caret < mark and caret > mark" {
    var tf: TextField = undefined;
    tf.caret_byte = 2;
    tf.mark_byte = 5;
    try std.testing.expectEqual(@as(usize, 2), tf.selectionStartByte());
    try std.testing.expectEqual(@as(usize, 5), tf.selectionEndByte());
    try std.testing.expect(tf.hasSelection());

    tf.caret_byte = 7;
    tf.mark_byte = 3;
    try std.testing.expectEqual(@as(usize, 3), tf.selectionStartByte());
    try std.testing.expectEqual(@as(usize, 7), tf.selectionEndByte());

    tf.caret_byte = 4;
    tf.mark_byte = 4;
    try std.testing.expect(!tf.hasSelection());
}
