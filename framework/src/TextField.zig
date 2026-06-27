//! TextField widget. See `framework/doc/textfield.md`.
//!
//! Single-line, LTR, grapheme-cluster-granularity editing. State machine:
//!   - selection = [min(caret,mark), max(caret,mark))
//!   - char input replaces selection (or inserts at caret if empty)
//!   - key input: arrows / Home / End / Backspace / Del / Ctrl+A/C/X/V
//!   - mouse: press sets caret + mark; drag extends selection (capture)
//!   - caret blinks via Application.setInterval(500ms) while focused

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Application = @import("Application.zig");
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ActionListenerList = listener.ActionListenerList;
const ChangeEvent = listener.ChangeEvent;
const ActionEvent = listener.ActionEvent;
const ImeSession = @import("ImeSession.zig");
const EditableText = @import("EditableText.zig");

const TextField = @This();

const PADDING_X: f32 = 6;
const PADDING_Y: f32 = 4;
const CARET_WIDTH: f32 = 1;
const DEFAULT_COLUMNS: f32 = 20;
const BLINK_PERIOD_MS: u32 = 500;
const BORDER_WIDTH: f32 = 1;

// Colors come from `component.theme`: frame = border (accent when focused),
// preedit underlines = ime_preedit_underline / ime_preedit_target. The
// selection highlight is derived from accent (see `selectionColor`) so it
// tracks accent automatically. See `framework/doc/theme.md`.

/// Selection highlight: the theme accent at 40% alpha (derived, not a token).
fn selectionColor(t: *const @import("theme.zig").Theme) awt.Graphics.Color {
    return awt.Graphics.Color.rgba(t.accent.r, t.accent.g, t.accent.b, 0.40);
}

component: Component,
app: *Application,
core: EditableText,
font: awt.Graphics.TextFont,
color: awt.Graphics.Color,
background: awt.Graphics.Color,
caret_color: awt.Graphics.Color,
caret_visible: bool,
blink_timer_id: ?Application.TimerId,
has_focus: bool,
/// True between a left-button press inside the field and its release. Gates
/// selection-by-drag: plain hover also delivers `.move` (it reaches us via the
/// container hit-test, not just via mouse capture), so without this flag a
/// focused field would extend its selection just from the cursor passing over.
dragging: bool,
/// Horizontal scroll offset in pixels, measured from the text start (>= 0).
/// On-screen x of a glyph = PADDING_X + glyphXAtByte(b) - scroll_x. Kept so
/// the caret stays visible once the text outgrows the field width.
/// Recomputed by `ensureCaretVisible` whenever the caret moves (and as a
/// safety net at paint time, since width is only known after layout).
scroll_x: f32,
/// IME preedit (composition) session. Empty when not composing.
ime: ImeSession,
/// Fired (and the key consumed) when Enter is pressed  E"submit this field".
/// Used e.g. by a List cell editor to commit. See `textfield.md`.
submit_listeners: ActionListenerList,
/// Fired (and the key consumed) when Escape is pressed  E"cancel". Used e.g.
/// by a List cell editor to revert.
cancel_listeners: ActionListenerList,
/// Fired whenever the text content actually changes  Eedit
/// keys, typing, cut/paste, or `setText`. NOT fired for caret movement,
/// selection, focus, or IME preedit (uncommitted). Lets callers observe the
/// field without polling (mirrors Swing's DocumentListener at widget level).
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

const cursor_query = Component.CursorQuery{
    .at = ibeamCursor,
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

    const single_line = try singleLineCopy(allocator, initial_text);
    defer allocator.free(single_line);
    var core = try EditableText.initFromSlice(allocator, single_line);
    errdefer core.deinit();

    tf.* = .{
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
        .scroll_x = 0,
        .ime = ImeSession.init(allocator),
        .submit_listeners = ActionListenerList.init(allocator),
        .cancel_listeners = ActionListenerList.init(allocator),
        .change_listeners = ChangeListenerList.init(allocator),
        .allocator = allocator,
    };
    tf.ime.setOnCleared(ImeSession.ClearedHook.typed(TextField, imeCleared, tf));
    tf.component.role = .text_field;
    tf.component.a11y = .{ .name = a11yName };
    tf.component.cursor_query = cursor_query;
    tf.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context };
    tf.applyMetrics();
    try TextField.vtable.install(&tf.component);
    return tf;
}

