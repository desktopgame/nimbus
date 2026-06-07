//! TextArea widget. See `framework/doc/textarea.md`.
//!
//! Multi-line, LTR editor over a `GapBuffer` (designed for longer text than
//! TextField). Two modes: no-wrap (natural width = longest line, scrolls both
//! axes inside a ScrollPane) and wrap (tracks the viewport width, reflows, only
//! scrolls vertically). Codepoint-granularity editing; the boundary stepping is
//! centralized in `prevBoundary` / `nextBoundary` so a future move to grapheme
//! clusters is a one-place change. Attributed text is out of scope.
//!
//! TextArea does not scroll itself — it sizes to its content and relies on an
//! enclosing ScrollPane for clipping/offset, asking it (via ScrollController)
//! to keep the caret visible.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Application = @import("Application.zig");
const GapBuffer = @import("GapBuffer.zig");
const Window = @import("Window.zig");

const TextArea = @This();

const PADDING_X: f32 = 6;
const PADDING_Y: f32 = 4;
const CARET_WIDTH: f32 = 1;
const DEFAULT_COLUMNS: f32 = 40;
const DEFAULT_ROWS: f32 = 6;
const BLINK_PERIOD_MS: u32 = 500;
const BORDER_WIDTH: f32 = 1;

const SELECTION_BG      = awt.Graphics.Color.rgba(0.30, 0.55, 0.95, 0.40);
const BORDER_COLOR      = awt.Graphics.Color.rgb(0.55, 0.55, 0.55);
const FOCUS_BORDER      = awt.Graphics.Color.rgb(0.30, 0.55, 0.95);
const PREEDIT_UNDERLINE = awt.Graphics.Color.rgb(0.40, 0.40, 0.40);
const PREEDIT_TARGET    = awt.Graphics.Color.rgb(0.20, 0.20, 0.20);

/// One on-screen line. `start`/`end` are logical byte offsets; `end` excludes a
/// trailing '\n'. For wrapped segments `end` is the soft-break point and equals
/// the next segment's `start` (no character between them).
const VisualLine = struct {
    start:       usize,
    end:         usize,
    has_newline: bool, // a hard '\n' follows at `end` (logical)
};

component:      Component,
app:            *Application,
text:           GapBuffer,
/// Caret / selection anchor as logical byte offsets. caret == mark → no
/// selection. Byte offsets are internal; public API speaks in abstract terms.
caret:          usize,
mark:           usize,
font:           awt.Graphics.TextFont,
color:          awt.Graphics.Color,
background:     awt.Graphics.Color,
caret_color:    awt.Graphics.Color,
caret_visible:  bool,
blink_timer_id: ?Application.TimerId,
has_focus:      bool,
/// True between a left-button press inside and its release. Gates selection-
/// by-drag: plain hover also delivers `.move` (via the container hit-test, not
/// only via mouse capture), so without this a focused area would extend its
/// selection just from the cursor passing over it.
dragging:       bool,
line_wrap:      bool,
/// On-screen line model, rebuilt by `reflowAt` (and so by `refreshMinSize`
/// and `sizeQueryMinHeightForWidth`, both of which call into it).
lines:          std.ArrayList(VisualLine),
/// Reusable buffer for copying a (logical) byte range out of the gap buffer
/// into contiguous memory for measuring / drawing.
scratch:        std.ArrayList(u8),
/// IME preedit (composition). Empty when not composing.
preedit_text:         std.ArrayList(u8),
preedit_target_start: usize,
preedit_target_end:   usize,
allocator:      std.mem.Allocator,

pub const vtable = Component.VTable{
    .install      = install,
    .uninstall    = uninstall,
    .paint        = paint,
    .processEvent = processEvent,
    .destroy      = destroy,
};

const size_query = Component.SizeQuery{
    .minHeightForWidth = sizeQueryMinHeightForWidth,
};

