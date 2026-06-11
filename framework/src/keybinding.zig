//! Keystroke -> handler bindings. See `framework/doc/keybinding.md` (spec)
//! and `framework/doc/narrative/keybinding.md` (design rationale).
//!
//! A `KeyBindings` is a small mutable map a Component opts into via
//! `Component.bindKey`. Dispatch (`Window.dispatchInput`) walks the focus
//! owner's ancestor chain and asks each node's bindings whether it eats the
//! key. Bindings fire on `.press` and `.repeat` alike — the toolkit has no
//! repeat policy of its own (same stance as Swing / Win32); a handler that
//! must not auto-repeat guards itself.

const std = @import("std");
const builtin = @import("builtin");
const awt = @import("awt");

/// Platform-neutral modifier set for accelerators. `command` resolves at
/// match time: Ctrl on Windows / Linux, Cmd (the OS `meta`/super bit) on
/// macOS. A literal Ctrl bit (macOS emacs-style bindings) is intentionally
/// absent in v1 — that is widget-internal keymap territory.
pub const Mods = packed struct {
    command: bool = false,
    shift:   bool = false,
    alt:     bool = false,
};

/// A key chord: physical key + abstract modifiers.
pub const KeyStroke = struct {
    code: awt.Event.KeyCode,
    mods: Mods = .{},

    pub fn of(code: awt.Event.KeyCode) KeyStroke {
        return .{ .code = code };
    }

    pub fn cmd(code: awt.Event.KeyCode) KeyStroke {
        return .{ .code = code, .mods = .{ .command = true } };
    }

    pub fn cmdShift(code: awt.Event.KeyCode) KeyStroke {
        return .{ .code = code, .mods = .{ .command = true, .shift = true } };
    }

    pub fn alt(code: awt.Event.KeyCode) KeyStroke {
        return .{ .code = code, .mods = .{ .alt = true } };
    }

    pub fn eql(a: KeyStroke, b: KeyStroke) bool {
        return a.code == b.code and
            a.mods.command == b.mods.command and
            a.mods.shift == b.mods.shift and
            a.mods.alt == b.mods.alt;
    }

    /// True when the raw key event (`code` + OS modifier state) matches this
    /// stroke. Modifier comparison is exact (Ctrl+S does not match a plain S
    /// binding), with `command` resolved per platform.
    pub fn satisfies(self: KeyStroke, code: awt.Event.KeyCode, raw: awt.Event.Modifiers) bool {
        if (self.code != code) return false;
        var want = awt.Event.Modifiers{};
        if (self.mods.command) {
            if (builtin.os.tag == .macos) want.meta = true else want.ctrl = true;
        }
        want.shift = self.mods.shift;
        want.alt = self.mods.alt;
        return @as(u8, @bitCast(raw)) == @as(u8, @bitCast(want));
    }
};

/// Type-erased callback box. Same thunk strategy as `listener.zig`: the thunk
/// is comptime-built per (T, f), so the same (T, f, ctx) triple produces an
/// identical Handler — usable for compare-and-remove if ever needed.
pub const Handler = struct {
    ctx:    *anyopaque,
    invoke: *const fn (*anyopaque) void,

    pub fn typed(comptime T: type, comptime f: fn (*T) void, ctx: *T) Handler {
        const Thunk = struct {
            fn call(p: *anyopaque) void {
                f(@ptrCast(@alignCast(p)));
            }
        };
        return .{ .ctx = ctx, .invoke = Thunk.call };
    }
};

/// Letter / digit key -> lowercase ASCII for mnemonic matching, else null.
/// Shared by the Window's Alt+letter scan and the open-menu local matching.
pub fn letterOf(code: awt.Event.KeyCode) ?u8 {
    const v = @intFromEnum(code);
    if (v >= 'A' and v <= 'Z') return @intCast(v - 'A' + 'a');
    if (v >= '0' and v <= '9') return @intCast(v);
    return null;
}

/// Mutable stroke -> handler map (opt-in per Component). ArrayList rather
/// than a HashMap: a component carries a handful of bindings, linear scan
/// wins, and `KeyStroke` needs no hash implementation.
pub const KeyBindings = struct {
    pub const Entry = struct {
        stroke:  KeyStroke,
        handler: Handler,
    };

    entries:   std.ArrayList(Entry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KeyBindings {
        return .{ .entries = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *KeyBindings) void {
        self.entries.deinit(self.allocator);
    }

    /// Bind `stroke` to `handler`. Rebinding an already-bound stroke replaces
    /// the previous handler (runtime rebind is a first-class operation).
    pub fn bind(self: *KeyBindings, stroke: KeyStroke, handler: Handler) !void {
        for (self.entries.items) |*e| {
            if (KeyStroke.eql(e.stroke, stroke)) {
                e.handler = handler;
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .stroke = stroke, .handler = handler });
    }

    /// Remove the binding for `stroke`. No-op when absent.
    pub fn unbind(self: *KeyBindings, stroke: KeyStroke) void {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            if (KeyStroke.eql(self.entries.items[i].stroke, stroke)) {
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    /// First entry whose stroke matches the raw key event, or null.
    pub fn lookup(self: *const KeyBindings, code: awt.Event.KeyCode, raw: awt.Event.Modifiers) ?Handler {
        for (self.entries.items) |e| {
            if (e.stroke.satisfies(code, raw)) return e.handler;
        }
        return null;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const native_command: awt.Event.Modifiers =
    if (builtin.os.tag == .macos) .{ .meta = true } else .{ .ctrl = true };

test "satisfies: command resolves per platform, match is exact" {
    const s = KeyStroke.cmd(.s);
    try std.testing.expect(s.satisfies(.s, native_command));
    // Wrong key.
    try std.testing.expect(!s.satisfies(.a, native_command));
    // Missing modifier.
    try std.testing.expect(!s.satisfies(.s, .{}));
    // Extra modifier (exact match: cmd+shift+S must not trigger cmd+S).
    var extra = native_command;
    extra.shift = true;
    try std.testing.expect(!s.satisfies(.s, extra));
    // Plain stroke must not match a modified event.
    const plain = KeyStroke.of(.s);
    try std.testing.expect(plain.satisfies(.s, .{}));
    try std.testing.expect(!plain.satisfies(.s, native_command));
}

test "bind / lookup / unbind / rebind" {
    var kb = KeyBindings.init(std.testing.allocator);
    defer kb.deinit();

    const Ctx = struct {
        hits: u32 = 0,
        fn fire(self: *@This()) void {
            self.hits += 1;
        }
    };
    var a = Ctx{};
    var b = Ctx{};

    try kb.bind(KeyStroke.cmd(.s), Handler.typed(Ctx, Ctx.fire, &a));
    const h = kb.lookup(.s, native_command) orelse return error.TestUnexpectedResult;
    h.invoke(h.ctx);
    try std.testing.expectEqual(@as(u32, 1), a.hits);
    try std.testing.expect(kb.lookup(.s, .{}) == null);

    // Rebind replaces in place (no duplicate entry).
    try kb.bind(KeyStroke.cmd(.s), Handler.typed(Ctx, Ctx.fire, &b));
    try std.testing.expectEqual(@as(usize, 1), kb.entries.items.len);
    const h2 = kb.lookup(.s, native_command) orelse return error.TestUnexpectedResult;
    h2.invoke(h2.ctx);
    try std.testing.expectEqual(@as(u32, 1), a.hits);
    try std.testing.expectEqual(@as(u32, 1), b.hits);

    kb.unbind(KeyStroke.cmd(.s));
    try std.testing.expect(kb.lookup(.s, native_command) == null);
}