// ── public API ───────────────────────────────────────────────────────────

pub fn getText(self: *TextField) []const u8 {
    return self.core.textSlice();
}

pub fn setText(self: *TextField, new_text: []const u8) !void {
    const single_line = try singleLineCopy(self.allocator, new_text);
    defer self.allocator.free(single_line);
    try self.core.setText(single_line);
    self.applyMetrics();
    self.change_listeners.fire(&.{ .source = self });
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

/// Listener fired when Enter is pressed (the field "submits"). The key is
/// consumed so it does not bubble. Multiple listeners allowed.
pub fn addSubmitListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void {
    try self.submit_listeners.addTyped(T, f, user_data);
}

pub fn removeSubmitListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void {
    self.submit_listeners.removeTyped(T, f, user_data);
}

/// Listener fired when Escape is pressed (the field "cancels").
pub fn addCancelListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void {
    try self.cancel_listeners.addTyped(T, f, user_data);
}

pub fn removeCancelListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void {
    self.cancel_listeners.removeTyped(T, f, user_data);
}

/// Listener fired whenever the text content changes. Lets a
/// caller mirror / validate the field without polling. Multiple allowed.
pub fn addChangeListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void {
    try self.change_listeners.addTyped(T, f, user_data);
}

pub fn removeChangeListener(self: *TextField, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void {
    self.change_listeners.removeTyped(T, f, user_data);
}

// ── layout ───────────────────────────────────────────────────────────────

fn applyMetrics(self: *TextField) void {
    const ui = self.component.ui;
    const min = ui.vtable.measureMinSize(&self.component, ui.ctx);
    self.component.min_size = min;
    self.component.max_size = .{ .width = std.math.inf(f32), .height = min.height };
    // Do not touch grow_x here. Its default 0 comes from Component.init, and
    // metrics recalculation (including setText) must not overwrite caller
    // layout policy such as setGrowX(1).
}

fn lookMeasureMinSize(self: *Component, _: *anyopaque) Component.Size {
    const tf: *TextField = @fieldParentPtr("component", self);
    return measureMinSizeValue(tf);
}

pub fn measureMinSizeValue(tf: *TextField) Component.Size {
    // setPixelSize MUST come first  Eboth metrics() and glyphAdvance read
    // freetype state that is only valid for the most recently-set size.
    tf.font.face.setPixelSize(tf.font.pixel_size);
    const line_h = tf.font.face.metrics().line_height;
    // Use 'M' as the canonical column-width sample (a common Western
    // convention; CJK columns naturally take ~2x this in advance units,
    // which is fine for a baseline).
    const sample_adv = tf.font.face.glyphAdvance('M');
    const w = sample_adv * DEFAULT_COLUMNS + PADDING_X * 2;
    const h = line_h + PADDING_Y * 2;
    return .{ .width = w, .height = h };
}

fn a11yName(c: *const Component) ?[]const u8 {
    const tf: *const TextField = @fieldParentPtr("component", c);
    return @constCast(tf).getText();
}

// ── vtable impl ──────────────────────────────────────────────────────────

fn ibeamCursor(_: *const Component, _: f32, _: f32) ?Component.CursorShape {
    return .ibeam;
}

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
    // requestFocus is a no-op  Eacceptable.
    if (tf.has_focus) self.requestFocus(); // will route to null via cleared focus_owner if root lost?  Eguarded below
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
    // full widget repaint is acceptable per CLAUDE.md「スチE��チED、E
    tf.component.repaint();
}

fn lookPaint(self: *Component, _: *anyopaque, g: *awt.Graphics) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    const sz = self.size;

    // Background.
    g.setColor(tf.background);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = sz.height });

    // Border (1px). Blue when focused for keyboard-focus feedback,
    // mid-grey otherwise. Drawn as four edge strips so we don't need a
    // stroke primitive.
    g.setColor(if (tf.has_focus) self.theme.accent else self.theme.border);
    g.fillRect(.{ .x = 0, .y = 0, .width = sz.width, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = 0, .y = sz.height - BORDER_WIDTH, .width = sz.width, .height = BORDER_WIDTH });
    g.fillRect(.{ .x = 0, .y = 0, .width = BORDER_WIDTH, .height = sz.height });
    g.fillRect(.{ .x = sz.width - BORDER_WIDTH, .y = 0, .width = BORDER_WIDTH, .height = sz.height });

    tf.paintContent(self, g);
}

