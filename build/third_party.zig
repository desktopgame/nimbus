//! Vendored third-party library builds.
//!
//! Each `buildXxx` function returns a static library that consumers can
//! `linkLibrary` against. Consumers must also add the library's public
//! include directory to their own module if they want to `#include` it.

const std = @import("std");

pub const glfw_root = "vendor/glfw-3.4";
pub const glfw_include = glfw_root ++ "/include";

pub const freetype_root = "vendor/freetype-2.14.3";
pub const freetype_include = freetype_root ++ "/include";

pub const zigimg_root = "vendor/zigimg-zigimg_zig_0.16.0";
pub const zigimg_source = zigimg_root ++ "/zigimg.zig";

/// Build GLFW 3.4 as a static library. Platform support:
/// - Windows: Win32 backend
/// - macOS:   Cocoa backend
/// - Linux:   X11 backend (Wayland intentionally not built yet)
pub fn buildGlfw(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Public + private include paths (private "src" is needed by GLFW's own .c files)
    mod.addIncludePath(b.path(glfw_root ++ "/include"));
    mod.addIncludePath(b.path(glfw_root ++ "/src"));

    // Sources shared by every backend, including the always-built null backend.
    const common_sources: []const []const u8 = &.{
        "src/context.c",
        "src/init.c",
        "src/input.c",
        "src/monitor.c",
        "src/platform.c",
        "src/vulkan.c",
        "src/window.c",
        "src/egl_context.c",
        "src/osmesa_context.c",
        "src/null_init.c",
        "src/null_monitor.c",
        "src/null_window.c",
        "src/null_joystick.c",
    };

    switch (target.result.os.tag) {
        .windows => {
            mod.addCMacro("_GLFW_WIN32", "");
            mod.addCMacro("UNICODE", "");
            mod.addCMacro("_UNICODE", "");

            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = common_sources,
                .flags = &.{"-std=c99"},
            });
            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = &.{
                    // OS-level time/thread/module
                    "src/win32_module.c",
                    "src/win32_time.c",
                    "src/win32_thread.c",
                    // Win32 backend
                    "src/win32_init.c",
                    "src/win32_joystick.c",
                    "src/win32_monitor.c",
                    "src/win32_window.c",
                    "src/wgl_context.c",
                },
                .flags = &.{"-std=c99"},
            });

            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("shell32", .{});
        },

        .macos => {
            mod.addCMacro("_GLFW_COCOA", "");

            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = common_sources,
                .flags = &.{"-std=c99"},
            });
            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = &.{
                    "src/cocoa_time.c",
                    "src/posix_module.c",
                    "src/posix_thread.c",
                },
                .flags = &.{"-std=c99"},
            });
            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = &.{
                    "src/cocoa_init.m",
                    "src/cocoa_joystick.m",
                    "src/cocoa_monitor.m",
                    "src/cocoa_window.m",
                    "src/nsgl_context.m",
                },
                // NOTE: GLFW is written with manual retain/release; do NOT enable ARC.
                .flags = &.{"-std=c99"},
            });

            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("IOKit", .{});
            mod.linkFramework("CoreFoundation", .{});
        },

        .linux => {
            mod.addCMacro("_GLFW_X11", "");
            mod.addCMacro("_DEFAULT_SOURCE", "");

            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = common_sources,
                .flags = &.{"-std=c99"},
            });
            mod.addCSourceFiles(.{
                .root = b.path(glfw_root),
                .files = &.{
                    "src/posix_module.c",
                    "src/posix_time.c",
                    "src/posix_thread.c",
                    "src/posix_poll.c",
                    "src/linux_joystick.c",
                    "src/x11_init.c",
                    "src/x11_monitor.c",
                    "src/x11_window.c",
                    "src/xkb_unicode.c",
                    "src/glx_context.c",
                },
                .flags = &.{"-std=c99"},
            });

            // X11 dev packages must be installed on the host
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("Xrandr", .{});
            mod.linkSystemLibrary("Xinerama", .{});
            mod.linkSystemLibrary("Xcursor", .{});
            mod.linkSystemLibrary("Xi", .{});
            mod.linkSystemLibrary("Xext", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("rt", .{});
            mod.linkSystemLibrary("dl", .{});
        },

        else => @panic("buildGlfw: unsupported OS"),
    }

    return b.addLibrary(.{
        .name = "glfw",
        .linkage = .static,
        .root_module = mod,
    });
}

/// Build FreeType 2.14.3 as a static library.
/// Uses the default `ftoption.h` / `ftmodule.h` (all standard modules enabled).
/// Validation modules (`gxvalid`, `otvalid`) and the optional cache (`ftcache`)
/// are excluded. SVG glyphs compile in but render as no-ops unless the user
/// installs SVG hooks (FreeType design — no external SVG dependency required).
pub fn buildFreeType(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addIncludePath(b.path(freetype_include));
    mod.addCMacro("FT2_BUILD_LIBRARY", "");

    const flags: []const []const u8 = &.{"-std=c99"};

    // Base components (cross-platform). ftmac.c is intentionally omitted
    // because the default ftsystem.c works on macOS too; ftmac.c is for
    // resource-fork font files which we don't need.
    mod.addCSourceFiles(.{
        .root = b.path(freetype_root),
        .files = &.{
            "src/base/ftbase.c",
            "src/base/ftbbox.c",
            "src/base/ftbdf.c",
            "src/base/ftbitmap.c",
            "src/base/ftcid.c",
            "src/base/ftdebug.c",
            "src/base/ftfstype.c",
            "src/base/ftgasp.c",
            "src/base/ftglyph.c",
            "src/base/ftinit.c",
            "src/base/ftmm.c",
            "src/base/ftpatent.c",
            "src/base/ftpfr.c",
            "src/base/ftstroke.c",
            "src/base/ftsynth.c",
            "src/base/ftsystem.c",
            "src/base/fttype1.c",
            "src/base/ftwinfnt.c",
        },
        .flags = flags,
    });

    // Font drivers and rasterizers (one aggregator .c per module).
    mod.addCSourceFiles(.{
        .root = b.path(freetype_root),
        .files = &.{
            "src/autofit/autofit.c",
            "src/bdf/bdf.c",
            "src/cff/cff.c",
            "src/cid/type1cid.c",
            "src/gzip/ftgzip.c",
            "src/lzw/ftlzw.c",
            "src/pcf/pcf.c",
            "src/pfr/pfr.c",
            "src/psaux/psaux.c",
            "src/pshinter/pshinter.c",
            "src/psnames/psnames.c",
            "src/raster/raster.c",
            "src/sdf/sdf.c",
            "src/sfnt/sfnt.c",
            "src/smooth/smooth.c",
            "src/svg/svg.c",
            "src/truetype/truetype.c",
            "src/type1/type1.c",
            "src/type42/type42.c",
            "src/winfonts/winfnt.c",
        },
        .flags = flags,
    });

    return b.addLibrary(.{
        .name = "freetype",
        .linkage = .static,
        .root_module = mod,
    });
}

/// Create the zigimg Zig module. Pure Zig — no C compile or link step needed,
/// consumers just add the returned module to their `imports`.
pub fn buildZigimg(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(zigimg_source),
        .target = target,
        .optimize = optimize,
    });
    // zigimg's own code does `@import("zigimg")` for some cross-module refs.
    mod.addImport("zigimg", mod);
    return mod;
}
