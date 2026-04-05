#include <metal_stdlib>
using namespace metal;

struct PreviewUniforms {
    float2 resolution;
    float time;
    float intensity;
    float4 tint;
    float2 origin;
    uint useBands;
};

struct RasterizerData {
    float4 position [[position]];
    float2 uv;
};

vertex RasterizerData previewVertex(uint vertexID [[vertex_id]],
                                    constant PreviewUniforms& uniforms [[buffer(0)]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2(1.0, -1.0),
        float2(-1.0, 1.0),
        float2(1.0, 1.0)
    };

    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    RasterizerData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 previewFragment(RasterizerData in [[stage_in]],
                                constant PreviewUniforms& uniforms [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 centered = uv - uniforms.origin;
    float distanceField = length(centered);
    float ripples = sin(distanceField * 28.0 - uniforms.time * 2.8);
    float bands = uniforms.useBands == 1 ? smoothstep(-0.15, 0.85, ripples) : ripples * 0.5 + 0.5;
    float glow = exp(-distanceField * (5.0 - uniforms.intensity * 2.0));
    float scan = 0.92 + 0.08 * sin((uv.y + uniforms.time * 0.2) * uniforms.resolution.y * 0.12);
    float3 base = mix(float3(0.03, 0.04, 0.08), uniforms.tint.xyz, bands * glow * scan);
    float sparks = smoothstep(0.95, 1.0, fract(sin(dot(uv + uniforms.time, float2(91.7, 13.3))) * 43758.5453));
    return float4(base + sparks * uniforms.intensity * 0.25, 1.0);
}
