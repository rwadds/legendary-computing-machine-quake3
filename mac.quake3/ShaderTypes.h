//
//  ShaderTypes.h
//  mac.quake3
//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2,
    BufferIndexStageUniforms = 3,
    BufferIndexTwoDVertices  = 4
};

typedef struct
{
    simd_float2 position;   // screen-space (0-640, 0-480)
    simd_float2 texCoord;
    simd_float4 color;
} Q3_2DVertex;

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor    = 0,
    TextureIndexLightmap = 1,
};

// Original template uniforms (kept for backward compatibility)
typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
} Uniforms;

// Q3 frame uniforms (per-frame, shared across all surfaces)
typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    matrix_float4x4 modelMatrix;
    simd_float3 viewOrigin;
    float time;
} Q3FrameUniforms;

// Q3 per-stage uniforms (set per shader stage draw call)
typedef struct
{
    simd_float4 color;              // Computed rgbGen/alphaGen color
    simd_float2x2 tcModMat;        // Texture coord transform matrix
    simd_float2 tcModOffset;       // Texture coord transform offset
    int alphaTestFunc;             // 0=none, 1=GT0, 2=LT128, 3=GE128
    float alphaTestValue;          // Alpha test threshold
    int useVertexColor;            // 1 = multiply by vertex RGB
    int useVertexAlpha;            // 1 = use vertex alpha
    int tcGen;                     // 0=bad,1=identity,2=lightmap,3=texture,4=envmap,5=fog,6=vector
    int animFrame;                 // Animation frame index (for animMap)
    float turbAmplitude;           // tcMod turb amplitude
    float turbPhase;               // tcMod turb phase
    float turbFrequency;           // tcMod turb frequency
    float turbTime;                // tcMod turb time
    int useLightmap;               // 1 = this stage is a lightmap stage
    int _pad0;
    int _pad1;
} Q3StageUniforms;

#endif /* ShaderTypes_h */
