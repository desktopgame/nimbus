//! GPU texture. Single-mip 2D image readable from shaders.

const c = @import("c");
const Device = @import("Device.zig");
const CommandBuffer = @import("CommandBuffer.zig");

const Texture = @This();

pub const Format = enum(c_uint) {
    rgba8 = c.nmTextureFormatRGBA8,
    bgra8 = c.nmTextureFormatBGRA8,
    r8 = c.nmTextureFormatR8,
};

handle: *c.struct_nmTexture,

pub fn init(device: Device, width: i32, height: i32, format: Format) !Texture {
    const h = c.nmCreateTexture(device.handle, width, height, @intFromEnum(format)) orelse return error.TextureCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Texture) void {
    c.nmDestroyTexture(self.handle);
    self.handle = undefined;
}

pub fn upload(self: Texture, data: []const u8) void {
    c.nmUploadTexture(self.handle, data.ptr, data.len);
}

pub fn uploadRegion(self: Texture, x: i32, y: i32, width: i32, height: i32, data: []const u8, row_pitch: usize) void {
    c.nmUploadTextureRegion(self.handle, x, y, width, height, data.ptr, row_pitch);
}
