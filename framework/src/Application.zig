//! Top-level application object. See `framework/doc/application.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const Label = @import("Label.zig");
const Panel = @import("Panel.zig");
const Button = @import("Button.zig");
const CheckBox = @import("CheckBox.zig");
const RadioButton = @import("RadioButton.zig");
const ButtonGroup = @import("ButtonGroup.zig");
const ComboBox = @import("ComboBox.zig");
const List = @import("List.zig");
const ScrollBar = @import("ScrollBar.zig");
const ScrollPane = @import("ScrollPane.zig");
const Slider = @import("Slider.zig");
const Frame = @import("Frame.zig");
const Dialog = @import("Dialog.zig");
const Window = @import("Window.zig");
const Menu = @import("Menu.zig");
const MenuItem = @import("MenuItem.zig");
const MenuBar = @import("MenuBar.zig");
const CheckBoxMenuItem = @import("CheckBoxMenuItem.zig");
const PopupMenu = @import("PopupMenu.zig");
const MenuSeparator = @import("MenuSeparator.zig");
const TextField = @import("TextField.zig");
const TextArea = @import("TextArea.zig");
const Theme = @import("theme.zig").Theme;
const noto = @import("noto/fonts.zig");
const lucide = @import("lucide/icons.zig");

const Application = @This();

const WindowEntry = struct {
    window:  *Window,
    /// Free the outer widget (Frame 等) that contains the Window.
    /// Called when the window closes or Application.deinit runs. For caller-
    /// owned Dialogs this is a no-op (see `dialog`); the loop routes their
    /// close to `Dialog.close` instead of destroying them.
    outer:   *anyopaque,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Non-null when this entry is a Dialog. Lets the close-reaper route a
    /// close request to `Dialog.close(.none)` instead of destroying (Dialogs
    /// are owned by the caller, not by Application).
    dialog:  ?*Dialog = null,
    /// Window geometry last synced with the OS. Compared against the Window's
    /// desired `win_pos`/`win_size` at each loop tail; a mismatch is pushed to
    /// the OS and recorded here. OS-driven resizes update this via
    /// `noteOsGeometry` so the diff does not bounce back. See
    /// `application.md`「OS との同期」.
    synced_pos:  awt.Window.Point,
    synced_size: awt.Window.Size,
};

pub const TimerId = u32;
/// Callback fired when a timer's deadline elapses. Receives the opaque
/// `user_data` registered with `setTimeout` / `setInterval`.
pub const TimerCallback = *const fn (*anyopaque) void;

const Timer = struct {
    id:        TimerId,
    /// Monotonic `awt.time()` (seconds since `awt.init`) at which this
    /// timer next fires.
    due_time:  f64,
    /// Repeat period in milliseconds. 0 → one-shot (removed after firing).
    period_ms: u32,
    cb:        TimerCallback,
    user_data: *anyopaque,
};

/// Time source selector. `real` reads the monotonic `awt.time()` (GLFW clock);
/// `virtual` reads `virtual_now`, advanced only by `advanceClock` — used by the
/// headless / Robot path to drive time-dependent behavior deterministically
/// without real sleeps. See `framework/doc/robot.md`「仮想クロック」.
pub const ClockMode = enum { real, virtual };

allocator:    std.mem.Allocator,
device:       awt.Device,
context:      awt.Graphics.Context,
default_font: awt.Font,
event_queue:  *awt.EventQueue,
windows:      std.ArrayList(WindowEntry),
/// Active modal Dialog windows, bottom→top. Non-empty means a modal is up:
/// only the top window receives input (`refreshModalBlocking`). Supports
/// nested modals (a dialog opened from a dialog).
modal_stack:  std.ArrayList(*Window),
timers:       std.ArrayList(Timer),
next_timer_id: TimerId,
/// Time source. Real mode (default) follows `awt.time()`; virtual mode is set
/// by the headless factory so `advanceClock` drives time deterministically.
clock_mode:   ClockMode,
virtual_now:  f64,
/// Lazily-decoded GPU images for built-in lucide icons. Slot is null until
/// the first `icon(.foo)` call decodes the PNG and uploads the texture.
/// All slots are freed in `deinit`.
icon_cache:   [lucide.Icon.count]?awt.Image,
/// Color catalog for the default look. Fixed at startup (`initWithTheme`);
/// every factory-created component points at this copy (`&app.theme`).
/// See `framework/doc/theme.md`.
theme:        Theme,

