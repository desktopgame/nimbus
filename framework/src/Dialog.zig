//! Owner-bound top-level window, shown modally (blocking, returns a result)
//! or modeless (non-blocking). See `framework/doc/dialog.md`.
//!
//! Modality is a show-time choice, not a separate type (mirrors Swing's
//! JDialog): `showModal` runs a nested timer-aware event loop and blocks the
//! caller until `close` is called; `show` just registers the window and
//! returns. Lifetime is caller-owned — `showModal` leaves the Dialog and its
//! widget tree alive after returning so the caller can read widget state and
//! reuse the dialog.

const std = @import("std");
const awt = @import("awt");
const Window = @import("Window.zig");
const Application = @import("Application.zig");

const Dialog = @This();

/// Outcome of a modal dialog. Non-exhaustive so callers can carry custom
/// integer codes (yes/no/apply, a chosen index, ...) through the same
/// channel — `close` accepts any `Result` and `showModal` returns it.
pub const Result = enum(i32) {
    none   = 0, // closed with no explicit result (X button / dispose)
    ok     = 1,
    cancel = 2,
    _,
};

window:     Window,
app:        *Application,
owner:      *Window,
/// True while shown via `showModal` (vs `show`).
modal:      bool,
/// Result set by the most recent `close`; `showModal` returns it.
result:     Result,
/// Set by `close` to break the modal loop in `showModal`.
modal_done: bool,
/// True while registered in Application's window list (guards double
/// show / double close).
shown:      bool,
allocator:  std.mem.Allocator,

pub fn init(
    app: *Application,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Dialog {
    var window = try Window.init(app.allocator, @ptrCast(app), app.event_queue, title, w, h, device, context);
    // The OS window is created visible; hide it until shown. A Dialog is not
    // destroyed on close (caller-owned), so show/close toggle visibility
    // rather than create/destroy the OS window.
    window.awt_window.?.setVisible(false);
    return .{
        .window     = window,
        .app        = app,
        .owner      = owner,
        .modal      = false,
        .result     = .none,
        .modal_done = false,
        .shown      = false,
        .allocator  = app.allocator,
    };
}

pub fn deinit(self: *Dialog) void {
    // If still shown (e.g. a modeless dialog the caller forgot to close),
    // unregister first so the run loop stops referencing freed memory.
    if (self.shown) self.app.unregisterWindow(&self.window);
    self.window.deinit();
}

/// Free the dialog in a single call: release internal resources (`deinit`)
/// and the heap allocation itself. A Dialog is caller-owned — it lives
/// outside Application's window tree, so nothing frees it automatically;
/// the caller calls this exactly once when done. Use this instead of the
/// `deinit` + `allocator.destroy` pair (mirrors how tree-owned widgets are
/// torn down by their container).
pub fn destroy(self: *Dialog) void {
    const allocator = self.allocator;
    self.deinit();
    allocator.destroy(self);
}

// ── show / close ──────────────────────────────────────────────────────────

/// Show the dialog and block the caller until it is closed, returning the
/// result. Must be called on the UI thread from within `Application.run`.
/// On return the dialog is hidden but still alive (read widget state / reuse).
pub fn showModal(self: *Dialog) Result {
    if (self.shown) return self.result;
    self.modal = true;
    self.result = .none;
    self.modal_done = false;
    // Clear a stale OS close flag so a dialog previously closed via its X
    // button can be re-shown.
    self.window.awt_window.?.setShouldClose(false);

    self.app.registerDialog(self) catch return .none;
    self.shown = true;
    // Best-effort: if the modal-stack push OOMs, fall through without input
    // blocking rather than failing the whole call.
    self.app.pushModal(&self.window) catch {};
    self.centerOnOwner();
    self.window.awt_window.?.setVisible(true);
    // GLFW has no OS-level modality. `input_blocked` already drops widget
    // input on the owner; floating + focus additionally keep the dialog above
    // the owner so it cannot be raised over / hidden behind it.
    self.window.awt_window.?.setFloating(true);
    self.window.awt_window.?.focus();
    self.window.repaint();

    // Nested timer-aware event loop: wakes on the soonest pending timer so
    // caret blink and the attention-flash animation keep ticking while modal.
    // Exits when `close` sets `modal_done`.
    while (!self.modal_done) {
        if (self.app.earliestDueIn()) |delay| {
            awt.waitEventsTimeout(@max(0, delay));
        } else {
            awt.waitEvents();
        }
        self.app.tickOnce();
    }
    // close() (button-driven or X-routed) already unregistered + popped the
    // modal stack; nothing else to clean up here.
    return self.result;
}

/// Show the dialog without blocking (modeless). The caller keeps the pointer
/// and manages lifetime; query `getResult` / observe `close` to react.
pub fn show(self: *Dialog) !void {
    if (self.shown) return;
    self.modal = false;
    self.result = .none;
    self.window.awt_window.?.setShouldClose(false);
    try self.app.registerDialog(self);
    self.shown = true;
    self.centerOnOwner();
    self.window.awt_window.?.setVisible(true);
    self.window.repaint();
}

/// Close the dialog with `result`. For a modal dialog this unblocks the
/// `showModal` call; for a modeless one it just hides the window. No-op if
/// already closed. Typically called from an OK / Cancel button handler.
pub fn close(self: *Dialog, result: Result) void {
    if (!self.shown) return;
    self.result = result;
    self.window.awt_window.?.setFloating(false);
    self.window.awt_window.?.setVisible(false);
    self.app.unregisterWindow(&self.window);
    self.shown = false;
    // Break the modal loop in `showModal` (no-op for a modeless dialog).
    self.modal_done = true;
    awt.postEmptyEvent();
}

// ── queries ─────────────────────────────────────────────────────────────

pub fn getResult(self: Dialog) Result {
    return self.result;
}

pub fn isModal(self: Dialog) bool {
    return self.modal;
}

pub fn isShown(self: Dialog) bool {
    return self.shown;
}

// ── internal ────────────────────────────────────────────────────────────

/// Position the dialog centered over its owner (OS screen coordinates).
fn centerOnOwner(self: *Dialog) void {
    const op = self.owner.awt_window.?.pos();
    const os = self.owner.awt_window.?.size();
    const ds = self.window.awt_window.?.size();
    const x = op.x + @divTrunc(os.width - ds.width, 2);
    const y = op.y + @divTrunc(os.height - ds.height, 2);
    self.window.awt_window.?.setPos(x, y);
}
