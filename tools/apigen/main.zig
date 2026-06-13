//! nimbus C ABI generator.
//!
//! Reads the binding spec `tools/apigen/nimbus.api` and emits three files:
//!   - include/nimbus.h          (typedefs + prototypes)
//!   - framework/src/c_api.zig   (`export fn` shims)
//!   - bindings/nimbus_api.json  (machine-readable IR for Python / JS binding
//!                                generators: class<->method mapping,
//!                                inheritance, callbacks)
//! The .h / .zig outputs are a hand-written preamble (preamble.h / preamble.zig)
//! followed by mechanically generated declarations. Run via `zig build apigen`.
//!
//! The grammar this parses is documented in nimbus.api and doc/internal/c_api_codegen.md.
//! This is an internal build tool; paths are fixed relative to the repo root
//! (the build step runs it with the repo root as the working directory).

const std = @import("std");

const SPEC_PATH = "tools/apigen/nimbus.api";
const PREAMBLE_H = "tools/apigen/preamble.h";
/// Hand-written C prototypes emitted AFTER the generated typedefs (so they may
/// reference opaque types like nmApplication). Keeps hand-written / generated
/// cleanly separated while producing a correctly-ordered merged header.
const PREAMBLE_PROTOS_H = "tools/apigen/preamble_protos.h";
const PREAMBLE_ZIG = "tools/apigen/preamble.zig";
/// Hand-written IR entries (for the hand-written preamble functions, which never
/// reach the parsed model). A small sectioned text format: `@<section>` headers
/// (functions / types / structs / …) followed by raw JSON array elements, merged
/// into the matching array of the generated IR. The .json output's third leg of
/// the preamble (mirrors preamble_protos.h / preamble.zig for .h / .zig).
const PREAMBLE_IR = "tools/apigen/preamble_ir.txt";
const OUT_H = "include/nimbus.h";
const OUT_ZIG = "framework/src/c_api.zig";
const OUT_JSON_DIR = "bindings";
const OUT_JSON = "bindings/nimbus_api.json";

// ── parsed model ────────────────────────────────────────────────────────────

/// How the receiver (first parameter) is passed.
const Recv = enum { none, ptr, value };

/// Scalar field / value type. C and Zig spellings; IR uses the Zig spelling.
const Scalar = enum {
    f32,
    f64,
    i32,
    u32,
    usize,
    bool,

    fn parse(s: []const u8) ?Scalar {
        inline for (@typeInfo(Scalar).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
    fn cName(self: Scalar) []const u8 {
        return switch (self) {
            .f32 => "float",
            .f64 => "double",
            .i32 => "int32_t",
            .u32 => "uint32_t",
            .usize => "size_t",
            .bool => "bool",
        };
    }
    fn zigName(self: Scalar) []const u8 {
        return @tagName(self);
    }
};

/// Argument wire type. Extended per doc/internal/c_api_codegen.md「未対応」.
const ArgType = union(enum) {
    str,
    /// `*T` handle argument; payload is the Zig type name (e.g. "Component").
    handle: []const u8,
    /// By-value struct argument; payload is the declared ABI struct name (e.g. "nmColor").
    struct_ref: []const u8,
    /// Primitive scalar argument (passed straight through).
    scalar: Scalar,
    /// Enum argument; payload is the declared ABI enum name (e.g. "nmAlignment").
    enum_ref: []const u8,
    /// Event-handler callback; payload is the declared ABI callback name (e.g. "nmChangeListener").
    callback: []const u8,
    /// `strs` — array of UTF-8 strings (`[]const []const u8`). Expands to a C
    /// `const char* const*` + `size_t` count; the shim builds a temp slice.
    str_array,
    /// `?<struct>` — optional value struct argument (nullable `const <CName>*`).
    struct_opt: []const u8,
    /// `?*T` — optional handle argument (nullable pointer; null = none). Payload = Zig type name.
    handle_opt: []const u8,
    /// `?str` — optional UTF-8 string argument (nullable `const char*`; null = none).
    str_opt,
};

/// Function return shape.
const Ret = union(enum) {
    void,
    /// Owned/borrowed handle pointer; payload is the Zig type name (e.g. "Button").
    ptr: []const u8,
    /// `?*T` optional handle pointer return (nullable; null = none). Payload = Zig type name.
    ptr_opt: []const u8,
    /// By-value struct return; payload is the declared ABI struct name.
    struct_ref: []const u8,
    /// Primitive scalar return (passed straight through).
    scalar: Scalar,
    /// Enum return; payload is the declared ABI enum name.
    enum_ref: []const u8,
    /// Borrowed UTF-8 slice return (`[]const u8`) -> `nmStr` (ptr + len).
    str,
    /// Optional borrowed slice (`?[]const u8`) -> `nmStr` (ptr = null when none).
    str_opt,
    /// Optional value-struct return (`?<Struct>`). Emitted as `bool fn(..., <CName>* out)`:
    /// returns true + writes `out` when present, false when none. Payload = struct name.
    struct_opt: []const u8,
};

const Field = struct {
    name: []const u8,
    scalar: Scalar,
};

/// `struct <CName> { <field>:<scalar> ... }` — a by-value record whose layout
/// is exposed across the ABI (generated as an `extern struct`).
const Struct = struct {
    cname: []const u8,
    fields: std.ArrayList(Field),
};

/// `enum <CName> = <NativeZigPath> { <member> ... }` — an enum exposed across the
/// ABI as an integer. `native` (e.g. "Component.Alignment", framework-relative)
/// is used to emit a comptime check that the C values match the Zig enum, so a
/// reorder/rename in the native enum is caught at compile time (not silently).
const EnumDecl = struct {
    cname: []const u8,
    native: []const u8,
    members: std.ArrayList([]const u8),
};

/// Failure-signalling convention.
const Fail = enum { none, null, err };

/// Ownership annotation (`@owned` / `@borrowed` / `@transfer`). Drives the
/// binding's free / no-free decision. `default` = unspecified.
const Ownership = enum { default, owned, borrowed, transfer };

const Arg = struct {
    name: []const u8,
    ty: ArgType,
    ownership: Ownership = .default,
};

const Func = struct {
    cname: []const u8,
    ztype: []const u8,
    method: []const u8,
    recv: Recv,
    args: std.ArrayList(Arg),
    ret: Ret,
    fail: Fail,
    ret_ownership: Ownership = .default,
};

/// `cast <CName> = <ZigType>.<field> -> <Target>` — upcast helper.
const Cast = struct {
    cname: []const u8,
    ztype: []const u8,
    field: []const u8,
    target: []const u8,
};

/// `destroy <CName> = <ZigType>` — generic vtable-dispatch destructor.
const Destructor = struct {
    cname: []const u8,
    ztype: []const u8,
};

/// `callback <CName> = <NativeEventType>` — an event-handler callback.
/// The C side passes a `{ fn, userdata }` box (approach C); a generated
/// Zig-callconv trampoline bridges to the typed listener registration.
/// `native_event` (framework-relative, e.g. "ChangeEvent" / "ActionEvent") is
/// the event type the native listener delivers; it crosses to C as an opaque
/// `const void*` (read via hand-written accessors in the preamble).
const CallbackDecl = struct {
    cname: []const u8,
    native_event: []const u8,
};

const Opaque = struct {
    name: []const u8,
    /// Single-inheritance parent (the `: <Parent>` clause), or null.
    parent: ?[]const u8,
};

const Model = struct {
    opaques: std.ArrayList(Opaque) = .empty,
    structs: std.ArrayList(Struct) = .empty,
    enums: std.ArrayList(EnumDecl) = .empty,
    callbacks: std.ArrayList(CallbackDecl) = .empty,
    funcs: std.ArrayList(Func) = .empty,
    casts: std.ArrayList(Cast) = .empty,
    destructors: std.ArrayList(Destructor) = .empty,

    fn findCallback(self: *const Model, name: []const u8) bool {
        for (self.callbacks.items) |c| {
            if (std.mem.eql(u8, c.cname, name)) return true;
        }
        return false;
    }
    fn findStruct(self: *const Model, name: []const u8) ?*const Struct {
        for (self.structs.items) |*s| {
            if (std.mem.eql(u8, s.cname, name)) return s;
        }
        return null;
    }
    fn findEnum(self: *const Model, name: []const u8) bool {
        for (self.enums.items) |e| {
            if (std.mem.eql(u8, e.cname, name)) return true;
        }
        return false;
    }
};

// All string slices in the model point into the spec buffer, which is kept
// alive for the whole run, so nothing here owns its strings.

/// Free every list a Model owns. Used by `main`'s defer and by the tests.
fn deinitModel(gpa: std.mem.Allocator, model: *Model) void {
    for (model.funcs.items) |*f| f.args.deinit(gpa);
    model.funcs.deinit(gpa);
    for (model.structs.items) |*s| s.fields.deinit(gpa);
    model.structs.deinit(gpa);
    for (model.enums.items) |*e| e.members.deinit(gpa);
    model.enums.deinit(gpa);
    model.callbacks.deinit(gpa);
    model.opaques.deinit(gpa);
    model.casts.deinit(gpa);
    model.destructors.deinit(gpa);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const spec = try cwd.readFileAlloc(io, SPEC_PATH, gpa, .unlimited);
    defer gpa.free(spec);
    const pre_h = try cwd.readFileAlloc(io, PREAMBLE_H, gpa, .unlimited);
    defer gpa.free(pre_h);
    const pre_protos = try cwd.readFileAlloc(io, PREAMBLE_PROTOS_H, gpa, .unlimited);
    defer gpa.free(pre_protos);
    const pre_zig = try cwd.readFileAlloc(io, PREAMBLE_ZIG, gpa, .unlimited);
    defer gpa.free(pre_zig);
    const pre_ir = try cwd.readFileAlloc(io, PREAMBLE_IR, gpa, .unlimited);
    defer gpa.free(pre_ir);

    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa, spec, &model);

    // Hand-written IR fragments (sectioned text → merged into the JSON arrays).
    var frag: std.ArrayList(IrSection) = .empty;
    defer frag.deinit(gpa);
    parseFragment(pre_ir, &frag, gpa) catch |e| {
        std.debug.print("apigen: failed to parse {s}\n", .{PREAMBLE_IR});
        return e;
    };

    var h: std.ArrayList(u8) = .empty;
    defer h.deinit(gpa);
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);

    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);

    try emitHeader(gpa, &h, pre_h, pre_protos, &model);
    try emitZig(gpa, &z, pre_zig, &model);
    try emitJson(gpa, &j, &model, frag.items);

    try cwd.writeFile(io, .{ .sub_path = OUT_H, .data = h.items });
    try cwd.writeFile(io, .{ .sub_path = OUT_ZIG, .data = z.items });
    try cwd.createDirPath(io, OUT_JSON_DIR);
    try cwd.writeFile(io, .{ .sub_path = OUT_JSON, .data = j.items });

    std.debug.print(
        "apigen: {d} opaque type(s), {d} function(s) -> {s}, {s}, {s}\n",
        .{ model.opaques.items.len, model.funcs.items.len, OUT_H, OUT_ZIG, OUT_JSON },
    );
}

