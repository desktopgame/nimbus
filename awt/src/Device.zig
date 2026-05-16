//! GPU device handle. One per process is typically enough; multiple is allowed.

const c = @import("c");

const Device = @This();

handle: *c.struct_nmDevice,

pub fn init() !Device {
    const h = c.nmCreateDevice() orelse return error.DeviceCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Device) void {
    c.nmDestroyDevice(self.handle);
    self.handle = undefined;
}
