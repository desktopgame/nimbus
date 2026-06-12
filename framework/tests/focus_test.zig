//! Keyboard / focus integration tests (keybinding.md): Tab traversal,
//! Space/Enter activation, mnemonics, accelerators, default button, and the
//! deleted fan-out. Driven headlessly via Application.initHeadless + Robot —
//! synthetic input takes the exact OS-input path (postInput -> EventQueue ->
//! Window.dispatchInput). GPU device required (skips when unavailable).

const std = @import("std");
const builtin = @import("builtin");
const nimbus = @import("nimbus");
const awt = nimbus.awt;

/// The raw modifier state that satisfies a `command` stroke on this OS.
const command_mods: awt.Event.Modifiers =
    if (builtin.os.tag == .macos) .{ .meta = true } else .{ .ctrl = true };

const Counter = struct {
    count: u32 = 0,
    fn onAction(self: *@This(), _: *const nimbus.ActionEvent) void {
        self.count += 1;
    }
};

/// Test-quiet log: drop debug/info chatter, keep warn/error visible. Any
/// stderr from a passing test binary makes `zig build` print it under a
/// noisy "failed command:" banner, so the happy path must stay silent.
fn quietLog(level: awt.LogLevel, category: [*c]const u8, message: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level < awt.c.nmLogLevelWarn) return;
    const tag: []const u8 = if (level == awt.c.nmLogLevelWarn) "WARN" else "ERROR";
    const cat: [*:0]const u8 = category;
    const msg: [*:0]const u8 = message;
    std.debug.print("[{s}] [{s}] {s}\n", .{ tag, std.mem.span(cat), std.mem.span(msg) });
}

fn newApp() !*nimbus.Application {
    awt.setLogCallback(quietLog, null);
    return nimbus.Application.initHeadless(std.testing.allocator, std.testing.io) catch
        return error.SkipZigTest;
}

test "tab traversal: initial focus, order, wrap, shift+tab" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const b1 = try app.button("One");
    const b2 = try app.button("Two");
    const b3 = try app.button("Three");
    try row.add(&b1.component);
    try row.add(&b2.component);
    try row.add(&b3.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump(); // first frame: layout + initial focus

    // Initial focus lands on the first focusable in traversal order.
    try std.testing.expect(frame.window.focus_owner == &b1.component);

    robot.keyDown(.tab, .{});
    robot.pump();
    try std.testing.expect(frame.window.focus_owner == &b2.component);

    robot.keyDown(.tab, .{});
    robot.pump();
    try std.testing.expect(frame.window.focus_owner == &b3.component);

    // Wrap at the end.
    robot.keyDown(.tab, .{});
    robot.pump();
    try std.testing.expect(frame.window.focus_owner == &b1.component);

    // Shift+Tab is the exact reverse (wraps backwards).
    robot.keyDown(.tab, .{ .shift = true });
    robot.pump();
    try std.testing.expect(frame.window.focus_owner == &b3.component);
}

test "tab traversal skips disabled widgets (FocusQuery)" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const b1 = try app.button("One");
    const b2 = try app.button("Two");
    const b3 = try app.button("Three");
    b2.getModel().setEnabled(false);
    try row.add(&b1.component);
    try row.add(&b2.component);
    try row.add(&b3.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();
    try std.testing.expect(frame.window.focus_owner == &b1.component);

    robot.keyDown(.tab, .{});
    robot.pump();
    try std.testing.expect(frame.window.focus_owner == &b3.component); // b2 skipped
}

test "space / enter activate the focused button; doClick guards disabled" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const b1 = try app.button("Go");
    try nimbus.BorderLayout.add(&frame.window.container, .center, &b1.component);

    var counter = Counter{};
    try b1.getModel().addActionListener(Counter, Counter.onAction, &counter);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump(); // initial focus -> b1

    robot.keyDown(.space, .{});
    robot.pump();
    try std.testing.expectEqual(@as(u32, 1), counter.count);

    robot.keyDown(.enter, .{});
    robot.pump();
    try std.testing.expectEqual(@as(u32, 2), counter.count);

    // Disabled: every activation entry point is guarded in doClick.
    b1.getModel().setEnabled(false);
    b1.doClick();
    try std.testing.expectEqual(@as(u32, 2), counter.count);
}

test "no focus owner: keys do not reach widgets (fan-out is gone)" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const cb = try app.checkBox("Opt");
    try nimbus.BorderLayout.add(&frame.window.container, .center, &cb.component);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();
    frame.window.requestFocusFor(null); // clear the initial focus

    robot.keyDown(.space, .{});
    robot.pump();
    // Under the old fan-out, the unfocused checkbox would have toggled.
    try std.testing.expect(!cb.isSelected());
}

