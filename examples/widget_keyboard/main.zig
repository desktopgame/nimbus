//! Keyboard navigation demo: focus traversal, mnemonics, accelerators and
//! the default button, all on one small form.
//!
//! Things to try (mouse optional — that's the point):
//!   - Tab / Shift+Tab     cycle focus in add order, wrapping at the ends.
//!                         The disabled button is skipped.
//!   - Space / Enter       activate the focused button / checkbox / radio.
//!   - Arrow keys          adjust the focused slider.
//!   - Alt+F               open the File menu (menu mnemonic) with its first
//!                         item highlighted. While it is open:
//!                           Up/Down  move the highlight (wraps; separators
//!                                    skipped; disabled items stop the
//!                                    highlight but Enter does nothing)
//!                           Enter    activate the highlighted item
//!                           Right    open the highlighted submenu
//!                           Left     close one submenu level
//!                           Esc      close ONE level per press
//!                           S / O / Q  menu-local mnemonics (no Alt needed)
//!   - Ctrl+S / Ctrl+O     fire Save / Open (accelerators; Cmd on macOS) —
//!                         with the menu CLOSED, and also while it is OPEN
//!                         (the popup closes first, then the action runs).
//!   - Alt+A / Alt+R       activate the Apply / Reset buttons from anywhere
//!                         (button mnemonics — note the underlined letters).
//!   - Enter               fires the OK default button when the focused
//!                         widget doesn't consume Enter itself (the
//!                         TextField does: it fires submit instead).
//!   - Tab on the dropdown While the ComboBox popup is open, Tab closes it
//!                         like an outside click and moves focus on.
//!
//! Usage:
//!     zig build run-widget_keyboard

const std = @import("std");
const nimbus = @import("nimbus");
const ChangeEvent = nimbus.ChangeEvent;
const ActionEvent = nimbus.ActionEvent;

const State = struct {
    status: *nimbus.Label,
    field: *nimbus.TextField,
    extras: *nimbus.CheckBox,
    rb_a: *nimbus.RadioButton,
    rb_b: *nimbus.RadioButton,
    slider: *nimbus.Slider,
    frame: *nimbus.Frame,
    buf: [256]u8 = undefined,
};

fn setStatus(s: *State, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&s.buf, fmt, args) catch return;
    s.status.setText(text) catch {};
}

// ── menu actions ─────────────────────────────────────────────────────────

fn onSave(s: *State, _: *const ActionEvent) void {
    setStatus(s, "Save — via click, Ctrl/Cmd+S (accelerator) or Alt+F,S (mnemonics)", .{});
}

fn onOpen(s: *State, _: *const ActionEvent) void {
    setStatus(s, "Open — via click, Ctrl/Cmd+O or Alt+F,O", .{});
}

fn onQuit(s: *State, _: *const ActionEvent) void {
    s.frame.window.dispose();
}

fn onRecentA(s: *State, _: *const ActionEvent) void {
    setStatus(s, "Recent > alpha.txt — submenu reached by → / Enter / hover", .{});
}

fn onRecentB(s: *State, _: *const ActionEvent) void {
    setStatus(s, "Recent > beta.txt — submenu reached by → / Enter / hover", .{});
}

// ── form actions ─────────────────────────────────────────────────────────

fn onApply(s: *State, _: *const ActionEvent) void {
    const which: []const u8 = if (s.rb_a.isSelected()) "A" else "B";
    setStatus(s, "Apply: name=\"{s}\" extras={} choice={s} value={d}", .{
        s.field.getText(),
        s.extras.isSelected(),
        which,
        s.slider.getModel().getValue(),
    });
}

fn onReset(s: *State, _: *const ActionEvent) void {
    s.field.setText("") catch {};
    s.extras.setSelected(false);
    s.rb_a.doClick();
    s.slider.getModel().setValue(50);
    setStatus(s, "Reset.", .{});
}

fn onOk(s: *State, _: *const ActionEvent) void {
    setStatus(s, "OK — the default button (Enter fires it when nothing else eats Enter)", .{});
}

fn onSubmit(s: *State, _: *const ActionEvent) void {
    setStatus(s, "TextField submit — the focused field consumed Enter before the default button", .{});
}

fn onSliderChange(s: *State, _: *const ChangeEvent) void {
    setStatus(s, "Slider: {d} (arrow keys work while focused)", .{s.slider.getModel().getValue()});
}

// ── ui assembly ──────────────────────────────────────────────────────────

fn addLabeledCell(app: *nimbus.Application, grid: *nimbus.Container, text: []const u8, child: *nimbus.Component) !void {
    const l = try app.label(text);
    l.component.setAlignY(.center);
    child.setAlignY(.center);
    try grid.add(&l.component);
    try grid.add(child);
}

