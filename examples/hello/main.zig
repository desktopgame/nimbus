const std = @import("std");
const nimbus = @import("nimbus");
const awt = nimbus.awt;
const c = awt.c;

const Context = struct {
    device: *awt.Device,
    swapchain: *awt.Swapchain,
};

fn renderFrame(device: *awt.Device, swapchain: *awt.Swapchain) void {
    const cb = awt.CommandBuffer.acquire(device.*) catch return;
    defer cb.release();

    cb.begin();
    cb.bindRenderTarget(swapchain.getTarget());
    cb.clearColor(0.5, 0.7, 1.0, 1.0);
    cb.clearStencil(0);
    cb.end();
    cb.submit(device.*);
    swapchain.present();
}

fn onResize(
    _: ?*c.struct_nmWindow,
    width: c_int,
    height: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data.?));
    ctx.swapchain.resize(@intCast(width), @intCast(height)) catch {};
    renderFrame(ctx.device, ctx.swapchain);
}

fn onRefresh(
    _: ?*c.struct_nmWindow,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(user_data.?));
    renderFrame(ctx.device, ctx.swapchain);
}

pub fn main() !void {
    std.debug.print("AWT backend: {s}\n", .{awt.backendVersion()});

    try awt.init();
    defer awt.deinit();

    var device = try awt.Device.init();
    defer device.deinit();

    var window = try awt.Window.init("hello nimbus", 800, 600);
    defer window.deinit();

    var swapchain = try awt.Swapchain.init(device, window);
    defer swapchain.deinit();

    var ctx = Context{ .device = &device, .swapchain = &swapchain };
    window.setResizeCallback(onResize, &ctx);
    window.setRefreshCallback(onRefresh, &ctx);

    std.debug.print("Window opened. Close it to exit.\n", .{});
    while (!window.shouldClose()) {
        awt.pollEvents();
        renderFrame(&device, &swapchain);
    }
    std.debug.print("Bye.\n", .{});
}
