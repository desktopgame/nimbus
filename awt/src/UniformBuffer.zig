//! Single GPU buffer that serves as a per-frame ring allocator for uniform
//! blocks. All program uniforms in a frame share this one buffer, sub-allocated
//! at 256-byte boundaries (CBV alignment requirement on D3D12 and Metal).
//!
//! Lifecycle per frame:
//!   1. Acquire a command buffer (which waits for the previous submission's
//!      GPU work to complete, making it safe to overwrite uniform data).
//!   2. Call `reset()` to rewind the cursor.
//!   3. Call `push(value)` for each uniform block needed this frame; receive a
//!      `Handle` pointing into the buffer.
//!   4. Bind via `program.bindUniforms(cb, ubuf, handle)` (or
//!      `cb.bindConstantBuffer(ubuf.buffer, slot, h.offset, h.size)`).
//!
//! Because the CB pool blocks `acquire` until the previous frame is GPU-idle,
//! reusing offsets across frames is safe with no extra synchronization.

const std = @import("std");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");

const UniformBuffer = @This();

/// CBV / argument buffer alignment requirement on both D3D12 and Metal.
pub const alignment: usize = 256;

/// Range inside the underlying buffer reserved for one uniform block.
pub const Handle = struct {
    offset: usize,
    size: usize,
};

buffer: Buffer,
capacity: usize,
cursor: usize,

pub fn init(device: Device, capacity: usize) !UniformBuffer {
    return .{
        .buffer = try Buffer.init(device, capacity, .{ .constant = true }),
        .capacity = capacity,
        .cursor = 0,
    };
}

pub fn deinit(self: *UniformBuffer) void {
    self.buffer.deinit();
    self.* = undefined;
}

/// Rewind the cursor. Safe to call once per frame, *after* the new frame's
/// command buffer has been acquired (which guarantees the GPU is done with the
/// previous frame's uniform reads).
pub fn reset(self: *UniformBuffer) void {
    self.cursor = 0;
}

/// Reserve and upload one uniform block. Returns the handle for binding.
/// The size is taken from the value's compile-time type; alignment is handled
/// internally.
pub fn push(self: *UniformBuffer, value: anytype) !Handle {
    const size = @sizeOf(@TypeOf(value));
    const aligned_cursor = std.mem.alignForward(usize, self.cursor, alignment);
    if (aligned_cursor + size > self.capacity) return error.UniformBufferFull;
    self.buffer.upload(std.mem.asBytes(&value), aligned_cursor);
    self.cursor = aligned_cursor + size;
    return .{ .offset = aligned_cursor, .size = size };
}