// Owned program / buffer objects (Graphics.Context holds pointers to these).
_color_program: awt.programs.Color,
_image_program: awt.programs.Image,
_rrect_program: awt.programs.RoundedRect,
_text_program:  awt.programs.Text,
_vertex_ring:   awt.VertexRing,
_uniforms:      awt.UniformBuffer,
_quad_index:    awt.QuadIndexBuffer,
_atlas:         awt.GlyphAtlas,

/// Initialize the application. The default font is the bundled Noto Sans JP
/// regular (see `framework/src/noto/`); callers do not need to supply font
/// bytes. `io` is used for the internal EventQueue's mutex / condvar
/// operations; typically obtained from `std.process.Init.io` in the caller's
/// `main`.
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Application {
    const app = try allocator.create(Application);
    errdefer allocator.destroy(app);

    try awt.init();
    errdefer awt.deinit();

    app.allocator = allocator;
    app.windows = .empty;
    app.modal_stack = .empty;
    app.timers = .empty;
    app.next_timer_id = 1;
    app.clock_mode = .real;
    app.virtual_now = 0;
    app.icon_cache = @splat(null);
    app.theme = Theme.default;

    app.device = try awt.Device.init();
    errdefer app.device.deinit();

    app._color_program = try awt.programs.Color.init(app.device);
    errdefer app._color_program.deinit();
    app._image_program = try awt.programs.Image.init(app.device);
    errdefer app._image_program.deinit();
    app._rrect_program = try awt.programs.RoundedRect.init(app.device);
    errdefer app._rrect_program.deinit();
    app._text_program = try awt.programs.Text.init(app.device);
    errdefer app._text_program.deinit();

    // 1 MB ring ≈ 16384 text glyphs (64 B each) per frame — comfortable for a
    // full-screen dense text view. Single UPLOAD-heap allocation, so the cost
    // is just that one buffer. max_quads 4096 raises the single-drawString cap
    // (one visual line) from 1024 to 4096 glyphs.
    app._vertex_ring = try awt.VertexRing.init(app.device, 1024 * 1024);
    errdefer app._vertex_ring.deinit();
    app._uniforms = try awt.UniformBuffer.init(app.device, 64 * 1024);
    errdefer app._uniforms.deinit();
    app._quad_index = try awt.QuadIndexBuffer.init(allocator, app.device, 4096);
    errdefer app._quad_index.deinit();
    app._atlas = try awt.GlyphAtlas.init(allocator, app.device, 2048);
    errdefer app._atlas.deinit();

    app.context = .{
        .vertex_ring   = &app._vertex_ring,
        .uniforms      = &app._uniforms,
        .quad_index    = &app._quad_index,
        .atlas         = &app._atlas,
        .color_program = &app._color_program,
        .image_program = &app._image_program,
        .rrect_program = &app._rrect_program,
        .text_program  = &app._text_program,
    };

    app.default_font = try awt.Font.init(noto.noto_sans_jp_regular, 0);
    errdefer app.default_font.deinit();

    app.event_queue = try awt.EventQueue.init(allocator, io);
    errdefer app.event_queue.deinit();
    app.event_queue.setUiThread(std.Thread.getCurrentId());

    return app;
}

/// Headless variant of `init` for the Robot / deterministic-test path: same
/// setup as `init`, but the clock runs in virtual mode (`advanceClock`-driven).
/// Create windows with `frameHeadless`; drive the loop with `Robot.pump` rather
/// than `run` (which would block on OS events that never come). See
/// `framework/doc/robot.md`.
pub fn initHeadless(allocator: std.mem.Allocator, io: std.Io) !*Application {
    const app = try Application.init(allocator, io);
    app.clock_mode = .virtual;
    app.virtual_now = 0;
    return app;
}