pub fn create(
    allocator: std.mem.Allocator,
    app: *Application,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
    initial_text: []const u8,
) !*TextArea {
    const ta = try allocator.create(TextArea);
    errdefer allocator.destroy(ta);

    // Normalize line endings on the way in: CRLF / lone CR → LF. The line
    // model keys on '\n', so a stray '\r' would otherwise survive in the buffer
    // and render as a notdef box at every line end.
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);
    try tmp.ensureTotalCapacity(allocator, initial_text.len);
    for (initial_text) |b| {
        if (b != '\r') tmp.appendAssumeCapacity(b);
    }
    var text = try GapBuffer.initFromSlice(allocator, tmp.items);
    errdefer text.deinit();
    const end = text.len();

    ta.* = .{
        .component      = Component.init(allocator, &vtable),
        .app            = app,
        .text           = text,
        .caret          = end,
        .mark           = end,
        .font           = font,
        .color          = color,
        .background     = awt.Graphics.Color.rgb(1.0, 1.0, 1.0),
        .caret_color    = color,
        .caret_visible  = true,
        .blink_timer_id = null,
        .has_focus      = false,
        .dragging       = false,
        .line_wrap      = false,
        .lines          = .empty,
        .scratch        = .empty,
        .preedit_text         = .empty,
        .preedit_target_start = 0,
        .preedit_target_end   = 0,
        .allocator      = allocator,
    };
    ta.component.role = .text_area;
    ta.refreshMinSize();
    try TextArea.vtable.install(&ta.component);
    return ta;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getText(self: *TextArea) []const u8 {
    // Move the gap to the end so the live content is one contiguous run, then
    // hand back a slice into it (valid until the next edit).
    self.text.moveGap(self.text.len());
    return self.text.buf[0..self.text.len()];
}

pub fn setText(self: *TextArea, new_text: []const u8) !void {
    self.text.clear();
    _ = try self.insertStripCR(0, new_text);
    self.caret = self.text.len();
    self.mark = self.caret;
    self.refreshMinSize();
    self.component.markLayoutDirty();
    self.component.repaint();
}

pub fn getLineWrap(self: TextArea) bool {
    return self.line_wrap;
}

/// Toggle line wrapping. In wrap mode the view tracks its ScrollPane viewport
/// width (`Component.scrollable`) and exposes a height-for-width query
/// (`Component.size_query`) so any laying-out parent can ask for the wrapped
/// height; in no-wrap mode it takes the natural width of its longest line and
/// scrolls horizontally.
pub fn setLineWrap(self: *TextArea, wrap: bool) void {
    if (self.line_wrap == wrap) return;
    self.line_wrap = wrap;
    self.component.scrollable = if (wrap)
        .{ .tracks_viewport_width = true }
    else
        null;
    self.component.size_query = if (wrap) size_query else null;
    self.refreshMinSize();
    self.component.markLayoutDirty();
    self.component.repaint();
}

pub fn getCaretColor(self: TextArea) awt.Graphics.Color {
    return self.caret_color;
}

pub fn setCaretColor(self: *TextArea, c: awt.Graphics.Color) void {
    self.caret_color = c;
    self.component.repaint();
}

pub fn getBackground(self: TextArea) awt.Graphics.Color {
    return self.background;
}