test "mnemonic: Alt+letter activates a button window-wide" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const other = try app.textField("");
    other.component.setMinSize(.{ .width = 100, .height = 24 });
    const save = try app.button("Save");
    save.setMnemonic('S');
    try row.add(&other.component);
    try row.add(&save.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    var counter = Counter{};
    try save.getModel().addActionListener(Counter, Counter.onAction, &counter);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();
    // Focus sits on the text field; the mnemonic must still fire (window-wide).
    frame.window.requestFocusFor(&other.component);

    robot.keyDown(.s, .{ .alt = true });
    robot.pump();
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}

test "accelerator: command stroke fires a menu item while the menu is closed" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const bar = try app.menuBar();
    const file_menu = try app.menu("File");
    const save_item = try app.menuItem("Save");
    save_item.setAccelerator(nimbus.KeyStroke.cmd(.s));
    try file_menu.add(&save_item.component);
    try bar.add(file_menu);
    try frame.setMenuBar(bar);

    var counter = Counter{};
    try save_item.getModel().addActionListener(Counter, Counter.onAction, &counter);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    robot.keyDown(.s, command_mods);
    robot.pump();
    try std.testing.expectEqual(@as(u32, 1), counter.count);

    // Disabled item must not fire.
    save_item.getModel().setEnabled(false);
    robot.keyDown(.s, command_mods);
    robot.pump();
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}

test "default button: Enter fires it when nothing focused consumes Enter" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const field = try app.textField("");
    field.component.setMinSize(.{ .width = 100, .height = 24 });
    const ok = try app.button("OK");
    try row.add(&field.component);
    try row.add(&ok.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);
    try frame.window.setDefaultButton(ok);

    var counter = Counter{};
    try ok.getModel().addActionListener(Counter, Counter.onAction, &counter);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();
    frame.window.requestFocusFor(null);

    robot.keyDown(.enter, .{});
    robot.pump();
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}

test "overlay + Tab: dropdown dismisses (cancel) and focus moves on" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const row = try app.container();
    row.setLayout(nimbus.BoxLayout.horizontal());
    const combo = try app.comboBox(&.{ "a", "b", "c" });
    const btn = try app.button("Next");
    try row.add(&combo.component);
    try row.add(&btn.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &row.component);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump(); // initial focus -> combo (first focusable)
    try std.testing.expect(frame.window.focus_owner == &combo.component);

    // Open the dropdown from the keyboard, then Tab away.
    robot.keyDown(.space, .{});
    robot.pump();
    try std.testing.expect(combo.open);

    robot.keyDown(.tab, .{});
    robot.pump();
    try std.testing.expect(!combo.open); // dismissed like an outside click
    try std.testing.expect(frame.window.focus_owner == &btn.component);
    try std.testing.expectEqual(@as(usize, 0), combo.getSelectedIndex()); // cancel, not commit
}

test "accelerator while menu open: closes the menu, then fires (#6a)" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const bar = try app.menuBar();
    const file_menu = try app.menu("File");
    file_menu.setMnemonic('F');
    const save_item = try app.menuItem("Save");
    save_item.setAccelerator(nimbus.KeyStroke.cmd(.s));
    try file_menu.add(&save_item.component);
    try bar.add(file_menu);
    try frame.setMenuBar(bar);

    var counter = Counter{};
    try save_item.getModel().addActionListener(Counter, Counter.onAction, &counter);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    robot.keyDown(.f, .{ .alt = true }); // open via mnemonic
    robot.pump();
    try std.testing.expect(file_menu.open);

    var chord = command_mods;
    robot.keyDown(.s, chord);
    robot.pump();
    try std.testing.expect(!file_menu.open); // closed first...
    try std.testing.expectEqual(@as(u32, 1), counter.count); // ...then fired

    // Non-matching chord is still swallowed (menu untouched, nothing fires).
    robot.keyDown(.f, .{ .alt = true });
    robot.pump();
    try std.testing.expect(file_menu.open);
    chord.shift = true;
    robot.keyDown(.x, chord);
    robot.pump();
    try std.testing.expect(file_menu.open);
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}