/// `init` with a theme: `theme` is copied by value into the Application (the
/// argument's lifetime does not matter afterwards) and every factory-created
/// component will consult this copy. The theme is fixed for the app's
/// lifetime — there is no runtime switching (see `framework/doc/theme.md`).
pub fn initWithTheme(allocator: std.mem.Allocator, io: std.Io, theme: Theme) !*Application {
    const app = try Application.init(allocator, io);
    app.theme = theme;
    return app;
}

pub fn deinit(self: *Application) void {
    for (self.windows.items) |entry| {
        entry.destroy(entry.outer, self.allocator);
    }
    self.windows.deinit(self.allocator);
    self.modal_stack.deinit(self.allocator);

    self.timers.deinit(self.allocator);

    self.event_queue.deinit();
    self.default_font.deinit();

    // Free cached icon textures before tearing down the device they live on.
    for (&self.icon_cache) |*slot| {
        if (slot.*) |*img| img.deinit();
    }

    self._atlas.deinit();
    self._quad_index.deinit();
    self._uniforms.deinit();
    self._vertex_ring.deinit();
    self._text_program.deinit();
    self._rrect_program.deinit();
    self._image_program.deinit();
    self._color_program.deinit();
    self.device.deinit();
    awt.deinit();

    self.allocator.destroy(self);
}

pub fn getEventQueue(self: *Application) *awt.EventQueue {
    return self.event_queue;
}

/// Current time in seconds for time-dependent logic (timers, double-click,
/// caret blink). Real mode returns the monotonic `awt.time()`; virtual mode
/// returns the internal counter advanced by `advanceClock`.
pub fn now(self: *const Application) f64 {
    return switch (self.clock_mode) {
        .real => awt.time(),
        .virtual => self.virtual_now,
    };
}

/// Advance the virtual clock by `ms` milliseconds. No-op in real mode (the
/// clock follows `awt.time()` there). Due timers do not fire until the loop is
/// stepped — call `tickOnce` (or `Robot.pump`) afterward.
pub fn advanceClock(self: *Application, ms: u32) void {
    if (self.clock_mode == .virtual) {
        self.virtual_now += @as(f64, @floatFromInt(ms)) / 1000.0;
    }
}

/// Run the main event loop. Returns when all windows have been closed.
pub fn run(self: *Application) !void {
    while (self.windows.items.len > 0) {
        // Block until either (a) an OS event arrives or (b) the next
        // timer's deadline elapses. waitEvents (no timeout) when no
        // timers are pending.
        if (self.earliestDueIn()) |delay| {
            awt.waitEventsTimeout(@max(0, delay));
        } else {
            awt.waitEvents();
        }

        self.tickOnce();
    }
}

/// One iteration of per-window upkeep: fire due timers, drain queued input,
/// redraw dirty windows, reap closed ones. Shared by `run` and by the nested
/// modal loop in `Dialog.showModal`, so a modal keeps every window painting,
/// timers ticking, and `invokeLater` tasks flowing. Does NOT wait for events
/// — the caller's loop owns the blocking wait.
pub fn tickOnce(self: *Application) void {
    self.fireDueTimers();
    self.event_queue.drain();
    // Push any code-driven window move/resize to the OS before painting, so
    // the redraw below lays out against the up-to-date size.
    self.syncWindowGeometry();

    for (self.windows.items) |entry| {
        if (entry.window.paint_dirty or entry.window.layout_dirty) {
            entry.window.redraw();
        }
    }

    self.collectClosedWindows();
}

