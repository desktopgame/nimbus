//! Decoded image backed by a GPU texture. Wraps zigimg decoding so callers
//! do not have to depend on zigimg directly.

const std = @import("std");
const zigimg = @import("zigimg");
const Device = @import("Device.zig");
const Texture = @import("Texture.zig");

const Image = @This();

texture: Texture,
width: i32,
height: i32,

/// Decode encoded image bytes (PNG / JPEG / GIF / BMP) and upload the
/// pixels to a new RGBA8 `Texture`. The decoded CPU-side pixels are freed
/// before returning; only the GPU texture remains.
///
/// `allocator` is used transiently for decode + format conversion.
pub fn fromMemory(allocator: std.mem.Allocator, device: Device, bytes: []const u8) !Image {
    var decoded = try zigimg.Image.fromMemory(allocator, bytes);
    defer decoded.deinit(allocator);
    try decoded.convert(allocator, .rgba32);

    const w: i32 = @intCast(decoded.width);
    const h: i32 = @intCast(decoded.height);

    var texture = try Texture.init(device, w, h, .rgba8);
    errdefer texture.deinit();
    texture.upload(decoded.rawBytes());

    return .{ .texture = texture, .width = w, .height = h };
}

pub fn deinit(self: *Image) void {
    self.texture.deinit();
    self.* = undefined;
}