pub fn setBackground(self: *TextArea, c: awt.Graphics.Color) void {
    self.background = c;
    self.component.repaint();
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn install(self: *Component) !void {
    self.setFocusable(true);
    const ta: *TextArea = @fieldParentPtr("component", self);
    ta.blink_timer_id = try ta.app.setInterval(BLINK_PERIOD_MS, blinkTick, @ptrCast(ta));
}

fn uninstall(self: *Component) void {
    const ta: *TextArea = @fieldParentPtr("component", self);
    if (ta.blink_timer_id) |id| ta.app.clearTimer(id);
    ta.blink_timer_id = null;

    // If we own focus, clear it via the root FocusController so freed memory
    // is never targeted by later input.
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

/// SizeQuery hook: pure query for "minimum outer height at outer width `w`".
/// Reuses the same wrap algorithm as `refreshMinSize`, but **does not** push
/// the result back into `min_size`. Internal `lines` cache may be updated for
/// the next paint at this width; that's the only allowed side effect.
fn sizeQueryMinHeightForWidth(self: *const Component, w: f32) f32 {
    const ta: *TextArea = @constCast(@fieldParentPtr("component", self));
    const inner_w = @max(0, w - PADDING_X * 2);
    const r = ta.reflowAt(inner_w);
    return r.min_h;
}

fn blinkTick(user_data: *anyopaque) void {
    const ta: *TextArea = @ptrCast(@alignCast(user_data));
    ta.caret_visible = !ta.caret_visible;
    ta.component.repaint();
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const ta: *TextArea = @fieldParentPtr("component", self);
    self.deinit();
    ta.text.deinit();
    ta.lines.deinit(allocator);
    ta.scratch.deinit(allocator);
    ta.preedit_text.deinit(allocator);
    allocator.destroy(ta);
}

// ── line model ─────────────────────────────────────────────────────────────

/// Inner width available for text (content rect minus horizontal padding).
fn innerWidth(self: *TextArea) f32 {
    return self.component.size.width - PADDING_X * 2;
}

/// Width to wrap at: the laid-out inner width if known, else a default so the
/// initial (pre-layout) reflow produces a sensible height.
fn wrapWidth(self: *TextArea) f32 {
    if (!self.line_wrap) return std.math.inf(f32);
    const iw = self.innerWidth();
    if (iw > 0) return iw;
    self.font.face.setPixelSize(self.font.pixel_size);
    return self.font.face.glyphAdvance('M') * DEFAULT_COLUMNS;
}

/// Rebuild `lines` at the given inner (content) width and return the outer
/// `min_w` / `min_h` this would imply. **Pure with respect to component
/// state**: writes only `self.lines` (the cached wrap, used by the next paint
/// at this width). Does NOT touch `component.min_size`/`max_size`; that's
/// `refreshMinSize`'s job. Called from both `refreshMinSize` (for the publish
/// path) and `sizeQueryMinHeightForWidth` (for the SizeQuery pure query).
/// O(n) in the text length (full rescan); incremental relayout is a future
/// optimization (see `doc/internal/optimize.md` / `textarea.md`).
fn reflowAt(self: *TextArea, inner_w: f32) struct { min_w: f32, min_h: f32 } {
    self.font.face.setPixelSize(self.font.pixel_size);
    const line_h = self.font.face.metrics().line_height;
    const total = self.text.len();
    const wrap_w = if (self.line_wrap) inner_w else std.math.inf(f32);

    self.lines.clearRetainingCapacity();
    var content_w: f32 = 0;

    var ls: usize = 0;
    while (true) {
        const le = self.findNewline(ls, total);
        // Split the logical line [ls, le) into visual segments.
        var seg = ls;
        while (true) {
            const seg_end = if (self.line_wrap) self.wrapPoint(seg, le, wrap_w) else le;
            const newline_here = (seg_end == le) and (le < total);
            self.lines.append(self.allocator, .{
                .start = seg,
                .end = seg_end,
                .has_newline = newline_here,
            }) catch {};
            const w = self.measureRange(seg, seg_end);
            if (w > content_w) content_w = w;
            if (seg_end >= le) break;
            seg = seg_end;
        }
        if (le >= total) break;
        ls = le + 1; // skip the '\n'
    }

    const rows: f32 = @floatFromInt(self.lines.items.len);
    const min_h = rows * line_h + PADDING_Y * 2;
    const min_w = if (self.line_wrap)
        self.font.face.glyphAdvance('M') * DEFAULT_COLUMNS + PADDING_X * 2
    else
        content_w + PADDING_X * 2 + CARET_WIDTH;

    return .{ .min_w = min_w, .min_h = min_h };
}

/// Recompute min/max from the current text + wrap mode and push them to the
/// component. Called on edits / setText / setLineWrap / initial create — i.e.
/// from paths that intentionally change observable state and want the parent
/// notified via `markLayoutDirty`. NOT called by `setBounds` (no implicit
/// callback there anymore); a wrapping view's actual height-at-width is
/// instead delivered through `SizeQuery.minHeightForWidth`.
fn refreshMinSize(self: *TextArea) void {
    const r = self.reflowAt(self.wrapWidth());
    self.component.setMinSize(.{ .width = r.min_w, .height = r.min_h });
    self.component.setMaxSize(.{ .width = std.math.inf(f32), .height = std.math.inf(f32) });
}

/// Logical index of the next '\n' in [from, total), or `total` if none.
fn findNewline(self: *TextArea, from: usize, total: usize) usize {
    var i = from;
    while (i < total) : (i += 1) {
        if (self.text.byteAt(i) == '\n') return i;
    }
    return total;
}

/// Greedy character wrap: largest end in (start, le] whose measured width fits
/// `wrap_w`, but always at least one codepoint so progress is guaranteed.
fn wrapPoint(self: *TextArea, start: usize, le: usize, wrap_w: f32) usize {
    self.font.face.setPixelSize(self.font.pixel_size);
    var x: f32 = 0;
    var i = start;
    while (i < le) {
        const d = self.decodeAt(i, le);
        const adv = self.font.face.glyphAdvance(d.cp);
        if (x + adv > wrap_w and i > start) return i;
        x += adv;
        i += d.len;
    }
    return le;
}

// ── byte ↔ pixel / codepoint helpers ─────────────────────────────────────

const Decoded = struct { cp: u32, len: usize };

/// Decode the codepoint at logical index `i` (bounded by `limit`). Falls back
/// to a single raw byte on malformed input so we never stall.
fn decodeAt(self: *TextArea, i: usize, limit: usize) Decoded {
    const b0 = self.text.byteAt(i);
    const n = std.unicode.utf8ByteSequenceLength(b0) catch return .{ .cp = b0, .len = 1 };
    if (i + n > limit) return .{ .cp = b0, .len = 1 };
    var buf: [4]u8 = undefined;
    var k: usize = 0;
    while (k < n) : (k += 1) buf[k] = self.text.byteAt(i + k);
    const cp = std.unicode.utf8Decode(buf[0..n]) catch return .{ .cp = b0, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Copy logical range [start, end) into `scratch` and return it (empty on OOM).
/// The result is invalidated by the next `rangeSlice` / `measureRange` call.
fn rangeSlice(self: *TextArea, start: usize, end: usize) []const u8 {
    const n = end - start;
    self.scratch.resize(self.allocator, n) catch return &.{};
    self.text.copyRange(self.scratch.items, start, end);
    return self.scratch.items[0..n];
}

fn measureSlice(self: *TextArea, s: []const u8) f32 {
    self.font.face.setPixelSize(self.font.pixel_size);
    var x: f32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const bl = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + bl > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + bl]) catch {
            i += bl;
            continue;
        };
        x += self.font.face.glyphAdvance(cp);
        i += bl;
    }
    return x;
}

/// Width of the logical range [start, end).
fn measureRange(self: *TextArea, start: usize, end: usize) f32 {
    return self.measureSlice(self.rangeSlice(start, end));
}

/// Last visual line containing `caret` (start <= caret <= end). Picking the
/// last match places the caret at the *start* of the following line at a soft
/// wrap boundary, which is the expected editor behavior.
fn caretLine(self: *TextArea, caret: usize) usize {
    var idx: usize = 0;
    for (self.lines.items, 0..) |ln, i| {
        if (ln.start <= caret and caret <= ln.end) idx = i;
    }
    return idx;
}

const CaretGeom = struct { x: f32, y: f32, line_h: f32 };

/// Caret position in view-local pixels (top-left of the 1px caret).
fn caretGeom(self: *TextArea) CaretGeom {
    self.font.face.setPixelSize(self.font.pixel_size);
    const line_h = self.font.face.metrics().line_height;
    const li = self.caretLine(self.caret);
    const ln = self.lines.items[li];
    const x = PADDING_X + self.measureRange(ln.start, self.caret);
    const y = PADDING_Y + @as(f32, @floatFromInt(li)) * line_h;
    return .{ .x = x, .y = y, .line_h = line_h };
}

/// Logical byte position in `line` closest to content-relative `x_offset`
/// (i.e. on-screen x minus PADDING_X). Splits glyphs at the half-advance.
fn byteAtXInLine(self: *TextArea, line: VisualLine, x_offset: f32) usize {
    const s = self.rangeSlice(line.start, line.end);
    self.font.face.setPixelSize(self.font.pixel_size);
    var cur_x: f32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const bl = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + bl > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + bl]) catch {
            i += bl;
            continue;
        };
        const adv = self.font.face.glyphAdvance(cp);
        if (x_offset < cur_x + adv * 0.5) return line.start + i;
        cur_x += adv;
        i += bl;
    }
    return line.end;
}

