#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoords;
};

[[vertex]]
VertexOut vertex_main(constant float4x4 &modelProjectionMatrix [[buffer(0)]],
                      uint vertexID [[vertex_id]])
{
    float2 vertices[] = {
        { 0.0f, 0.0f },
        { 0.0f, 1.0f },
        { 1.0f, 0.0f },
        { 1.0f, 1.0f },
    };
    float2 modelPosition = vertices[vertexID];
    float2 texCoords = vertices[vertexID];

    float4 clipPosition = modelProjectionMatrix * float4(modelPosition, 0.0f, 1.0f);

    return {
        clipPosition,
        texCoords,
    };
}

[[fragment]]
half4 fragment_linear(VertexOut in [[stage_in]],
                      texture2d<half> frameTexture [[texture(0)]])
{
    constexpr sampler bilinearSampler(address::clamp_to_edge, filter::linear, mip_filter::none);
    half4 color = frameTexture.sample(bilinearSampler, in.texCoords);
    return color;
}

float3 tonemap_maxrgb(float3 x, float maxInput, float maxOutput) {
    if (maxInput <= maxOutput) {
        return x;
    }
    float a = maxOutput / (maxInput * maxInput);
    float b = 1.0f / maxOutput;
    float colorMax = max(x.r, max(x.g, x.b));
    return x * (1.0f + a * colorMax) / (1.0f + b * colorMax);
}

float3 eotf_pq(float3 x) {
    float c1 =  107 / 128.0f;
    float c2 = 2413 / 128.0f;
    float c3 = 2392 / 128.0f;
    float m1 = 1305 / 8192.0f;
    float m2 = 2523 / 32.0f;
    float3 p = pow(x, 1.0f / m2);
    float3 L = 10000.0f * pow(max(p - c1, 0.0f) / (c2 - c3 * p), 1.0f / m1);
    return L;
}

float3 tonemap_pq(float3 x, float hdrHeadroom) {
    const float referenceWhite = 203.0f;
    const float peakWhite = 10000.0f;
    return tonemap_maxrgb(eotf_pq(x) / referenceWhite, peakWhite / referenceWhite, hdrHeadroom);
}

[[fragment]]
float4 fragment_tonemap_pq(VertexOut in [[stage_in]],
                          constant float &edrHeadroom [[buffer(0)]],
                          texture2d<float> frameTexture [[texture(0)]])
{
    constexpr sampler bilinearSampler(address::clamp_to_edge, filter::linear, mip_filter::none);
    float4 color = frameTexture.sample(bilinearSampler, in.texCoords);
    color.rgb = tonemap_pq(color.rgb, edrHeadroom);
    return color;
}

float3 ootf_hlg(float3 Y, float Lw) {
    float gamma = 1.2f + 0.42f * log(Lw / 1000.0f) / log(10.0f);
    return pow(Y, gamma - 1.0f) * Y;
}

float inv_oetf_hlg(float v) {
    float a = 0.17883277f;
    float b = 1.0f - 4 * a;
    float c = 0.5f - a * log(4.0f * a);
    if (v <= 0.5f) {
        return pow(v, 2.0f) / 3.0f;
    } else {
        return (exp((v - c) / a) + b) / 12.0f;
    }
}

float3 inv_oetf_hlg(float3 v) {
    return float3(inv_oetf_hlg(v.r),
                  inv_oetf_hlg(v.g),
                  inv_oetf_hlg(v.b));
}

float3 tonemap_hlg(float3 x, float edrHeadroom) {
    const float referenceWhite = 100.0f;
    const float peakWhite = 1000.0f;

    float3 v = ootf_hlg(inv_oetf_hlg(x), peakWhite);
    v *= peakWhite / referenceWhite;
    v = tonemap_maxrgb(v, peakWhite / referenceWhite, edrHeadroom);
    return v;
};

[[fragment]]
float4 fragment_tonemap_hlg(VertexOut in [[stage_in]],
                           constant float &edrHeadroom [[buffer(0)]],
                           texture2d<float> frameTexture [[texture(0)]])
{
    constexpr sampler bilinearSampler(address::clamp_to_edge, filter::linear, mip_filter::none);
    float4 color = frameTexture.sample(bilinearSampler, in.texCoords);
    color.rgb = tonemap_hlg(color.rgb, edrHeadroom);
    return color;
}