/// Reflect each window's desired geometry (`win_pos`/`win_size`) to the OS.
/// Runs at the event-loop tail (`application.md`「OS との同期」): for every
/// window, diff the model against the last-synced value and push only the
/// fields that changed. OS-driven resizes are absorbed by `noteOsGeometry`
/// (called from the resize callback), so a live user resize is not pushed
/// back and the model never ping-pongs with the OS.
fn syncWindowGeometry(self: *Application) void {
    for (self.windows.items) |*entry| {
        const w = entry.window;
        if (w.headless) continue; // headless windows have no OS geometry to sync
        const want_pos = w.getPos();
        if (want_pos.x != entry.synced_pos.x or want_pos.y != entry.synced_pos.y) {
            w.awt_window.?.setPos(want_pos.x, want_pos.y);
            entry.synced_pos = want_pos;
        }
        const want_size = w.getSize();
        if (want_size.width != entry.synced_size.width or
            want_size.height != entry.synced_size.height)
        {
            w.awt_window.?.setSize(want_size.width, want_size.height);
            entry.synced_size = want_size;
        }
    }
}

/// Mark `w`'s current geometry as already synced with the OS. Called from the
/// window's resize callback so `syncWindowGeometry` sees no diff and does not
/// push the size back while the user is dragging the window's edge. No-op if
/// `w` is not (yet) registered.
pub fn noteOsGeometry(self: *Application, w: *Window) void {
    for (self.windows.items) |*entry| {
        if (entry.window == w) {
            entry.synced_pos = w.getPos();
            entry.synced_size = w.getSize();
            return;
        }
    }
}

/// Reap windows whose OS close flag is set. Frames are destroyed (Application
/// owns them). Dialogs are caller-owned: route the close to
/// `Dialog.close(.none)` (which unregisters + exits any modal loop) and leave
/// the object alive. While a modal is active, only the top modal window's
/// close is acted on — the owner cannot be torn down underneath a modal.
fn collectClosedWindows(self: *Application) void {
    const modal_top: ?*Window = if (self.modal_stack.items.len > 0)
        self.modal_stack.items[self.modal_stack.items.len - 1]
    else
        null;

    var i: usize = 0;
    while (i < self.windows.items.len) {
        const entry = self.windows.items[i];
        if (!entry.window.shouldClose()) {
            i += 1;
            continue;
        }
        if (modal_top != null and entry.window != modal_top.?) {
            // Defer: a modal is up and this is not it. Leave the close flag
            // set; a later tick (after the modal ends) will reap it.
            i += 1;
            continue;
        }
        if (entry.dialog) |d| {
            // close() removes this entry from `windows`; keep i (the next
            // entry shifts into this slot).
            d.close(.none);
        } else {
            _ = self.windows.orderedRemove(i);
            entry.destroy(entry.outer, self.allocator);
        }
    }
}

// ── dialog / modal plumbing (used by Dialog) ──────────────────────────────

fn noopDestroy(_: *anyopaque, _: std.mem.Allocator) void {}

/// Register a Dialog's window in the run loop (called by `Dialog.show` /
/// `showModal`). Unlike Frames, the entry's `destroy` is a no-op — Dialogs
/// are caller-owned.
pub fn registerDialog(self: *Application, d: *Dialog) !void {
    try self.windows.append(self.allocator, .{
        .window  = &d.window,
        .outer   = @ptrCast(d),
        .destroy = noopDestroy,
        .dialog  = d,
        .synced_pos  = d.window.getPos(),
        .synced_size = d.window.getSize(),
    });
    // Respect any modal currently in effect (block the freshly-shown window
    // unless it is itself the modal top).
    self.refreshModalBlocking();
}

/// Remove a window from the run loop and the modal stack (called by
/// `Dialog.close` / `deinit`). Idempotent.
pub fn unregisterWindow(self: *Application, w: *Window) void {
    var i: usize = 0;
    while (i < self.modal_stack.items.len) : (i += 1) {
        if (self.modal_stack.items[i] == w) {
            _ = self.modal_stack.orderedRemove(i);
            break;
        }
    }
    i = 0;
    while (i < self.windows.items.len) : (i += 1) {
        if (self.windows.items[i].window == w) {
            _ = self.windows.orderedRemove(i);
            break;
        }
    }
    self.refreshModalBlocking();
}

