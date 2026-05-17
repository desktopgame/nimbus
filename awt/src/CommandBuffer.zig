//! Borrowed command buffer from the device's pool. Acquire → begin → record →
//! end → submit → release. The handle remains valid only until release.

const c = @import("c");
const Device = @import("Device.zig");
const RenderTarget = @import("RenderTarget.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const Texture = @import("Texture.zig");

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

pub fn bindPipeline(self: CommandBuffer, pipeline: Pipeline) void {
    c.nmBindPipeline(self.handle, pipeline.handle);
}

pub fn setStencilRef(self: CommandBuffer, value: u32) void {
    c.nmSetStencilRef(self.handle, value);
}

pub fn bindVertexBuffer(self: CommandBuffer, buf: Buffer, slot: i32, stride: usize, offset: usize) void {
    c.nmBindVertexBuffer(self.handle, buf.handle, slot, stride, offset);
}

pub fn bindIndexBuffer(self: CommandBuffer, buf: Buffer, fmt: Buffer.IndexFormat, offset: usize) void {
    c.nmBindIndexBuffer(self.handle, buf.handle, @intFromEnum(fmt), offset);
}

pub fn bindConstantBuffer(self: CommandBuffer, buf: Buffer, slot: i32, offset: usize, size: usize) void {
    c.nmBindConstantBuffer(self.handle, buf.handle, slot, offset, size);
}

pub fn bindTexture(self: CommandBuffer, texture: Texture, slot: i32) void {
    c.nmBindTexture(self.handle, texture.handle, slot);
}

pub fn draw(self: CommandBuffer, vertex_count: i32, start_vertex: i32) void {
    c.nmDraw(self.handle, vertex_count, start_vertex);
}

pub fn drawIndexed(self: CommandBuffer, index_count: i32, start_index: i32, base_vertex: i32) void {
    c.nmDrawIndexed(self.handle, index_count, start_index, base_vertex);
}