/// Map a view-local point to a caret byte position.
fn pointToCaret(self: *TextArea, x_local: f32, y_local: f32) usize {
    self.font.face.setPixelSize(self.font.pixel_size);
    const line_h = self.font.face.metrics().line_height;
    if (self.lines.items.len == 0) return 0;
    var li_f = (y_local - PADDING_Y) / line_h;
    if (li_f < 0) li_f = 0;
    var li: usize = @intFromFloat(li_f);
    if (li >= self.lines.items.len) li = self.lines.items.len - 1;
    return self.byteAtXInLine(self.lines.items[li], x_local - PADDING_X);
}

// ── codepoint boundary stepping (the grapheme-cluster swap point) ──────────
//
// To migrate to grapheme-cluster granularity later, replace the bodies of
// these two functions (and `decodeAt`'s callers) with UAX #29 segmentation.
// All caret motion / Backspace / Delete go through here, so editing logic above
// does not hard-code byte stepping.

fn prevBoundary(self: *TextArea, from: usize) usize {
    if (from == 0) return 0;
    var i = from - 1;
    while (i > 0 and (self.text.byteAt(i) & 0xC0) == 0x80) i -= 1;
    return i;
}

fn nextBoundary(self: *TextArea, from: usize) usize {
    const total = self.text.len();
    if (from >= total) return total;
    const n = std.unicode.utf8ByteSequenceLength(self.text.byteAt(from)) catch return @min(from + 1, total);
    return @min(from + n, total);
}

