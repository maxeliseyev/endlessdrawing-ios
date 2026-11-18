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

static float analyticCircle(CircleVarying in) {
    float distance = length(in.delta);
    return clamp((in.radius - distance) / max(fwidth(distance), 1e-5f) + 0.5f, 0.0f, 1.0f);
}

fragment float circleCoverage(CircleVarying in [[stage_in]]) { return analyticCircle(in); }

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

// Single-pass ink: per stroke, geometry raises a coverage attachment (max = union, never a sum),
// one bounds triangle reads it through framebuffer fetch and composites opacity once, another resets it.
struct InkCoverage { float coverage [[color(1)]]; };
struct InkOutput { float4 color [[color(0)]]; float coverage [[color(1)]]; };

fragment InkCoverage solidCoverageInk() { return { 1.0f }; }

fragment InkCoverage circleCoverageInk(CircleVarying in [[stage_in]]) {
    return { analyticCircle(in) };
}

/// rect = (x0, y0, x1, y1) in normalized device coordinates; callers scissor to the rect.
vertex float4 boundsTriangle(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    // One oversized triangle: no internal edge, so every covered sample is shaded exactly once.
    constexpr float2 corners[] = { {0,0}, {2,0}, {0,2} };
    return float4(rect.xy + (rect.zw - rect.xy) * corners[id], 0, 1);
}

// Reads coverage only. The reset is a separate draw: a reset written by this function at pixel rate
// would also clear samples whose ink it has not composited (observed on Apple GPUs).
fragment float4 compositeInkFetch(float coverage [[color(1)]], constant float4 &color [[buffer(0)]]) {
    float alpha = coverage * color.a;
    return float4(color.rgb * alpha, alpha);
}

fragment InkCoverage resetCoverage() { return { 0.0f }; }

fragment InkOutput copyCanvasInk(QuadVarying in [[stage_in]], texture2d<float> canvas [[texture(0)]]) {
    constexpr sampler sample(filter::nearest, address::clamp_to_edge);
    return { canvas.sample(sample, in.uv), 0.0f };
}

// Raster tiles: a textured rect in NDC; nearest at the exact scale (1:1 whole pixels), linear while zooming.
struct TileVarying { float4 position [[position]]; float2 uv; };

vertex TileVarying tileQuad(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    constexpr float2 corners[] = { {0,0}, {1,0}, {0,1}, {0,1}, {1,0}, {1,1} };
    float2 corner = corners[id];
    return { float4(mix(rect.xy, rect.zw, corner), 0, 1), corner };
}

static float4 sampleTile(TileVarying in, texture2d<float> tile, uint linear) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler smooth(filter::linear, address::clamp_to_edge);
    return linear != 0 ? tile.sample(smooth, in.uv) : tile.sample(nearest, in.uv);
}

fragment float4 tileCopy(TileVarying in [[stage_in]], texture2d<float> tile [[texture(0)]],
                         constant uint &linear [[buffer(0)]]) {
    return sampleTile(in, tile, linear);
}

fragment InkOutput tileCopyInk(TileVarying in [[stage_in]], texture2d<float> tile [[texture(0)]],
                               constant uint &linear [[buffer(0)]]) {
    return { sampleTile(in, tile, linear), 0.0f };
}
