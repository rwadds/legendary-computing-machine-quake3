// MD3Model.swift — MD3 model loader (header, frames, surfaces, tags)

import Foundation
import simd

let MD3_IDENT: UInt32 = 0x33504449  // "IDP3"
let MD3_VERSION: Int32 = 15
let MD3_XYZ_SCALE: Float = 1.0 / 64.0

// MARK: - MD3 Structures

struct MD3Frame {
    var bounds: (Vec3, Vec3) = (.zero, .zero)
    var localOrigin: Vec3 = .zero
    var radius: Float = 0
    var name: String = ""
}

struct MD3Tag {
    var name: String = ""
    var origin: Vec3 = .zero
    var axis: (Vec3, Vec3, Vec3) = (Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))
}

struct MD3Shader {
    var name: String = ""
    var shaderIndex: Int32 = 0
}

struct MD3Triangle {
    var indexes: (Int32, Int32, Int32) = (0, 0, 0)
}

struct MD3TexCoord {
    var s: Float = 0
    var t: Float = 0
}

struct MD3Vertex {
    var xyz: SIMD3<Int16> = .zero
    var normal: Int16 = 0

    var position: Vec3 {
        return Vec3(Float(xyz.x), Float(xyz.y), Float(xyz.z)) * MD3_XYZ_SCALE
    }

    var decodedNormal: Vec3 {
        let lat = Float((Int(normal) >> 8) & 0xFF) * (2.0 * Float.pi / 256.0)
        let lng = Float(Int(normal) & 0xFF) * (2.0 * Float.pi / 256.0)
        return Vec3(cosf(lat) * sinf(lng), sinf(lat) * sinf(lng), cosf(lng))
    }
}

struct MD3Surface {
    var name: String = ""
    var numFrames: Int = 0
    var numShaders: Int = 0
    var numVerts: Int = 0
    var numTriangles: Int = 0
    var shaders: [MD3Shader] = []
    var triangles: [MD3Triangle] = []
    var texCoords: [MD3TexCoord] = []
    var vertices: [MD3Vertex] = []  // numVerts * numFrames
}

// MARK: - MD3 Model

class MD3Model {
    var name: String = ""
    var numFrames: Int = 0
    var numTags: Int = 0
    var numSurfaces: Int = 0
    var frames: [MD3Frame] = []
    var tags: [MD3Tag] = []       // numFrames * numTags
    var surfaces: [MD3Surface] = []

    // MARK: - Loading

    func load(from data: Data) -> Bool {
        guard data.count >= 108 else {
            Q3Console.shared.print("MD3: file too small")
            return false
        }

        return data.withUnsafeBytes { ptr -> Bool in
            let base = ptr.baseAddress!

            // Read header
            let ident = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let version = base.loadUnaligned(fromByteOffset: 4, as: Int32.self)

            guard ident == MD3_IDENT else {
                Q3Console.shared.print("MD3: bad ident 0x\(String(ident, radix: 16))")
                return false
            }
            guard version == MD3_VERSION else {
                Q3Console.shared.print("MD3: bad version \(version)")
                return false
            }

            // Read name
            name = readString(base.advanced(by: 8), maxLen: 64)

            numFrames = Int(base.loadUnaligned(fromByteOffset: 76, as: Int32.self))
            numTags = Int(base.loadUnaligned(fromByteOffset: 80, as: Int32.self))
            numSurfaces = Int(base.loadUnaligned(fromByteOffset: 84, as: Int32.self))

            let ofsFrames = Int(base.loadUnaligned(fromByteOffset: 92, as: Int32.self))
            let ofsTags = Int(base.loadUnaligned(fromByteOffset: 96, as: Int32.self))
            let ofsSurfaces = Int(base.loadUnaligned(fromByteOffset: 100, as: Int32.self))

            // Load frames
            frames.removeAll()
            for i in 0..<numFrames {
                let ofs = ofsFrames + i * 56  // sizeof(md3Frame_t) = 56
                guard ofs + 56 <= data.count else { break }

                var frame = MD3Frame()
                frame.bounds.0 = readVec3(base, at: ofs)
                frame.bounds.1 = readVec3(base, at: ofs + 12)
                frame.localOrigin = readVec3(base, at: ofs + 24)
                frame.radius = base.loadUnaligned(fromByteOffset: ofs + 36, as: Float.self)
                frame.name = readString(base.advanced(by: ofs + 40), maxLen: 16)
                frames.append(frame)
            }

            // Load tags
            tags.removeAll()
            for i in 0..<(numFrames * numTags) {
                let ofs = ofsTags + i * 112  // sizeof(md3Tag_t) = 112 (64 + 12 + 36)
                guard ofs + 112 <= data.count else { break }

                var tag = MD3Tag()
                tag.name = readString(base.advanced(by: ofs), maxLen: 64)
                tag.origin = readVec3(base, at: ofs + 64)
                tag.axis.0 = readVec3(base, at: ofs + 76)
                tag.axis.1 = readVec3(base, at: ofs + 88)
                tag.axis.2 = readVec3(base, at: ofs + 100)
                tags.append(tag)
            }

            // Load surfaces
            surfaces.removeAll()
            var surfOfs = ofsSurfaces
            for _ in 0..<numSurfaces {
                guard surfOfs + 108 <= data.count else { break }

                var surface = MD3Surface()
                surface.name = readString(base.advanced(by: surfOfs + 4), maxLen: 64)
                surface.numFrames = Int(base.loadUnaligned(fromByteOffset: surfOfs + 72, as: Int32.self))
                surface.numShaders = Int(base.loadUnaligned(fromByteOffset: surfOfs + 76, as: Int32.self))
                surface.numVerts = Int(base.loadUnaligned(fromByteOffset: surfOfs + 80, as: Int32.self))
                surface.numTriangles = Int(base.loadUnaligned(fromByteOffset: surfOfs + 84, as: Int32.self))

                let ofsTriangles = Int(base.loadUnaligned(fromByteOffset: surfOfs + 88, as: Int32.self))
                let ofsShaders = Int(base.loadUnaligned(fromByteOffset: surfOfs + 92, as: Int32.self))
                let ofsSt = Int(base.loadUnaligned(fromByteOffset: surfOfs + 96, as: Int32.self))
                let ofsXyzNormals = Int(base.loadUnaligned(fromByteOffset: surfOfs + 100, as: Int32.self))
                let ofsEnd = Int(base.loadUnaligned(fromByteOffset: surfOfs + 104, as: Int32.self))

                // Shaders
                for j in 0..<surface.numShaders {
                    let sOfs = surfOfs + ofsShaders + j * 68  // name(64) + index(4)
                    guard sOfs + 68 <= data.count else { break }
                    var shader = MD3Shader()
                    shader.name = readString(base.advanced(by: sOfs), maxLen: 64)
                    shader.shaderIndex = base.loadUnaligned(fromByteOffset: sOfs + 64, as: Int32.self)
                    surface.shaders.append(shader)
                }

                // Triangles
                for j in 0..<surface.numTriangles {
                    let tOfs = surfOfs + ofsTriangles + j * 12
                    guard tOfs + 12 <= data.count else { break }
                    let i0 = base.loadUnaligned(fromByteOffset: tOfs, as: Int32.self)
                    let i1 = base.loadUnaligned(fromByteOffset: tOfs + 4, as: Int32.self)
                    let i2 = base.loadUnaligned(fromByteOffset: tOfs + 8, as: Int32.self)
                    surface.triangles.append(MD3Triangle(indexes: (i0, i1, i2)))
                }

                // Tex coords
                for j in 0..<surface.numVerts {
                    let tcOfs = surfOfs + ofsSt + j * 8
                    guard tcOfs + 8 <= data.count else { break }
                    let s = base.loadUnaligned(fromByteOffset: tcOfs, as: Float.self)
                    let t = base.loadUnaligned(fromByteOffset: tcOfs + 4, as: Float.self)
                    surface.texCoords.append(MD3TexCoord(s: s, t: t))
                }

                // Vertices (all frames)
                let totalVerts = surface.numVerts * surface.numFrames
                for j in 0..<totalVerts {
                    let vOfs = surfOfs + ofsXyzNormals + j * 8
                    guard vOfs + 8 <= data.count else { break }
                    var vert = MD3Vertex()
                    vert.xyz = SIMD3<Int16>(
                        base.loadUnaligned(fromByteOffset: vOfs, as: Int16.self),
                        base.loadUnaligned(fromByteOffset: vOfs + 2, as: Int16.self),
                        base.loadUnaligned(fromByteOffset: vOfs + 4, as: Int16.self)
                    )
                    vert.normal = base.loadUnaligned(fromByteOffset: vOfs + 6, as: Int16.self)
                    surface.vertices.append(vert)
                }

                surfaces.append(surface)
                surfOfs += ofsEnd
            }

            Q3Console.shared.print("MD3 \(name): \(numFrames) frames, \(numTags) tags, \(numSurfaces) surfaces")
            return true
        }
    }