// ── selection / edit helpers ─────────────────────────────────────────────

fn hasSelection(self: TextArea) bool {
    return self.caret != self.mark;
}

fn selectionStart(self: TextArea) usize {
    return @min(self.caret, self.mark);
}

fn selectionEnd(self: TextArea) usize {
    return @max(self.caret, self.mark);
}

fn deleteSelection(self: *TextArea) void {
    const start = self.selectionStart();
    const end = self.selectionEnd();
    if (end == start) return;
    self.text.delete(start, end - start);
    self.caret = start;
    self.mark = start;
}

/// Insert `bytes` at logical `pos`, dropping '\r' so pasted CRLF / CR text
/// becomes LF. Inserts the non-CR runs back-to-back without a temp allocation.
/// Returns the number of bytes actually inserted (caret advance).
fn insertStripCR(self: *TextArea, pos: usize, bytes: []const u8) !usize {
    var inserted: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const run_end = std.mem.indexOfScalarPos(u8, bytes, i, '\r') orelse bytes.len;
        if (run_end > i) {
            try self.text.insert(pos + inserted, bytes[i..run_end]);
            inserted += run_end - i;
        }
        i = if (run_end < bytes.len) run_end + 1 else run_end;
    }
    return inserted;
}

// ── vtable: events ─────────────────────────────────────────────────────────

