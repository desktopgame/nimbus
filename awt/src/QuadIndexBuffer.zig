//! Static index buffer pre-filled with quad indices (TL, BL, BR, TL, BR, TR
//! repeating). Shared across all draw calls that emit quads via the
//! `VertexRing`. A single draw call can render up to `max_quads` quads using
//! `drawIndexed(quad_count * 6, 0, 0)` after binding the matching VB at the
//! quad block's offset.
//!
//! `max_quads` is capped at 16383 because vertex indices are u16
//! (16383 * 4 = 65532 vertices).

const std = @import("std");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");

const QuadIndexBuffer = @This();

pub const max_supported_quads: u32 = 16383;

buffer: Buffer,
max_quads: u32,

pub fn init(allocator: std.mem.Allocator, device: Device, max_quads: u32) !QuadIndexBuffer {
    std.debug.assert(max_quads <= max_supported_quads);
    const indices = try allocator.alloc(u16, @as(usize, max_quads) * 6);
    defer allocator.free(indices);
    var q: u32 = 0;
    while (q < max_quads) : (q += 1) {
        const base: u16 = @intCast(q * 4);
        const i = q * 6;
        // CCW: TL → BL → BR (tri1), TL → BR → TR (tri2).
        indices[i + 0] = base + 0;
        indices[i + 1] = base + 1;
        indices[i + 2] = base + 2;
        indices[i + 3] = base + 0;
        indices[i + 4] = base + 2;
        indices[i + 5] = base + 3;
    }
    var buffer = try Buffer.init(device, indices.len * @sizeOf(u16), .{ .index = true });
    errdefer buffer.deinit();
    buffer.upload(std.mem.sliceAsBytes(indices), 0);
    return .{ .buffer = buffer, .max_quads = max_quads };
}

pub fn deinit(self: *QuadIndexBuffer) void {
    self.buffer.deinit();
    self.* = undefined;
}