    // MARK: - Tag Lookup

    func getTag(named name: String, frame: Int) -> MD3Tag? {
        guard numTags > 0 && frame >= 0 && frame < numFrames else { return nil }
        let baseIdx = frame * numTags
        for i in 0..<numTags {
            let idx = baseIdx + i
            guard idx < tags.count else { continue }
            if tags[idx].name == name { return tags[idx] }
        }
        return nil
    }

    func lerpTag(named name: String, frame: Int, oldFrame: Int, backlerp: Float) -> MD3Tag? {
        guard let tag1 = getTag(named: name, frame: frame),
              let tag2 = getTag(named: name, frame: oldFrame) else {
            return getTag(named: name, frame: frame)
        }

        let frac = 1.0 - backlerp
        var result = tag1
        result.origin = tag2.origin * backlerp + tag1.origin * frac
        // Simplified axis lerp (should use slerp for correctness)
        result.axis.0 = simd_normalize(tag2.axis.0 * backlerp + tag1.axis.0 * frac)
        result.axis.1 = simd_normalize(tag2.axis.1 * backlerp + tag1.axis.1 * frac)
        result.axis.2 = simd_normalize(tag2.axis.2 * backlerp + tag1.axis.2 * frac)
        return result
    }

    // MARK: - Helpers

    private func readString(_ ptr: UnsafeRawPointer, maxLen: Int) -> String {
        var chars: [UInt8] = []
        for i in 0..<maxLen {
            let c = ptr.load(fromByteOffset: i, as: UInt8.self)
            if c == 0 { break }
            chars.append(c)
        }
        return String(bytes: chars, encoding: .utf8) ?? ""
    }

    private func readVec3(_ ptr: UnsafeRawPointer, at offset: Int) -> Vec3 {
        return Vec3(
            ptr.loadUnaligned(fromByteOffset: offset, as: Float.self),
            ptr.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
            ptr.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
        )
    }
}

// MARK: - Model Cache

class ModelCache {
    static let shared = ModelCache()

    private var models: [String: MD3Model] = [:]

    private init() {}

    func loadModel(_ path: String) -> MD3Model? {
        let key = path.lowercased()
        if let cached = models[key] { return cached }

        guard let data = Q3FileSystem.shared.loadFile(path) else {
            return nil
        }

        let model = MD3Model()
        guard model.load(from: data) else { return nil }

        models[key] = model
        return model
    }

    func clear() {
        models.removeAll()
    }
}
