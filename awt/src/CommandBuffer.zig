//! Borrowed command buffer from the device's pool. Acquire → begin → record →
//! end → submit → release. The handle remains valid only until release.

const c = @import("c");
const Device = @import("Device.zig");
const RenderTarget = @import("RenderTarget.zig");

const CommandBuffer = @This();

handle: *c.struct_nmCommandBuffer,

pub fn acquire(device: Device) !CommandBuffer {
    const h = c.nmAcquireCommandBuffer(device.handle)
        orelse return error.CommandBufferAcquireFailed;
    return .{ .handle = h };
}

pub fn release(self: CommandBuffer) void {
    c.nmReleaseCommandBuffer(self.handle);
}

pub fn begin(self: CommandBuffer) void {
    c.nmBeginCommandBuffer(self.handle);
}

pub fn end(self: CommandBuffer) void {
    c.nmEndCommandBuffer(self.handle);
}

pub fn submit(self: CommandBuffer, device: Device) void {
    c.nmSubmitCommandBuffer(self.handle, device.handle);
}

pub fn wait(self: CommandBuffer) void {
    c.nmWaitForCommandBuffer(self.handle);
}

pub fn bindRenderTarget(self: CommandBuffer, target: RenderTarget) void {
    c.nmBindRenderTarget(self.handle, target.handle);
}

pub fn setViewport(self: CommandBuffer, x: f32, y: f32, width: f32, height: f32) void {
    c.nmSetViewport(self.handle, x, y, width, height);
}

pub fn clearColor(self: CommandBuffer, r: f32, g: f32, b: f32, a: f32) void {
    c.nmClearRenderTarget(self.handle, r, g, b, a);
}

pub fn clearStencil(self: CommandBuffer, value: u8) void {
    c.nmClearStencil(self.handle, value);
}
