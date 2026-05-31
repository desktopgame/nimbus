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
//! The grammar this parses is documented in nimbus.api and doc/c_api_codegen.md.
//! This is an internal build tool; paths are fixed relative to the repo root
//! (the build step runs it with the repo root as the working directory).

const std = @import("std");

const SPEC_PATH = "tools/apigen/nimbus.api";
const PREAMBLE_H = "tools/apigen/preamble.h";
const PREAMBLE_ZIG = "tools/apigen/preamble.zig";
const OUT_H = "include/nimbus.h";
const OUT_ZIG = "framework/src/c_api.zig";
const OUT_JSON_DIR = "bindings";
const OUT_JSON = "bindings/nimbus_api.json";

// ── parsed model ────────────────────────────────────────────────────────────

/// How the receiver (first parameter) is passed.
const Recv = enum { none, ptr, value };

/// Argument wire type. PoC subset; extended per doc/c_api_codegen.md「未対応」.
const ArgType = enum { str };

/// Function return shape.
const Ret = union(enum) {
    void,
    /// Owned/borrowed handle pointer; payload is the Zig type name (e.g. "Button").
    ptr: []const u8,
};

/// Failure-signalling convention.
const Fail = enum { none, null, err };

const Arg = struct {
    name: []const u8,
    ty: ArgType,
};

const Func = struct {
    cname: []const u8,
    ztype: []const u8,
    method: []const u8,
    recv: Recv,
    args: std.ArrayList(Arg),
    ret: Ret,
    fail: Fail,
};

const Opaque = struct {
    name: []const u8,
    /// Single-inheritance parent (the `: <Parent>` clause), or null.
    parent: ?[]const u8,
};

const Model = struct {
    opaques: std.ArrayList(Opaque) = .empty,
    funcs: std.ArrayList(Func) = .empty,
};

// All string slices in the model point into the spec buffer, which is kept
// alive for the whole run, so nothing here owns its strings.

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const spec = try cwd.readFileAlloc(io, SPEC_PATH, gpa, .unlimited);
    defer gpa.free(spec);
    const pre_h = try cwd.readFileAlloc(io, PREAMBLE_H, gpa, .unlimited);
    defer gpa.free(pre_h);
    const pre_zig = try cwd.readFileAlloc(io, PREAMBLE_ZIG, gpa, .unlimited);
    defer gpa.free(pre_zig);

    var model: Model = .{};
    defer {
        for (model.funcs.items) |*f| f.args.deinit(gpa);
        model.funcs.deinit(gpa);
        model.opaques.deinit(gpa);
    }
    try parse(gpa, spec, &model);

    var h: std.ArrayList(u8) = .empty;
    defer h.deinit(gpa);
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);

    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);

    try emitHeader(gpa, &h, pre_h, &model);
    try emitZig(gpa, &z, pre_zig, &model);
    try emitJson(gpa, &j, &model);

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
        } else if (std.mem.eql(u8, kw, "fn")) {
            try parseFn(gpa, line_no, tokens.items, model);
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
        } else {
            const colon = std.mem.indexOfScalar(u8, tok, ':') orelse
                return fail(line_no, "expected <name>:<type> argument");
            const ty = parseArgType(tok[colon + 1 ..]) orelse
                return fail(line_no, "unsupported argument type (PoC: only 'str')");
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
    } else if (rt.len > 1 and rt[0] == '*') {
        f.ret = .{ .ptr = rt[1..] };
    } else {
        return fail(line_no, "unsupported return type (PoC: 'void' or '*Type')");
    }
    i += 1;

    if (i < t.len) {
        const ft = t[i];
        if (std.mem.eql(u8, ft, "!null")) {
            f.fail = .null;
        } else if (std.mem.eql(u8, ft, "!err")) {
            f.fail = .err;
        } else {
            return fail(line_no, "unknown failure marker (expected !null or !err)");
        }
    }

    try model.funcs.append(gpa, f);
}

fn parseArgType(s: []const u8) ?ArgType {
    if (std.mem.eql(u8, s, "str")) return .str;
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
        if (c == '(' or c == ')' or c == ',') {
            try out.append(gpa, line[i .. i + 1]);
            i += 1;
            continue;
        }
        const start = i;
        while (i < line.len) : (i += 1) {
            const d = line[i];
            if (d == ' ' or d == '\t' or d == '\r' or d == '(' or d == ')' or d == ',') break;
        }
        try out.append(gpa, line[start..i]);
    }
}

