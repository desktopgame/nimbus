// Vertex shader for the Color program (HLSL / DX12).
// Pass-through transform: input is already in NDC.

struct VsOut {
    float4 pos : SV_Position;
};

VsOut vsMain(float2 in_pos : POSITION) {
    VsOut o;
    o.pos = float4(in_pos, 0.0, 1.0);
    return o;
}
