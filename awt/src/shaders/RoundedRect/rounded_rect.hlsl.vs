// Vertex shader for the RoundedRect program (HLSL / DX12).
// UV is expected to span [-1, 1] over the quad corners; pixel shader maps
// that to pixel-space local coordinates via `half_size`.

struct VsOut {
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

VsOut vsMain(float2 in_pos : POSITION, float2 in_uv : TEXCOORD0) {
    VsOut o;
    o.pos = float4(in_pos, 0.0, 1.0);
    o.uv = in_uv;
    return o;
}