// ── parsing ──────────────────────────────────────────────────────────────────

fn parse(gpa: std.mem.Allocator, spec: []const u8, model: *Model) !void {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(gpa);

    var lines = std.mem.splitScalar(u8, spec, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = stripComment(raw);
        try tokenize(gpa, line, &tokens);
        if (tokens.items.len == 0) continue;

        const kw = tokens.items[0];
        if (std.mem.eql(u8, kw, "opaque")) {
            // opaque <Name>               (len 2)
            // opaque <Name> : <Parent>    (len 4)
            const items = tokens.items;
            if (items.len == 2) {
                try model.opaques.append(gpa, .{ .name = items[1], .parent = null });
            } else if (items.len == 4 and std.mem.eql(u8, items[2], ":")) {
                try model.opaques.append(gpa, .{ .name = items[1], .parent = items[3] });
            } else {
                return fail(line_no, "opaque expects '<Name>' or '<Name> : <Parent>'");
            }
        } else if (std.mem.eql(u8, kw, "struct")) {
            try parseStruct(gpa, line_no, tokens.items, model);
        } else if (std.mem.eql(u8, kw, "enum")) {
            try parseEnum(gpa, line_no, tokens.items, model);
        } else if (std.mem.eql(u8, kw, "callback")) {
            // callback <CName> = <NativeEventType>
            const items = tokens.items;
            if (items.len != 4 or !std.mem.eql(u8, items[2], "="))
                return fail(line_no, "callback expects '<CName> = <NativeEventType>'");
            try model.callbacks.append(gpa, .{ .cname = items[1], .native_event = items[3] });
        } else if (std.mem.eql(u8, kw, "fn")) {
            try parseFn(gpa, line_no, tokens.items, model);
        } else if (std.mem.eql(u8, kw, "cast")) {
            // cast <CName> = <ZigType>.<field> -> <Target>
            const items = tokens.items;
            if (items.len != 6 or !std.mem.eql(u8, items[2], "=") or !std.mem.eql(u8, items[4], "->"))
                return fail(line_no, "cast expects '<CName> = <ZigType>.<field> -> <Target>'");
            const dot = std.mem.indexOfScalar(u8, items[3], '.') orelse
                return fail(line_no, "cast expects '<ZigType>.<field>'");
            try model.casts.append(gpa, .{
                .cname = items[1],
                .ztype = items[3][0..dot],
                .field = items[3][dot + 1 ..],
                .target = items[5],
            });
        } else if (std.mem.eql(u8, kw, "destroy")) {
            // destroy <CName> = <ZigType>
            const items = tokens.items;
            if (items.len != 4 or !std.mem.eql(u8, items[2], "="))
                return fail(line_no, "destroy expects '<CName> = <ZigType>'");
            try model.destructors.append(gpa, .{ .cname = items[1], .ztype = items[3] });
        } else {
            return fail(line_no, "unknown statement keyword");
        }
    }
}

