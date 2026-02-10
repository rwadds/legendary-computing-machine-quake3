//
//  Shaders.metal
//  mac.quake3
//

#include <metal_stdlib>
#include <simd/simd.h>

#import "ShaderTypes.h"

using namespace metal;

// MARK: - Original template shaders (kept for backward compatibility)

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);
    half4 colorSample = colorMap.sample(colorSampler, in.texCoord.xy);
    return float4(colorSample);
}

// MARK: - Q3 BSP World Shaders

// Q3 vertex input (matches Q3GPUVertex struct in Swift)
struct Q3VertexIn {
    float3 position;
    float2 texCoord;
    float2 lightmapCoord;
    float3 normal;
    float4 color;
};

// Interpolated vertex output
struct Q3VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 lightmapCoord;
    float3 normal;
    float4 color;
    float3 worldPos;
};

vertex Q3VertexOut q3VertexShader(
    uint vertexID [[vertex_id]],
    constant Q3VertexIn* vertices [[buffer(BufferIndexMeshPositions)]],
    constant Q3FrameUniforms& uniforms [[buffer(BufferIndexUniforms)]]
)
{
    Q3VertexOut out;

    constant Q3VertexIn& vert = vertices[vertexID];

    float4 worldPos = uniforms.modelMatrix * float4(vert.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.texCoord = vert.texCoord;
    out.lightmapCoord = vert.lightmapCoord;
    out.normal = vert.normal;
    out.color = vert.color;
    out.worldPos = worldPos.xyz;

    return out;
}

// Sine wave table lookup approximation
float q3_sin_approx(float x) {
    return sin(x * 2.0 * M_PI_F);
}

fragment float4 q3FragmentShader(
    Q3VertexOut in [[stage_in]],
    constant Q3FrameUniforms& frameUniforms [[buffer(BufferIndexUniforms)]],
    constant Q3StageUniforms& stageUniforms [[buffer(BufferIndexStageUniforms)]],
    texture2d<float> diffuseMap [[texture(TextureIndexColor)]],
    texture2d<float> lightmapTex [[texture(TextureIndexLightmap)]]
)
{
    constexpr sampler texSampler(mip_filter::linear,
                                 mag_filter::linear,
                                 min_filter::linear,
                                 address::repeat);

    constexpr sampler lmSampler(mip_filter::nearest,
                                mag_filter::linear,
                                min_filter::linear,
                                address::clamp_to_edge);

    // Determine texture coordinates based on tcGen
    float2 tc;
    int tcGen = stageUniforms.tcGen;

    if (tcGen == 2) {
        // Lightmap
        tc = in.lightmapCoord;
    } else if (tcGen == 4) {
        // Environment mapped
        float3 viewer = normalize(frameUniforms.viewOrigin - in.worldPos);
        float d = dot(in.normal, viewer);
        float3 reflected = in.normal * (2.0 * d) - viewer;
        tc = float2(0.5 + reflected.x * 0.5, 0.5 - reflected.z * 0.5);
    } else {
        // Default: texture coordinates
        tc = in.texCoord;
    }

    // Apply tcMod matrix transform
    tc = stageUniforms.tcModMat * tc + stageUniforms.tcModOffset;

    // Apply turbulence if active
    if (stageUniforms.turbAmplitude > 0.0) {
        float sPhase = stageUniforms.turbPhase + tc.x * stageUniforms.turbFrequency + stageUniforms.turbTime * stageUniforms.turbFrequency;
        float tPhase = stageUniforms.turbPhase + tc.y * stageUniforms.turbFrequency + stageUniforms.turbTime * stageUniforms.turbFrequency;
        tc.x += sin(sPhase * 2.0 * M_PI_F) * stageUniforms.turbAmplitude;
        tc.y += sin(tPhase * 2.0 * M_PI_F) * stageUniforms.turbAmplitude;
    }

    // Sample texture
    float4 texColor = diffuseMap.sample(texSampler, tc);

    // Start with stage color (from rgbGen/alphaGen evaluation)
    float4 color = stageUniforms.color;

    // Multiply by vertex color if rgbGen is vertex/exactVertex
    if (stageUniforms.useVertexColor != 0) {
        color.rgb *= in.color.rgb;
    }

    // Use vertex alpha if alphaGen is vertex
    if (stageUniforms.useVertexAlpha != 0) {
        color.a *= in.color.a;
    }

    // Modulate by texture
    color *= texColor;

    // Apply lightmap if this is a lightmap stage
    if (stageUniforms.useLightmap != 0) {
        float4 lm = lightmapTex.sample(lmSampler, in.lightmapCoord);
        color *= lm;
    }

    // Alpha test
    int alphaFunc = stageUniforms.alphaTestFunc;
    if (alphaFunc == 1) {
        // GT0
        if (color.a <= 0.0) discard_fragment();
    } else if (alphaFunc == 2) {
        // LT128 (< 0.5)
        if (color.a >= stageUniforms.alphaTestValue) discard_fragment();
    } else if (alphaFunc == 3) {
        // GE128 (>= 0.5)
        if (color.a < stageUniforms.alphaTestValue) discard_fragment();
    }

    // Force output alpha to 1.0 — macOS compositor uses framebuffer alpha for
    // window transparency; we always want opaque pixels for non-discarded fragments
    return float4(color.rgb, 1.0);
}

// MARK: - Q3 2D UI Shaders

struct Q3_2DVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex Q3_2DVertexOut q3_2d_vertex(
    uint vertexID [[vertex_id]],
    constant Q3_2DVertex* vertices [[buffer(BufferIndexTwoDVertices)]]
)
{
    Q3_2DVertexOut out;
    constant Q3_2DVertex& v = vertices[vertexID];

    // Ortho projection: Q3 virtual screen 640x480 → NDC [-1,1]
    float x = v.position.x / 320.0 - 1.0;
    float y = 1.0 - v.position.y / 240.0;
    out.position = float4(x, y, 0.0, 1.0);
    out.texCoord = v.texCoord;
    out.color = v.color;
    return out;
}

fragment float4 q3_2d_fragment(
    Q3_2DVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(TextureIndexColor)]]
)
{
    constexpr sampler s(mip_filter::linear,
                        mag_filter::linear,
                        min_filter::linear,
                        address::clamp_to_edge);
    float4 texColor = tex.sample(s, in.texCoord);
    float4 color = in.color * texColor;
    if (color.a < 0.004) discard_fragment();
    return color;
}

// MARK: - Depth Clear Shaders (fullscreen triangle that writes depth=1.0)

struct DepthClearOut {
    float4 position [[position]];
};

vertex DepthClearOut depthClearVertex(uint vertexID [[vertex_id]])
{
    // Fullscreen triangle: 3 vertices covering [-1,1] clip space at z=1.0 (far plane)
    float2 pos[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
    DepthClearOut out;
    out.position = float4(pos[vertexID], 1.0, 1.0);
    return out;
}

fragment float4 depthClearFragment(DepthClearOut in [[stage_in]])
{
    return float4(0);
}
