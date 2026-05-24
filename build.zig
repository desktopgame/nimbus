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
                    "win32_ime.c",
                },
                .flags = c_flags,
            });
            awt_c_mod.linkSystemLibrary("d3d12", .{});
            awt_c_mod.linkSystemLibrary("dxgi", .{});
            awt_c_mod.linkSystemLibrary("dxguid", .{});
            awt_c_mod.linkSystemLibrary("d3dcompiler_47", .{});
            awt_c_mod.linkSystemLibrary("imm32", .{});
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
                    "cocoa_ime.m",
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
                .files = &.{ "dx12_stub.c", "ime_stub.c" },
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

    // ── shared snapshot scenes (used by tests AND examples/snapshot) ──
    const scenes_mod = b.createModule(.{
        .root_source_file = b.path("awt/tests/scenes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "awt", .module = awt_mod },
            .{ .name = "nimbus", .module = framework_mod },
        },
    });

    // ── examples ─────────────────────────────────────────────────
    addExample(b, "hello", framework_mod, null, target, optimize);
    addExample(b, "snapshot", framework_mod, scenes_mod, target, optimize);
    addExample(b, "widget_simple", framework_mod, null, target, optimize);
    addExample(b, "widget_menu", framework_mod, null, target, optimize);
    addExample(b, "widget_textfield", framework_mod, null, target, optimize);
    addExample(b, "widget_checkbox", framework_mod, null, target, optimize);
    addExample(b, "widget_radio", framework_mod, null, target, optimize);
    addExample(b, "widget_combobox", framework_mod, null, target, optimize);
    addExample(b, "widget_dialog", framework_mod, null, target, optimize);
    addExample(b, "widget_window", framework_mod, null, target, optimize);
    addExample(b, "widget_scroll", framework_mod, null, target, optimize);

    // ── tests ────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all unit tests");
    inline for (.{
        .{ "awt", awt_mod },
        .{ "framework", framework_mod },
    }) |entry| {
        const t = b.addTest(.{ .root_module = entry[1] });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // framework integration tests under framework/tests/ — split per
    // layout-manager so failures point at a single subject.
    inline for (.{
        "framework/tests/box_layout_test.zig",
        "framework/tests/border_layout_test.zig",
    }) |path| {
        const m = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nimbus", .module = framework_mod },
            },
        });
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── snapshot tests (golden-image comparison) ─────────────────
    const snapshot_test_mod = b.createModule(.{
        .root_source_file = b.path("awt/tests/snapshot_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "awt", .module = awt_mod },
            .{ .name = "zigimg", .module = zigimg_mod },
            .{ .name = "scenes", .module = scenes_mod },
        },
    });

    // Same test artifact is reused by `zig build test` (compare) and
    // `zig build update-snapshots` (regenerate fixtures via env var).
    const snapshot_test_exe = b.addTest(.{ .root_module = snapshot_test_mod });

    const snapshot_test_run = b.addRunArtifact(snapshot_test_exe);
    test_step.dependOn(&snapshot_test_run.step);

    const update_step = b.step(
        "update-snapshots",
        "Regenerate snapshot test fixtures from the current renderer output",
    );
    const update_run = b.addRunArtifact(snapshot_test_exe);
    update_run.setEnvironmentVariable("NIMBUS_UPDATE_SNAPSHOTS", "1");
    update_step.dependOn(&update_run.step);

    // ── framework snapshot tests (golden-image, framework widgets) ─────
    const framework_scenes_mod = b.createModule(.{
        .root_source_file = b.path("framework/tests/scenes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "awt", .module = awt_mod },
            .{ .name = "nimbus", .module = framework_mod },
        },
    });

    const framework_snapshot_test_mod = b.createModule(.{
        .root_source_file = b.path("framework/tests/snapshot_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "awt", .module = awt_mod },
            .{ .name = "zigimg", .module = zigimg_mod },
            .{ .name = "framework_scenes", .module = framework_scenes_mod },
        },
    });

    const framework_snapshot_test_exe = b.addTest(.{ .root_module = framework_snapshot_test_mod });
    test_step.dependOn(&b.addRunArtifact(framework_snapshot_test_exe).step);

    const framework_update_run = b.addRunArtifact(framework_snapshot_test_exe);
    framework_update_run.setEnvironmentVariable("NIMBUS_UPDATE_SNAPSHOTS", "1");
    update_step.dependOn(&framework_update_run.step);
}

fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    nimbus_mod: *std.Build.Module,
    scenes_mod: ?*std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "nimbus", .module = nimbus_mod }) catch unreachable;
    if (scenes_mod) |m| {
        imports.append(b.allocator, .{ .name = "scenes", .module = m }) catch unreachable;
    }

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    run_step.dependOn(&run.step);
}
