//! Nimbus AWT layer: platform abstraction over the C shim (`awt-c`).

const std = @import("std");

pub const c = @import("c");
pub const Window = @import("Window.zig");
pub const Device = @import("Device.zig");
pub const Swapchain = @import("Swapchain.zig");
pub const CommandBuffer = @import("CommandBuffer.zig");
pub const RenderTarget = @import("RenderTarget.zig");
pub const Shader = @import("Shader.zig");
pub const Buffer = @import("Buffer.zig");
pub const RootSignature = @import("RootSignature.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Texture = @import("Texture.zig");
pub const Image = @import("Image.zig");
pub const Font = @import("Font.zig");
pub const GlyphAtlas = @import("GlyphAtlas.zig");
pub const UniformBuffer = @import("UniformBuffer.zig");
pub const VertexRing = @import("VertexRing.zig");
pub const QuadIndexBuffer = @import("QuadIndexBuffer.zig");
pub const programs = @import("programs.zig");
pub const Graphics = @import("Graphics.zig");
pub const Event = @import("Event.zig");
pub const EventQueue = @import("EventQueue.zig");
pub const snapshot = @import("snapshot.zig");
pub const grapheme = @import("grapheme.zig");

/// Wake the UI thread blocked in `waitEvents`. Safe from any thread.
pub fn postEmptyEvent() void {
    c.nmPostEmptyEvent();
}

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

/// Block for at most `seconds` waiting for an event. Returns even if no
/// event arrived (timeout fired). Used by run loops that need to wake
/// on a future deadline (timers, caret blink).
pub fn waitEventsTimeout(seconds: f64) void {
    c.nmWaitEventsTimeout(seconds);
}

/// Seconds since `init`. Monotonic; suitable for animation / timing.
pub fn time() f64 {
    return c.nmGetTime();
}

/// Backend identification string (e.g. "3.4.0 Win32 WGL ...").
/// Safe to call before `init`.
pub fn backendVersion() [:0]const u8 {
    const ptr: [*:0]const u8 = @ptrCast(c.nmAwtBackendVersion());
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

test "Image module is reachable" {
    _ = Image;
}

test "built-in programs type-check" {
    // Force comptime generation of each program type and its Uniforms alias.
    _ = programs.Text;
    _ = programs.Text.Uniforms;
    _ = programs.Color;
    _ = programs.Color.Uniforms;
    _ = programs.Image;
    _ = programs.Image.Uniforms;
    _ = programs.Gradient;
    _ = programs.Gradient.Uniforms;
    _ = programs.RoundedRect;
    _ = programs.RoundedRect.Uniforms;
}

test {
    // Run tests in every sub-module of awt (mirrors framework/src/root.zig).
    std.testing.refAllDecls(@This());
}
