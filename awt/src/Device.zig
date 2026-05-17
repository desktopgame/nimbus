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

/// Block until the GPU has finished all submitted work. Call before
/// destroying resources that any in-flight command list may still reference.
pub fn waitIdle(self: Device) void {
    c.nmWaitDeviceIdle(self.handle);
}
