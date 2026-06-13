//! Wrapper around a render target handle. Borrowed from a Swapchain or
//! created via `create`. Only RTs returned from `create` should have `deinit`
//! called on them.

const std = @import("std");
const c = @import("c");
const zigimg = @import("zigimg");
const Device = @import("Device.zig");

const RenderTarget = @This();

handle: *c.struct_nmRenderTarget,

/// Create an offscreen render target with the given dimensions. Caller must
/// `deinit` it.
pub fn create(device: Device, width: i32, height: i32) !RenderTarget {
    const h = c.nmCreateRenderTarget(device.handle, width, height) orelse return error.RenderTargetCreateFailed;
    return .{ .handle = h };
}

/// Destroy an owned render target. Only valid on the value returned from
/// `create`; calling on a swapchain-borrowed RT is UB.
pub fn deinit(self: *RenderTarget) void {
    c.nmDestroyRenderTarget(self.handle);
    self.handle = undefined;
}

/// Wrap an existing raw handle (typically obtained from `Swapchain.getTarget`).
/// The wrapper does not take ownership; do not call `deinit` on the result.
pub fn fromBorrowed(handle: *c.struct_nmRenderTarget) RenderTarget {
    return .{ .handle = handle };
}

/// Read back the contents into `out_rgba` as tightly-packed RGBA8.
/// `out_rgba.len` must be at least `width * height * 4`. Blocking.
pub fn readback(self: RenderTarget, width: i32, height: i32, out_rgba: []u8) !void {
    const required: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    std.debug.assert(out_rgba.len >= required);
    if (c.nmReadbackRenderTarget(self.handle, out_rgba.ptr, out_rgba.len) != 0) {
        return error.ReadbackFailed;
    }
}

/// Read back the contents and write them as a PNG file to `path`.
/// `allocator` is used transiently for the readback buffer and the encoder.
pub fn readbackToPng(
    self: RenderTarget,
    allocator: std.mem.Allocator,
    io: std.Io,
    width: i32,
    height: i32,
    path: []const u8,
) !void {
    const w_usize: usize = @intCast(width);
    const h_usize: usize = @intCast(height);
    const byte_count = w_usize * h_usize * 4;

    const buf = try allocator.alloc(u8, byte_count);
    defer allocator.free(buf);

    try self.readback(width, height, buf);

    var img = try zigimg.Image.fromRawPixels(allocator, w_usize, h_usize, buf, .rgba32);
    defer img.deinit(allocator);

    var write_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try img.writeToFilePath(allocator, io, path, write_buffer[0..], .{ .png = .{} });
}