fn parseFn(
    gpa: std.mem.Allocator,
    line_no: usize,
    t: []const []const u8,
    model: *Model,
) !void {
    // fn <cname> = <ztype>.<method> ( ... ) -> <ret> [!fail]
    if (t.len < 7) return fail(line_no, "function declaration too short");
    if (!std.mem.eql(u8, t[2], "=")) return fail(line_no, "expected '=' after C name");

    const dot = std.mem.indexOfScalar(u8, t[3], '.') orelse
        return fail(line_no, "expected <ZigType>.<method>");

    var f: Func = .{
        .cname = t[1],
        .ztype = t[3][0..dot],
        .method = t[3][dot + 1 ..],
        .recv = .none,
        .args = .empty,
        .ret = .void,
        .fail = .none,
    };
    errdefer f.args.deinit(gpa);

    if (!std.mem.eql(u8, t[4], "(")) return fail(line_no, "expected '(' after method");

    // Args until ')'.
    var i: usize = 5;
    while (i < t.len and !std.mem.eql(u8, t[i], ")")) : (i += 1) {
        const tok = t[i];
        if (std.mem.eql(u8, tok, ",")) continue;
        if (std.mem.eql(u8, tok, "&self")) {
            f.recv = .ptr;
        } else if (std.mem.eql(u8, tok, "=self")) {
            f.recv = .value;
        } else if (tok[0] == '@') {
            // Ownership tag applies to the most recently parsed argument.
            if (f.args.items.len == 0) return fail(line_no, "ownership tag with no argument");
            f.args.items[f.args.items.len - 1].ownership =
                parseOwnership(tok) orelse return fail(line_no, "unknown ownership tag");
        } else {
            const colon = std.mem.indexOfScalar(u8, tok, ':') orelse
                return fail(line_no, "expected <name>:<type> argument");
            const ty = parseArgType(model, tok[colon + 1 ..]) orelse
                return fail(line_no, "unsupported argument type (supported: 'str', '*Type', declared struct)");
            try f.args.append(gpa, .{ .name = tok[0..colon], .ty = ty });
        }
    }
    if (i >= t.len) return fail(line_no, "missing ')'");
    i += 1; // consume ')'

    if (i >= t.len or !std.mem.eql(u8, t[i], "->")) return fail(line_no, "expected '->'");
    i += 1;
    if (i >= t.len) return fail(line_no, "missing return type");
    const rt = t[i];
    if (std.mem.eql(u8, rt, "void")) {
        f.ret = .void;
    } else if (std.mem.eql(u8, rt, "str")) {
        f.ret = .str;
    } else if (std.mem.eql(u8, rt, "?str")) {
        f.ret = .str_opt;
    } else if (rt.len > 1 and rt[0] == '?' and model.findStruct(rt[1..]) != null) {
        f.ret = .{ .struct_opt = rt[1..] };
    } else if (rt.len > 2 and rt[0] == '?' and rt[1] == '*') {
        f.ret = .{ .ptr_opt = rt[2..] };
    } else if (rt.len > 1 and rt[0] == '*') {
        f.ret = .{ .ptr = rt[1..] };
    } else if (Scalar.parse(rt)) |sc| {
        f.ret = .{ .scalar = sc };
    } else if (model.findStruct(rt) != null) {
        f.ret = .{ .struct_ref = rt };
    } else if (model.findEnum(rt)) {
        f.ret = .{ .enum_ref = rt };
    } else {
        return fail(line_no, "unsupported return type ('void', '*Type', scalar, declared struct, or declared enum)");
    }
    i += 1;

    // Trailing markers: `!null` / `!err` (failure) and/or `@owned` / `@borrowed`
    // (return ownership), in any order.
    while (i < t.len) : (i += 1) {
        const tok = t[i];
        if (std.mem.eql(u8, tok, "!null")) {
            f.fail = .null;
        } else if (std.mem.eql(u8, tok, "!err")) {
            f.fail = .err;
        } else if (tok[0] == '@') {
            f.ret_ownership = parseOwnership(tok) orelse return fail(line_no, "unknown ownership tag");
        } else {
            return fail(line_no, "unexpected trailing token after return type");
        }
    }

    const ret_is_value = switch (f.ret) {
        .struct_ref, .scalar, .enum_ref, .str, .str_opt, .struct_opt, .ptr_opt => true,
        else => false,
    };
    // `?*T` already signals "none" with NULL, so it cannot also use !null/!err.
    if (ret_is_value and f.fail != .none)
        return fail(line_no, "value or optional-handle (?*T) return combined with !fail is not supported");

    // `strs` allocates a temp slice in the shim, so the function must have a
    // failure channel to report OOM.
    for (f.args.items) |a| {
        if (a.ty == .str_array and f.fail == .none)
            return fail(line_no, "string-array (strs) arg requires !null or !err");
    }

    try model.funcs.append(gpa, f);
}

fn parseArgType(model: *const Model, s: []const u8) ?ArgType {
    if (std.mem.eql(u8, s, "str")) return .str;
    if (std.mem.eql(u8, s, "?str")) return .str_opt;
    if (std.mem.eql(u8, s, "strs")) return .str_array;
    if (s.len > 1 and s[0] == '?' and model.findStruct(s[1..]) != null) return .{ .struct_opt = s[1..] };
    if (s.len > 2 and s[0] == '?' and s[1] == '*') return .{ .handle_opt = s[2..] };
    if (s.len > 1 and s[0] == '*') return .{ .handle = s[1..] };
    if (Scalar.parse(s)) |sc| return .{ .scalar = sc };
    if (model.findCallback(s)) return .{ .callback = s };
    if (model.findStruct(s) != null) return .{ .struct_ref = s };
    if (model.findEnum(s)) return .{ .enum_ref = s };
    return null;
}

fn parseEnum(
    gpa: std.mem.Allocator,
    line_no: usize,
    t: []const []const u8,
    model: *Model,
) !void {
    // enum <CName> = <NativeZigPath> { <member> ... }
    if (t.len < 6) return fail(line_no, "enum declaration too short");
    if (!std.mem.eql(u8, t[2], "=")) return fail(line_no, "expected '=' after enum name");
    if (!std.mem.eql(u8, t[4], "{")) return fail(line_no, "expected '{' after native type");
    if (!std.mem.eql(u8, t[t.len - 1], "}")) return fail(line_no, "expected '}' to close enum");

    var e: EnumDecl = .{ .cname = t[1], .native = t[3], .members = .empty };
    errdefer e.members.deinit(gpa);

    for (t[5 .. t.len - 1]) |tok| {
        try e.members.append(gpa, tok);
    }
    if (e.members.items.len == 0) return fail(line_no, "enum needs at least one member");

    try model.enums.append(gpa, e);
}

fn parseStruct(
    gpa: std.mem.Allocator,
    line_no: usize,
    t: []const []const u8,
    model: *Model,
) !void {
    // struct <CName> { <name>:<scalar> ... }
    if (t.len < 5) return fail(line_no, "struct declaration too short");
    if (!std.mem.eql(u8, t[2], "{")) return fail(line_no, "expected '{' after struct name");
    if (!std.mem.eql(u8, t[t.len - 1], "}")) return fail(line_no, "expected '}' to close struct");

    var s: Struct = .{ .cname = t[1], .fields = .empty };
    errdefer s.fields.deinit(gpa);

    for (t[3 .. t.len - 1]) |tok| {
        const colon = std.mem.indexOfScalar(u8, tok, ':') orelse
            return fail(line_no, "expected <name>:<scalar> field");
        const scalar = Scalar.parse(tok[colon + 1 ..]) orelse
            return fail(line_no, "unsupported scalar (f32/f64/i32/u32/bool)");
        try s.fields.append(gpa, .{ .name = tok[0..colon], .scalar = scalar });
    }
    if (s.fields.items.len == 0) return fail(line_no, "struct needs at least one field");

    try model.structs.append(gpa, s);
}

fn parseOwnership(tok: []const u8) ?Ownership {
    if (std.mem.eql(u8, tok, "@owned")) return .owned;
    if (std.mem.eql(u8, tok, "@borrowed")) return .borrowed;
    if (std.mem.eql(u8, tok, "@transfer")) return .transfer;
    return null;
}

/// Cut a line at the first '#'.
fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |idx| return line[0..idx];
    return line;
}

/// Split a line into tokens. '(' ')' ',' are single-char tokens; whitespace
/// separates. Everything else (e.g. "->", "*Button", "text:str", "&self")
/// accumulates into one token. Token slices point into `line`.
fn tokenize(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '(' or c == ')' or c == ',' or c == '{' or c == '}') {
            try out.append(gpa, line[i .. i + 1]);
            i += 1;
            continue;
        }
        const start = i;
        while (i < line.len) : (i += 1) {
            const d = line[i];
            if (d == ' ' or d == '\t' or d == '\r' or d == '(' or d == ')' or d == ',' or d == '{' or d == '}') break;
        }
        try out.append(gpa, line[start..i]);
    }
}

fn fail(line_no: usize, msg: []const u8) error{SpecParse} {
    // Silent under `zig build test`: the negative parser tests hit this on
    // purpose, and any stderr from a passing test binary makes `zig build`
    // print it under a noisy "failed command:" banner. The CLI still reports.
    if (!@import("builtin").is_test)
        std.debug.print("apigen: parse error at line {d}: {s}\n", .{ line_no, msg });
    return error.SpecParse;
}

// ── hand-written IR fragment (preamble_ir.txt) ───────────────────────────────
//
// A small sectioned text format. A line beginning with `@` opens a section
// (`@functions`, `@types`, …); the lines until the next `@` (or EOF) are that
// section's raw JSON array elements, kept verbatim (comma-separated, indented to
// match the generated entries). They are spliced into the matching array of the
// generated IR. Lines before the first `@` are a header comment and ignored.
// Text slices point into the fragment buffer (alive for the whole run).

