//! TextArea widget. See `framework/doc/textarea.md`.
//!
//! Multi-line, LTR editor over `EditableText`. Two modes: no-wrap
//! (natural width = longest line, scrolls both
//! axes inside a ScrollPane) and wrap (tracks the viewport width, reflows, only
//! scrolls vertically). Grapheme-cluster-granularity editing; boundary stepping
//! is centralized in `prevBoundary` / `nextBoundary`. Attributed text is out of
//! scope.
//!
//! TextArea does not scroll itself  Eit sizes to its content and relies on an
//! enclosing ScrollPane for clipping/offset, asking it (via ScrollController)
//! to keep the caret visible.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Application = @import("Application.zig");
const EditableText = @import("EditableText.zig");
const Window = @import("Window.zig");
const ImeSession = @import("ImeSession.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;

const TextArea = @This();

const PADDING_X: f32 = 6;
const PADDING_Y: f32 = 4;
const CARET_WIDTH: f32 = 1;
const DEFAULT_COLUMNS: f32 = 40;
const DEFAULT_ROWS: f32 = 6;
const BLINK_PERIOD_MS: u32 = 500;

// Colors come from `component.theme`: preedit underlines =
// ime_preedit_underline / ime_preedit_target. The selection highlight is
// derived from accent (see `selectionColor`) so it tracks accent automatically.
// See `framework/doc/theme.md`.

/// Selection highlight: the theme accent at 40% alpha (derived, not a token).
fn selectionColor(t: *const @import("theme.zig").Theme) awt.Graphics.Color {
    return awt.Graphics.Color.rgba(t.accent.r, t.accent.g, t.accent.b, 0.40);
}

/// One on-screen line. `start`/`end` are logical byte offsets; `end` excludes a
/// trailing '\n'. For wrapped segments `end` is the soft-break point and equals
/// the next segment's `start` (no character between them).
const VisualLine = struct {
    start: usize,
    end: usize,
    has_newline: bool, // a hard '\n' follows at `end` (logical)
};

component: Component,
app: *Application,
core: EditableText,
/// Caret / selection anchor as logical byte offsets. caret == mark ↁEno
/// selection. Byte offsets are internal; public API speaks in abstract terms.
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
background: awt.Graphics.Color,
caret_color: awt.Graphics.Color,
caret_visible: bool,
blink_timer_id: ?Application.TimerId,
has_focus: bool,
/// True between a left-button press inside and its release. Gates selection-
/// by-drag: plain hover also delivers `.move` (via the container hit-test, not
/// only via mouse capture), so without this a focused area would extend its
/// selection just from the cursor passing over it.
dragging: bool,
line_wrap: bool,
/// On-screen line model, rebuilt by `reflowAt` (and so by `refreshMinSize`
/// and `sizeQueryMinHeightForWidth`, both of which call into it).
lines: std.ArrayList(VisualLine),
/// Reusable buffer for copying a (logical) byte range out of the gap buffer
/// into contiguous memory for measuring / drawing.
scratch: std.ArrayList(u8),
/// IME preedit (composition) session. Empty when not composing.
ime: ImeSession,
/// Fired whenever text, caret, or selection state changes. This is a single
/// app-level observation point for status and command enablement.
change_listeners: ChangeListenerList,
allocator: std.mem.Allocator,

pub const vtable = Component.VTable{
    .install = install,
    .uninstall = uninstall,
    .processEvent = processEvent,
    .destroy = destroy,
};

pub const look_vtable = Component.LookVTable{
    .paint = lookPaint,
    .paintOver = lookPaintOver,
    .measureMinSize = lookMeasureMinSize,
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

    // EditableText normalizes line endings so the line model only sees '\n'.
    var core = try EditableText.initFromSlice(allocator, initial_text);
    errdefer core.deinit();

    ta.* = .{
        .component = Component.init(allocator, &vtable),
        .app = app,
        .core = core,
        .font = font,
        .color = color,
        .background = awt.Graphics.Color.rgb(1.0, 1.0, 1.0),
        .caret_color = color,
        .caret_visible = true,
        .blink_timer_id = null,
        .has_focus = false,
        .dragging = false,
        .line_wrap = false,
        .lines = .empty,
        .scratch = .empty,
        .ime = ImeSession.init(allocator),
        .change_listeners = ChangeListenerList.init(allocator),
        .allocator = allocator,
    };
    ta.ime.setOnCleared(ImeSession.ClearedHook.typed(TextArea, imeCleared, ta));
    ta.component.role = .text_area;
    ta.component.a11y = .{ .name = a11yName };
    ta.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    ta.refreshMinSize();
    try TextArea.vtable.install(&ta.component);
    return ta;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getText(self: *TextArea) []const u8 {
    return self.core.textSlice();
}

pub fn setText(self: *TextArea, new_text: []const u8) !void {
    try self.core.setText(new_text);
    self.refreshMinSize();
    self.component.markLayoutDirty();
    self.fireChange();
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

/// Listener fired whenever text, caret, or selection state changes. Multiple
/// listeners are allowed.
pub fn addChangeListener(self: *TextArea, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}

pub fn removeChangeListener(self: *TextArea, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

pub fn undo(self: *TextArea) void {
    if (self.core.undo() catch false) self.afterReflow(null, true);
}

pub fn redo(self: *TextArea) void {
    if (self.core.redo() catch false) self.afterReflow(null, true);
}

pub fn cut(self: *TextArea) void {
    self.copyToClipboard();
    if (!self.hasSelection()) return;
    self.core.breakCoalescing();
    const changed = self.deleteSelection();
    self.core.breakCoalescing();
    self.afterReflow(null, changed);
}

pub fn copy(self: *TextArea) void {
    self.copyToClipboard();
}

pub fn paste(self: *TextArea) void {
    const changed = self.pasteFromClipboard() catch false;
    if (changed) self.afterReflow(null, true);
}

pub fn selectAll(self: *TextArea) void {
    const old_caret = self.core.caret;
    const old_mark = self.core.mark;
    self.core.mark = 0;
    self.core.caret = self.core.len();
    self.core.breakCoalescing();
    self.afterEdit(null, old_caret != self.core.caret or old_mark != self.core.mark);
}

pub fn caretLineColumn(self: *const TextArea) struct { line: usize, col: usize } {
    const caret = @min(self.core.caret, self.core.len());
    var line: usize = 1;
    var i: usize = 0;
    while (i < caret) : (i += 1) {
        if (self.core.byteAt(i) == '\n') line += 1;
    }
    const line_start = self.core.lineStartAtByte(caret);
    var col: usize = 1;
    i = line_start;
    while (i < caret) {
        const b = self.core.byteAt(i);
        const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (i + n > caret) break;
        i += n;
        col += 1;
    }
    return .{ .line = line, .col = col };
}

pub fn canUndo(self: *const TextArea) bool {
    return self.core.canUndo();
}

pub fn canRedo(self: *const TextArea) bool {
    return self.core.canRedo();
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
    ta.core.deinit();
    ta.lines.deinit(allocator);
    ta.scratch.deinit(allocator);
    ta.ime.deinit();
    ta.change_listeners.deinit();
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
    const total = self.core.len();
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
/// component. Called on edits / setText / setLineWrap / initial create  Ei.e.
/// from paths that intentionally change observable state and want the parent
/// notified via `markLayoutDirty`. NOT called by `setBounds` (no implicit
/// callback there anymore); a wrapping view's actual height-at-width is
/// instead delivered through `SizeQuery.minHeightForWidth`.
fn refreshMinSize(self: *TextArea) void {
    const r = self.measureMinSizeFromLook();
    self.component.setMinSizeDerived(.{ .width = r.min_w, .height = r.min_h });
    self.component.setMaxSize(.{ .width = std.math.inf(f32), .height = std.math.inf(f32) });
}

fn measureMinSizeFromLook(self: *TextArea) struct { min_w: f32, min_h: f32 } {
    const s = lookMeasureMinSize(&self.component, &Component.default_look_context);
    return .{ .min_w = s.width, .min_h = s.height };
}

fn a11yName(c: *const Component) ?[]const u8 {
    const ta: *const TextArea = @fieldParentPtr("component", c);
    return @constCast(ta).core.textSlice();
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const ta: *TextArea = @fieldParentPtr("component", self);
    const r = ta.reflowAt(ta.wrapWidth());
    return .{ .width = r.min_w, .height = r.min_h };
}

/// Logical index of the next '\n' in [from, total), or `total` if none.
fn findNewline(self: *TextArea, from: usize, total: usize) usize {
    var i = from;
    while (i < total) : (i += 1) {
        if (self.core.byteAt(i) == '\n') return i;
    }
    return total;
}

/// Shared grapheme-safe wrap: largest end in (start, le] whose measured width
/// fits `wrap_w`, with break opportunities and kinsoku handled by awt.
fn wrapPoint(self: *TextArea, start: usize, le: usize, wrap_w: f32) usize {
    self.font.face.setPixelSize(self.font.pixel_size);
    const slice = self.rangeSlice(start, le);
    return start + awt.textwrap.wrapSegment(self.font.face, slice, 0, slice.len, wrap_w);
}

// ── byte ↁEpixel / codepoint helpers ─────────────────────────────────────

const Decoded = struct { cp: u32, len: usize };

/// Decode the codepoint at logical index `i` (bounded by `limit`). Falls back
/// to a single raw byte on malformed input so we never stall.
fn decodeAt(self: *TextArea, i: usize, limit: usize) Decoded {
    const b0 = self.core.byteAt(i);
    const n = std.unicode.utf8ByteSequenceLength(b0) catch return .{ .cp = b0, .len = 1 };
    if (i + n > limit) return .{ .cp = b0, .len = 1 };
    var buf: [4]u8 = undefined;
    var k: usize = 0;
    while (k < n) : (k += 1) buf[k] = self.core.byteAt(i + k);
    const cp = std.unicode.utf8Decode(buf[0..n]) catch return .{ .cp = b0, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Copy logical range [start, end) into `scratch` and return it (empty on OOM).
/// The result is invalidated by the next `rangeSlice` / `measureRange` call.
fn rangeSlice(self: *TextArea, start: usize, end: usize) []const u8 {
    const n = end - start;
    self.scratch.resize(self.allocator, n) catch return &.{};
    self.core.copyRange(self.scratch.items, start, end);
    return self.scratch.items[0..n];
}

fn measureSlice(self: *TextArea, s: []const u8) f32 {
    self.font.face.setPixelSize(self.font.pixel_size);
    return self.font.face.advanceOfRange(s, 0, s.len);
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
    const li = self.caretLine(self.core.caret);
    const ln = self.lines.items[li];
    const x = PADDING_X + self.measureRange(ln.start, self.core.caret);
    const y = PADDING_Y + @as(f32, @floatFromInt(li)) * line_h;
    return .{ .x = x, .y = y, .line_h = line_h };
}

/// Logical byte position in `line` closest to content-relative `x_offset`
/// (i.e. on-screen x minus PADDING_X). Splits glyphs at the half-advance.
fn byteAtXInLine(self: *TextArea, line: VisualLine, x_offset: f32) usize {
    const s = self.rangeSlice(line.start, line.end);
    self.font.face.setPixelSize(self.font.pixel_size);
    const raw = line.start + self.font.face.byteAtX(s, x_offset);
    return self.snapByteToGraphemeBoundary(raw);
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

// ── grapheme boundary stepping ────────────────────────────────────────────
//
// EditableText owns grapheme stepping; these wrappers keep old TextArea call
// sites focused on widget geometry.

fn prevBoundary(self: *TextArea, from: usize) usize {
    return self.core.prevBoundary(from);
}

fn nextBoundary(self: *TextArea, from: usize) usize {
    return self.core.nextBoundary(from);
}

fn snapByteToGraphemeBoundary(self: *TextArea, byte_pos: usize) usize {
    return self.core.snapToBoundary(byte_pos);
}

// ── selection / edit helpers ─────────────────────────────────────────────

fn hasSelection(self: TextArea) bool {
    return self.core.hasSelection();
}

fn selectionStart(self: TextArea) usize {
    return self.core.selectionStart();
}

fn selectionEnd(self: TextArea) usize {
    return self.core.selectionEnd();
}

fn deleteSelection(self: *TextArea) bool {
    return self.core.deleteSelection() catch false;
}

// ── vtable: events ─────────────────────────────────────────────────────────

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const ta: *TextArea = @fieldParentPtr("component", self);
    const sz = self.size;

    g.setColor(ta.background);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    ta.paintContent(self, g);
}

pub fn paintContent(ta: *TextArea, self: *Component, g: *awt.Graphics) void {
    ta.font.face.setPixelSize(ta.font.pixel_size);
    const line_h = ta.font.face.metrics().line_height;
    const sel_start = ta.selectionStart();
    const sel_end = ta.selectionEnd();

    // Only draw lines that intersect the visible clip. TextArea is sized to its
    // whole content (it relies on an enclosing ScrollPane for clipping), so
    // without this we would push every line's glyphs into the finite per-frame
    // vertex ring  Eoverflowing it drops later draws (trailing lines AND the
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
                g.setColor(selectionColor(self.theme));
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
    if (ta.has_focus and ta.ime.isComposing()) {
        const preedit = ta.ime.preeditSlice();
        const target = ta.ime.targetRange();
        const cg = ta.caretGeom();
        g.setFont(ta.font);
        g.setColor(ta.color);
        g.drawString(preedit, cg.x, cg.y);

        const pre_w = ta.measureSlice(preedit);
        const underline_y = cg.y + cg.line_h - 1;
        g.setColor(self.theme.ime_preedit_underline);
        g.fillRect(.{ .x = cg.x, .y = underline_y, .width = pre_w, .height = 1 });

        if (target.end > target.start and target.end <= preedit.len) {
            const t0 = ta.measureSlice(preedit[0..target.start]);
            const t1 = ta.measureSlice(preedit[0..target.end]);
            g.setColor(self.theme.ime_preedit_target);
            g.fillRect(.{ .x = cg.x + t0, .y = underline_y - 1, .width = t1 - t0, .height = 2 });
        }
    }

    // Caret.
    if (ta.has_focus and ta.caret_visible and !ta.ime.isComposing()) {
        const cg = ta.caretGeom();
        g.setColor(ta.caret_color);
        g.fillRect(.{ .x = cg.x, .y = cg.y, .width = CARET_WIDTH, .height = cg.line_h });
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const ta: *TextArea = @fieldParentPtr("component", self);
    switch (ev.payload) {
        .mouse => |m| handleMouse(ta, ev, m),
        .key => |k| handleKey(ta, ev, k),
        .char => |ch| handleChar(ta, ev, ch),
        .focus => |f| {
            ta.has_focus = f.gained;
            ta.caret_visible = true;
            if (f.gained) ta.ensureCaretVisible();
            ta.component.repaint();
            if (f.gained) ta.pushCaretToIme();
        },
        .composition => |comp| {
            ta.ime.update(comp) catch {};
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
                const old_caret = ta.core.caret;
                const old_mark = ta.core.mark;
                ta.core.caret = pos;
                ta.core.mark = pos;
                ta.core.breakCoalescing();
                ta.dragging = true;
                ev.requestCapture(@ptrCast(&ta.component));
                ta.component.requestFocus();
                ta.caret_visible = true;
                ta.ensureCaretVisible();
                ta.component.repaint();
                ta.pushCaretToIme();
                if (old_caret != ta.core.caret or old_mark != ta.core.mark) ta.fireChange();
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
                if (pos != ta.core.caret) {
                    ta.core.caret = pos;
                    ta.core.breakCoalescing();
                    ta.caret_visible = true;
                    ta.ensureCaretVisible();
                    ta.component.repaint();
                    ta.fireChange();
                }
            }
        },
        .scroll => {}, // let the enclosing ScrollPane handle the wheel
    }
}

fn handleKey(ta: *TextArea, ev: *Component.Event, k: awt.Event.KeyEvent) void {
    if (k.action != .press and k.action != .repeat) return;
    // During composition the OS IME owns the keyboard (see TextField rationale).
    if (ta.ime.isComposing()) return;

    const shift = k.modifiers.shift;
    const ctrl = k.modifiers.ctrl;

    switch (k.code) {
        .arrow_left => {
            const old_caret = ta.core.caret;
            const old_mark = ta.core.mark;
            ta.core.caret = ta.prevBoundary(ta.core.caret);
            if (!shift) ta.core.mark = ta.core.caret;
            ta.core.breakCoalescing();
            ta.afterEdit(ev, old_caret != ta.core.caret or old_mark != ta.core.mark);
        },
        .arrow_right => {
            const old_caret = ta.core.caret;
            const old_mark = ta.core.mark;
            ta.core.caret = ta.nextBoundary(ta.core.caret);
            if (!shift) ta.core.mark = ta.core.caret;
            ta.core.breakCoalescing();
            ta.afterEdit(ev, old_caret != ta.core.caret or old_mark != ta.core.mark);
        },
        .arrow_up => {
            const old_caret = ta.core.caret;
            const old_mark = ta.core.mark;
            ta.moveVertical(-1);
            if (!shift) ta.core.mark = ta.core.caret;
            ta.core.breakCoalescing();
            ta.afterEdit(ev, old_caret != ta.core.caret or old_mark != ta.core.mark);
        },
        .arrow_down => {
            const old_caret = ta.core.caret;
            const old_mark = ta.core.mark;
            ta.moveVertical(1);
            if (!shift) ta.core.mark = ta.core.caret;
            ta.core.breakCoalescing();
            ta.afterEdit(ev, old_caret != ta.core.caret or old_mark != ta.core.mark);
        },
        .home => {
            const old_caret = ta.core.caret;
            const old_mark = ta.core.mark;
            ta.core.caret = ta.lines.items[ta.caretLine(ta.core.caret)].start;
            if (!shift) ta.core.mark = ta.core.caret;
            ta.core.breakCoalescing();
            ta.afterEdit(ev, old_caret != ta.core.caret or old_mark != ta.core.mark);
        },
        .end => {
            const old_caret = ta.core.caret;
            const old_mark = ta.core.mark;
            ta.core.caret = ta.lines.items[ta.caretLine(ta.core.caret)].end;
            if (!shift) ta.core.mark = ta.core.caret;
            ta.core.breakCoalescing();
            ta.afterEdit(ev, old_caret != ta.core.caret or old_mark != ta.core.mark);
        },
        .z => if (ctrl) {
            ta.undo();
            ev.consume();
        },
        .y => if (ctrl) {
            ta.redo();
            ev.consume();
        },
        .backspace => {
            const changed = ta.core.deleteBackward() catch false;
            ta.afterReflow(ev, changed);
        },
        .delete => {
            const changed = ta.core.deleteForward() catch false;
            ta.afterReflow(ev, changed);
        },
        .enter => {
            const changed = ta.core.insert("\n") catch false;
            ta.afterReflow(ev, changed);
        },
        .a => if (ctrl) {
            ta.selectAll();
            ev.consume();
        },
        .c => if (ctrl) {
            ta.copy();
            ev.consume();
        },
        .x => if (ctrl) {
            ta.cut();
            ev.consume();
        },
        .v => if (ctrl) {
            ta.paste();
            ev.consume();
        },
        else => {},
    }
}

fn handleChar(ta: *TextArea, ev: *Component.Event, ch: awt.Event.CharEvent) void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(ch.codepoint), &buf) catch return;
    const changed = ta.core.insert(buf[0..n]) catch return;
    ta.afterReflow(ev, changed);
}

/// Edit that changed content ↁErebuild line model, then the common tail.
fn afterReflow(ta: *TextArea, ev: ?*Component.Event, changed: bool) void {
    ta.refreshMinSize();
    ta.component.markLayoutDirty();
    ta.afterEdit(ev, changed);
}

/// Caret-only change (navigation) ↁEno reflow, just refresh + scroll into view.
fn afterEdit(ta: *TextArea, ev: ?*Component.Event, changed: bool) void {
    if (changed) ta.fireChange();
    ta.caret_visible = true;
    ta.ensureCaretVisible();
    ta.component.repaint();
    ta.pushCaretToIme();
    if (ev) |e| e.consume();
}

/// Move the caret one visual line up (`-1`) or down (`+1`), preserving the
/// horizontal offset as closely as the target line allows. At the top/bottom
/// edge, jump to document start/end (common editor behavior).
fn moveVertical(ta: *TextArea, dir: i32) void {
    const li = ta.caretLine(ta.core.caret);
    const target: isize = @as(isize, @intCast(li)) + dir;
    if (target < 0) {
        ta.core.caret = 0;
        return;
    }
    if (target >= @as(isize, @intCast(ta.lines.items.len))) {
        ta.core.caret = ta.core.len();
        return;
    }
    const cur = ta.lines.items[li];
    const x_offset = ta.measureRange(cur.start, ta.core.caret);
    ta.core.caret = ta.byteAtXInLine(ta.lines.items[@intCast(target)], x_offset);
}

// ── clipboard / IME / scroll integration ───────────────────────────────────

fn copyToClipboard(self: *TextArea) void {
    if (!self.hasSelection()) return;
    const start = self.selectionStart();
    const end = self.selectionEnd();
    const tmp = self.allocator.allocSentinel(u8, end - start, 0) catch return;
    defer self.allocator.free(tmp);
    self.core.copyRange(tmp[0 .. end - start], start, end);
    if (self.parentWindow()) |w| if (w.awt_window) |*aw| aw.setClipboardString(tmp);
}

fn pasteFromClipboard(self: *TextArea) !bool {
    const w = self.parentWindow() orelse return false;
    if (w.awt_window == null) return false; // headless: no clipboard
    const got = w.awt_window.?.getClipboardString() orelse return false;
    return try self.core.paste(got);
}

fn imeCleared(self: *TextArea) void {
    self.core.breakCoalescing();
}

fn fireChange(self: *TextArea) void {
    self.change_listeners.fire(&.{ .source = self });
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
    self.ime.pushCaret(if (w.awt_window) |*aw| aw else null, .{
        .x = origin.x + cg.x,
        .y = origin.y + cg.y,
        .height = cg.line_h,
    });
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

// ── tests ────────────────────────────────────────────────────────────────

fn initTestArea(initial_text: []const u8) !TextArea {
    var ta: TextArea = undefined;
    ta.core = try EditableText.initFromSlice(std.testing.allocator, initial_text);
    ta.scratch = .empty;
    ta.lines = .empty;
    ta.change_listeners = ChangeListenerList.init(std.testing.allocator);
    ta.allocator = std.testing.allocator;
    return ta;
}

fn deinitTestArea(ta: *TextArea) void {
    ta.core.deinit();
    ta.scratch.deinit(std.testing.allocator);
    ta.lines.deinit(std.testing.allocator);
    ta.change_listeners.deinit();
}

fn expectText(ta: *TextArea, expected: []const u8) !void {
    const got = try std.testing.allocator.alloc(u8, ta.core.len());
    defer std.testing.allocator.free(got);
    ta.core.copyRange(got, 0, ta.core.len());
    try std.testing.expectEqualStrings(expected, got);
}

fn newHeadlessApp() !*Application {
    return Application.initHeadless(std.testing.allocator, std.testing.io) catch
        return error.SkipZigTest;
}

const ChangeProbe = struct {
    count: usize = 0,
    last_source: ?*anyopaque = null,

    fn onChange(self: *@This(), ev: *const ChangeEvent) void {
        self.count += 1;
        self.last_source = ev.source;
    }
};

test "TextArea change listener fires for typing public undo cut and caret movement" {
    const app = try newHeadlessApp();
    defer app.deinit();
    const frame = try app.frameHeadless("ta", 360, 160);
    frame.window.container.setLayout(null);

    const area = try app.textArea("");
    area.component.setBounds(.{ .x = 10, .y = 10, .width = 240, .height = 80 });
    try frame.window.add(&area.component);

    var probe = ChangeProbe{};
    try area.addChangeListener(ChangeProbe, ChangeProbe.onChange, &probe);

    var robot = @import("Robot.zig").init(app, &frame.window);
    var driver = @import("Driver.zig"){ .robot = &robot };
    robot.pump();

    try driver.clickOn(.{ .role = .text_area, .text = "" });
    robot.typeText("abc");
    robot.pump();
    try std.testing.expectEqual(@as(usize, 3), probe.count);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(area)), probe.last_source.?);

    robot.keyDown(.arrow_left, .{});
    robot.keyUp(.arrow_left, .{});
    robot.pump();
    try std.testing.expectEqual(@as(usize, 4), probe.count);

    area.undo();
    try expectText(area, "");
    try std.testing.expectEqual(@as(usize, 5), probe.count);

    try area.setText("abc");
    probe.count = 0;
    area.selectAll();
    area.cut();
    try expectText(area, "");
    try std.testing.expectEqual(@as(usize, 2), probe.count);

    area.removeChangeListener(ChangeProbe, ChangeProbe.onChange, &probe);
    area.undo();
    try expectText(area, "abc");
    try std.testing.expectEqual(@as(usize, 2), probe.count);
}

test "TextArea public actions match keyboard control paths" {
    const app = try newHeadlessApp();
    defer app.deinit();
    const frame = try app.frameHeadless("ta", 420, 180);
    frame.window.container.setLayout(null);

    const from_api = try app.textArea("abc");
    from_api.component.setBounds(.{ .x = 10, .y = 10, .width = 180, .height = 80 });
    try frame.window.add(&from_api.component);
    const from_keys = try app.textArea("abc");
    from_keys.component.setBounds(.{ .x = 210, .y = 10, .width = 180, .height = 80 });
    try frame.window.add(&from_keys.component);

    from_api.selectAll();
    from_api.cut();
    from_api.undo();

    var robot = @import("Robot.zig").init(app, &frame.window);
    robot.pump();
    robot.click(220, 20, .left);
    robot.keyDown(.a, .{ .ctrl = true });
    robot.keyUp(.a, .{ .ctrl = true });
    robot.keyDown(.x, .{ .ctrl = true });
    robot.keyUp(.x, .{ .ctrl = true });
    robot.keyDown(.z, .{ .ctrl = true });
    robot.keyUp(.z, .{ .ctrl = true });
    robot.pump();

    try std.testing.expectEqualStrings(from_api.getText(), from_keys.getText());
    try std.testing.expectEqual(from_api.canUndo(), from_keys.canUndo());
    try std.testing.expectEqual(from_api.canRedo(), from_keys.canRedo());
    try std.testing.expectEqual(from_api.caretLineColumn(), from_keys.caretLineColumn());
}

test "TextArea caretLineColumn and undo accessors expose core state" {
    var ta = try initTestArea("ab\nc\n\u{3042}\u{1F44D}z");
    defer deinitTestArea(&ta);

    ta.core.caret = 0;
    try std.testing.expectEqual(@as(usize, 1), ta.caretLineColumn().line);
    try std.testing.expectEqual(@as(usize, 1), ta.caretLineColumn().col);

    ta.core.caret = 2;
    try std.testing.expectEqual(@as(usize, 1), ta.caretLineColumn().line);
    try std.testing.expectEqual(@as(usize, 3), ta.caretLineColumn().col);

    ta.core.caret = 3;
    try std.testing.expectEqual(@as(usize, 2), ta.caretLineColumn().line);
    try std.testing.expectEqual(@as(usize, 1), ta.caretLineColumn().col);

    ta.core.caret = 5;
    try std.testing.expectEqual(@as(usize, 3), ta.caretLineColumn().line);
    try std.testing.expectEqual(@as(usize, 1), ta.caretLineColumn().col);

    ta.core.caret = 8;
    try std.testing.expectEqual(@as(usize, 3), ta.caretLineColumn().line);
    try std.testing.expectEqual(@as(usize, 2), ta.caretLineColumn().col);

    ta.core.caret = 12;
    try std.testing.expectEqual(@as(usize, 3), ta.caretLineColumn().line);
    try std.testing.expectEqual(@as(usize, 3), ta.caretLineColumn().col);

    try std.testing.expect(!ta.canUndo());
    try std.testing.expect(!ta.canRedo());
    try std.testing.expect(try ta.core.insert("!"));
    try std.testing.expect(ta.canUndo());
    try std.testing.expect(!ta.canRedo());
    try std.testing.expect(try ta.core.undo());
    try std.testing.expect(!ta.canUndo());
    try std.testing.expect(ta.canRedo());
}

test "TextArea grapheme boundaries drive movement and deletion" {
    const cases = [_][]const u8{
        "e\u{0301}",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        "\u{1F44D}\u{1F3FB}",
        "\u{1F1EF}\u{1F1F5}",
    };

    for (cases) |cluster| {
        const s = try std.mem.concat(std.testing.allocator, u8, &.{ "a", cluster, "b" });
        defer std.testing.allocator.free(s);
        const cluster_start = "a".len;
        const cluster_end = "a".len + cluster.len;

        var ta = try initTestArea(s);
        defer deinitTestArea(&ta);

        try std.testing.expectEqual(cluster_end, ta.nextBoundary(cluster_start));
        try std.testing.expectEqual(cluster_start, ta.prevBoundary(cluster_end));

        ta.core.caret = cluster_end;
        ta.core.mark = cluster_end;
        try std.testing.expect(try ta.core.deleteBackward());
        try expectText(&ta, "ab");

        var ta_delete = try initTestArea(s);
        defer deinitTestArea(&ta_delete);
        ta_delete.core.caret = cluster_start;
        ta_delete.core.mark = cluster_start;
        try std.testing.expect(try ta_delete.core.deleteForward());
        try expectText(&ta_delete, "ab");
    }
}

test "TextArea odd regional-indicator sequence keeps full-context parity" {
    const flag = "\u{1F1EF}\u{1F1F5}";
    const third = "\u{1F1FA}";
    const s = "a" ++ flag ++ third ++ "b";
    const flag_start = "a".len;
    const flag_end = "a".len + flag.len;
    const third_end = "a".len + flag.len + third.len;

    var ta = try initTestArea(s);
    defer deinitTestArea(&ta);

    try std.testing.expectEqual(flag_end, ta.nextBoundary(flag_start));
    try std.testing.expectEqual(third_end, ta.nextBoundary(flag_end));
    try std.testing.expectEqual(flag_end, ta.prevBoundary(third_end));
    try std.testing.expectEqual(flag_start, ta.prevBoundary(flag_end));
}

test "TextArea grapheme boundaries survive gap straddling" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const s = "a" ++ family ++ "b";
    const cluster_start = "a".len;
    const cluster_end = "a".len + family.len;
    const inside_cluster = cluster_start + "\u{1F468}".len;

    var ta = try initTestArea(s);
    defer deinitTestArea(&ta);
    ta.core.buffer.gap.moveGap(inside_cluster);

    try std.testing.expectEqual(cluster_start, ta.prevBoundary(cluster_end));
    try std.testing.expectEqual(cluster_end, ta.nextBoundary(cluster_start));
    try std.testing.expectEqual(cluster_start, ta.snapByteToGraphemeBoundary(inside_cluster));
}

test "TextArea hit-test byte results snap to grapheme boundaries" {
    const thumbs = "\u{1F44D}\u{1F3FB}";
    const s = "a" ++ thumbs ++ "b";
    const cluster_start = "a".len;
    const inside_cluster = cluster_start + "\u{1F44D}".len;
    const cluster_end = "a".len + thumbs.len;

    var ta = try initTestArea(s);
    defer deinitTestArea(&ta);

    try std.testing.expectEqual(cluster_start, ta.snapByteToGraphemeBoundary(inside_cluster));
    try std.testing.expectEqual(cluster_end, ta.snapByteToGraphemeBoundary(cluster_end));
    try std.testing.expectEqual(s.len, ta.snapByteToGraphemeBoundary(s.len));
}

test "TextArea composition handler updates IME session" {
    var ta: TextArea = undefined;
    ta.component = Component.init(std.testing.allocator, &TextArea.vtable);
    ta.ime = ImeSession.init(std.testing.allocator);
    defer ta.ime.deinit();

    var ev = awt.Event{ .payload = .{ .composition = .{
        .text = "abc",
        .target_start = 1,
        .target_end = 2,
    } } };
    processEvent(&ta.component, &ev);

    try std.testing.expect(ta.ime.isComposing());
    try std.testing.expectEqualStrings("abc", ta.ime.preeditSlice());
    try std.testing.expectEqual(ImeSession.TargetRange{ .start = 1, .end = 2 }, ta.ime.targetRange());
}