fn fail(line_no: usize, msg: []const u8) error{SpecParse} {
    std.debug.print("apigen: parse error at line {d}: {s}\n", .{ line_no, msg });
    return error.SpecParse;
}

// ── emission: C header ────────────────────────────────────────────────────────

fn emitHeader(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    preamble: []const u8,
    model: *const Model,
) !void {
    try buf.appendSlice(gpa, preamble);

    try buf.appendSlice(gpa, "\n/* ── opaque handles ── */\n");
    for (model.opaques.items) |t| {
        try print(gpa, buf, "typedef struct nm{s} nm{s};\n", .{ t.name, t.name });
    }

    try buf.appendSlice(gpa, "\n/* ── functions ── */\n");
    for (model.funcs.items) |*f| {
        try emitHeaderProto(gpa, buf, f);
    }

    try buf.appendSlice(gpa, "\n#ifdef __cplusplus\n}\n#endif\n");
}

fn emitHeaderProto(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), f: *const Func) !void {
    // return type
    switch (f.ret) {
        .void => try buf.appendSlice(gpa, if (f.fail == .err) "int" else "void"),
        .ptr => |zt| try print(gpa, buf, "nm{s}*", .{zt}),
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
            .str => try print(gpa, buf, "const char* {s}", .{a.name}),
        }
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
    for (model.funcs.items) |*f| {
        try emitZigShim(gpa, buf, f);
    }
}

fn emitZigShim(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), f: *const Func) !void {
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
        }
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
    }
    try buf.appendSlice(gpa, " {\n");

    // call expression
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
        }
    }
    try call.appendSlice(gpa, ")");

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
                .ptr => try print(gpa, buf, "    return {s};\n", .{call.items}),
            }
        },
    }

    try buf.appendSlice(gpa, "}\n");
}

// ── emission: binding IR (JSON) ───────────────────────────────────────────────
//
// Consumed by per-language binding generators (separate repos; see
// framework/doc/binding.md). JSON so they need no Zig parser. All emitted
// strings are identifiers (ASCII alnum / '_'), so no escaping is required.
// Deterministic: entries are emitted in spec order.

fn emitJson(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), model: *const Model) !void {
    try buf.appendSlice(gpa, "{\n");

    // types
    try buf.appendSlice(gpa, "  \"types\": [");
    for (model.opaques.items, 0..) |t, idx| {
        try buf.appendSlice(gpa, if (idx == 0) "\n" else ",\n");
        try print(gpa, buf, "    {{ \"name\": \"{s}\", \"c\": \"nm{s}\", \"extends\": ", .{ t.name, t.name });
        if (t.parent) |p| {
            try print(gpa, buf, "\"{s}\"", .{p});
        } else {
            try buf.appendSlice(gpa, "null");
        }
        try buf.appendSlice(gpa, " }");
    }
    try buf.appendSlice(gpa, if (model.opaques.items.len == 0) "],\n" else "\n  ],\n");

    // callbacks (none codegen'd yet; the array is part of the contract so
    // consumers can rely on its presence). See doc/c_api_codegen.md.
    try buf.appendSlice(gpa, "  \"callbacks\": [],\n");

    // functions
    try buf.appendSlice(gpa, "  \"functions\": [");
    for (model.funcs.items, 0..) |*f, idx| {
        try buf.appendSlice(gpa, if (idx == 0) "\n" else ",\n");
        try emitJsonFunc(gpa, buf, f);
    }
    try buf.appendSlice(gpa, if (model.funcs.items.len == 0) "]\n" else "\n  ]\n");

    try buf.appendSlice(gpa, "}\n");
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
        switch (a.ty) {
            .str => try print(gpa, buf, "{{ \"name\": \"{s}\", \"type\": \"str\" }}", .{a.name}),
        }
    }
    try buf.appendSlice(gpa, "],\n");

    // ret
    switch (f.ret) {
        .void => try buf.appendSlice(gpa, "      \"ret\": { \"type\": \"void\" },\n"),
        .ptr => |zt| try print(gpa, buf, "      \"ret\": {{ \"type\": \"handle\", \"handle\": \"{s}\" }},\n", .{zt}),
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
