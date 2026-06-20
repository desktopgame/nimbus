//! Built-in shader programs. Each program is generated at comptime from a
//! single metadata literal that declares its bindings, pipeline state, and
//! per-platform shader sources. The metadata replaces what would otherwise be
//! 4 sites that have to stay in sync (HLSL, MSL, root-signature bindings,
//! CPU-side pipeline desc).

const std = @import("std");
const builtin = @import("builtin");
const Device = @import("Device.zig");
const Shader = @import("Shader.zig");
const RootSignature = @import("RootSignature.zig");
const Pipeline = @import("Pipeline.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const UniformBuffer = @import("UniformBuffer.zig");

// ── Meta types ───────────────────────────────────────────────────────────

pub const UniformDecl = struct {
    stage: Shader.Stage,
    slot: i32,
    /// CPU-side struct matching the shader's cbuffer layout. Held comptime.
    type: type,
};

pub const TextureDecl = struct {
    stage: Shader.Stage,
    slot: i32,
};

pub const ShaderSources = struct {
    hlsl_vs: [:0]const u8,
    hlsl_ps: [:0]const u8,
    msl_vs: [:0]const u8,
    msl_ps: [:0]const u8,
};

pub const ProgramMeta = struct {
    vertex_layout: Pipeline.VertexLayout,
    topology: Pipeline.Topology = .triangle_list,
    blend: Pipeline.BlendMode = .none,
    color_write_enable: bool = true,
    uniforms: []const UniformDecl = &.{},
    textures: []const TextureDecl = &.{},
    shaders: ShaderSources,
};

// ── Generator ────────────────────────────────────────────────────────────

/// Generate a program type from comptime metadata.
pub fn ProgramFromMeta(comptime meta: ProgramMeta) type {
    return struct {
        vs: Shader,
        ps: Shader,
        root_signature: RootSignature,
        pipeline: Pipeline,

        const Self = @This();

        /// CPU-side type matching the program's first uniform block.
        /// `void` if no uniforms declared.
        pub const Uniforms = if (meta.uniforms.len > 0) meta.uniforms[0].type else void;

        pub fn init(device: Device) !Self {
            const vs_src = comptime selectShader(meta.shaders, .vertex);
            const ps_src = comptime selectShader(meta.shaders, .pixel);

            var vs = try Shader.compile(.vertex, vs_src);
            errdefer vs.deinit();
            var ps = try Shader.compile(.pixel, ps_src);
            errdefer ps.deinit();

            const bindings = comptime collectBindings(meta);
            var root_signature = try RootSignature.init(device, &bindings);
            errdefer root_signature.deinit();

            var pipeline = try Pipeline.init(device, .{
                .root_signature = root_signature,
                .vertex_shader = vs,
                .pixel_shader = ps,
                .vertex_layout = meta.vertex_layout,
                .topology = meta.topology,
                .blend = meta.blend,
                .color_write_enable = meta.color_write_enable,
            });
            errdefer pipeline.deinit();

            return .{
                .vs = vs,
                .ps = ps,
                .root_signature = root_signature,
                .pipeline = pipeline,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pipeline.deinit();
            self.root_signature.deinit();
            self.ps.deinit();
            self.vs.deinit();
        }

        /// Bind the pipeline. Textures and uniforms still need to be bound
        /// separately via CommandBuffer.bindTexture / .bindConstantBuffer or
        /// via the program-aware helpers `bindUniforms`.
        pub fn bind(self: Self, cb: CommandBuffer) void {
            cb.bindPipeline(self.pipeline);
        }

        /// Bind a uniform block from a shared UniformBuffer at the slot this
        /// program declared in its metadata.
        pub fn bindUniforms(self: Self, cb: CommandBuffer, ubuf: UniformBuffer, handle: UniformBuffer.Handle) void {
            _ = self;
            const slot: i32 = comptime blk: {
                if (meta.uniforms.len == 0) {
                    @compileError("Program declares no uniforms");
                }
                break :blk meta.uniforms[0].slot;
            };
            cb.bindConstantBuffer(ubuf.buffer, slot, handle.offset, handle.size);
        }
    };
}

fn selectShader(comptime shaders: ShaderSources, comptime stage: Shader.Stage) [:0]const u8 {
    return switch (builtin.target.os.tag) {
        .macos => switch (stage) {
            .vertex => shaders.msl_vs,
            .pixel => shaders.msl_ps,
        },
        else => switch (stage) {
            .vertex => shaders.hlsl_vs,
            .pixel => shaders.hlsl_ps,
        },
    };
}

fn collectBindings(comptime meta: ProgramMeta) [meta.uniforms.len + meta.textures.len]RootSignature.Binding {
    var bindings: [meta.uniforms.len + meta.textures.len]RootSignature.Binding = undefined;
    var i: usize = 0;
    inline for (meta.uniforms) |u| {
        bindings[i] = .{ .type = .constant_buffer, .stage = u.stage, .slot = u.slot };
        i += 1;
    }
    inline for (meta.textures) |t| {
        bindings[i] = .{ .type = .texture, .stage = t.stage, .slot = t.slot };
        i += 1;
    }
    return bindings;
}

// ── Built-in programs ────────────────────────────────────────────────────

/// Text renders a single textured quad with the R channel of an R8 atlas
/// modulated by a uniform color. Input vertices are 2D NDC + UV.
pub const Text = ProgramFromMeta(.{
    .vertex_layout = .vertex_texcoord_2d,
    .blend = .alpha,
    .uniforms = &.{
        .{
            .stage = .pixel,
            .slot = 0,
            .type = extern struct { color: [4]f32 },
        },
    },
    .textures = &.{
        .{ .stage = .pixel, .slot = 0 },
    },
    .shaders = .{
        .hlsl_vs = @embedFile("shaders/Text/text.hlsl.vs"),
        .hlsl_ps = @embedFile("shaders/Text/text.hlsl.ps"),
        .msl_vs = @embedFile("shaders/Text/text.msl.vs"),
        .msl_ps = @embedFile("shaders/Text/text.msl.ps"),
    },
});

/// Color renders flat-filled quads in a uniform RGBA color. No texture.
/// Used for widget backgrounds, panels, separators, scrollbar tracks, etc.
pub const Color = ProgramFromMeta(.{
    .vertex_layout = .vertex_2d,
    .blend = .alpha,
    .uniforms = &.{
        .{
            .stage = .pixel,
            .slot = 0,
            .type = extern struct { color: [4]f32 },
        },
    },
    .shaders = .{
        .hlsl_vs = @embedFile("shaders/Color/color.hlsl.vs"),
        .hlsl_ps = @embedFile("shaders/Color/color.hlsl.ps"),
        .msl_vs = @embedFile("shaders/Color/color.msl.vs"),
        .msl_ps = @embedFile("shaders/Color/color.msl.ps"),
    },
});

/// Image renders an RGBA texture onto a 2D quad, modulated by a uniform tint.
/// For untinted display pass tint = (1, 1, 1, 1). Used for icons (checkbox,
/// radio, arrows), user-provided images, and photos.
pub const Image = ProgramFromMeta(.{
    .vertex_layout = .vertex_texcoord_2d,
    .blend = .alpha,
    .uniforms = &.{
        .{
            .stage = .pixel,
            .slot = 0,
            .type = extern struct { tint: [4]f32 },
        },
    },
    .textures = &.{
        .{ .stage = .pixel, .slot = 0 },
    },
    .shaders = .{
        .hlsl_vs = @embedFile("shaders/Image/image.hlsl.vs"),
        .hlsl_ps = @embedFile("shaders/Image/image.hlsl.ps"),
        .msl_vs = @embedFile("shaders/Image/image.msl.vs"),
        .msl_ps = @embedFile("shaders/Image/image.msl.ps"),
    },
});

/// Gradient renders a 2-stop vertical linear gradient over a 2D quad.
/// Quad UV y=0 maps to color0 (top), and y=1 maps to color1 (bottom).
pub const Gradient = ProgramFromMeta(.{
    .vertex_layout = .vertex_texcoord_2d,
    .blend = .alpha,
    .uniforms = &.{
        .{
            .stage = .pixel,
            .slot = 0,
            .type = extern struct {
                color0: [4]f32,
                color1: [4]f32,
            },
        },
    },
    .shaders = .{
        .hlsl_vs = @embedFile("shaders/Gradient/gradient.hlsl.vs"),
        .hlsl_ps = @embedFile("shaders/Gradient/gradient.hlsl.ps"),
        .msl_vs = @embedFile("shaders/Gradient/gradient.msl.vs"),
        .msl_ps = @embedFile("shaders/Gradient/gradient.msl.ps"),
    },
});

/// RoundedRect is a signed-distance-field shape program. One pipeline covers
/// rounded rectangles, circles, and their outlines:
///
///   filled rounded rect → corner_radius > 0, thickness = 0
///   rect outline         → corner_radius = 0, thickness > 0
///   filled circle        → corner_radius = min(half_size.x, half_size.y), thickness = 0
///   circle outline       → same as filled circle, thickness > 0
///
/// Quad vertices are positioned at the shape's bounding box in NDC, with UV
/// spanning [-1, 1]. The shader does the SDF math in pixel space, so AA is
/// resolution-independent within a 1-pixel transition band.
pub const RoundedRect = ProgramFromMeta(.{
    .vertex_layout = .vertex_texcoord_2d,
    .blend = .alpha,
    .uniforms = &.{
        .{
            .stage = .pixel,
            .slot = 0,
            .type = extern struct {
                color: [4]f32,
                half_size: [2]f32,
                corner_radius: f32,
                thickness: f32,
            },
        },
    },
    .shaders = .{
        .hlsl_vs = @embedFile("shaders/RoundedRect/rounded_rect.hlsl.vs"),
        .hlsl_ps = @embedFile("shaders/RoundedRect/rounded_rect.hlsl.ps"),
        .msl_vs = @embedFile("shaders/RoundedRect/rounded_rect.msl.vs"),
        .msl_ps = @embedFile("shaders/RoundedRect/rounded_rect.msl.ps"),
    },
});
