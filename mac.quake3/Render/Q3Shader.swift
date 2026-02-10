// Q3Shader.swift — Runtime shader representation

import Foundation
import simd

// MARK: - Shader Enums

enum ShaderSort: Float {
    case bad = 0
    case portal = 1
    case environment = 2     // sky
    case opaque = 3
    case decal = 4
    case seeThrough = 5
    case banner = 6
    case fog = 7
    case underwater = 8
    case blend0 = 9
    case blend1 = 10
    case blend2 = 11
    case blend3 = 12
    case blend6 = 13
    case stencilShadow = 14
    case almostNearest = 15
    case nearest = 16
}

enum CullType: Int {
    case frontSided = 0
    case backSided
    case twoSided
}

enum GenFunc: Int {
    case none = 0
    case sin
    case square
    case triangle
    case sawtooth
    case inverseSawtooth
    case noise
}

enum ColorGen: Int {
    case bad = 0
    case identityLighting
    case identity
    case entity
    case oneMinusEntity
    case exactVertex
    case vertex
    case oneMinusVertex
    case waveform
    case lightingDiffuse
    case fog
    case const_
}

enum AlphaGen: Int {
    case identity = 0
    case skip
    case entity
    case oneMinusEntity
    case vertex
    case oneMinusVertex
    case lightingSpecular
    case waveform
    case portal
    case const_
}

enum TexCoordGen: Int {
    case bad = 0
    case identity
    case lightmap
    case texture
    case environmentMapped
    case fog
    case vector
}

enum TexMod: Int {
    case none = 0
    case transform
    case turbulent
    case scroll
    case scale
    case stretch
    case rotate
    case entityTranslate
}

enum FogPass: Int {
    case none = 0
    case equal
    case le
}

// MARK: - GLS State Bits

struct GLState: OptionSet {
    let rawValue: UInt32

    // Source blend modes (bits 0-3)
    static let srcBlendZero             = GLState(rawValue: 0x00000001)
    static let srcBlendOne              = GLState(rawValue: 0x00000002)
    static let srcBlendDstColor         = GLState(rawValue: 0x00000003)
    static let srcBlendOneMinusDstColor = GLState(rawValue: 0x00000004)
    static let srcBlendSrcAlpha         = GLState(rawValue: 0x00000005)
    static let srcBlendOneMinusSrcAlpha = GLState(rawValue: 0x00000006)
    static let srcBlendDstAlpha         = GLState(rawValue: 0x00000007)
    static let srcBlendOneMinusDstAlpha = GLState(rawValue: 0x00000008)
    static let srcBlendAlphaSaturate    = GLState(rawValue: 0x00000009)
    static let srcBlendBits             = GLState(rawValue: 0x0000000f)

    // Dest blend modes (bits 4-7)
    static let dstBlendZero             = GLState(rawValue: 0x00000010)
    static let dstBlendOne              = GLState(rawValue: 0x00000020)
    static let dstBlendSrcColor         = GLState(rawValue: 0x00000030)
    static let dstBlendOneMinusSrcColor = GLState(rawValue: 0x00000040)
    static let dstBlendSrcAlpha         = GLState(rawValue: 0x00000050)
    static let dstBlendOneMinusSrcAlpha = GLState(rawValue: 0x00000060)
    static let dstBlendDstAlpha         = GLState(rawValue: 0x00000070)
    static let dstBlendOneMinusDstAlpha = GLState(rawValue: 0x00000080)
    static let dstBlendBits             = GLState(rawValue: 0x000000f0)

    static let depthMaskTrue            = GLState(rawValue: 0x00000100)
    static let polymodeLine             = GLState(rawValue: 0x00001000)
    static let depthTestDisable         = GLState(rawValue: 0x00010000)
    static let depthFuncEqual           = GLState(rawValue: 0x00020000)

    static let atestGT0                 = GLState(rawValue: 0x10000000)
    static let atestLT80                = GLState(rawValue: 0x20000000)
    static let atestGE80                = GLState(rawValue: 0x40000000)
    static let atestBits                = GLState(rawValue: 0x70000000)

    static let `default`                = GLState.depthMaskTrue
}

// MARK: - Deform Types

enum DeformType: Int {
    case none = 0
    case wave
    case normals
    case bulge
    case move
    case projectionShadow
    case autosprite
    case autosprite2
}

struct DeformStage {
    var deformation: DeformType = .none
    var moveVector: Vec3 = .zero
    var deformationWave: WaveForm = WaveForm()
    var deformationSpread: Float = 0
    var bulgeWidth: Float = 0
    var bulgeHeight: Float = 0
    var bulgeSpeed: Float = 0
}

// MARK: - Shader Structures

struct WaveForm {
    var func_: GenFunc = .none
    var base: Float = 0
    var amplitude: Float = 0
    var phase: Float = 0
    var frequency: Float = 0
}

struct TexModInfo {
    var type: TexMod = .none
    var wave: WaveForm = WaveForm()
    var matrix: ((Float, Float), (Float, Float)) = ((1, 0), (0, 1))
    var translate: SIMD2<Float> = .zero
    var scale: SIMD2<Float> = .one
    var scroll: SIMD2<Float> = .zero
    var rotateSpeed: Float = 0
}

struct TextureBundle {
    var imageNames: [String] = []        // animation frames
    var imageAnimationSpeed: Float = 0
    var tcGen: TexCoordGen = .texture
    var tcGenVectors: (Vec3, Vec3) = (.zero, .zero)
    var texMods: [TexModInfo] = []
    var isLightmap: Bool = false
}

struct ShaderStage {
    var active: Bool = false
    var bundles: [TextureBundle] = [TextureBundle(), TextureBundle()]
    var rgbWave: WaveForm = WaveForm()
    var rgbGen: ColorGen = .identity
    var alphaWave: WaveForm = WaveForm()
    var alphaGen: AlphaGen = .identity
    var constantColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var stateBits: UInt32 = GLState.default.rawValue
    var isDetail: Bool = false

    // Resolved texture handles (set during loading)
    var textureHandle: Int = -1
    var lightmapHandle: Int = -1
}

struct Q3ShaderDef {
    var name: String = ""
    var lightmapIndex: Int = -1
    var index: Int = 0
    var sort: Float = ShaderSort.opaque.rawValue
    var defaultShader: Bool = false
    var explicitlyDefined: Bool = false
    var surfaceFlags: Int32 = 0
    var contentFlags: Int32 = 0
    var cullType: CullType = .frontSided
    var polygonOffset: Bool = false
    var noMipMaps: Bool = false
    var noPicMip: Bool = false
    var fogPass: FogPass = .none
    var entityMergable: Bool = false
    var isSky: Bool = false
    var stages: [ShaderStage] = []
    var deforms: [DeformStage] = []

    // Sky
    var skyBoxNames: [String] = []
    var cloudHeight: Float = 512

    // Fog
    var fogColor: Vec3 = .zero
    var fogDepthForOpaque: Float = 0

    var isOpaque: Bool {
        if stages.isEmpty { return true }
        let bits = stages[0].stateBits
        return (bits & GLState.srcBlendBits.rawValue) == 0 && (bits & GLState.dstBlendBits.rawValue) == 0
    }

    var hasLightmap: Bool {
        for stage in stages {
            for bundle in stage.bundles {
                if bundle.isLightmap { return true }
            }
        }
        return false
    }
}