/// Push a window as the active modal (called by `Dialog.showModal`).
pub fn pushModal(self: *Application, w: *Window) !void {
    try self.modal_stack.append(self.allocator, w);
    self.refreshModalBlocking();
}

/// Flash the active (top) modal window to demand attention. Called when the
/// user pokes a window blocked behind a modal — mirrors Swing, where clicking
/// a modal's owner flashes the dialog. No-op if no modal is active.
pub fn flashActiveModal(self: *Application) void {
    if (self.modal_stack.items.len == 0) return;
    const top = self.modal_stack.items[self.modal_stack.items.len - 1];
    // OS window-frame attention flash (Win32 FlashWindowEx → title bar +
    // taskbar + DWM drop shadow pulse; macOS dock bounce). Matches native
    // modal behavior. Note this is a window-frame effect: if the dialog is
    // positioned entirely off the owner there is no in-content feedback —
    // same as Swing/NetBeans.
    if (top.awt_window) |*aw| aw.requestAttention();
}

/// Recompute per-window input blocking from the modal stack: only the top
/// modal window (if any) accepts input; everything else is blocked.
fn refreshModalBlocking(self: *Application) void {
    const top: ?*Window = if (self.modal_stack.items.len > 0)
        self.modal_stack.items[self.modal_stack.items.len - 1]
    else
        null;
    for (self.windows.items) |entry| {
        entry.window.input_blocked = (top != null and entry.window != top.?);
    }
}

// ── timers ───────────────────────────────────────────────────────────────

/// Schedule a one-shot callback to fire after `ms` milliseconds.
/// Returns an opaque id usable with `clearTimer` if you need to cancel
/// before it fires (e.g. component being destroyed).
pub fn setTimeout(
    self: *Application,
    ms: u32,
    cb: TimerCallback,
    user_data: *anyopaque,
) !TimerId {
    return self.addTimer(ms, 0, cb, user_data);
}

/// Schedule a repeating callback to fire every `ms` milliseconds.
/// The first firing happens `ms` after the call. Use `clearTimer` to stop.
pub fn setInterval(
    self: *Application,
    ms: u32,
    cb: TimerCallback,
    user_data: *anyopaque,
) !TimerId {
    return self.addTimer(ms, ms, cb, user_data);
}

/// Cancel a pending timer. No-op if the id is unknown (already fired /
/// cleared / never existed).
pub fn clearTimer(self: *Application, id: TimerId) void {
    var i: usize = 0;
    while (i < self.timers.items.len) : (i += 1) {
        if (self.timers.items[i].id == id) {
            _ = self.timers.orderedRemove(i);
            return;
        }
    }
}

fn addTimer(
    self: *Application,
    delay_ms: u32,
    period_ms: u32,
    cb: TimerCallback,
    user_data: *anyopaque,
) !TimerId {
    const id = self.next_timer_id;
    self.next_timer_id +%= 1;
    const delay_s: f64 = @as(f64, @floatFromInt(delay_ms)) / 1000.0;
    try self.timers.append(self.allocator, .{
        .id        = id,
        .due_time  = self.now() + delay_s,
        .period_ms = period_ms,
        .cb        = cb,
        .user_data = user_data,
    });
    // Wake the run loop so the wait deadline is recomputed (the new timer
    // may be sooner than the current sleep target).
    awt.postEmptyEvent();
    return id;
}

/// Seconds until the soonest timer fires (clamped to 0). Returns null
/// when no timers are scheduled.
pub fn earliestDueIn(self: *Application) ?f64 {
    if (self.timers.items.len == 0) return null;
    var soonest: f64 = self.timers.items[0].due_time;
    for (self.timers.items[1..]) |t| {
        if (t.due_time < soonest) soonest = t.due_time;
    }
    return soonest - self.now();
}