pub fn paintContent(tf: *TextField, self: *Component, g: *awt.Graphics) void {
    const sz = self.size;

    // Keep scroll_x consistent with the caret now that the width is known
    // (layout runs before paint). This is the authoritative recompute;
    // edit/click paths also call it so the IME caret push is up to date.
    tf.ensureCaretVisible();

    // Everything below (selection / text / preedit / caret) is drawn through
    // a Graphics clipped to the inner content rect [PADDING_X, width-PADDING_X],
    // so scrolled glyphs never paint over the padding or the border. The
    // child Graphics' origin is shifted to (PADDING_X, 0), so content x is
    // expressed as `glyphXAtByte(b) - scroll_x` (0-based from the text start).
    const inner_w = sz.width - PADDING_X * 2;
    if (inner_w <= 0) return;
    var cg = g.clip(.{ .x = PADDING_X, .y = 0, .width = inner_w, .height = sz.height });
    const sx = tf.scroll_x;

    // Selection highlight (if non-empty).
    const sel_start = tf.selectionStartByte();
    const sel_end = tf.selectionEndByte();
    if (sel_end > sel_start) {
        const x0 = tf.glyphXAtByte(sel_start) - sx;
        const x1 = tf.glyphXAtByte(sel_end) - sx;
        cg.setColor(selectionColor(self.theme));
        cg.fillRect(.{
            .x = x0,
            .y = PADDING_Y,
            .width = x1 - x0,
            .height = sz.height - PADDING_Y * 2,
        });
    }

    // Text. `drawString` takes the top-left of the bbox (graphics.md: top-of-bbox派).
    cg.setFont(tf.font);
    cg.setColor(tf.color);
    cg.drawString(tf.getText(), -sx, PADDING_Y);

    // IME preedit (composition string). Rendered inline at the caret
    // position so it visually flows with surrounding text. Underlines
    // signal "this is provisional": a thin one under the whole preedit,
    // a thicker one under the target clause being converted.
    if (tf.has_focus and tf.ime.isComposing()) {
        const preedit = tf.ime.preeditSlice();
        const target = tf.ime.targetRange();
        const caret_x = tf.glyphXAtByte(tf.core.caret) - sx;

        cg.setFont(tf.font);
        cg.setColor(tf.color);
        cg.drawString(preedit, caret_x, PADDING_Y);

        const pre_w = tf.measureUtf8(preedit);
        const underline_y = sz.height - PADDING_Y;
        cg.setColor(self.theme.ime_preedit_underline);
        cg.fillRect(.{ .x = caret_x, .y = underline_y - 1, .width = pre_w, .height = 1 });

        if (target.end > target.start and target.end <= preedit.len) {
            const t0 = tf.measureUtf8(preedit[0..target.start]);
            const t1 = tf.measureUtf8(preedit[0..target.end]);
            cg.setColor(self.theme.ime_preedit_target);
            cg.fillRect(.{
                .x = caret_x + t0,
                .y = underline_y - 2,
                .width = t1 - t0,
                .height = 2,
            });
        }
    }

    // Caret. Hide while composing  Ethe OS IME / candidate window
    // owns the visual cursor inside the preedit, and drawing our own
    // would just be noise.
    if (tf.has_focus and tf.caret_visible and !tf.ime.isComposing()) {
        const cx = tf.glyphXAtByte(tf.core.caret) - sx;
        cg.setColor(tf.caret_color);
        cg.fillRect(.{
            .x = cx,
            .y = PADDING_Y,
            .width = CARET_WIDTH,
            .height = sz.height - PADDING_Y * 2,
        });
    }
}

fn lookPaintOver(_: *Component, _: *anyopaque, _: *awt.Graphics) void {}

fn processEvent(self: *Component, ev: *Component.Event) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    switch (ev.payload) {
        .mouse => |m| handleMouse(tf, ev, m),
        .key => |k| handleKey(tf, ev, k),
        .char => |ch| handleChar(tf, ev, ch),
        .focus => |f| {
            tf.has_focus = f.gained;
            // Restart blink at "visible" so the caret appears immediately
            // on focus gain (no awkward off→on flicker).
            tf.caret_visible = true;
            if (f.gained) tf.ensureCaretVisible();
            tf.component.repaint();
            if (f.gained) tf.pushCaretToIme();
        },
        .composition => |comp| {
            tf.ime.update(comp) catch {};
            tf.component.repaint();
        },
    }
}

fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const tf: *TextField = @fieldParentPtr("component", self);
    self.deinit();
    tf.core.deinit();
    tf.ime.deinit();
    tf.submit_listeners.deinit();
    tf.cancel_listeners.deinit();
    tf.change_listeners.deinit();
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
                tf.core.caret = pos;
                tf.core.mark = pos;
                tf.core.breakCoalescing();
                tf.dragging = true;
                ev.requestCapture(@ptrCast(&tf.component));
                tf.component.requestFocus();
                tf.caret_visible = true;
                tf.ensureCaretVisible();
                tf.component.repaint();
                tf.pushCaretToIme();
                ev.consume();
            }
        },
        .release => {
            if (m.button == .left) {
                tf.dragging = false;
                ev.consume();
            }
        },
        .move => {
            // Extend selection only while dragging (left button held since a
            // press inside). Plain hover also delivers `.move`, so gating on
            // `dragging` keeps a passing cursor from moving the caret.
            if (tf.dragging) {
                const pos = tf.hitTestByteAt(lx);
                if (pos != tf.core.caret) {
                    tf.core.caret = pos;
                    tf.core.breakCoalescing();
                    tf.caret_visible = true;
                    tf.ensureCaretVisible();
                    tf.component.repaint();
                }
            }
        },
        .scroll => {},
    }
}

fn handleKey(tf: *TextField, ev: *Component.Event, k: awt.Event.KeyEvent) void {
    if (k.action != .press and k.action != .repeat) return;

    // During IME composition the OS IME owns the keyboard. On Windows IMM32
    // consumes virtually every navigation / edit key, so this never mattered.
    // On macOS NSTextInputContext routes some keys (Shift+Left/Right, etc.)
    // both to the IME (for clause narrowing) AND through GLFW's key callback,
    // so if we react to them here too the buffer caret moves while the IME
    // is still composing  Epreedit ends up painted in the middle of already-
    // committed text. Bail out and let the composition flow drive everything.
    if (tf.ime.isComposing()) return;

    const shift = k.modifiers.shift;
    const ctrl = k.modifiers.ctrl;

    switch (k.code) {
        .arrow_left => {
            tf.moveCaretLeft(shift);
            tf.afterEdit(ev, false);
        },
        .arrow_right => {
            tf.moveCaretRight(shift);
            tf.afterEdit(ev, false);
        },
        .home => {
            tf.core.caret = 0;
            if (!shift) tf.core.mark = tf.core.caret;
            tf.core.breakCoalescing();
            tf.afterEdit(ev, false);
        },
        .end => {
            tf.core.caret = tf.core.len();
            if (!shift) tf.core.mark = tf.core.caret;
            tf.core.breakCoalescing();
            tf.afterEdit(ev, false);
        },
        .z => if (ctrl) {
            if (tf.core.undo() catch false) tf.afterEdit(ev, true) else ev.consume();
        },
        .y => if (ctrl) {
            if (tf.core.redo() catch false) tf.afterEdit(ev, true) else ev.consume();
        },
        .backspace => {
            const changed = tf.deleteBackwardGrapheme() catch false;
            tf.afterEdit(ev, changed);
        },
        .delete => {
            const changed = tf.deleteForwardGrapheme() catch false;
            tf.afterEdit(ev, changed);
        },
        .a => if (ctrl) {
            // Select-all is a selection change, not a content change.
            tf.core.mark = 0;
            tf.core.caret = tf.core.len();
            tf.core.breakCoalescing();
            tf.afterEdit(ev, false);
        },
        .c => if (ctrl) {
            tf.copyToClipboard();
            ev.consume();
        },
        .x => if (ctrl) {
            tf.copyToClipboard();
            const had_sel = tf.hasSelection();
            if (had_sel) {
                tf.core.breakCoalescing();
                tf.deleteSelection() catch {};
                tf.core.breakCoalescing();
            }
            tf.afterEdit(ev, had_sel);
        },
        .v => if (ctrl) {
            const changed = tf.pasteFromClipboard() catch false;
            tf.afterEdit(ev, changed);
        },
        .enter => {
            // Single-line: Enter submits. Fire listeners and consume so the
            // key does not bubble (a List cell editor commits here).
            tf.submit_listeners.fire(&.{ .source = tf });
            ev.consume();
        },
        .escape => {
            tf.cancel_listeners.fire(&.{ .source = tf });
            ev.consume();
        },
        else => {},
    }
}