const IrSection = struct {
    name: []const u8,
    /// Raw element text (verbatim, CR/LF-trimmed at both ends; internal
    /// indentation / commas preserved). Empty sections are skipped.
    text: []const u8,
};

fn parseFragment(src: []const u8, out: *std.ArrayList(IrSection), gpa: std.mem.Allocator) !void {
    var cur_name: ?[]const u8 = null;
    var body_start: usize = 0;
    var line_start: usize = 0;
    while (line_start <= src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, line_start, '\n') orelse src.len;
        const line = src[line_start..nl];
        if (line.len > 0 and line[0] == '@') {
            if (cur_name) |nm|
                try out.append(gpa, .{ .name = nm, .text = std.mem.trim(u8, src[body_start..line_start], "\r\n") });
            cur_name = std.mem.trim(u8, line[1..], " \t\r");
            body_start = @min(nl + 1, src.len);
        }
        if (nl == src.len) break;
        line_start = nl + 1;
    }
    if (cur_name) |nm|
        try out.append(gpa, .{ .name = nm, .text = std.mem.trim(u8, src[body_start..], "\r\n") });
}

fn fragText(frag: []const IrSection, name: []const u8) ?[]const u8 {
    for (frag) |s| {
        if (std.mem.eql(u8, s.name, name)) return if (s.text.len == 0) null else s.text;
    }
    return null;
}

/// Emit the separator before a JSON array element: newline for the first entry,
/// `,\n` thereafter. Flips `first` to false.
fn jsonSep(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), first: *bool) !void {
    try buf.appendSlice(gpa, if (first.*) "\n" else ",\n");
    first.* = false;
}

/// Append the hand-written fragment block for `name` (if any) after the
/// generated entries of a section.
fn appendFrag(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), frag: []const IrSection, name: []const u8, first: *bool) !void {
    const block = fragText(frag, name) orelse return;
    try jsonSep(gpa, buf, first);
    try buf.appendSlice(gpa, block);
}

/// Close a JSON array. `first` = no entries emitted; `last` = final section
/// (no trailing comma). Matches the hand-formatted layout of the rest of the IR.
fn jsonClose(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), first: bool, last: bool) !void {
    if (first) {
        try buf.appendSlice(gpa, if (last) "]\n" else "],\n");
    } else {
        try buf.appendSlice(gpa, if (last) "\n  ]\n" else "\n  ],\n");
    }
}

// ── emission: C header ────────────────────────────────────────────────────────

fn emitHeader(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    preamble: []const u8,
    proto_preamble: []const u8,
    model: *const Model,
) !void {
    try buf.appendSlice(gpa, preamble);

    try buf.appendSlice(gpa, "\n/* ── opaque handles ── */\n");
    for (model.opaques.items) |t| {
        try print(gpa, buf, "typedef struct nm{s} nm{s};\n", .{ t.name, t.name });
    }

    if (model.structs.items.len > 0) {
        try buf.appendSlice(gpa, "\n/* ── value structs ── */\n");
        for (model.structs.items) |s| {
            try buf.appendSlice(gpa, "typedef struct {");
            for (s.fields.items) |fld| {
                try print(gpa, buf, " {s} {s};", .{ fld.scalar.cName(), fld.name });
            }
            try print(gpa, buf, " }} {s};\n", .{s.cname});
        }
    }

    if (model.enums.items.len > 0) {
        try buf.appendSlice(gpa, "\n/* ── enums ── */\n");
        for (model.enums.items) |e| {
            try buf.appendSlice(gpa, "typedef enum {");
            for (e.members.items, 0..) |m, idx| {
                if (idx != 0) try buf.appendSlice(gpa, ",");
                try print(gpa, buf, " {s}_{s}", .{ e.cname, m });
            }
            try print(gpa, buf, " }} {s};\n", .{e.cname});
        }
    }

    if (model.callbacks.items.len > 0) {
        try buf.appendSlice(gpa, "\n/* ── event-handler callbacks ── */\n");
        for (model.callbacks.items) |c| {
            // box: caller's function pointer + its userdata. `event` is opaque
            // (read with nmEvent* accessors). Passed by pointer.
            try print(gpa, buf, "typedef struct {{ void (*fn)(void* userdata, const void* event); void* userdata; }} {s};\n", .{c.cname});
        }
    }

    // Hand-written prototypes, emitted here so they may reference the opaque
    // typedefs above (e.g. nmAppCreate -> nmApplication*).
    try buf.appendSlice(gpa, proto_preamble);

    try buf.appendSlice(gpa, "\n/* ── functions ── */\n");
    for (model.funcs.items) |*f| {
        try emitHeaderProto(gpa, buf, f);
    }

    if (model.casts.items.len > 0) {
        try buf.appendSlice(gpa, "\n/* ── upcasts ── */\n");
        for (model.casts.items) |c| {
            try print(gpa, buf, "nm{s}* {s}(nm{s}* self);\n", .{ c.target, c.cname, c.ztype });
        }
    }

    if (model.destructors.items.len > 0) {
        try buf.appendSlice(gpa, "\n/* ── destructors ── */\n");
        for (model.destructors.items) |d| {
            try print(gpa, buf, "void {s}(nm{s}* self);\n", .{ d.cname, d.ztype });
        }
    }

    try buf.appendSlice(gpa, "\n#ifdef __cplusplus\n}\n#endif\n");
}

fn emitHeaderProto(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), f: *const Func) !void {
    // return type (optional value struct -> bool + out-param, see below)
    switch (f.ret) {
        .void => try buf.appendSlice(gpa, if (f.fail == .err) "int" else "void"),
        .ptr, .ptr_opt => |zt| try print(gpa, buf, "nm{s}*", .{zt}),
        .struct_ref => |sn| try buf.appendSlice(gpa, sn),
        .scalar => |sc| try buf.appendSlice(gpa, sc.cName()),
        .enum_ref => |en| try buf.appendSlice(gpa, en),
        .str, .str_opt => try buf.appendSlice(gpa, "nmStr"),
        .struct_opt => try buf.appendSlice(gpa, "bool"),
    }
    try print(gpa, buf, " {s}(", .{f.cname});

    var wrote = false;
    if (f.recv != .none) {
        const cnst = if (f.recv == .value) "const " else "";
        try print(gpa, buf, "{s}nm{s}* self", .{ cnst, f.ztype });
        wrote = true;
    }
    for (f.args.items) |a| {
        if (wrote) try buf.appendSlice(gpa, ", ");
        switch (a.ty) {
            .str, .str_opt => try print(gpa, buf, "const char* {s}", .{a.name}),
            .handle, .handle_opt => |zt| try print(gpa, buf, "nm{s}* {s}", .{ zt, a.name }),
            .struct_ref => |sn| try print(gpa, buf, "{s} {s}", .{ sn, a.name }),
            .scalar => |sc| try print(gpa, buf, "{s} {s}", .{ sc.cName(), a.name }),
            .enum_ref => |en| try print(gpa, buf, "{s} {s}", .{ en, a.name }),
            .callback => |cn| try print(gpa, buf, "{s}* {s}", .{ cn, a.name }),
            .struct_opt => |sn| try print(gpa, buf, "const {s}* {s}", .{ sn, a.name }),
            .str_array => try print(gpa, buf, "const char* const* {s}, size_t {s}_len", .{ a.name, a.name }),
        }
        wrote = true;
    }
    // Optional value-struct return: trailing out-param, function returns bool.
    if (f.ret == .struct_opt) {
        if (wrote) try buf.appendSlice(gpa, ", ");
        try print(gpa, buf, "{s}* out", .{f.ret.struct_opt});
        wrote = true;
    }
    if (!wrote) try buf.appendSlice(gpa, "void");
    try buf.appendSlice(gpa, ");\n");
}