fn fireDueTimers(self: *Application) void {
    const now_s = self.now();
    var i: usize = 0;
    while (i < self.timers.items.len) {
        var t = self.timers.items[i];
        if (t.due_time <= now_s) {
            // Snapshot the timer before firing; the callback may call
            // `clearTimer` on its own id, which would invalidate `i`.
            t.cb(t.user_data);

            // Re-locate by id since the list may have changed in the cb.
            if (self.findTimerIndex(t.id)) |idx| {
                if (self.timers.items[idx].period_ms == 0) {
                    _ = self.timers.orderedRemove(idx);
                } else {
                    const period_s: f64 = @as(f64, @floatFromInt(self.timers.items[idx].period_ms)) / 1000.0;
                    // Advance by period (no skip-catch-up; missed ticks coalesce).
                    self.timers.items[idx].due_time = now_s + period_s;
                    i = idx + 1;
                    continue;
                }
            }
            // Either deleted by callback or removed as one-shot — don't bump i.
        } else {
            i += 1;
        }
    }
}

fn findTimerIndex(self: *Application, id: TimerId) ?usize {
    for (self.timers.items, 0..) |t, idx| {
        if (t.id == id) return idx;
    }
    return null;
}

// ── factories ────────────────────────────────────────────────────────────

pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    errdefer self.allocator.destroy(f);
    f.* = try Frame.init(self.allocator, @ptrCast(self), self.event_queue, title, w, h, &self.device, &self.context);
    // Frame.init succeeded; from here on any failure must run Frame.deinit to
    // release Window / Swapchain / title_dup (install can fail with OOM since
    // it allocates DirtyNotify property; windows.append can also fail).
    errdefer f.deinit();

    // The Window vtable's install() does container linkup + OS callback wiring.
    try Window.vtable.install(&f.window.container.component);
    f.window.container.component.theme = &self.theme;
    f.window.background = self.theme.surface_window;

    const dtor = struct {
        fn destroy(p: *anyopaque, a: std.mem.Allocator) void {
            const frm: *Frame = @ptrCast(@alignCast(p));
            frm.deinit();
            a.destroy(frm);
        }
    }.destroy;

    try self.windows.append(self.allocator, .{
        .window  = &f.window,
        .outer   = @ptrCast(f),
        .destroy = dtor,
        // Model == OS at creation: seed synced from the window's initial geometry.
        .synced_pos  = f.window.getPos(),
        .synced_size = f.window.getSize(),
    });

    return f;
}

/// Headless variant of `frame`: the window opens no OS window and renders
/// offscreen (for the Robot / deterministic tests). Otherwise identical — it is
/// registered in the window list and laid out / painted via `tickOnce` /
/// `Robot.pump`.
pub fn frameHeadless(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    errdefer self.allocator.destroy(f);
    f.* = try Frame.initHeadless(self.allocator, @ptrCast(self), self.event_queue, title, w, h, &self.device, &self.context);
    errdefer f.deinit();

    try Window.vtable.install(&f.window.container.component);
    f.window.container.component.theme = &self.theme;
    f.window.background = self.theme.surface_window;

    const dtor = struct {
        fn destroy(p: *anyopaque, a: std.mem.Allocator) void {
            const frm: *Frame = @ptrCast(@alignCast(p));
            frm.deinit();
            a.destroy(frm);
        }
    }.destroy;

    try self.windows.append(self.allocator, .{
        .window  = &f.window,
        .outer   = @ptrCast(f),
        .destroy = dtor,
        .synced_pos  = f.window.getPos(),
        .synced_size = f.window.getSize(),
    });

    return f;
}

