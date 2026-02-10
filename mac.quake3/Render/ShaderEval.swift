// ShaderEval.swift — Runtime evaluation of shader effects (wave, tcMod, rgbGen, alphaGen, deform)

import Foundation
import simd

class ShaderEval {
    static let shared = ShaderEval()

    // Pre-computed wave tables (1024 entries each)
    static let tableSize = 1024
    static let tableMask = 1023

    let sinTable: [Float]
    let squareTable: [Float]
    let triangleTable: [Float]
    let sawToothTable: [Float]
    let inverseSawToothTable: [Float]

    // Noise for turbulent effects
    private var noiseTable: [Float]

    private init() {
        var sin_ = [Float](repeating: 0, count: Self.tableSize)
        var sq_ = [Float](repeating: 0, count: Self.tableSize)
        var tri_ = [Float](repeating: 0, count: Self.tableSize)
        var saw_ = [Float](repeating: 0, count: Self.tableSize)
        var isaw_ = [Float](repeating: 0, count: Self.tableSize)
        var noise_ = [Float](repeating: 0, count: Self.tableSize)

        for i in 0..<Self.tableSize {
            let f = Float(i) / Float(Self.tableSize)

            sin_[i] = sinf(f * 2.0 * .pi)
            sq_[i] = f < 0.5 ? 1.0 : -1.0
            saw_[i] = f
            isaw_[i] = 1.0 - f

            if f < 0.25 {
                tri_[i] = 4.0 * f
            } else if f < 0.75 {
                tri_[i] = 2.0 - 4.0 * f
            } else {
                tri_[i] = -4.0 + 4.0 * f
            }

            noise_[i] = Float.random(in: -1...1)
        }

        sinTable = sin_
        squareTable = sq_
        triangleTable = tri_
        sawToothTable = saw_
        inverseSawToothTable = isaw_
        noiseTable = noise_
    }

    // MARK: - Wave Evaluation

    func tableForFunc(_ f: GenFunc) -> [Float]? {
        switch f {
        case .sin: return sinTable
        case .square: return squareTable
        case .triangle: return triangleTable
        case .sawtooth: return sawToothTable
        case .inverseSawtooth: return inverseSawToothTable
        case .noise: return noiseTable
        case .none: return nil
        }
    }

    func evalWaveForm(_ wave: WaveForm, time: Float) -> Float {
        guard let table = tableForFunc(wave.func_) else { return 1.0 }

        let phase = wave.phase + time * wave.frequency
        let index = Int(phase * Float(Self.tableSize)) & Self.tableMask
        return wave.base + table[index] * wave.amplitude
    }

    func evalWaveFormClamped(_ wave: WaveForm, time: Float) -> Float {
        return max(0, min(1, evalWaveForm(wave, time: time)))
    }

    // MARK: - Texture Coordinate Modification

    /// Apply tcMod chain to texture coordinates, returning modified (s, t)
    func applyTexMods(_ texMods: [TexModInfo], s: Float, t: Float, time: Float) -> (Float, Float) {
        var s = s
        var t = t

        for mod in texMods {
            switch mod.type {
            case .none:
                break

            case .scroll:
                s += mod.scroll.x * time
                t += mod.scroll.y * time

            case .scale:
                s *= mod.scale.x
                t *= mod.scale.y

            case .rotate:
                let angle = mod.rotateSpeed * time * (.pi / 180.0)
                let cosA = cosf(angle)
                let sinA = sinf(angle)
                // Rotate around (0.5, 0.5)
                let cs = s - 0.5
                let ct = t - 0.5
                s = cs * cosA - ct * sinA + 0.5
                t = cs * sinA + ct * cosA + 0.5

            case .stretch:
                let p = evalWaveForm(mod.wave, time: time)
                let invP = p != 0 ? 1.0 / p : 1.0
                s = (s - 0.5) * invP + 0.5
                t = (t - 0.5) * invP + 0.5

            case .turbulent:
                let phase = mod.wave.phase
                let freq = mod.wave.frequency
                let amp = mod.wave.amplitude
                let sOff = phase + s * freq + time * freq
                let tOff = phase + t * freq + time * freq
                let sIdx = Int(sOff * Float(Self.tableSize)) & Self.tableMask
                let tIdx = Int(tOff * Float(Self.tableSize)) & Self.tableMask
                s += sinTable[sIdx] * amp
                t += sinTable[tIdx] * amp

            case .transform:
                let newS = s * mod.matrix.0.0 + t * mod.matrix.1.0 + mod.translate.x
                let newT = s * mod.matrix.0.1 + t * mod.matrix.1.1 + mod.translate.y
                s = newS
                t = newT

            case .entityTranslate:
                // Would use entity position; for world geometry, no-op
                break
            }
        }

        return (s, t)
    }

    // MARK: - Per-Stage Uniform Generation

