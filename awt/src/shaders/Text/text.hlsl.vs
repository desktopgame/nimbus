// Vertex shader for the Text program (HLSL / DX12).
// Pass-through transform: input is already in NDC; UV forwarded to PS.

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