// ── emission: Zig shims ───────────────────────────────────────────────────────

fn emitZig(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    preamble: []const u8,
    model: *const Model,
) !void {
    try buf.appendSlice(gpa, preamble);
    try buf.appendSlice(gpa,
        \\
        \\// ── generated exports (do not edit; regenerate with `zig build apigen`) ──
        \\
    );

    // ABI-layout value structs. `extern struct` guarantees C-compatible layout;
    // shims convert field-by-field to/from the native (plain) Zig struct.
    for (model.structs.items) |s| {
        try print(gpa, buf, "\nconst {s} = extern struct {{", .{s.cname});
        for (s.fields.items) |fld| {
            try print(gpa, buf, " {s}: {s},", .{ fld.name, fld.scalar.zigName() });
        }
        try buf.appendSlice(gpa, " };\n");
    }

    // Enums cross the ABI as integers (C enum / `c_int`). This comptime block
    // verifies each declared member's value matches the native Zig enum, so a
    // reorder / rename in the native enum is a compile error, not a silent ABI
    // break (a renamed member fails to resolve; a reorder fails the assert).
    for (model.enums.items) |e| {
        try buf.appendSlice(gpa, "\ncomptime {\n");
        for (e.members.items, 0..) |m, idx| {
            try print(gpa, buf, "    std.debug.assert(@intFromEnum(framework.{s}.{s}) == {d});\n", .{ e.native, m, idx });
        }
        try buf.appendSlice(gpa, "}\n");
    }

    // Event-handler callbacks (approach C). Each declares an ABI box
    // ({fn, userdata}) and a Zig-callconv trampoline. The trampoline is a typed
    // listener `fn(*box, *const NativeEvent)` so it plugs straight into the
    // typed `addXxxListener(T, f, ud)` — no raw registration needed. The native
    // event crosses to C as an opaque `const void*` (read via preamble
    // accessors); no per-event conversion here. `callconv(.c)` appears only on
    // the box's `fn_ptr` field (the genuinely C-supplied pointer).
    for (model.callbacks.items) |c| {
        try print(gpa, buf,
            \\
            \\const {s} = extern struct {{
            \\    fn_ptr: ?*const fn (?*anyopaque, ?*const anyopaque) callconv(.c) void,
            \\    userdata: ?*anyopaque,
            \\}};
            \\fn nm_trampoline_{s}(box: *{s}, e: *const framework.{s}) void {{
            \\    if (box.fn_ptr) |f| f(box.userdata, e);
            \\}}
            \\
        , .{ c.cname, c.cname, c.cname, c.native_event });
    }

    for (model.funcs.items) |*f| {
        try emitZigShim(gpa, buf, model, f);
    }

    // Upcasts: one-line `return &self.<field>` as a *<Target> handle.
    for (model.casts.items) |c| {
        try print(
            gpa,
            buf,
            "\nexport fn {s}(self: *framework.{s}) *framework.{s} {{\n    return &self.{s};\n}}\n",
            .{ c.cname, c.ztype, c.target, c.field },
        );
    }

    // Destructors: dispatch the widget's own vtable.destroy with the allocator
    // stored on the Component.
    for (model.destructors.items) |d| {
        try print(
            gpa,
            buf,
            "\nexport fn {s}(self: *framework.{s}) void {{\n    self.vtable.destroy(self, self.allocator);\n}}\n",
            .{ d.cname, d.ztype },
        );
    }
}

fn emitZigShim(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), model: *const Model, f: *const Func) !void {
    try print(gpa, buf, "\nexport fn {s}(", .{f.cname});

    var wrote = false;
    if (f.recv != .none) {
        try print(gpa, buf, "self: *framework.{s}", .{f.ztype});
        wrote = true;
    }
    for (f.args.items) |a| {
        if (wrote) try buf.appendSlice(gpa, ", ");
        switch (a.ty) {
            .str => try print(gpa, buf, "{s}: [*:0]const u8", .{a.name}),
            .str_opt => try print(gpa, buf, "{s}: ?[*:0]const u8", .{a.name}),
            .handle => |zt| try print(gpa, buf, "{s}: *framework.{s}", .{ a.name, zt }),
            .handle_opt => |zt| try print(gpa, buf, "{s}: ?*framework.{s}", .{ a.name, zt }),
            .struct_ref => |sn| try print(gpa, buf, "{s}: {s}", .{ a.name, sn }),
            .scalar => |sc| try print(gpa, buf, "{s}: {s}", .{ a.name, sc.zigName() }),
            // Enums cross as int; convert at the call site.
            .enum_ref => try print(gpa, buf, "{s}: c_int", .{a.name}),
            .callback => |cn| try print(gpa, buf, "{s}: *{s}", .{ a.name, cn }),
            .struct_opt => |sn| try print(gpa, buf, "{s}: ?*const {s}", .{ a.name, sn }),
            .str_array => try print(gpa, buf, "{s}: [*]const [*:0]const u8, {s}_len: usize", .{ a.name, a.name }),
        }
        wrote = true;
    }
    // Optional value-struct return: trailing out-param, function returns bool.
    if (f.ret == .struct_opt) {
        if (wrote) try buf.appendSlice(gpa, ", ");
        try print(gpa, buf, "out: *{s}", .{f.ret.struct_opt});
        wrote = true;
    }
    try buf.appendSlice(gpa, ") ");

    // return type
    switch (f.ret) {
        .void => try buf.appendSlice(gpa, if (f.fail == .err) "c_int" else "void"),
        .ptr => |zt| {
            if (f.fail == .null) {
                try print(gpa, buf, "?*framework.{s}", .{zt});
            } else {
                try print(gpa, buf, "*framework.{s}", .{zt});
            }
        },
        .ptr_opt => |zt| try print(gpa, buf, "?*framework.{s}", .{zt}),
        .struct_ref => |sn| try buf.appendSlice(gpa, sn),
        .scalar => |sc| try buf.appendSlice(gpa, sc.zigName()),
        .enum_ref => try buf.appendSlice(gpa, "c_int"),
        .str, .str_opt => try buf.appendSlice(gpa, "nmStr"),
        .struct_opt => try buf.appendSlice(gpa, "bool"),
    }
    try buf.appendSlice(gpa, " {\n");

    // Failure return expression for prelude allocations (str_array).
    const fail_expr: []const u8 = switch (f.fail) {
        .null => "null",
        .err => "errorToCode(e)",
        .none => "", // not reached: str_array requires a fail mode
    };

    // Prelude: per-arg setup emitted before the call (str_array temp slice).
    var prelude: std.ArrayList(u8) = .empty;
    defer prelude.deinit(gpa);

    // call expression. A struct arg is converted from the ABI extern struct to
    // the native struct via an anonymous literal (Zig coerces it to the method's
    // parameter type; a field-name mismatch is then a compile error).
    var call: std.ArrayList(u8) = .empty;
    defer call.deinit(gpa);
    if (f.recv != .none) {
        try print(gpa, &call, "self.{s}(", .{f.method});
    } else {
        try print(gpa, &call, "framework.{s}.{s}(", .{ f.ztype, f.method });
    }
    for (f.args.items, 0..) |a, idx| {
        if (idx != 0) try call.appendSlice(gpa, ", ");
        switch (a.ty) {
            .str => try print(gpa, &call, "std.mem.span({s})", .{a.name}),
            .str_opt => try print(gpa, &call, "if ({s}) |_p| std.mem.span(_p) else null", .{a.name}),
            .handle, .handle_opt => try call.appendSlice(gpa, a.name),
            .struct_ref => |sn| try appendStructLiteral(gpa, &call, a.name, model.findStruct(sn).?),
            .scalar => try call.appendSlice(gpa, a.name),
            .enum_ref => try print(gpa, &call, "@enumFromInt({s})", .{a.name}),
            // 1 callback arg expands to (comptime T=box, comptime f=trampoline, ud=box)
            // fed to the typed addXxxListener.
            .callback => |cn| try print(gpa, &call, "{s}, nm_trampoline_{s}, {s}", .{ cn, cn, a.name }),
            .struct_opt => |sn| {
                // ?*const nmX -> ?NativeStruct (field-by-field when present).
                try print(gpa, &call, "if ({s}) |_p| ", .{a.name});
                try appendStructLiteral(gpa, &call, "_p", model.findStruct(sn).?);
                try call.appendSlice(gpa, " else null");
            },
            .str_array => {
                // Build a temp []const []const u8; freed after the call (callee copies).
                try print(gpa, &prelude, "    const _{s} = std.heap.c_allocator.alloc([]const u8, {s}_len) catch |e| {{ setLastError(e); return {s}; }};\n    defer std.heap.c_allocator.free(_{s});\n    for (_{s}, 0..) |*_it, _i| _it.* = std.mem.span({s}[_i]);\n", .{ a.name, a.name, fail_expr, a.name, a.name, a.name });
                try print(gpa, &call, "_{s}", .{a.name});
            },
        }
    }
    try call.appendSlice(gpa, ")");

    try buf.appendSlice(gpa, prelude.items);

    // body
    switch (f.fail) {
        .null => {
            try print(gpa, buf, "    return {s} catch |e| {{\n        setLastError(e);\n        return null;\n    }};\n", .{call.items});
        },
        .err => {
            try print(gpa, buf, "    {s} catch |e| {{\n        setLastError(e);\n        return errorToCode(e);\n    }};\n    return 0;\n", .{call.items});
        },
        .none => {
            switch (f.ret) {
                .void => try print(gpa, buf, "    {s};\n", .{call.items}),
                .ptr, .ptr_opt, .scalar => try print(gpa, buf, "    return {s};\n", .{call.items}),
                .enum_ref => try print(gpa, buf, "    return @intFromEnum({s});\n", .{call.items}),
                .struct_ref => |sn| {
                    // native struct -> ABI extern struct, field by field.
                    try print(gpa, buf, "    const _ret = {s};\n    return ", .{call.items});
                    try appendStructLiteral(gpa, buf, "_ret", model.findStruct(sn).?);
                    try buf.appendSlice(gpa, ";\n");
                },
                // Borrowed slice -> nmStr (ptr + len). No copy; valid until the
                // source mutates (binding copies immediately).
                .str => try print(gpa, buf, "    const _s = {s};\n    return .{{ .ptr = _s.ptr, .len = _s.len }};\n", .{call.items}),
                .str_opt => try print(gpa, buf, "    const _s = {s};\n    return if (_s) |v| .{{ .ptr = v.ptr, .len = v.len }} else .{{ .ptr = null, .len = 0 }};\n", .{call.items}),
                // Optional value struct -> out-param + bool (true when present).
                .struct_opt => |sn| {
                    try print(gpa, buf, "    const _v = {s};\n    if (_v) |s| {{\n        out.* = ", .{call.items});
                    try appendStructLiteral(gpa, buf, "s", model.findStruct(sn).?);
                    try buf.appendSlice(gpa, ";\n        return true;\n    }\n    return false;\n");
                },
            }
        },
    }

    try buf.appendSlice(gpa, "}\n");
}