    /// Compute per-stage fragment uniforms for a given shader stage
    func computeStageUniforms(
        stage: ShaderStage,
        time: Float,
        entityColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    ) -> Q3StageUniforms {
        var uniforms = Q3StageUniforms()

        // RGB Generation
        var color = SIMD4<Float>(1, 1, 1, 1)
        switch stage.rgbGen {
        case .identity, .identityLighting:
            color = SIMD4<Float>(1, 1, 1, 1)
        case .entity:
            color = entityColor
        case .oneMinusEntity:
            color = SIMD4<Float>(1 - entityColor.x, 1 - entityColor.y, 1 - entityColor.z, entityColor.w)
        case .waveform:
            let v = evalWaveFormClamped(stage.rgbWave, time: time)
            color = SIMD4<Float>(v, v, v, 1)
        case .const_:
            color = stage.constantColor
        case .vertex, .exactVertex:
            // Handled in shader via vertex color; set modulate to white
            uniforms.useVertexColor = 1
        case .lightingDiffuse:
            // Use vertex lighting (computed per-vertex); flag it
            uniforms.useVertexColor = 1
        default:
            break
        }
        uniforms.color = color

        // Alpha Generation
        switch stage.alphaGen {
        case .identity:
            uniforms.color.w = 1.0
        case .entity:
            uniforms.color.w = entityColor.w
        case .oneMinusEntity:
            uniforms.color.w = 1.0 - entityColor.w
        case .waveform:
            uniforms.color.w = evalWaveFormClamped(stage.alphaWave, time: time)
        case .const_:
            uniforms.color.w = stage.constantColor.w
        case .vertex, .oneMinusVertex:
            uniforms.useVertexAlpha = 1
        case .portal:
            uniforms.color.w = 1.0
        default:
            break
        }

        // Alpha test
        let atestBits = stage.stateBits & GLState.atestBits.rawValue
        if atestBits == GLState.atestGT0.rawValue {
            uniforms.alphaTestFunc = 1
            uniforms.alphaTestValue = 0.0
        } else if atestBits == GLState.atestLT80.rawValue {
            uniforms.alphaTestFunc = 2
            uniforms.alphaTestValue = 0.5
        } else if atestBits == GLState.atestGE80.rawValue {
            uniforms.alphaTestFunc = 3
            uniforms.alphaTestValue = 0.5
        }

        // tcMod — compute as a 2x3 matrix (2x2 + translate)
        // We compute the aggregate transform for CPU-side convenience
        // and pass it to the shader as matrix + offset
        computeTcModMatrix(texMods: stage.bundles[0].texMods, time: time, uniforms: &uniforms)

        // tcGen
        uniforms.tcGen = Int32(stage.bundles[0].tcGen.rawValue)

        // Animation frame selection
        let bundle = stage.bundles[0]
        if bundle.imageNames.count > 1 && bundle.imageAnimationSpeed > 0 {
            let frameCount = bundle.imageNames.count
            let frame = Int(time * bundle.imageAnimationSpeed) % frameCount
            uniforms.animFrame = Int32(frame)
        }

        return uniforms
    }

    /// Compute tcMod as a combined 2x3 matrix (mat2x2 + vec2 offset)
    private func computeTcModMatrix(texMods: [TexModInfo], time: Float, uniforms: inout Q3StageUniforms) {
        // Start with identity
        var m00: Float = 1, m01: Float = 0
        var m10: Float = 0, m11: Float = 1
        var tx: Float = 0, ty: Float = 0

        for mod in texMods {
            var nm00: Float = 1, nm01: Float = 0
            var nm10: Float = 0, nm11: Float = 1
            var ntx: Float = 0, nty: Float = 0

            switch mod.type {
            case .none:
                continue

            case .scroll:
                ntx = mod.scroll.x * time
                nty = mod.scroll.y * time

            case .scale:
                nm00 = mod.scale.x
                nm11 = mod.scale.y

            case .rotate:
                let angle = -mod.rotateSpeed * time * (.pi / 180.0)
                let cosA = cosf(angle)
                let sinA = sinf(angle)
                nm00 = cosA; nm01 = -sinA
                nm10 = sinA; nm11 = cosA
                // Rotate around (0.5, 0.5)
                ntx = 0.5 - 0.5 * cosA + 0.5 * sinA
                nty = 0.5 - 0.5 * sinA - 0.5 * cosA

            case .stretch:
                let p = evalWaveForm(mod.wave, time: time)
                let invP = p != 0 ? 1.0 / p : 1.0
                nm00 = invP; nm11 = invP
                ntx = 0.5 - 0.5 * invP
                nty = 0.5 - 0.5 * invP

            case .turbulent:
                // Turbulent is per-vertex, pass wave params for GPU eval
                uniforms.turbAmplitude = mod.wave.amplitude
                uniforms.turbPhase = mod.wave.phase
                uniforms.turbFrequency = mod.wave.frequency
                uniforms.turbTime = time
                continue

            case .transform:
                nm00 = mod.matrix.0.0
                nm01 = mod.matrix.0.1
                nm10 = mod.matrix.1.0
                nm11 = mod.matrix.1.1
                ntx = mod.translate.x
                nty = mod.translate.y

            case .entityTranslate:
                continue
            }

            // Multiply: new = current * mod
            let rm00 = m00 * nm00 + m01 * nm10
            let rm01 = m00 * nm01 + m01 * nm11
            let rm10 = m10 * nm00 + m11 * nm10
            let rm11 = m10 * nm01 + m11 * nm11
            let rtx = tx * nm00 + ty * nm10 + ntx
            let rty = tx * nm01 + ty * nm11 + nty

            m00 = rm00; m01 = rm01
            m10 = rm10; m11 = rm11
            tx = rtx; ty = rty
        }

        uniforms.tcModMat = simd_float2x2(SIMD2<Float>(m00, m01), SIMD2<Float>(m10, m11))
        uniforms.tcModOffset = SIMD2<Float>(tx, ty)
    }