fn handleChar(tf: *TextField, ev: *Component.Event, ch: awt.Event.CharEvent) void {
    if (ch.codepoint == '\n' or ch.codepoint == '\r') {
        ev.consume();
        return;
    }
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(ch.codepoint), &buf) catch return;
    const changed = tf.core.insert(buf[0..n]) catch return;
    tf.afterEdit(ev, changed);
}

/// Common tail for every key/char handler. `changed` is true only when the
/// text content was actually mutated (not for caret movement / selection),
/// in which case change listeners fire before the repaint.
fn afterEdit(tf: *TextField, ev: *Component.Event, changed: bool) void {
    if (changed) tf.change_listeners.fire(&.{ .source = tf });
    tf.caret_visible = true;
    tf.ensureCaretVisible();
    tf.component.repaint();
    tf.pushCaretToIme();
    ev.consume();
}

/// Tell the OS IME where the caret currently sits (in OS screen-relative
/// pixels via the awt.Window helper, which expects window-local). The IME
/// uses this to anchor its candidate window beneath the caret. No-op if
/// the widget is not attached to a Window.
fn pushCaretToIme(self: *TextField) void {
    const w = self.parentWindow() orelse return;
    const origin = self.component.absoluteOriginInWindow();
    const caret_x = origin.x + PADDING_X + self.glyphXAtByte(self.core.caret) - self.scroll_x;
    const caret_y = origin.y + PADDING_Y;
    self.font.face.setPixelSize(self.font.pixel_size);
    const line_h = self.font.face.metrics().line_height;
    self.ime.pushCaret(if (w.awt_window) |*aw| aw else null, .{
        .x = caret_x,
        .y = caret_y,
        .height = line_h,
    });
}

/// Adjust `scroll_x` so the caret stays inside the visible content area
/// [0, inner_w] (in text-start coordinates). Scrolls right when the caret
/// runs past the right edge, left when it precedes the left edge, then
/// clamps so we never scroll before the start or leave dead space on the
/// right when the tail could shift back into view. No-op before the widget
/// has been laid out (width 0).
fn ensureCaretVisible(self: *TextField) void {
    const inner_w = self.component.size.width - PADDING_X * 2;
    if (inner_w <= 0) return;

    const caret_x = self.glyphXAtByte(self.core.caret);
    // Reserve CARET_WIDTH at the right so the caret itself is not clipped
    // by the content rect's right edge.
    if (caret_x - self.scroll_x > inner_w - CARET_WIDTH) {
        self.scroll_x = caret_x - (inner_w - CARET_WIDTH);
    } else if (caret_x - self.scroll_x < 0) {
        self.scroll_x = caret_x;
    }

    // +CARET_WIDTH: the trailing caret sits just past the last glyph, so the
    // scrollable content effectively extends that far  Eotherwise a caret at
    // end-of-text would be clipped at the right boundary.
    const end_x = self.glyphXAtByte(self.getText().len);
    const max_scroll = @max(0, end_x + CARET_WIDTH - inner_w);
    if (self.scroll_x > max_scroll) self.scroll_x = max_scroll;
    if (self.scroll_x < 0) self.scroll_x = 0;
}

// ── selection / edit helpers ─────────────────────────────────────────────

fn singleLineCopy(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, bytes.len);
    for (bytes) |b| {
        if (b != '\r' and b != '\n') out.appendAssumeCapacity(b);
    }
    return try out.toOwnedSlice(allocator);
}

fn hasSelection(self: *TextField) bool {
    return self.core.hasSelection();
}

fn selectionStartByte(self: *TextField) usize {
    return self.core.selectionStart();
}

fn selectionEndByte(self: *TextField) usize {
    return self.core.selectionEnd();
}

fn selectionSlice(self: *TextField) []const u8 {
    return self.getText()[self.selectionStartByte()..self.selectionEndByte()];
}

fn deleteSelection(self: *TextField) !void {
    _ = try self.core.deleteSelection();
}

fn moveCaretLeft(self: *TextField, extend_selection: bool) void {
    self.core.caret = self.core.prevBoundary(self.core.caret);
    if (!extend_selection) self.core.mark = self.core.caret;
    self.core.breakCoalescing();
}