/// Append `.{ .a = src.a, .b = src.b, ... }` for the given struct's fields.
fn appendStructLiteral(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), src: []const u8, st: *const Struct) !void {
    try buf.appendSlice(gpa, ".{ ");
    for (st.fields.items, 0..) |fld, idx| {
        if (idx != 0) try buf.appendSlice(gpa, ", ");
        try print(gpa, buf, ".{s} = {s}.{s}", .{ fld.name, src, fld.name });
    }
    try buf.appendSlice(gpa, " }");
}

// ── emission: binding IR (JSON) ───────────────────────────────────────────────
//
// Consumed by per-language binding generators (separate repos; see
// framework/doc/binding.md). JSON so they need no Zig parser. All emitted
// strings are identifiers (ASCII alnum / '_'), so no escaping is required.
// Deterministic: entries are emitted in spec order.

fn emitJson(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), model: *const Model, frag: []const IrSection) !void {
    try buf.appendSlice(gpa, "{\n");

    // Each section: generated entries first, then any hand-written fragment
    // entries (appendFrag), then the close. `last = true` only on the final
    // section (no trailing comma).

    // types
    try buf.appendSlice(gpa, "  \"types\": [");
    {
        var first = true;
        for (model.opaques.items) |t| {
            try jsonSep(gpa, buf, &first);
            try print(gpa, buf, "    {{ \"name\": \"{s}\", \"c\": \"nm{s}\", \"extends\": ", .{ t.name, t.name });
            if (t.parent) |p| {
                try print(gpa, buf, "\"{s}\"", .{p});
            } else {
                try buf.appendSlice(gpa, "null");
            }
            try buf.appendSlice(gpa, " }");
        }
        try appendFrag(gpa, buf, frag, "types", &first);
        try jsonClose(gpa, buf, first, false);
    }

    // value structs (layout exposed)
    try buf.appendSlice(gpa, "  \"structs\": [");
    {
        var first = true;
        for (model.structs.items) |s| {
            try jsonSep(gpa, buf, &first);
            try print(gpa, buf, "    {{ \"name\": \"{s}\", \"fields\": [", .{s.cname});
            for (s.fields.items, 0..) |fld, fidx| {
                if (fidx != 0) try buf.appendSlice(gpa, ", ");
                try print(gpa, buf, "{{ \"name\": \"{s}\", \"type\": \"{s}\" }}", .{ fld.name, fld.scalar.zigName() });
            }
            try buf.appendSlice(gpa, "] }");
        }
        try appendFrag(gpa, buf, frag, "structs", &first);
        try jsonClose(gpa, buf, first, false);
    }

    // enums (exposed as integers; members carry their value)
    try buf.appendSlice(gpa, "  \"enums\": [");
    {
        var first = true;
        for (model.enums.items) |e| {
            try jsonSep(gpa, buf, &first);
            try print(gpa, buf, "    {{ \"name\": \"{s}\", \"members\": [", .{e.cname});
            for (e.members.items, 0..) |m, midx| {
                if (midx != 0) try buf.appendSlice(gpa, ", ");
                try print(gpa, buf, "{{ \"name\": \"{s}\", \"value\": {d} }}", .{ m, midx });
            }
            try buf.appendSlice(gpa, "] }");
        }
        try appendFrag(gpa, buf, frag, "enums", &first);
        try jsonClose(gpa, buf, first, false);
    }

    // callbacks (event-handler boxes). C fn = void(*)(void* userdata, const void* event);
    // the event is opaque, read via nmEvent* accessors (see preamble).
    try buf.appendSlice(gpa, "  \"callbacks\": [");
    {
        var first = true;
        for (model.callbacks.items) |c| {
            try jsonSep(gpa, buf, &first);
            try print(gpa, buf, "    {{ \"name\": \"{s}\", \"event\": \"opaque\" }}", .{c.cname});
        }
        try appendFrag(gpa, buf, frag, "callbacks", &first);
        try jsonClose(gpa, buf, first, false);
    }

    // functions
    try buf.appendSlice(gpa, "  \"functions\": [");
    {
        var first = true;
        for (model.funcs.items) |*f| {
            try jsonSep(gpa, buf, &first);
            try emitJsonFunc(gpa, buf, f);
        }
        try appendFrag(gpa, buf, frag, "functions", &first);
        try jsonClose(gpa, buf, first, false);
    }

    // casts (upcasts): from -> to
    try buf.appendSlice(gpa, "  \"casts\": [");
    {
        var first = true;
        for (model.casts.items) |c| {
            try jsonSep(gpa, buf, &first);
            try print(gpa, buf, "    {{ \"c\": \"{s}\", \"from\": \"{s}\", \"to\": \"{s}\" }}", .{ c.cname, c.ztype, c.target });
        }
        try appendFrag(gpa, buf, frag, "casts", &first);
        try jsonClose(gpa, buf, first, false);
    }

    // destructors (final section — no trailing comma)
    try buf.appendSlice(gpa, "  \"destructors\": [");
    {
        var first = true;
        for (model.destructors.items) |d| {
            try jsonSep(gpa, buf, &first);
            try print(gpa, buf, "    {{ \"c\": \"{s}\", \"type\": \"{s}\" }}", .{ d.cname, d.ztype });
        }
        try appendFrag(gpa, buf, frag, "destructors", &first);
        try jsonClose(gpa, buf, first, true);
    }

    try buf.appendSlice(gpa, "}\n");
}

