//! Per-window swapchain. Owns its back buffer render targets; resizing or
//! destroying the swapchain invalidates any RenderTarget obtained from it.

const c = @import("c");
const Device = @import("Device.zig");
const Window = @import("Window.zig");
const RenderTarget = @import("RenderTarget.zig");

const Swapchain = @This();

handle: *c.struct_nmSwapchain,

pub fn init(device: Device, window: Window) !Swapchain {
    const h = c.nmCreateSwapchain(device.handle, window.handle) orelse return error.SwapchainCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Swapchain) void {
    c.nmDestroySwapchain(self.handle);
    self.handle = undefined;
}

pub fn resize(self: Swapchain, width: i32, height: i32) !void {
    if (c.nmResizeSwapchain(self.handle, width, height) != 0) {
        return error.SwapchainResizeFailed;
    }
}

pub fn getTarget(self: Swapchain) RenderTarget {
    const h = c.nmGetSwapchainTarget(self.handle).?;
    return RenderTarget.fromBorrowed(h);
}

pub fn present(self: Swapchain) void {
    c.nmPresentSwapchain(self.handle);
}
