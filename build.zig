const std = @import("std");
const third_party = @import("build/third_party.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── third-party: GLFW (vendored, built from source) ──────────
    const glfw_lib = third_party.buildGlfw(b, target, optimize);

    // ── third-party: FreeType (vendored, built from source) ──────
    const freetype_lib = third_party.buildFreeType(b, target, optimize);

    // ── third-party: zigimg (pure-Zig image decoder, module-only) ─
    const zigimg_mod = third_party.buildZigimg(b, target, optimize);

    // ── awt-c: C shim (internal only, not installed) ─────────────
    const awt_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    awt_c_mod.addIncludePath(b.path("awt-c/src"));
    awt_c_mod.addIncludePath(b.path(third_party.glfw_include));
    awt_c_mod.addIncludePath(b.path(third_party.freetype_include));

    const c_flags = &.{ "-std=c11", "-Wall", "-Wextra" };

    // Cross-platform sources.
    awt_c_mod.addCSourceFiles(.{
        .root = b.path("awt-c/src"),
        .files = &.{ "glfw_shim.c", "nm_log.c", "nm_font.c" },
        .flags = c_flags,
    });

    // Platform-specific backend.
    switch (target.result.os.tag) {
        .windows => {
            awt_c_mod.addCMacro("COBJMACROS", "");
            awt_c_mod.addCMacro("CINTERFACE", "");
            awt_c_mod.addCMacro("WIN32_LEAN_AND_MEAN", "");
            awt_c_mod.addCMacro("UNICODE", "");
            awt_c_mod.addCMacro("_UNICODE", "");
            if (optimize == .Debug) awt_c_mod.addCMacro("NM_DX12_DEBUG", "1");

            awt_c_mod.addCSourceFiles(.{
                .root = b.path("awt-c/src"),
                .files = &.{
                    "dx12_device.c",
                    "dx12_swapchain.c",
                    "dx12_command_buffer.c",
                    "dx12_render_target.c",
                    "dx12_shader.c",
                    "dx12_buffer.c",
                    "dx12_texture.c",
                    "dx12_root_signature.c",
                    "dx12_pipeline.c",
                },
                .flags = c_flags,
            });
            awt_c_mod.linkSystemLibrary("d3d12", .{});
            awt_c_mod.linkSystemLibrary("dxgi", .{});
            awt_c_mod.linkSystemLibrary("dxguid", .{});
            awt_c_mod.linkSystemLibrary("d3dcompiler_47", .{});
        },
        .macos => {
            if (optimize == .Debug) awt_c_mod.addCMacro("NM_METAL_DEBUG", "1");

            // Objective-C sources: ARC intentionally off (mirrors GLFW Cocoa).
            awt_c_mod.addCSourceFiles(.{
                .root = b.path("awt-c/src"),
                .files = &.{
                    "metal_device.m",
                    "metal_swapchain.m",
                    "metal_command_buffer.m",
                    "metal_render_target.m",
                    "metal_shader.m",
                    "metal_buffer.m",
                    "metal_texture.m",
                    "metal_root_signature.m",
                    "metal_pipeline.m",
                },
                .flags = &.{ "-fno-objc-arc", "-Wall", "-Wextra" },
            });

            awt_c_mod.linkFramework("Metal", .{});
            awt_c_mod.linkFramework("QuartzCore", .{});
            awt_c_mod.linkFramework("AppKit", .{});
            awt_c_mod.linkFramework("Foundation", .{});
        },
        else => {
            awt_c_mod.addCSourceFiles(.{
                .root = b.path("awt-c/src"),
                .files = &.{"dx12_stub.c"},
                .flags = c_flags,
            });
        },
    }

    awt_c_mod.linkLibrary(glfw_lib);
    awt_c_mod.linkLibrary(freetype_lib);

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
            .{ .name = "zigimg", .module = zigimg_mod },
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
