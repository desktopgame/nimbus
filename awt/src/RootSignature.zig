//! Root signature describing the layout of CBV / Texture bindings visible to
//! a pipeline. Static samplers (s0..s3) are always included implicitly.

const c = @import("c");
const Device = @import("Device.zig");
const Shader = @import("Shader.zig");

const RootSignature = @This();

pub const BindingType = enum(c_uint) {
    constant_buffer = c.nmRootBindingTypeConstantBuffer,
    texture = c.nmRootBindingTypeTexture,
};

pub const Binding = struct {
    type: BindingType,
    stage: Shader.Stage,
    slot: i32,
};

handle: *c.struct_nmRootSignature,

pub fn init(device: Device, bindings: []const Binding) !RootSignature {
    var stack_bindings: [16]c.nmRootBinding = undefined;
    if (bindings.len > stack_bindings.len) return error.TooManyBindings;
    for (bindings, 0..) |b, i| {
        stack_bindings[i] = .{
            .type = @intFromEnum(b.type),
            .stage = @intFromEnum(b.stage),
            .slot = b.slot,
        };
    }
    const ptr: ?[*]const c.nmRootBinding =
        if (bindings.len == 0) null else &stack_bindings;
    const h = c.nmCreateRootSignature(device.handle, ptr, @intCast(bindings.len)) orelse return error.RootSignatureCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *RootSignature) void {
    c.nmDestroyRootSignature(self.handle);
    self.handle = undefined;
}
