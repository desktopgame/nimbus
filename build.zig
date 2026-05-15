const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── awt-c: C shim (internal only, not installed) ─────────────
    const awt_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    awt_c_mod.addIncludePath(b.path("awt-c/src"));
    awt_c_mod.addCSourceFile(.{
        .file = b.path("awt-c/src/core.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });

    const awt_c_lib = b.addLibrary(.{
        .name = "nimbus_awt_c",
        .linkage = .static,
        .root_module = awt_c_mod,
    });

    // ── translate-c: awt-c/src/internal.h → Zig bindings ─────────
    const internal_translate = b.addTranslateC(.{
        .root_source_file = b.path("awt-c/src/internal.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_bindings = internal_translate.createModule();

    // ── awt: internal Zig module ─────────────────────────────────
    const awt_mod = b.createModule(.{
        .root_source_file = b.path("awt/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_bindings },
        },
    });
    awt_mod.linkLibrary(awt_c_lib);

    // ── framework: public "nimbus" module ────────────────────────
    const framework_mod = b.addModule("nimbus", .{
        .root_source_file = b.path("framework/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "awt", .module = awt_mod },
        },
    });

    // ── public C ABI shared lib: libnimbus ───────────────────────
    const cabi_mod = b.createModule(.{
        .root_source_file = b.path("framework/src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nimbus", .module = framework_mod },
            .{ .name = "awt", .module = awt_mod },
        },
    });
    const libnimbus = b.addLibrary(.{
        .name = "nimbus",
        .linkage = .dynamic,
        .root_module = cabi_mod,
    });
    b.installArtifact(libnimbus);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    // ── examples ─────────────────────────────────────────────────
    addExample(b, "hello", framework_mod, target, optimize);

    // ── tests ────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all unit tests");
    inline for (.{
        .{ "awt", awt_mod },
        .{ "framework", framework_mod },
    }) |entry| {
        const t = b.addTest(.{ .root_module = entry[1] });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    nimbus_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nimbus", .module = nimbus_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