fn paint(self: *Component, g: *awt.Graphics) void {
    const ta: *TextArea = @fieldParentPtr("component", self);
    const sz = self.size;

    g.setColor(ta.background);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    g.setColor(if (ta.has_focus) FOCUS_BORDER else BORDER_COLOR);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = 0, .y = sz.height - BORDER_WIDTH, .width = sz.width, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = 0, .y = 0, .width = BORDER_WIDTH, .height = sz.height });
    g.fillRect(.{ .x = sz.width - BORDER_WIDTH, .y = 0, .width = BORDER_WIDTH, .height = sz.height });

    ta.font.face.setPixelSize(ta.font.pixel_size);
    const line_h = ta.font.face.metrics().line_height;
    const sel_start = ta.selectionStart();
    const sel_end = ta.selectionEnd();

    // Only draw lines that intersect the visible clip. TextArea is sized to its
    // whole content (it relies on an enclosing ScrollPane for clipping), so
    // without this we would push every line's glyphs into the finite per-frame
    // vertex ring — overflowing it drops later draws (trailing lines AND the
    // scrollbars painted afterwards) to blank. See `Graphics.clipLocalRect`.
    const vis = g.clipLocalRect();
    const total_lines = ta.lines.items.len;
    var first: usize = 0;
    if (vis.y > PADDING_Y and line_h > 0) {
        first = @intFromFloat((vis.y - PADDING_Y) / line_h);
    }
    var last: usize = total_lines;
    if (line_h > 0) {
        const bottom = vis.y + vis.height;
        const lf = (bottom - PADDING_Y) / line_h + 1;
        if (lf >= 0) {
            const li: usize = @intFromFloat(lf);
            if (li < last) last = li;
        }
    }
    if (first > total_lines) first = total_lines;

    var i: usize = first;
    while (i < last) : (i += 1) {
        const ln = ta.lines.items[i];
        const y = PADDING_Y + @as(f32, @floatFromInt(i)) * line_h;

        // Selection highlight for the part of this line inside the selection.
        if (sel_end > sel_start) {
            const a = @max(sel_start, ln.start);
            const b = @min(sel_end, ln.end);
            if (b > a) {
                const x0 = PADDING_X + ta.measureRange(ln.start, a);
                const x1 = PADDING_X + ta.measureRange(ln.start, b);
                g.setColor(SELECTION_BG);
                g.fillRect(.{ .x = x0, .y = y, .width = x1 - x0, .height = line_h });
            }
        }

        // Line text.
        const slice = ta.rangeSlice(ln.start, ln.end);
        if (slice.len > 0) {
            g.setFont(ta.font);
            g.setColor(ta.color);
            g.drawString(slice, PADDING_X, y);
        }
    }

    // IME preedit at the caret.
    if (ta.has_focus and ta.preedit_text.items.len > 0) {
        const cg = ta.caretGeom();
        g.setFont(ta.font);
        g.setColor(ta.color);
        g.drawString(ta.preedit_text.items, cg.x, cg.y);

        const pre_w = ta.measureSlice(ta.preedit_text.items);
        const underline_y = cg.y + cg.line_h - 1;
        g.setColor(PREEDIT_UNDERLINE);
        g.fillRect(.{ .x = cg.x, .y = underline_y, .width = pre_w, .height = 1 });

        if (ta.preedit_target_end > ta.preedit_target_start and
            ta.preedit_target_end <= ta.preedit_text.items.len)
        {
            const t0 = ta.measureSlice(ta.preedit_text.items[0..ta.preedit_target_start]);
            const t1 = ta.measureSlice(ta.preedit_text.items[0..ta.preedit_target_end]);
            g.setColor(PREEDIT_TARGET);
            g.fillRect(.{ .x = cg.x + t0, .y = underline_y - 1, .width = t1 - t0, .height = 2 });
        }
    }

    // Caret.
    if (ta.has_focus and ta.caret_visible and ta.preedit_text.items.len == 0) {
        const cg = ta.caretGeom();
        g.setColor(ta.caret_color);
        g.fillRect(.{ .x = cg.x, .y = cg.y, .width = CARET_WIDTH, .height = cg.line_h });
    }
}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const ta: *TextArea = @fieldParentPtr("component", self);
    switch (ev.payload) {
        .mouse => |m| handleMouse(ta, ev, m),
        .key   => |k| handleKey(ta, ev, k),
        .char  => |ch| handleChar(ta, ev, ch),
        .focus => |f| {
            ta.has_focus = f.gained;
            ta.caret_visible = true;
            if (f.gained) ta.ensureCaretVisible();
            ta.component.repaint();
            if (f.gained) ta.pushCaretToIme();
        },
        .composition => |comp| {
            ta.preedit_text.clearRetainingCapacity();
            if (comp.text.len > 0) ta.preedit_text.appendSlice(ta.allocator, comp.text) catch {};
            ta.preedit_target_start = comp.target_start;
            ta.preedit_target_end = comp.target_end;
            ta.component.repaint();
        },
    }
}

