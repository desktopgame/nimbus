//! Per-frame ring allocator for vertex data. All Graphics draw calls in a
//! frame share this buffer, sub-allocated by byte cursor. Mirrors
//! `UniformBuffer` but for vertex storage; no alignment requirement beyond
//! the natural stride of whatever payload the caller pushes.
//!
//! Lifecycle: reset at frame start (after the new frame's command buffer is
//! acquired, which waits for the previous GPU work), then `pushBytes` each
//! quad / glyph batch and bind via `cb.bindVertexBuffer(ring.buffer, slot,
//! stride, handle.offset)`.

const std = @import("std");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");

const VertexRing = @This();

pub const Handle = struct {
    offset: usize,
    size: usize,
};

buffer: Buffer,
capacity: usize,
cursor: usize,

pub fn init(device: Device, capacity: usize) !VertexRing {
    return .{
        .buffer = try Buffer.init(device, capacity, .{ .vertex = true }),
        .capacity = capacity,
        .cursor = 0,
    };
}

pub fn deinit(self: *VertexRing) void {
    self.buffer.deinit();
    self.* = undefined;
}

pub fn reset(self: *VertexRing) void {
    self.cursor = 0;
}

pub fn pushBytes(self: *VertexRing, bytes: []const u8) !Handle {
    if (self.cursor + bytes.len > self.capacity) return error.VertexRingFull;
    self.buffer.upload(bytes, self.cursor);
    const result = Handle{ .offset = self.cursor, .size = bytes.len };
    self.cursor += bytes.len;
    return result;
}
