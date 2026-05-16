//! GPU buffer for vertex / index / constant data.

const c = @import("c");
const Device = @import("Device.zig");

const Buffer = @This();

pub const Usage = packed struct(c_uint) {
    vertex: bool = false,
    index: bool = false,
    constant: bool = false,
    _padding: u29 = 0,

    pub fn toC(self: Usage) c.nmBufferUsage {
        var out: c.nmBufferUsage = 0;
        if (self.vertex) out |= c.nmBufferUsageVertex;
        if (self.index) out |= c.nmBufferUsageIndex;
        if (self.constant) out |= c.nmBufferUsageConstant;
        return out;
    }
};

pub const IndexFormat = enum(c_uint) {
    u16 = c.nmIndexFormatU16,
    u32 = c.nmIndexFormatU32,
};

handle: *c.struct_nmBuffer,

pub fn init(device: Device, size: usize, usage: Usage) !Buffer {
    const h = c.nmCreateBuffer(device.handle, size, usage.toC())
        orelse return error.BufferCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Buffer) void {
    c.nmDestroyBuffer(self.handle);
    self.handle = undefined;
}

pub fn upload(self: Buffer, data: []const u8, offset: usize) void {
    c.nmUploadBuffer(self.handle, data.ptr, data.len, offset);
}
