//! Wrapper around a render target handle. Borrowed from a Swapchain or created
//! via Device-backed APIs (future). Has no Zig-side destructor: ownership is
//! the responsibility of whoever created it on the C side.

const c = @import("c");

const RenderTarget = @This();

handle: *c.struct_nmRenderTarget,