fn ownStr(o: Ownership) ?[]const u8 {
    return switch (o) {
        .default => null,
        .owned => "owned",
        .borrowed => "borrowed",
        .transfer => "transfer",
    };
}

fn emitJsonFunc(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), f: *const Func) !void {
    try buf.appendSlice(gpa, "    {\n");
    try print(gpa, buf, "      \"c\": \"{s}\",\n", .{f.cname});
    try print(gpa, buf, "      \"owner\": \"{s}\",\n", .{f.ztype});
    try print(gpa, buf, "      \"method\": \"{s}\",\n", .{f.method});

    // Target-language method names. JS keeps the Zig camelCase; Python uses
    // snake_case (see snakeCase). A spec-level override could set these later.
    try buf.appendSlice(gpa, "      \"names\": { \"py\": \"");
    try appendSnake(gpa, buf, f.method);
    try print(gpa, buf, "\", \"js\": \"{s}\" }},\n", .{f.method});

    try print(gpa, buf, "      \"kind\": \"{s}\",\n", .{if (f.recv == .none) "static" else "method"});
    const recv = switch (f.recv) {
        .none => "null",
        .ptr => "\"ptr\"",
        .value => "\"value\"",
    };
    try print(gpa, buf, "      \"receiver\": {s},\n", .{recv});

    // params
    try buf.appendSlice(gpa, "      \"params\": [");
    for (f.args.items, 0..) |a, idx| {
        if (idx != 0) try buf.appendSlice(gpa, ", ");
        try print(gpa, buf, "{{ \"name\": \"{s}\", ", .{a.name});
        switch (a.ty) {
            .str => try buf.appendSlice(gpa, "\"type\": \"str\""),
            .str_opt => try buf.appendSlice(gpa, "\"type\": \"str\", \"optional\": true"),
            .handle => |zt| try print(gpa, buf, "\"type\": \"handle\", \"handle\": \"{s}\"", .{zt}),
            .handle_opt => |zt| try print(gpa, buf, "\"type\": \"handle\", \"handle\": \"{s}\", \"optional\": true", .{zt}),
            .struct_ref => |sn| try print(gpa, buf, "\"type\": \"struct\", \"struct\": \"{s}\"", .{sn}),
            .scalar => |sc| try print(gpa, buf, "\"type\": \"{s}\"", .{sc.zigName()}),
            .enum_ref => |en| try print(gpa, buf, "\"type\": \"enum\", \"enum\": \"{s}\"", .{en}),
            .callback => |cn| try print(gpa, buf, "\"type\": \"callback\", \"callback\": \"{s}\", \"role\": \"event_handler\"", .{cn}),
            .struct_opt => |sn| try print(gpa, buf, "\"type\": \"struct\", \"struct\": \"{s}\", \"optional\": true", .{sn}),
            .str_array => try buf.appendSlice(gpa, "\"type\": \"str_array\""),
        }
        if (ownStr(a.ownership)) |o| try print(gpa, buf, ", \"ownership\": \"{s}\"", .{o});
        try buf.appendSlice(gpa, " }");
    }
    try buf.appendSlice(gpa, "],\n");

    // ret
    switch (f.ret) {
        .void => try buf.appendSlice(gpa, "      \"ret\": { \"type\": \"void\" },\n"),
        .ptr => |zt| {
            try print(gpa, buf, "      \"ret\": {{ \"type\": \"handle\", \"handle\": \"{s}\"", .{zt});
            if (ownStr(f.ret_ownership)) |o| try print(gpa, buf, ", \"ownership\": \"{s}\"", .{o});
            try buf.appendSlice(gpa, " },\n");
        },
        .ptr_opt => |zt| {
            try print(gpa, buf, "      \"ret\": {{ \"type\": \"handle\", \"handle\": \"{s}\", \"optional\": true", .{zt});
            if (ownStr(f.ret_ownership)) |o| try print(gpa, buf, ", \"ownership\": \"{s}\"", .{o});
            try buf.appendSlice(gpa, " },\n");
        },
        .struct_ref => |sn| try print(gpa, buf, "      \"ret\": {{ \"type\": \"struct\", \"struct\": \"{s}\" }},\n", .{sn}),
        .scalar => |sc| try print(gpa, buf, "      \"ret\": {{ \"type\": \"{s}\" }},\n", .{sc.zigName()}),
        .enum_ref => |en| try print(gpa, buf, "      \"ret\": {{ \"type\": \"enum\", \"enum\": \"{s}\" }},\n", .{en}),
        .str => try buf.appendSlice(gpa, "      \"ret\": { \"type\": \"str\", \"ownership\": \"borrowed\" },\n"),
        .str_opt => try buf.appendSlice(gpa, "      \"ret\": { \"type\": \"str\", \"optional\": true, \"ownership\": \"borrowed\" },\n"),
        // optional value struct: C is `bool fn(..., <CName>* out)` (out-param).
        .struct_opt => |sn| try print(gpa, buf, "      \"ret\": {{ \"type\": \"struct\", \"struct\": \"{s}\", \"optional\": true, \"out_param\": true }},\n", .{sn}),
    }

    // fail
    const failv = switch (f.fail) {
        .none => "null",
        .null => "\"null\"",
        .err => "\"err\"",
    };
    try print(gpa, buf, "      \"fail\": {s}\n", .{failv});

    try buf.appendSlice(gpa, "    }");
}

/// Append `s` to `buf` converting camelCase to snake_case (e.g. "setText" ->
/// "set_text", "addActionListener" -> "add_action_listener"). Acronyms split
/// per-capital (imperfect but deterministic); a spec override handles the rest.
fn appendSnake(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s, 0..) |c, i| {
        if (c >= 'A' and c <= 'Z') {
            if (i != 0) try buf.append(gpa, '_');
            try buf.append(gpa, c - 'A' + 'a');
        } else {
            try buf.append(gpa, c);
        }
    }
}

// ── helpers ────────────────────────────────────────────────────────────────

/// `std.fmt`-format into an unmanaged ArrayList(u8).
fn print(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try buf.appendSlice(gpa, s);
}

// ── tests ──────────────────────────────────────────────────────────────────
// The parser and emitters are pure (no I/O), so they test directly: feed a spec
// string, inspect the Model or the emitted text. `std.testing.allocator` also
// catches any leak (verifies deinitModel covers every list).

const testing = std.testing;

test "stripComment cuts at the first #" {
    try testing.expectEqualStrings("opaque Button ", stripComment("opaque Button # a comment"));
    try testing.expectEqualStrings("plain", stripComment("plain"));
    try testing.expectEqualStrings("", stripComment("# whole-line comment"));
}

test "Scalar.parse and spellings" {
    try testing.expectEqual(Scalar.usize, Scalar.parse("usize").?);
    try testing.expectEqual(Scalar.f32, Scalar.parse("f32").?);
    try testing.expect(Scalar.parse("f16") == null);
    try testing.expectEqualStrings("size_t", Scalar.usize.cName());
    try testing.expectEqualStrings("usize", Scalar.usize.zigName());
}

test "tokenize splits punctuation, keeps compound tokens" {
    const gpa = testing.allocator;
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, "fn x = T.m ( a:str , b:f32 ) -> void", &toks);
    const want = [_][]const u8{ "fn", "x", "=", "T.m", "(", "a:str", ",", "b:f32", ")", "->", "void" };
    try testing.expectEqual(want.len, toks.items.len);
    for (want, toks.items) |w, got| try testing.expectEqualStrings(w, got);
}