fn handleMouse(ta: *TextArea, ev: *Component.Event, m: awt.Event.MouseEvent) void {
    const origin = ta.component.absoluteOriginInWindow();
    const lx = m.x - origin.x;
    const ly = m.y - origin.y;
    const inside = lx >= 0 and lx < ta.component.size.width and ly >= 0 and ly < ta.component.size.height;

    switch (m.action) {
        .press => {
            if (m.button == .left and inside) {
                const pos = ta.pointToCaret(lx, ly);
                ta.caret = pos;
                ta.mark = pos;
                ta.dragging = true;
                ev.requestCapture(@ptrCast(&ta.component));
                ta.component.requestFocus();
                ta.caret_visible = true;
                ta.ensureCaretVisible();
                ta.component.repaint();
                ta.pushCaretToIme();
                ev.consume();
            }
        },
        .release => {
            if (m.button == .left) {
                ta.dragging = false;
                ev.consume();
            }
        },
        .move => {
            // Only while dragging (see `dragging`): plain hover also delivers
            // `.move`, which must not move the caret.
            if (ta.dragging) {
                const pos = ta.pointToCaret(lx, ly);
                if (pos != ta.caret) {
                    ta.caret = pos;
                    ta.caret_visible = true;
                    ta.ensureCaretVisible();
                    ta.component.repaint();
                }
            }
        },
        .scroll => {}, // let the enclosing ScrollPane handle the wheel
    }
}

fn handleKey(ta: *TextArea, ev: *Component.Event, k: awt.Event.KeyEvent) void {
    if (k.action != .press and k.action != .repeat) return;
    // During composition the OS IME owns the keyboard (see TextField rationale).
    if (ta.preedit_text.items.len > 0) return;

    const shift = k.modifiers.shift;
    const ctrl = k.modifiers.ctrl;

    switch (k.code) {
        .arrow_left => {
            ta.caret = ta.prevBoundary(ta.caret);
            if (!shift) ta.mark = ta.caret;
            ta.afterEdit(ev);
        },
        .arrow_right => {
            ta.caret = ta.nextBoundary(ta.caret);
            if (!shift) ta.mark = ta.caret;
            ta.afterEdit(ev);
        },
        .arrow_up => {
            ta.moveVertical(-1);
            if (!shift) ta.mark = ta.caret;
            ta.afterEdit(ev);
        },
        .arrow_down => {
            ta.moveVertical(1);
            if (!shift) ta.mark = ta.caret;
            ta.afterEdit(ev);
        },
        .home => {
            ta.caret = ta.lines.items[ta.caretLine(ta.caret)].start;
            if (!shift) ta.mark = ta.caret;
            ta.afterEdit(ev);
        },
        .end => {
            ta.caret = ta.lines.items[ta.caretLine(ta.caret)].end;
            if (!shift) ta.mark = ta.caret;
            ta.afterEdit(ev);
        },
        .backspace => {
            if (ta.hasSelection()) {
                ta.deleteSelection();
            } else if (ta.caret > 0) {
                const prev = ta.prevBoundary(ta.caret);
                ta.text.delete(prev, ta.caret - prev);
                ta.caret = prev;
                ta.mark = prev;
            }
            ta.afterReflow(ev);
        },
        .delete => {
            if (ta.hasSelection()) {
                ta.deleteSelection();
            } else if (ta.caret < ta.text.len()) {
                const next = ta.nextBoundary(ta.caret);
                ta.text.delete(ta.caret, next - ta.caret);
            }
            ta.afterReflow(ev);
        },
        .enter => {
            if (ta.hasSelection()) ta.deleteSelection();
            ta.text.insert(ta.caret, "\n") catch {};
            ta.caret += 1;
            ta.mark = ta.caret;
            ta.afterReflow(ev);
        },
        .a => if (ctrl) {
            ta.mark = 0;
            ta.caret = ta.text.len();
            ta.afterEdit(ev);
        },
        .c => if (ctrl) {
            ta.copyToClipboard();
            ev.consume();
        },
        .x => if (ctrl) {
            ta.copyToClipboard();
            if (ta.hasSelection()) ta.deleteSelection();
            ta.afterReflow(ev);
        },
        .v => if (ctrl) {
            ta.pasteFromClipboard() catch {};
            ta.afterReflow(ev);
        },
        else => {},
    }
}

