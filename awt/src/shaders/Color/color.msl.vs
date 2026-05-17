// Vertex shader for the Color program (MSL / Metal).
// Pass-through transform: input is already in NDC.

#include <metal_stdlib>
using namespace metal;

struct VsIn {
    float2 pos [[attribute(0)]];
};

struct VsOut {
    float4 pos [[position]];
};

vertex VsOut vsMain(VsIn in [[stage_in]]) {
    VsOut o;
    o.pos = float4(in.pos, 0.0, 1.0);
    return o;
}
