//! Input event types. See `awt/doc/event.md`.
//!
//! Events flow OS → awt-c callback → framework dispatcher (which constructs
//! Event values from raw callback args) → Component.vtable.processEvent.
//! awt itself does not dispatch — it only defines the types and helpers.

const c = @import("c");

const Event = @This();

pub const Point = struct { x: f32, y: f32 };

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl:  bool = false,
    alt:   bool = false,
    meta:  bool = false,
    _pad:  u4   = 0,

    pub fn fromCBits(bits: c_int) Modifiers {
        const b: u32 = @bitCast(bits);
        return .{
            .shift = (b & @as(u32, @intCast(c.nmModifierShift))) != 0,
            .ctrl  = (b & @as(u32, @intCast(c.nmModifierCtrl))) != 0,
            .alt   = (b & @as(u32, @intCast(c.nmModifierAlt))) != 0,
            .meta  = (b & @as(u32, @intCast(c.nmModifierMeta))) != 0,
        };
    }

    /// True if `self` contains every flag set in `m`.
    pub fn has(self: Modifiers, m: Modifiers) bool {
        const sb: u8 = @bitCast(self);
        const mb: u8 = @bitCast(m);
        return (sb & mb) == mb;
    }
};

pub const KeyAction = enum {
    press,
    release,
    repeat,

    pub fn fromC(a: c.nmKeyAction) KeyAction {
        return switch (a) {
            c.nmKeyActionPress   => .press,
            c.nmKeyActionRelease => .release,
            c.nmKeyActionRepeat  => .repeat,
            else                 => .release,
        };
    }
};

pub const MouseButton = enum {
    left,
    middle,
    right,

    pub fn fromC(b: c.nmMouseButton) MouseButton {
        return switch (b) {
            c.nmMouseButtonLeft   => .left,
            c.nmMouseButtonMiddle => .middle,
            c.nmMouseButtonRight  => .right,
            else                  => .left,
        };
    }
};

pub const MouseAction = enum { press, release, move, scroll };

/// Mirrors GLFW key codes. The full set is large; common keys are named.
/// Values match `GLFW_KEY_*` so `@intFromEnum` interoperates with the C layer.
pub const KeyCode = enum(c_int) {
    unknown = -1,

    space     = 32,
    apostrophe = 39,
    comma     = 44,
    minus     = 45,
    period    = 46,
    slash     = 47,

    digit_0 = 48, digit_1, digit_2, digit_3, digit_4,
    digit_5,      digit_6, digit_7, digit_8, digit_9,

    semicolon = 59,
    equal     = 61,

    a = 65, b, c, d, e, f, g, h, i, j, k, l, m,
    n,      o, p, q, r, s, t, u, v, w, x, y, z,

    left_bracket  = 91,
    backslash     = 92,
    right_bracket = 93,
    grave_accent  = 96,

    escape    = 256,
    enter     = 257,
    tab       = 258,
    backspace = 259,
    insert    = 260,
    delete    = 261,

    arrow_right = 262,
    arrow_left  = 263,
    arrow_down  = 264,
    arrow_up    = 265,

    page_up   = 266,
    page_down = 267,
    home      = 268,
    end       = 269,

    f1 = 290, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,

    shift_left   = 340,
    ctrl_left    = 341,
    alt_left     = 342,
    super_left   = 343,
    shift_right  = 344,
    ctrl_right   = 345,
    alt_right    = 346,
    super_right  = 347,

    _,

    pub fn fromCInt(v: c_int) KeyCode {
        return @enumFromInt(v);
    }
};

pub const KeyEvent = struct {
    code:      KeyCode,
    action:    KeyAction,
    modifiers: Modifiers,
};

pub const MouseEvent = struct {
    x:         f32,
    y:         f32,
    button:    ?MouseButton = null,
    action:    MouseAction,
    wheel:     f32 = 0,
    modifiers: Modifiers = .{},

    /// Return a copy of this event with `x` / `y` shifted by `-offset`.
    /// Used to convert window-local coordinates into component-local ones.
    pub fn translated(self: MouseEvent, offset: Point) MouseEvent {
        var out = self;
        out.x -= offset.x;
        out.y -= offset.y;
        return out;
    }
};

pub const Payload = union(enum) {
    key:   KeyEvent,
    mouse: MouseEvent,
};

consumed: bool = false,
payload:  Payload,

pub fn consume(self: *Event) void {
    self.consumed = true;
}

pub fn isConsumed(self: Event) bool {
    return self.consumed;
}

/// Translate the event by `offset` if it carries position data
/// (currently only mouse events). Key events pass through unchanged.
pub fn translated(self: Event, offset: Point) Event {
    return switch (self.payload) {
        .mouse => |m| .{
            .consumed = self.consumed,
            .payload  = .{ .mouse = m.translated(offset) },
        },
        .key => self,
    };
}

test "modifiers has" {
    const std = @import("std");
    const m: Modifiers = .{ .ctrl = true, .shift = true };
    try std.testing.expect(m.has(.{ .ctrl = true }));
    try std.testing.expect(m.has(.{ .shift = true }));
    try std.testing.expect(m.has(.{ .ctrl = true, .shift = true }));
    try std.testing.expect(!m.has(.{ .alt = true }));
    try std.testing.expect(!m.has(.{ .ctrl = true, .alt = true }));
}

test "mouse event translated" {
    const std = @import("std");
    const e = MouseEvent{ .x = 100, .y = 50, .action = .move };
    const t = e.translated(.{ .x = 20, .y = 10 });
    try std.testing.expectEqual(@as(f32, 80), t.x);
    try std.testing.expectEqual(@as(f32, 40), t.y);
}

test "event consume" {
    const std = @import("std");
    var e = Event{ .payload = .{ .mouse = .{ .x = 0, .y = 0, .action = .move } } };
    try std.testing.expect(!e.isConsumed());
    e.consume();
    try std.testing.expect(e.isConsumed());
}