test "parse: opaque with and without parent" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa, "opaque Component\nopaque Button : Component\n", &model);
    try testing.expectEqual(@as(usize, 2), model.opaques.items.len);
    try testing.expect(model.opaques.items[0].parent == null);
    try testing.expectEqualStrings("Button", model.opaques.items[1].name);
    try testing.expectEqualStrings("Component", model.opaques.items[1].parent.?);
}

test "parse: struct and enum members in order" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa,
        \\struct nmColor { r:f32 g:f32 b:f32 a:f32 }
        \\enum nmAlignment = Component.Alignment { start center end stretch }
        \\
    , &model);
    try testing.expectEqual(@as(usize, 1), model.structs.items.len);
    try testing.expectEqualStrings("nmColor", model.structs.items[0].cname);
    try testing.expectEqual(@as(usize, 4), model.structs.items[0].fields.items.len);
    try testing.expectEqualStrings("r", model.structs.items[0].fields.items[0].name);
    try testing.expectEqual(Scalar.f32, model.structs.items[0].fields.items[0].scalar);
    try testing.expectEqualStrings("Component.Alignment", model.enums.items[0].native);
    try testing.expectEqual(@as(usize, 4), model.enums.items[0].members.items.len);
    try testing.expectEqualStrings("start", model.enums.items[0].members.items[0]);
}

test "parse fn: handle arg + @transfer + !err" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa, "fn nmContainerAdd = Container.add (&self, child:*Component @transfer) -> void !err\n", &model);
    const f = model.funcs.items[0];
    try testing.expectEqualStrings("nmContainerAdd", f.cname);
    try testing.expectEqualStrings("Container", f.ztype);
    try testing.expectEqualStrings("add", f.method);
    try testing.expectEqual(Recv.ptr, f.recv);
    try testing.expectEqual(Fail.err, f.fail);
    try testing.expectEqual(@as(usize, 1), f.args.items.len);
    try testing.expectEqualStrings("child", f.args.items[0].name);
    try testing.expectEqual(Ownership.transfer, f.args.items[0].ownership);
    switch (f.args.items[0].ty) {
        .handle => |zt| try testing.expectEqualStrings("Component", zt),
        else => return error.WrongArgType,
    }
}

test "parse fn: optional handle / optional str args" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa,
        \\fn a = Frame.setMenuBar (&self, bar:?*MenuBar @transfer) -> void !err
        \\fn b = Component.setName (&self, name:?str) -> void
        \\
    , &model);
    switch (model.funcs.items[0].args.items[0].ty) {
        .handle_opt => |zt| try testing.expectEqualStrings("MenuBar", zt),
        else => return error.WrongArgType,
    }
    switch (model.funcs.items[1].args.items[0].ty) {
        .str_opt => {},
        else => return error.WrongArgType,
    }
}

test "parse fn: optional handle return + ownership, =self receiver" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa, "fn g = Frame.getMenuBar (=self) -> ?*MenuBar @borrowed\n", &model);
    const f = model.funcs.items[0];
    try testing.expectEqual(Recv.value, f.recv);
    try testing.expectEqual(Ownership.borrowed, f.ret_ownership);
    switch (f.ret) {
        .ptr_opt => |zt| try testing.expectEqualStrings("MenuBar", zt),
        else => return error.WrongRet,
    }
}

test "parse fn: str / usize / enum returns" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa,
        \\enum nmAlignment = Component.Alignment { start center end stretch }
        \\fn t = Button.getText (=self) -> str
        \\fn c = ComboBox.getItemCount (=self) -> usize
        \\fn a = Component.getAlignX (&self) -> nmAlignment
        \\
    , &model);
    try testing.expectEqual(Ret.str, model.funcs.items[0].ret);
    switch (model.funcs.items[1].ret) {
        .scalar => |s| try testing.expectEqual(Scalar.usize, s),
        else => return error.WrongRet,
    }
    switch (model.funcs.items[2].ret) {
        .enum_ref => |en| try testing.expectEqualStrings("nmAlignment", en),
        else => return error.WrongRet,
    }
}

test "parse: cast and destroy" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa,
        \\cast nmButtonAsComponent = Button.component -> Component
        \\destroy nmComponentDestroy = Component
        \\
    , &model);
    try testing.expectEqualStrings("Button", model.casts.items[0].ztype);
    try testing.expectEqualStrings("component", model.casts.items[0].field);
    try testing.expectEqualStrings("Component", model.casts.items[0].target);
    try testing.expectEqualStrings("nmComponentDestroy", model.destructors.items[0].cname);
    try testing.expectEqualStrings("Component", model.destructors.items[0].ztype);
}

test "parse rejects: value+fail, unknown keyword, bad scalar, strs without fail" {
    const gpa = testing.allocator;
    const bad = [_][]const u8{
        "fn x = T.m (=self) -> f32 !null\n", // value return cannot combine with !fail
        "frobnicate X\n", // unknown statement keyword
        "struct nmX { v:f16 }\n", // unsupported scalar
        "fn x = App.combo (&self, items:strs) -> void\n", // strs needs !null/!err
    };
    for (bad) |src| {
        var model: Model = .{};
        defer deinitModel(gpa, &model);
        try testing.expectError(error.SpecParse, parse(gpa, src, &model));
    }
}

test "parseFragment splits @sections and ignores the header" {
    const gpa = testing.allocator;
    var frag: std.ArrayList(IrSection) = .empty;
    defer frag.deinit(gpa);
    try parseFragment(
        \\# header line ignored
        \\@functions
        \\  { "c": "x" }
        \\@types
        \\  { "name": "Y" }
        \\
    , &frag, gpa);
    try testing.expectEqual(@as(usize, 2), frag.items.len);
    try testing.expectEqualStrings("functions", frag.items[0].name);
    try testing.expectEqualStrings("types", frag.items[1].name);
    try testing.expect(fragText(frag.items, "functions") != null);
    try testing.expect(fragText(frag.items, "missing") == null);
}

test "emit smoke: header / zig / json carry the function and inheritance" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa,
        \\opaque Component
        \\opaque Button : Component
        \\fn nmButtonSetText = Button.setText (&self, text:str) -> void !err
        \\
    , &model);

    var h: std.ArrayList(u8) = .empty;
    defer h.deinit(gpa);
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);
    try emitHeader(gpa, &h, "", "", &model);
    try emitZig(gpa, &z, "", &model);
    try emitJson(gpa, &j, &model, &[_]IrSection{});

    try testing.expect(std.mem.indexOf(u8, h.items, "typedef struct nmButton nmButton;") != null);
    try testing.expect(std.mem.indexOf(u8, h.items, "int nmButtonSetText(nmButton* self, const char* text);") != null);
    try testing.expect(std.mem.indexOf(u8, z.items, "export fn nmButtonSetText(self: *framework.Button, text: [*:0]const u8) c_int") != null);
    try testing.expect(std.mem.indexOf(u8, j.items, "\"c\": \"nmButtonSetText\"") != null);
    try testing.expect(std.mem.indexOf(u8, j.items, "\"extends\": \"Component\"") != null);
}

test "emit: hand-written IR fragment is merged into the functions array" {
    const gpa = testing.allocator;
    var model: Model = .{};
    defer deinitModel(gpa, &model);
    try parse(gpa, "fn nmGenerated = T.m (&self) -> void\n", &model);

    var frag: std.ArrayList(IrSection) = .empty;
    defer frag.deinit(gpa);
    try parseFragment("@functions\n    { \"c\": \"nmHandwritten\", \"impl\": \"manual\" }\n", &frag, gpa);

    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);
    try emitJson(gpa, &j, &model, frag.items);
    try testing.expect(std.mem.indexOf(u8, j.items, "\"c\": \"nmGenerated\"") != null);
    try testing.expect(std.mem.indexOf(u8, j.items, "\"c\": \"nmHandwritten\"") != null);
}
