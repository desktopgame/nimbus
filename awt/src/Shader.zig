//! Compiled shader (vertex or pixel). Wraps a bytecode blob.

const c = @import("c");

const Shader = @This();

pub const Stage = enum(c_uint) {
    vertex = c.nmShaderStageVertex,
    pixel  = c.nmShaderStagePixel,
};

handle: *c.struct_nmShader,

pub fn compile(stage: Stage, source: [:0]const u8) !Shader {
    const h = c.nmCompileShader(@intFromEnum(stage), source.ptr)
        orelse return error.ShaderCompileFailed;
    return .{ .handle = h };
}

pub fn deinit(self: *Shader) void {
    c.nmDestroyShader(self.handle);
    self.handle = undefined;
}
