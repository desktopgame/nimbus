//! Graphics pipeline state object: shader pair + vertex layout + blend / stencil
//! / topology / write-mask, all bound to a root signature.

const c = @import("c");
const Device = @import("Device.zig");
const Shader = @import("Shader.zig");
const RootSignature = @import("RootSignature.zig");

const Pipeline = @This();

pub const VertexLayout = enum(c_uint) {
    vertex_2d = c.nmVertexLayoutVertex2D,
    vertex_texcoord_2d = c.nmVertexLayoutVertexTexCoord2D,
};

pub const Topology = enum(c_uint) {
    triangle_list = c.nmPrimitiveTopologyTriangleList,
    line_list = c.nmPrimitiveTopologyLineList,
    point_list = c.nmPrimitiveTopologyPointList,
};

pub const BlendMode = enum(c_uint) {
    none = c.nmBlendModeNone,
    alpha = c.nmBlendModeAlpha,
    premultiplied_alpha = c.nmBlendModePremultipliedAlpha,
};

pub const StencilOp = enum(c_uint) {
    keep = c.nmStencilOpKeep,
    zero = c.nmStencilOpZero,
    replace = c.nmStencilOpReplace,
    increment_sat = c.nmStencilOpIncrementSat,
    decrement_sat = c.nmStencilOpDecrementSat,
    invert = c.nmStencilOpInvert,
    increment_wrap = c.nmStencilOpIncrementWrap,
    decrement_wrap = c.nmStencilOpDecrementWrap,
};

pub const CompareFunc = enum(c_uint) {
    never = c.nmCompareFuncNever,
    less = c.nmCompareFuncLess,
    equal = c.nmCompareFuncEqual,
    less_equal = c.nmCompareFuncLessEqual,
    greater = c.nmCompareFuncGreater,
    not_equal = c.nmCompareFuncNotEqual,
    greater_equal = c.nmCompareFuncGreaterEqual,
    always = c.nmCompareFuncAlways,
};

pub const StencilState = struct {
    enable: bool = false,
    fail_op: StencilOp = .keep,
    depth_fail_op: StencilOp = .keep,
    pass_op: StencilOp = .keep,
    compare_func: CompareFunc = .always,
    read_mask: u8 = 0xFF,
    write_mask: u8 = 0xFF,
};

pub const Desc = struct {
    root_signature: RootSignature,
    vertex_shader: Shader,
    pixel_shader: Shader,
    vertex_layout: VertexLayout,
    topology: Topology = .triangle_list,
    blend: BlendMode = .none,
    stencil: StencilState = .{},
    color_write_enable: bool = true,
};

handle: *c.struct_nmPipeline,

pub fn init(device: Device, desc: Desc) !Pipeline {
    var c_desc: c.nmPipelineDesc = .{
        .root_signature = desc.root_signature.handle,
        .vertex_shader = desc.vertex_shader.handle,
        .pixel_shader = desc.pixel_shader.handle,
        .vertex_layout = @intFromEnum(desc.vertex_layout),
        .topology = @intFromEnum(desc.topology),
        .blend = @intFromEnum(desc.blend),
        .stencil = .{
            .enable = desc.stencil.enable,
            .fail_op = @intFromEnum(desc.stencil.fail_op),
            .depth_fail_op = @intFromEnum(desc.stencil.depth_fail_op),
            .pass_op = @intFromEnum(desc.stencil.pass_op),
            .compare_func = @intFromEnum(desc.stencil.compare_func),
            .read_mask = desc.stencil.read_mask,
            .write_mask = desc.stencil.write_mask,
        },
        .color_write_enable = desc.color_write_enable,
    };
    const h = c.nmCreatePipeline(device.handle, &c_desc) orelse return error.PipelineCreateFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Pipeline) void {
    c.nmDestroyPipeline(self.handle);
    self.handle = undefined;
}