/// Create a Dialog owned by `owner` (typically `&frame.window`). The Dialog
/// is NOT shown yet — call `showModal` (blocking, returns a result) or `show`
/// (modeless). Unlike Frame, the returned Dialog is **caller-owned**: free it
/// with `dialog.deinit()` + `allocator.destroy(dialog)` when done (it may be
/// reused across multiple `showModal` calls before then). See `dialog.md`.
pub fn dialog(self: *Application, owner: *Window, title: []const u8, w: u32, h: u32) !*Dialog {
    const d = try self.allocator.create(Dialog);
    errdefer self.allocator.destroy(d);
    d.* = try Dialog.init(self, owner, title, w, h, &self.device, &self.context);
    errdefer d.deinit();

    // Wire DirtyNotify / FocusController properties (same as Frame).
    try Window.vtable.install(&d.window.container.component);
    d.window.container.component.theme = &self.theme;
    d.window.background = self.theme.surface_window;
    return d;
}

/// Inject this Application's theme into `c` and every descendant reachable
/// through the container tree (covers composites like ScrollPane whose
/// internal parts already exist at creation). Factory-side DI — see
/// `framework/doc/theme.md`.
fn applyTheme(self: *Application, c: *Component) void {
    c.theme = &self.theme;
    if (c.container) |cont| {
        for (cont.children.items) |elem| self.applyTheme(elem.component);
    }
}

pub fn label(self: *Application, text: []const u8) !*Label {
    const l = try Label.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
    );
    self.applyTheme(&l.component);
    return l;
}

pub fn container(self: *Application) !*Container {
    const c = try Container.create(self.allocator);
    self.applyTheme(&c.component);
    return c;
}

pub fn panel(self: *Application) !*Panel {
    const p = try Panel.create(self.allocator);
    self.applyTheme(&p.container.component);
    return p;
}

pub fn button(self: *Application, text: []const u8) !*Button {
    const b = try Button.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
    );
    self.applyTheme(&b.component);
    return b;
}

pub fn checkBox(self: *Application, text: []const u8) !*CheckBox {
    const cb = try CheckBox.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
    );
    self.applyTheme(&cb.component);
    return cb;
}

pub fn radioButton(self: *Application, text: []const u8) !*RadioButton {
    const rb = try RadioButton.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
    );
    self.applyTheme(&rb.component);
    return rb;
}

/// Mutually-exclusive grouping for radio buttons. The group is allocated
/// in Application's allocator; caller takes ownership and is responsible
/// for `group.deinit()` + `allocator.destroy(group)` at the end (it is
/// usually held alongside the radios in the same struct, with
/// matching lifetime).
pub fn buttonGroup(self: *Application) !*ButtonGroup {
    return try ButtonGroup.create(self.allocator);
}

/// Read-only drop-down. `items` is borrowed only for the duration of
/// the call — ComboBox copies every string internally.
pub fn comboBox(self: *Application, items: []const []const u8) !*ComboBox {
    const cb = try ComboBox.create(
        self.allocator,
        items,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
    );
    self.applyTheme(&cb.component);
    return cb;
}

/// Vertical single-selection list. `factory` produces the real cell instances
/// (materialized for the visible range and recycled); it is borrowed, so the
/// caller keeps it alive for the List's lifetime. The List creates and owns an
/// empty ListModel — add items to `list.model`.
pub fn list(self: *Application, factory: List.CellFactory) !*List {
    const l = try List.create(self.allocator, factory);
    self.applyTheme(&l.component);
    return l;
}

/// Like `list`, but the List borrows a caller-supplied (typically shared)
/// ListModel instead of creating its own.
pub fn listWithModel(self: *Application, model: *List.ListModel, factory: List.CellFactory) !*List {
    const l = try List.createWithModel(self.allocator, model, factory);
    self.applyTheme(&l.component);
    return l;
}