fn handleChar(ta: *TextArea, ev: *Component.Event, ch: awt.Event.CharEvent) void {
    if (ta.hasSelection()) ta.deleteSelection();
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(ch.codepoint), &buf) catch return;
    ta.text.insert(ta.caret, buf[0..n]) catch return;
    ta.caret += n;
    ta.mark = ta.caret;
    ta.afterReflow(ev);
}

/// Edit that changed content → rebuild line model, then the common tail.
fn afterReflow(ta: *TextArea, ev: *Component.Event) void {
    ta.refreshMinSize();
    ta.component.markLayoutDirty();
    ta.afterEdit(ev);
}

/// Caret-only change (navigation) → no reflow, just refresh + scroll into view.
fn afterEdit(ta: *TextArea, ev: *Component.Event) void {
    ta.caret_visible = true;
    ta.ensureCaretVisible();
    ta.component.repaint();
    ta.pushCaretToIme();
    ev.consume();
}

/// Move the caret one visual line up (`-1`) or down (`+1`), preserving the
/// horizontal offset as closely as the target line allows. At the top/bottom
/// edge, jump to document start/end (common editor behavior).
fn moveVertical(ta: *TextArea, dir: i32) void {
    const li = ta.caretLine(ta.caret);
    const target: isize = @as(isize, @intCast(li)) + dir;
    if (target < 0) {
        ta.caret = 0;
        return;
    }
    if (target >= @as(isize, @intCast(ta.lines.items.len))) {
        ta.caret = ta.text.len();
        return;
    }
    const cur = ta.lines.items[li];
    const x_offset = ta.measureRange(cur.start, ta.caret);
    ta.caret = ta.byteAtXInLine(ta.lines.items[@intCast(target)], x_offset);
}

// ── clipboard / IME / scroll integration ───────────────────────────────────

fn copyToClipboard(self: *TextArea) void {
    if (!self.hasSelection()) return;
    const start = self.selectionStart();
    const end = self.selectionEnd();
    const tmp = self.allocator.allocSentinel(u8, end - start, 0) catch return;
    defer self.allocator.free(tmp);
    self.text.copyRange(tmp[0 .. end - start], start, end);
    if (self.parentWindow()) |w| if (w.awt_window) |*aw| aw.setClipboardString(tmp);
}

fn pasteFromClipboard(self: *TextArea) !void {
    const w = self.parentWindow() orelse return;
    if (w.awt_window == null) return; // headless: no clipboard
    const got = w.awt_window.?.getClipboardString() orelse return;
    if (self.hasSelection()) self.deleteSelection();
    const n = try self.insertStripCR(self.caret, got);
    self.caret += n;
    self.mark = self.caret;
}

/// Ask the enclosing ScrollPane (if any) to keep the caret visible.
fn ensureCaretVisible(self: *TextArea) void {
    const sc = self.component.enclosingScrollController() orelse return;
    const cg = self.caretGeom();
    sc.scroll_rect_to_visible(sc.user_data, .{
        .x = cg.x,
        .y = cg.y,
        .width = CARET_WIDTH,
        .height = cg.line_h,
    });
}

fn pushCaretToIme(self: *TextArea) void {
    const w = self.parentWindow() orelse return;
    const origin = self.component.absoluteOriginInWindow();
    const cg = self.caretGeom();
    if (w.awt_window) |*aw| aw.setCompositionCursorPos(
        @intFromFloat(origin.x + cg.x),
        @intFromFloat(origin.y + cg.y),
        @intFromFloat(cg.line_h),
    );
}

fn parentWindow(self: *TextArea) ?*Window {
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
