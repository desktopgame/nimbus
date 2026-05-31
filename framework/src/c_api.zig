// ── runtime support (hand-written) ──────────────────────────────────────
// This block is prepended verbatim to the generated `framework/src/c_api.zig`
// by tools/apigen. Glue that cannot be derived mechanically from the binding
// spec (last-error storage, backend passthrough, future ctors that need an
// allocator / io) lives here. See doc/c_api_codegen.md.
const std = @import("std");
const framework = @import("nimbus");
const awt = framework.awt;

// Thread-local last-error storage. A failing export stores the error here and
// signals failure to C via NULL / a non-zero int (see CLAUDE.md
// 「エラーのC_ABIでの表現」). Callers read it back with the two accessors below.
threadlocal var last_error: ?anyerror = null;
threadlocal var last_error_buf: [256]u8 = [_]u8{0} ** 256;

fn setLastError(err: anyerror) void {
    last_error = err;
    const name = @errorName(err);
    const n = @min(name.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..n], name[0..n]);
    last_error_buf[n] = 0;
}

// Maps a Zig error to the stable integer code returned by `nmLastErrorCode`.
// Hand-maintained: extend as the public surface grows.
fn errorToCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => 1,
        else => 99,
    };
}

export fn nmLastErrorCode() c_int {
    return errorToCode(last_error orelse return 0);
}

export fn nmLastErrorMessage() [*:0]const u8 {
    return @ptrCast(&last_error_buf);
}

// Backend identification string. A passthrough into the awt layer rather than
// a framework method, so it is written by hand rather than generated.
export fn nmGetBackendVersion() [*:0]const u8 {
    return @ptrCast(awt.c.nmAwtBackendVersion());
}

// ── generated exports (do not edit; regenerate with `zig build apigen`) ──

const nmColor = extern struct { r: f32, g: f32, b: f32, a: f32, };

export fn nmAppButton(self: *framework.Application, text: [*:0]const u8) ?*framework.Button {
    return self.button(std.mem.span(text)) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmButtonSetText(self: *framework.Button, text: [*:0]const u8) c_int {
    self.setText(std.mem.span(text)) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmContainerAdd(self: *framework.Container, child: *framework.Component) c_int {
    self.add(child) catch |e| {
        setLastError(e);
        return errorToCode(e);
    };
    return 0;
}

export fn nmButtonSetColor(self: *framework.Button, c: nmColor) void {
    self.setColor(.{ .r = c.r, .g = c.g, .b = c.b, .a = c.a });
}

export fn nmButtonGetColor(self: *framework.Button) nmColor {
    const _ret = self.getColor();
    return .{ .r = _ret.r, .g = _ret.g, .b = _ret.b, .a = _ret.a };
}

export fn nmAppFrame(self: *framework.Application, title: [*:0]const u8, w: u32, h: u32) ?*framework.Frame {
    return self.frame(std.mem.span(title), w, h) catch |e| {
        setLastError(e);
        return null;
    };
}

export fn nmComponentSetGrowX(self: *framework.Component, v: f32) void {
    self.setGrowX(v);
}

export fn nmComponentGetGrowX(self: *framework.Component) f32 {
    return self.getGrowX();
}

export fn nmButtonAsComponent(self: *framework.Button) *framework.Component {
    return &self.component;
}

export fn nmContainerAsComponent(self: *framework.Container) *framework.Component {
    return &self.component;
}

export fn nmComponentDestroy(self: *framework.Component) void {
    self.vtable.destroy(self, self.allocator);
}