test "menu keyboard navigation: arrows, wrap, disabled stop, Enter (#6b)" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const bar = try app.menuBar();
    const file_menu = try app.menu("File");
    file_menu.setMnemonic('F');
    const item_a = try app.menuItem("Alpha");
    const item_b = try app.menuItem("Beta");
    item_b.getModel().setEnabled(false);
    const item_c = try app.menuItem("Gamma");
    try file_menu.add(&item_a.component);
    try file_menu.add(&item_b.component);
    try file_menu.addSeparator();
    try file_menu.add(&item_c.component);
    try bar.add(file_menu);
    try frame.setMenuBar(bar);

    var count_a = Counter{};
    var count_b = Counter{};
    var count_c = Counter{};
    try item_a.getModel().addActionListener(Counter, Counter.onAction, &count_a);
    try item_b.getModel().addActionListener(Counter, Counter.onAction, &count_b);
    try item_c.getModel().addActionListener(Counter, Counter.onAction, &count_c);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    // Keyboard-opened menu highlights the first row.
    robot.keyDown(.f, .{ .alt = true });
    robot.pump();
    try std.testing.expect(file_menu.open);
    try std.testing.expect(item_a.getModel().rollover);

    // Down: highlight stops on the disabled row...
    robot.keyDown(.arrow_down, .{});
    robot.pump();
    try std.testing.expect(item_b.getModel().rollover);

    // ...where Enter does nothing and the menu stays open.
    robot.keyDown(.enter, .{});
    robot.pump();
    try std.testing.expectEqual(@as(u32, 0), count_b.count);
    try std.testing.expect(file_menu.open);

    // Down skips the separator onto Gamma; another Down wraps to Alpha.
    robot.keyDown(.arrow_down, .{});
    robot.pump();
    try std.testing.expect(item_c.getModel().rollover);
    robot.keyDown(.arrow_down, .{});
    robot.pump();
    try std.testing.expect(item_a.getModel().rollover);

    // Up wraps backwards (Alpha -> Gamma, skipping the separator).
    robot.keyDown(.arrow_up, .{});
    robot.pump();
    try std.testing.expect(item_c.getModel().rollover);

    // Enter fires the highlighted enabled row and the menu auto-dismisses.
    robot.keyDown(.enter, .{});
    robot.pump();
    try std.testing.expectEqual(@as(u32, 1), count_c.count);
    try std.testing.expect(!file_menu.open);
    try std.testing.expectEqual(@as(u32, 0), count_a.count);
}

test "submenu: right opens highlighted, left closes one level, ESC is staged (#6b)" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 400, 200);
    const bar = try app.menuBar();
    const file_menu = try app.menu("File");
    file_menu.setMnemonic('F');
    const sub = try app.menu("More");
    const sub_item = try app.menuItem("Deep");
    try sub.add(&sub_item.component);
    try file_menu.add(&sub.component);
    try bar.add(file_menu);
    try frame.setMenuBar(bar);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump();

    robot.keyDown(.f, .{ .alt = true });
    robot.pump();
    try std.testing.expect(file_menu.open);
    try std.testing.expect(sub.getModel().rollover); // first (only) row highlighted

    // Right opens the submenu with its first row highlighted.
    robot.keyDown(.arrow_right, .{});
    robot.pump();
    try std.testing.expect(sub.open);
    try std.testing.expect(sub_item.getModel().rollover);

    // Left closes only the submenu; the parent popup remains.
    robot.keyDown(.arrow_left, .{});
    robot.pump();
    try std.testing.expect(!sub.open);
    try std.testing.expect(file_menu.open);

    // Re-open, then ESC twice: staged close, one level per press.
    robot.keyDown(.arrow_right, .{});
    robot.pump();
    try std.testing.expect(sub.open);
    robot.keyDown(.escape, .{});
    robot.pump();
    try std.testing.expect(!sub.open);
    try std.testing.expect(file_menu.open);
    robot.keyDown(.escape, .{});
    robot.pump();
    try std.testing.expect(!file_menu.open);
}

test "tab moves focus into view inside a ScrollPane (scrollIntoView)" {
    const app = try newApp();
    defer app.deinit();
    const frame = try app.frameHeadless("t", 300, 120);
    const column = try app.container();
    column.setLayout(nimbus.BoxLayout.vertical());
    var buttons: [8]*nimbus.Button = undefined;
    for (&buttons, 0..) |*slot, i| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "B{d}", .{i}) catch unreachable;
        slot.* = try app.button(name);
        try column.add(&slot.*.component);
    }
    const sp = try app.scrollPane(&column.component);
    try nimbus.BorderLayout.add(&frame.window.container, .center, &sp.container.component);

    var robot = nimbus.Robot.init(app, &frame.window);
    robot.pump(); // initial focus -> buttons[0], scroll at 0
    try std.testing.expectEqual(@as(f32, 0), sp.getScrollY());

    // Tab to the last button; it lies below the 120px viewport, so the
    // traversal's scrollIntoView must scroll down.
    for (0..buttons.len - 1) |_| {
        robot.keyDown(.tab, .{});
        robot.pump();
    }
    try std.testing.expect(frame.window.focus_owner == &buttons[buttons.len - 1].component);
    try std.testing.expect(sp.getScrollY() > 0);
}
