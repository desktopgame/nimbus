//! Nimbus AWT layer: platform abstraction over the C shim (`awt-c`).

const std = @import("std");

pub const c = @import("c");
pub const Window = @import("Window.zig");
pub const Device = @import("Device.zig");
pub const Swapchain = @import("Swapchain.zig");
pub const CommandBuffer = @import("CommandBuffer.zig");
pub const RenderTarget = @import("RenderTarget.zig");

pub const LogLevel = c.nmLogLevel;
pub const LogCallback = c.nmLogCallback;

/// Initialize the AWT backend (GLFW). Must be called once before any
/// other AWT call (apart from `backendVersion`).
pub fn init() !void {
    if (c.nmInitAwt() != 0) return error.AwtInitFailed;
}

pub fn deinit() void {
    c.nmTerminateAwt();
}

/// Pump pending events without blocking.
pub fn pollEvents() void {
    c.nmPollEvents();
}

/// Block the calling thread until at least one event arrives.
pub fn waitEvents() void {
    c.nmWaitEvents();
}

/// Backend identification string (e.g. "3.4.0 Win32 WGL ...").
/// Safe to call before `init`.
pub fn backendVersion() [:0]const u8 {
    const ptr: [*:0]const u8 = @ptrCast(c.nmGetBackendVersion());
    return std.mem.span(ptr);
}

/// Install a log callback. Pass null to restore the default stderr writer.
pub fn setLogCallback(cb: LogCallback, user_data: ?*anyopaque) void {
    c.nmSetLogCallback(cb, user_data);
}

test "backend version reports GLFW 3.4" {
    const ver = backendVersion();
    try std.testing.expect(std.mem.indexOf(u8, ver, "3.4") != null);
}