pub fn main(init: std.process.Init) !void {
    // Built-in dark preset; also exercises initWithTheme on a real window.
    const app = try nimbus.Application.initWithTheme(init.gpa, init.io, nimbus.Theme.dark);
    defer app.deinit();

    const frame = try app.frame("widget keyboard", 640, 360);

    // ── menu bar: File(F) with Save / Open (accelerators) and Quit ──
    const bar = try app.menuBar();
    const file_menu = try app.menu("File");
    file_menu.setMnemonic('F'); // Alt+F opens it

    const save_item = try app.menuItem("Save");
    save_item.setAccelerator(nimbus.KeyStroke.cmd(.s)); // Ctrl+S / Cmd+S, menu closed too
    save_item.setMnemonic('S'); // plain S while the menu is open
    const open_item = try app.menuItem("Open");
    open_item.setAccelerator(nimbus.KeyStroke.cmd(.o));
    open_item.setMnemonic('O');
    const quit_item = try app.menuItem("Quit");
    quit_item.setMnemonic('Q');

    // Submenu to try Right / Left / staged Esc on.
    const recent_menu = try app.menu("Recent");
    const recent_a = try app.menuItem("alpha.txt");
    const recent_b = try app.menuItem("beta.txt");
    try recent_menu.add(&recent_a.component);
    try recent_menu.add(&recent_b.component);

    // A disabled item: the highlight stops on it, Enter does nothing.
    const broken_item = try app.menuItem("Unavailable");
    broken_item.getModel().setEnabled(false);

    try file_menu.add(&save_item.component);
    try file_menu.add(&open_item.component);
    try file_menu.add(&recent_menu.component);
    try file_menu.add(&broken_item.component);
    try file_menu.addSeparator();
    try file_menu.add(&quit_item.component);
    try bar.add(file_menu);
    try frame.setMenuBar(bar);

    // ── form (vertical box; add order = Tab order = visual order) ──
    const column = try app.container();
    column.setLayout(nimbus.BoxLayout.vertical());

    const field = try app.textField("");
    field.component.setGrowX(1);
    const extras = try app.checkBox("Enable extras (Space toggles)");
    const rb_a = try app.radioButton("Choice A");
    const rb_b = try app.radioButton("Choice B");
    const group = try app.buttonGroup();
    defer group.destroy();
    try group.add(rb_a.getModel());
    try group.add(rb_b.getModel());
    rb_a.setSelected(true);
    const combo = try app.comboBox(&.{ "Red", "Green", "Blue" });
    combo.component.setMinSize(.{ .width = 140, .height = combo.component.getMinSize().height });
    const slider = try app.slider(.horizontal, 0, 50, 100);
    slider.component.setGrowX(1);

    const form = try app.container();
    form.setLayout(try nimbus.GridLayout.create(app.allocator, 2, .{ .col_spacing = 8, .row_spacing = 8 }));
    try addLabeledCell(app, form, "Name:", &field.component);
    try addLabeledCell(app, form, "Color:", &combo.component);
    try addLabeledCell(app, form, "Volume:", &slider.component);

    try column.add(&form.component);
    try column.add(&extras.component);
    const radio_row = try app.container();
    radio_row.setLayout(nimbus.BoxLayout.horizontal());
    try radio_row.add(&rb_a.component);
    try radio_row.add(&rb_b.component);
    try column.add(&radio_row.component);

    // Button row: mnemonics, a disabled button (Tab skips it), the default button.
    const buttons = try app.container();
    buttons.setLayout(nimbus.BoxLayout.horizontal());
    const apply = try app.button("Apply");
    apply.setMnemonic('A'); // Alt+A from anywhere
    const reset = try app.button("Reset");
    reset.setMnemonic('R'); // Alt+R from anywhere
    const broken = try app.button("Disabled");
    broken.getModel().setEnabled(false); // Tab must skip this one
    const ok = try app.button("OK");
    try buttons.add(&apply.component);
    try buttons.add(&reset.component);
    try buttons.add(&broken.component);
    try buttons.add(&ok.component);
    try column.add(&buttons.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, &column.component);

    // Status line (south).
    const status = try app.label("Try the keyboard — see the source header for the full list.");
    try nimbus.BorderLayout.add(&frame.window.container, .south, &status.component);

    // Enter anywhere (that doesn't consume it) fires OK.
    try frame.window.setDefaultButton(ok);

    var state = State{
        .status = status,
        .field = field,
        .extras = extras,
        .rb_a = rb_a,
        .rb_b = rb_b,
        .slider = slider,
        .frame = frame,
    };
    try save_item.getModel().addActionListener(State, onSave, &state);
    try open_item.getModel().addActionListener(State, onOpen, &state);
    try quit_item.getModel().addActionListener(State, onQuit, &state);
    try recent_a.getModel().addActionListener(State, onRecentA, &state);
    try recent_b.getModel().addActionListener(State, onRecentB, &state);
    try apply.getModel().addActionListener(State, onApply, &state);
    try reset.getModel().addActionListener(State, onReset, &state);
    try ok.getModel().addActionListener(State, onOk, &state);
    try field.addSubmitListener(State, onSubmit, &state);
    try slider.getModel().addChangeListener(State, onSliderChange, &state);

    std.debug.print("Keyboard demo — Tab around, Alt+F for the menu, Ctrl/Cmd+S to save.\n", .{});
    try app.run();
}