pub fn slider(
    self: *Application,
    orientation: Slider.Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*Slider {
    const s = try Slider.create(self.allocator, orientation, min, value, max);
    self.applyTheme(&s.component);
    return s;
}

pub fn scrollBar(
    self: *Application,
    orientation: ScrollBar.Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*ScrollBar {
    const sb = try ScrollBar.create(self.allocator, orientation, min, value, max);
    self.applyTheme(&sb.component);
    return sb;
}

/// Wrap `view` in a scroll pane. `view` ownership transfers to the pane.
pub fn scrollPane(self: *Application, view: *Component) !*ScrollPane {
    const sp = try ScrollPane.create(self.allocator, view);
    // Recursive: also reaches the internal viewport / bars (and re-stamps the
    // already-themed view harmlessly).
    self.applyTheme(&sp.container.component);
    return sp;
}

/// Get a built-in lucide icon as a GPU `awt.Image`, decoding + uploading on
/// first use. The returned Image is borrowed; do not call `deinit` on it.
/// Lifetime is tied to the Application.
pub fn icon(self: *Application, id: lucide.Icon) !awt.Image {
    const idx = @intFromEnum(id);
    if (self.icon_cache[idx]) |img| return img;
    const img = try awt.Image.fromMemory(self.allocator, self.device, id.bytes());
    self.icon_cache[idx] = img;
    return img;
}

pub fn filler(self: *Application) !*Panel {
    const p = try self.panel();
    p.container.component.setGrowX(1);
    p.container.component.setGrowY(1);
    return p;
}

/// Pre-configured Panel for use as a Frame toolbar. Light grey background,
/// horizontal BoxLayout, 32px fixed height. Add icon-only Buttons to it and
/// place it via `BorderLayout.add(window.container, .north, &tb.container.component)`.
pub fn toolBar(self: *Application) !*Panel {
    const p = try self.panel();
    p.setBackground(self.theme.surface_window);
    p.container.setLayout(@import("BoxLayout.zig").horizontal());
    p.container.component.min_size = .{ .width = 0, .height = 32 };
    p.container.component.max_size = .{ .width = std.math.inf(f32), .height = 32 };
    return p;
}

// ── menu family ──────────────────────────────────────────────────────────

fn menuFont(self: *Application) awt.Graphics.TextFont {
    return .{ .face = self.default_font, .pixel_size = 14 };
}

pub fn menu(self: *Application, text: []const u8) !*Menu {
    const m = try Menu.create(self.allocator, text, self.menuFont(), self.theme.text);
    self.applyTheme(&m.component);
    return m;
}

pub fn menuItem(self: *Application, text: []const u8) !*MenuItem {
    const mi = try MenuItem.create(self.allocator, text, self.menuFont(), self.theme.text);
    self.applyTheme(&mi.component);
    return mi;
}

pub fn checkBoxMenuItem(self: *Application, text: []const u8) !*CheckBoxMenuItem {
    const cmi = try CheckBoxMenuItem.create(self.allocator, text, self.menuFont(), self.theme.text);
    self.applyTheme(&cmi.component);
    return cmi;
}

pub fn menuBar(self: *Application) !*MenuBar {
    const bar = try MenuBar.create(self.allocator, self.menuFont(), self.theme.text);
    self.applyTheme(&bar.component);
    return bar;
}

pub fn popupMenu(self: *Application) !*PopupMenu {
    const pm = try PopupMenu.create(self.allocator);
    self.applyTheme(&pm.popup_root);
    return pm;
}

pub fn menuSeparator(self: *Application) !*MenuSeparator {
    const sep = try MenuSeparator.create(self.allocator);
    self.applyTheme(&sep.component);
    return sep;
}

/// Single-line text input. Uses default font (14px) and black text on a
/// white background. `initial_text` is copied into the widget's internal
/// UTF-8 buffer; pass `""` for an empty field.
pub fn textField(self: *Application, initial_text: []const u8) !*TextField {
    const tf = try TextField.create(
        self.allocator,
        self,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
        initial_text,
    );
    tf.background = self.theme.surface_input;
    self.applyTheme(&tf.component);
    return tf;
}

pub fn textArea(self: *Application, initial_text: []const u8) !*TextArea {
    const ta = try TextArea.create(
        self.allocator,
        self,
        .{ .face = self.default_font, .pixel_size = 14 },
        self.theme.text,
        initial_text,
    );
    ta.background = self.theme.surface_input;
    self.applyTheme(&ta.component);
    return ta;
}
