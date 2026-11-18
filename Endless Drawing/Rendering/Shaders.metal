#include <metal_stdlib>
using namespace metal;

struct Projection {
    float2 translation;
    float2 viewport;
    float2 zoom;
    float2 pixelWorld;
};

float4 project(float2 local, constant Projection &p) {
    float2 screen = local * p.zoom + p.translation;
    return float4(screen.x / p.viewport.x * 2 - 1, 1 - screen.y / p.viewport.y * 2, 0, 1);
}

vertex float4 roundMesh(uint id [[vertex_id]], device const float2 *points [[buffer(0)]],
                        constant Projection &p [[buffer(1)]]) {
    return project(points[id], p);
}

fragment float solidCoverage() { return 1; }

struct CircleInstance { float2 center; float radius; float padding; };
struct CircleVarying {
    float4 position [[position]];
    float2 delta;
    float radius [[flat]];
};

vertex CircleVarying roundCircle(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                device const CircleInstance *circles [[buffer(0)]],
                                constant Projection &p [[buffer(1)]]) {
    constexpr float2 corners[] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
    CircleInstance circle = circles[instanceID];
    float2 delta = corners[vertexID] * (circle.radius + p.pixelWorld);
    return { project(circle.center + delta, p), delta, circle.radius };
}

fragment float circleCoverage(CircleVarying in [[stage_in]]) {
    float distance = length(in.delta);
    return clamp((in.radius - distance) / max(fwidth(distance), 1e-5f) + 0.5f, 0.0f, 1.0f);
}

struct QuadVarying { float4 position [[position]]; float2 uv; };
vertex QuadVarying screenQuad(uint id [[vertex_id]]) {
    constexpr float2 points[] = { {-1,1}, {1,1}, {-1,-1}, {-1,-1}, {1,1}, {1,-1} };
    float2 point = points[id];
    return { float4(point, 0, 1), float2((point.x + 1) / 2, (1 - point.y) / 2) };
}

fragment float4 compositeInk(QuadVarying in [[stage_in]], texture2d<float> coverage [[texture(0)]],
                             constant float4 &color [[buffer(0)]]) {
    constexpr sampler sample(filter::nearest, address::clamp_to_edge);
    float alpha = coverage.sample(sample, in.uv).r * color.a;
    return float4(color.rgb * alpha, alpha);
}

fragment float4 copyCanvas(QuadVarying in [[stage_in]], texture2d<float> canvas [[texture(0)]]) {
    constexpr sampler sample(filter::nearest, address::clamp_to_edge);
    return canvas.sample(sample, in.uv);
}
