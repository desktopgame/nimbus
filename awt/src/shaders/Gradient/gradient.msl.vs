// Vertex shader for the Gradient program (MSL / Metal).
// Pass-through transform: input is already in NDC; UV forwarded to FS.

#include <metal_stdlib>
using namespace metal;

struct VsIn {
    float2 pos [[attribute(0)]];
    float2 uv  [[attribute(1)]];
};

struct VsOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VsOut vsMain(VsIn in [[stage_in]]) {
    VsOut o;
    o.pos = float4(in.pos, 0.0, 1.0);
    o.uv = in.uv;
    return o;
}

