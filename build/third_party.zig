//! Vendored third-party library builds.
//!
//! Each `buildXxx` function returns a static library that consumers can
//! `linkLibrary` against. Consumers must also add the library's public
//! include directory to their own module if they want to `#include` it.

const std = @import("std");

pub const glfw_root = "vendor/glfw-3.4";
pub const glfw_include = glfw_root ++ "/include";

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
                .flags = &.{ "-std=c99", "-fobjc-arc" },
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