fn moveCaretRight(self: *TextField, extend_selection: bool) void {
    self.core.caret = self.core.nextBoundary(self.core.caret);
    if (!extend_selection) self.core.mark = self.core.caret;
    self.core.breakCoalescing();
}

fn deleteBackwardGrapheme(self: *TextField) !bool {
    return self.core.deleteBackward();
}

fn deleteForwardGrapheme(self: *TextField) !bool {
    return self.core.deleteForward();
}

fn copyToClipboard(self: *TextField) void {
    if (!self.hasSelection()) return;
    const slice = self.selectionSlice();
    const tmp = self.allocator.allocSentinel(u8, slice.len, 0) catch return;
    defer self.allocator.free(tmp);
    @memcpy(tmp[0..slice.len], slice);
    if (self.parentWindow()) |w| if (w.awt_window) |*aw| aw.setClipboardString(tmp);
}

fn pasteText(self: *TextField, bytes: []const u8) !bool {
    const single_line = try singleLineCopy(self.allocator, bytes);
    defer self.allocator.free(single_line);
    return try self.core.paste(single_line);
}

fn pasteFromClipboard(self: *TextField) !bool {
    const w = self.parentWindow() orelse return false;
    if (w.awt_window == null) return false;
    const got = w.awt_window.?.getClipboardString() orelse return false;
    return try self.pasteText(got);
}

fn imeCleared(self: *TextField) void {
    self.core.breakCoalescing();
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

// ── byte ↁEpixel mapping ─────────────────────────────────────────────────

/// Return the byte position whose left edge is closest to `x_local`
/// (widget-local pixels). When `x_local` falls inside a glyph, we split at
/// the half-width  Eso clicking the right half of a character places the
/// caret after it. Returns text.items.len if `x_local` is past every glyph.
/// Accounts for the horizontal scroll offset: a click maps to the glyph
/// position `x_local - PADDING_X + scroll_x` in text-start coordinates.
fn hitTestByteAt(self: *TextField, x_local: f32) usize {
    self.font.face.setPixelSize(self.font.pixel_size);
    const target = x_local - PADDING_X + self.scroll_x;
    const byte = self.font.face.byteAtX(self.getText(), target);
    return self.snapByteToGraphemeBoundary(byte);
}

/// Sum of advance widths for the UTF-8 bytes in `s`. Used to measure
/// substrings (preedit, target clause) without the PADDING_X offset that
/// `xAtByte` adds.
fn measureUtf8(self: *TextField, s: []const u8) f32 {
    self.font.face.setPixelSize(self.font.pixel_size);
    return self.font.face.advanceOfRange(s, 0, s.len);
}

/// Return the x pixel offset of the left edge of the glyph starting at
/// `byte_pos`, measured from the text start (0-based, NOT including
/// PADDING_X or the scroll offset). `byte_pos == text.items.len` returns the
/// position after the last glyph (where the trailing caret sits). Callers
/// add `PADDING_X` and subtract `scroll_x` to get an on-screen position.
fn glyphXAtByte(self: *TextField, byte_pos: usize) f32 {
    self.font.face.setPixelSize(self.font.pixel_size);
    return self.font.face.advanceOfRange(self.getText(), 0, byte_pos);
}

fn snapByteToGraphemeBoundary(self: *TextField, byte_pos: usize) usize {
    const clamped = @min(byte_pos, self.getText().len);
    const prev = awt.grapheme.prevGraphemeBoundary(self.getText(), clamped);
    if (awt.grapheme.nextGraphemeBoundary(self.getText(), prev) == clamped) return clamped;
    return prev;
}

test "selection range - caret < mark and caret > mark" {
    var tf: TextField = undefined;
    tf.core = EditableText.init(std.testing.allocator);
    defer tf.core.deinit();

    tf.core.caret = 2;
    tf.core.mark = 5;
    try std.testing.expectEqual(@as(usize, 2), tf.selectionStartByte());
    try std.testing.expectEqual(@as(usize, 5), tf.selectionEndByte());
    try std.testing.expect(tf.hasSelection());

    tf.core.caret = 7;
    tf.core.mark = 3;
    try std.testing.expectEqual(@as(usize, 3), tf.selectionStartByte());
    try std.testing.expectEqual(@as(usize, 7), tf.selectionEndByte());

    tf.core.caret = 4;
    tf.core.mark = 4;
    try std.testing.expect(!tf.hasSelection());
}

test "caret movement uses grapheme cluster boundaries" {
    const accent = "e\u{0301}";
    const thumbs = "\u{1F44D}\u{1F3FB}";
    const s = "a" ++ accent ++ thumbs ++ "b";

    var tf: TextField = undefined;
    tf.core = try EditableText.initFromSlice(std.testing.allocator, s);
    defer tf.core.deinit();
    tf.core.caret = 0;
    tf.core.mark = 0;

    tf.moveCaretRight(false);
    try std.testing.expectEqual(@as(usize, 1), tf.core.caret);
    try std.testing.expectEqual(tf.core.caret, tf.core.mark);

    tf.moveCaretRight(false);
    try std.testing.expectEqual(@as(usize, 1 + accent.len), tf.core.caret);

    tf.moveCaretRight(false);
    try std.testing.expectEqual(@as(usize, 1 + accent.len + thumbs.len), tf.core.caret);

    tf.moveCaretLeft(false);
    try std.testing.expectEqual(@as(usize, 1 + accent.len), tf.core.caret);

    tf.moveCaretLeft(true);
    try std.testing.expectEqual(@as(usize, 1), tf.core.caret);
    try std.testing.expectEqual(@as(usize, 1 + accent.len), tf.core.mark);
}

test "backspace and delete remove whole grapheme clusters" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const s = "a" ++ family ++ "b";

    var tf: TextField = undefined;
    tf.core = try EditableText.initFromSlice(std.testing.allocator, s);
    defer tf.core.deinit();
    tf.core.caret = 1 + family.len;
    tf.core.mark = tf.core.caret;

    try std.testing.expect(try tf.deleteBackwardGrapheme());
    try std.testing.expectEqualStrings("ab", tf.getText());
    try std.testing.expectEqual(@as(usize, 1), tf.core.caret);
    try std.testing.expectEqual(tf.core.caret, tf.core.mark);

    try std.testing.expect(try tf.deleteForwardGrapheme());
    try std.testing.expectEqualStrings("a", tf.getText());
    try std.testing.expectEqual(@as(usize, 1), tf.core.caret);
}