    // MARK: - Vertex Deformation

    /// Apply deformVertexes to a vertex buffer (CPU-side)
    func applyDeforms(
        deforms: [DeformStage],
        vertices: UnsafeMutablePointer<Q3GPUVertex>,
        vertexCount: Int,
        time: Float
    ) {
        for deform in deforms {
            switch deform.deformation {
            case .none:
                break

            case .wave:
                applyDeformWave(deform, vertices: vertices, count: vertexCount, time: time)

            case .normals:
                applyDeformNormals(deform, vertices: vertices, count: vertexCount, time: time)

            case .bulge:
                applyDeformBulge(deform, vertices: vertices, count: vertexCount, time: time)

            case .move:
                applyDeformMove(deform, vertices: vertices, count: vertexCount, time: time)

            case .autosprite, .autosprite2:
                // Autosprite requires camera info; handled at render time
                break

            case .projectionShadow:
                break
            }
        }
    }

    private func applyDeformWave(
        _ deform: DeformStage,
        vertices: UnsafeMutablePointer<Q3GPUVertex>,
        count: Int,
        time: Float
    ) {
        for i in 0..<count {
            let pos = vertices[i].position
            let normal = vertices[i].normal

            // Per-vertex phase offset based on position
            let off = (pos.x + pos.y + pos.z) * deform.deformationSpread
            var wave = deform.deformationWave
            wave.phase += off
            let scale = evalWaveForm(wave, time: time)

            vertices[i].position = pos + normal * scale
        }
    }

    private func applyDeformNormals(
        _ deform: DeformStage,
        vertices: UnsafeMutablePointer<Q3GPUVertex>,
        count: Int,
        time: Float
    ) {
        let amp = deform.deformationWave.amplitude
        let freq = deform.deformationWave.frequency

        for i in 0..<count {
            let pos = vertices[i].position
            let scale = 0.98 * amp

            let sx = sinf(pos.x * freq + time)
            let sy = sinf(pos.y * freq + time)
            let sz = sinf(pos.z * freq + time)

            var n = vertices[i].normal
            n.x += scale * sx
            n.y += scale * sy
            n.z += scale * sz
            vertices[i].normal = simd_normalize(n)
        }
    }

    private func applyDeformBulge(
        _ deform: DeformStage,
        vertices: UnsafeMutablePointer<Q3GPUVertex>,
        count: Int,
        time: Float
    ) {
        for i in 0..<count {
            let normal = vertices[i].normal
            let st = vertices[i].texCoord.x

            let off = Float(st) * deform.bulgeWidth + time * deform.bulgeSpeed
            let scale = sinf(off) * deform.bulgeHeight

            vertices[i].position += normal * scale
        }
    }

    private func applyDeformMove(
        _ deform: DeformStage,
        vertices: UnsafeMutablePointer<Q3GPUVertex>,
        count: Int,
        time: Float
    ) {
        let scale = evalWaveForm(deform.deformationWave, time: time)
        let offset = deform.moveVector * scale

        for i in 0..<count {
            vertices[i].position += offset
        }
    }

    // MARK: - Environment Map TC Generation

    /// Compute environment-mapped texture coordinates
    static func environmentTexCoords(position: Vec3, normal: Vec3, viewOrigin: Vec3) -> SIMD2<Float> {
        let viewer = simd_normalize(viewOrigin - position)
        let d = simd_dot(normal, viewer)
        let reflected = normal * (2.0 * d) - viewer

        let s = 0.5 + reflected.x * 0.5
        let t = 0.5 - reflected.z * 0.5
        return SIMD2<Float>(s, t)
    }
}

// MARK: - Q3StageUniforms Extension (the struct itself is defined in ShaderTypes.h)

extension Q3StageUniforms {
    /// Create with default values
    init() {
        self.init(
            color: SIMD4<Float>(1, 1, 1, 1),
            tcModMat: simd_float2x2(1),
            tcModOffset: .zero,
            alphaTestFunc: 0,
            alphaTestValue: 0,
            useVertexColor: 0,
            useVertexAlpha: 0,
            tcGen: 3,
            animFrame: 0,
            turbAmplitude: 0,
            turbPhase: 0,
            turbFrequency: 0,
            turbTime: 0,
            useLightmap: 0,
            _pad0: 0,
            _pad1: 0
        )
    }
}
