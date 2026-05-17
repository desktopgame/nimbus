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

// Re-exports for terse meta declarations below.
const VertexLayout = Pipeline.VertexLayout;
const Topology = Pipeline.Topology;
const BlendMode = Pipeline.BlendMode;
const Stage = Shader.Stage;

/// Generate a program type from comptime metadata.
///
/// Expected meta shape (all fields comptime-known):
///   .vertex_layout      — Pipeline.VertexLayout
///   .topology           — Pipeline.Topology (default: .triangle_list)
///   .blend              — Pipeline.BlendMode (default: .none)
///   .color_write_enable — bool (default: true)
///   .uniforms           — tuple of { stage, slot, type } (CBV bindings; optional).
///                         `type` is the CPU-side struct matching the shader's cbuffer.
///                         The first entry is exposed as `Self.Uniforms` for convenience.
///   .textures           — tuple of { stage, slot } (SRV bindings; optional)
///   .shaders            — struct of { hlsl_vs, hlsl_ps, msl_vs, msl_ps } source strings
pub fn ProgramFromMeta(comptime meta: anytype) type {
    return struct {
        vs: Shader,
        ps: Shader,
        root_signature: RootSignature,
        pipeline: Pipeline,

        const Self = @This();

        /// Convenience alias for the first uniform block's CPU-side type.
        /// `void` if the program declares no uniforms.
        pub const Uniforms = if (@hasField(@TypeOf(meta), "uniforms") and meta.uniforms.len > 0)
            meta.uniforms[0].type
        else
            void;

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
                .topology = if (@hasField(@TypeOf(meta), "topology")) meta.topology else .triangle_list,
                .blend = if (@hasField(@TypeOf(meta), "blend")) meta.blend else .none,
                .color_write_enable = if (@hasField(@TypeOf(meta), "color_write_enable")) meta.color_write_enable else true,
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
                if (!@hasField(@TypeOf(meta), "uniforms") or meta.uniforms.len == 0) {
                    @compileError("Program declares no uniforms");
                }
                break :blk meta.uniforms[0].slot;
            };
            cb.bindConstantBuffer(ubuf.buffer, slot, handle.offset, handle.size);
        }
    };
}

fn selectShader(comptime shaders: anytype, comptime stage: Stage) [:0]const u8 {
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

fn collectBindings(comptime meta: anytype) [bindingCount(meta)]RootSignature.Binding {
    var bindings: [bindingCount(meta)]RootSignature.Binding = undefined;
    var i: usize = 0;
    if (@hasField(@TypeOf(meta), "uniforms")) {
        inline for (meta.uniforms) |u| {
            bindings[i] = .{ .type = .constant_buffer, .stage = u.stage, .slot = u.slot };
            i += 1;
        }
    }
    if (@hasField(@TypeOf(meta), "textures")) {
        inline for (meta.textures) |t| {
            bindings[i] = .{ .type = .texture, .stage = t.stage, .slot = t.slot };
            i += 1;
        }
    }
    return bindings;
}

fn bindingCount(comptime meta: anytype) usize {
    var n: usize = 0;
    if (@hasField(@TypeOf(meta), "uniforms")) n += meta.uniforms.len;
    if (@hasField(@TypeOf(meta), "textures")) n += meta.textures.len;
    return n;
}

// ── Built-in programs ────────────────────────────────────────────────────

/// Text renders a single textured quad with the R channel of an R8 atlas
/// modulated by a uniform color. Input vertices are 2D NDC + UV.
pub const Text = ProgramFromMeta(.{
    .vertex_layout = VertexLayout.vertex_texcoord_2d,
    .topology = Topology.triangle_list,
    .blend = BlendMode.alpha,
    .color_write_enable = true,
    .uniforms = .{
        .{
            .stage = Stage.pixel,
            .slot = 0,
            .type = extern struct { color: [4]f32 },
        },
    },
    .textures = .{
        .{ .stage = Stage.pixel, .slot = 0 },
    },
    .shaders = .{
        .hlsl_vs = @embedFile("shaders/Text/text.hlsl.vs"),
        .hlsl_ps = @embedFile("shaders/Text/text.hlsl.ps"),
        .msl_vs  = @embedFile("shaders/Text/text.msl.vs"),
        .msl_ps  = @embedFile("shaders/Text/text.msl.ps"),
    },
});