test "paste filters line breaks and undo restores" {
    var tf: TextField = undefined;
    tf.allocator = std.testing.allocator;
    tf.core = try EditableText.initFromSlice(std.testing.allocator, "a");
    defer tf.core.deinit();

    try std.testing.expect(try tf.pasteText("b\r\nc\nd"));
    try std.testing.expectEqualStrings("abcd", tf.getText());
    try std.testing.expect(try tf.core.undo());
    try std.testing.expectEqualStrings("a", tf.getText());
}

test "hit-test byte results snap back to grapheme cluster boundaries" {
    const thumbs = "\u{1F44D}\u{1F3FB}";
    const s = "a" ++ thumbs ++ "b";
    const cluster_start = "a".len;
    const inside_cluster = cluster_start + "\u{1F44D}".len;
    const cluster_end = "a".len + thumbs.len;

    var tf: TextField = undefined;
    tf.core = try EditableText.initFromSlice(std.testing.allocator, s);
    defer tf.core.deinit();

    try std.testing.expectEqual(cluster_start, tf.snapByteToGraphemeBoundary(inside_cluster));
    try std.testing.expectEqual(cluster_end, tf.snapByteToGraphemeBoundary(cluster_end));
    try std.testing.expectEqual(s.len, tf.snapByteToGraphemeBoundary(s.len));
}

test "TextField composition handler updates IME session" {
    var tf: TextField = undefined;
    tf.component = Component.init(std.testing.allocator, &TextField.vtable);
    tf.ime = ImeSession.init(std.testing.allocator);
    defer tf.ime.deinit();

    var ev = awt.Event{ .payload = .{ .composition = .{
        .text = "abc",
        .target_start = 1,
        .target_end = 2,
    } } };
    processEvent(&tf.component, &ev);

    try std.testing.expect(tf.ime.isComposing());
    try std.testing.expectEqualStrings("abc", tf.ime.preeditSlice());
    try std.testing.expectEqual(ImeSession.TargetRange{ .start = 1, .end = 2 }, tf.ime.targetRange());
}
