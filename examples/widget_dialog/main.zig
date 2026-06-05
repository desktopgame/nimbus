//! Dialog smoke test. A main Frame with two buttons:
//!   - "確認ダイアログ" opens a MODAL dialog (OK / Cancel); the main window is
//!     blocked until it closes, and the result is mirrored into a label.
//!   - "検索パネル" opens a MODELESS dialog that coexists with the main window.
//! The modal dialog is created once and reused across clicks.
//!
//! Usage:
//!     zig build run-widget_dialog
//!
//! Test recipe:
//!     - click "確認ダイアログ" → modal appears centered; main window ignores
//!       clicks until you press OK / Cancel / its X
//!     - OK / Cancel → label shows the result; reopen → dialog reappears (reuse)
//!     - close the modal via its X button → label shows "none"; reopen still works
//!     - click "検索パネル" → modeless dialog appears; you can still use the
//!       main window and the modal button while it is open

const std = @import("std");
const nimbus = @import("nimbus");
const Event = nimbus.ActionEvent;

const State = struct {
    app:      *nimbus.Application,
    modal:    *nimbus.Dialog,
    modeless: *nimbus.Dialog,
    label:    *nimbus.Label,
    buf:      [128]u8 = undefined,
};

fn onOpenModal(s: *State, _: *const Event) void {
    const result = s.modal.showModal(); // blocks until the dialog closes
    const name = switch (result) {
        .ok     => "ok",
        .cancel => "cancel",
        .none   => "none",
        else    => "?",
    };
    const text = std.fmt.bufPrint(&s.buf, "last result: {s}", .{name}) catch return;
    s.label.setText(text) catch {};
}

fn onModalOk(d: *nimbus.Dialog, _: *const Event) void {
    d.close(.ok);
}

fn onModalCancel(d: *nimbus.Dialog, _: *const Event) void {
    d.close(.cancel);
}

fn onOpenModeless(s: *State, _: *const Event) void {
    s.modeless.show() catch {};
}

fn onModelessClose(d: *nimbus.Dialog, _: *const Event) void {
    d.close(.none);
}

fn buildModal(app: *nimbus.Application, dialog: *nimbus.Dialog) !void {
    dialog.window.container.setLayout(nimbus.BoxLayout.vertical());

    const msg = try app.label("保存しますか?");
    msg.component.setAlignX(.center);

    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const ok = try app.button("OK");
    const cancel = try app.button("Cancel");
    try ok.getModel().addActionListener(nimbus.Dialog, onModalOk, dialog);
    try cancel.getModel().addActionListener(nimbus.Dialog, onModalCancel, dialog);
    try row.add(&ok.component);
    try row.add(&cancel.component);

    try dialog.window.add(&msg.component);
    try dialog.window.add(&row.component);
}

fn buildModeless(app: *nimbus.Application, dialog: *nimbus.Dialog) !void {
    dialog.window.container.setLayout(nimbus.BoxLayout.vertical());
    const msg = try app.label("モードレス: 親と並行して使える");
    const close = try app.button("閉じる");
    try close.getModel().addActionListener(nimbus.Dialog, onModelessClose, dialog);
    try dialog.window.add(&msg.component);
    try dialog.window.add(&close.component);
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_dialog", 480, 240);

    // Dialogs are caller-owned — create up front, reuse across clicks, free here.
    const modal = try app.dialog(&frame.window, "確認", 320, 140);
    defer modal.destroy();
    try buildModal(app, modal);

    const modeless = try app.dialog(&frame.window, "検索", 360, 120);
    defer modeless.destroy();
    try buildModeless(app, modeless);

    const label = try app.label("last result: (none yet)");

    var state = State{ .app = app, .modal = modal, .modeless = modeless, .label = label };

    const open_modal = try app.button("確認ダイアログ (モーダル)");
    const open_modeless = try app.button("検索パネル (モードレス)");
    try open_modal.getModel().addActionListener(State, onOpenModal, &state);
    try open_modeless.getModel().addActionListener(State, onOpenModeless, &state);

    const col = try app.container();
    col.setLayout(nimbus.BoxLayout.vertical());
    try col.add(&open_modal.component);
    try col.add(&open_modeless.component);
    try col.add(&label.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &col.component);

    std.debug.print("Click a button to open a modal / modeless dialog.\n", .{});
    try app.run();
}
