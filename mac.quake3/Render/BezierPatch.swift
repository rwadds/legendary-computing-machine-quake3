// BezierPatch.swift — Tessellate Q3 curved surfaces

import Foundation
import simd

let MAX_PATCH_SIZE = 32
let MAX_GRID_SIZE = 65

struct PatchVert {
    var xyz: Vec3 = .zero
    var st: SIMD2<Float> = .zero
    var lightmap: SIMD2<Float> = .zero
    var normal: Vec3 = .zero
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
}

class BezierPatch {

    static func tessellate(controlPoints: [BSPDrawVert], width: Int, height: Int, subdivisions: Int = 4) -> (verts: [PatchVert], indices: [UInt32])? {
        guard width >= 3 && height >= 3 else { return nil }
        guard (width - 1) % 2 == 0 && (height - 1) % 2 == 0 else { return nil }

        let numPatchesX = (width - 1) / 2
        let numPatchesY = (height - 1) / 2

        var allVerts: [PatchVert] = []
        var allIndices: [UInt32] = []

        for py in 0..<numPatchesY {
            for px in 0..<numPatchesX {
                // Extract 3x3 control points
                var cp = [[PatchVert]](repeating: [PatchVert](repeating: PatchVert(), count: 3), count: 3)

                for cy in 0..<3 {
                    for cx in 0..<3 {
                        let srcX = px * 2 + cx
                        let srcY = py * 2 + cy
                        let srcIdx = srcY * width + srcX
                        guard srcIdx < controlPoints.count else { continue }
                        cp[cy][cx] = convertVert(controlPoints[srcIdx])
                    }
                }

                let (verts, indices) = tessellateBiQuadratic(cp, steps: subdivisions, baseVertex: UInt32(allVerts.count))
                allVerts.append(contentsOf: verts)
                allIndices.append(contentsOf: indices)
            }
        }

        return (allVerts, allIndices)
    }

    private static func convertVert(_ dv: BSPDrawVert) -> PatchVert {
        return PatchVert(
            xyz: dv.xyz,
            st: dv.st,
            lightmap: dv.lightmap,
            normal: dv.normal,
            color: SIMD4<Float>(Float(dv.color.0) / 255.0, Float(dv.color.1) / 255.0,
                                Float(dv.color.2) / 255.0, Float(dv.color.3) / 255.0)
        )
    }

    private static func tessellateBiQuadratic(_ cp: [[PatchVert]], steps: Int, baseVertex: UInt32) -> ([PatchVert], [UInt32]) {
        let size = steps + 1
        var verts = [PatchVert](repeating: PatchVert(), count: size * size)

        // Tessellate
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            for j in 0...steps {
                let s = Float(j) / Float(steps)

                // Bi-quadratic Bezier evaluation
                let b0s = (1 - s) * (1 - s)
                let b1s = 2 * s * (1 - s)
                let b2s = s * s

                let b0t = (1 - t) * (1 - t)
                let b1t = 2 * t * (1 - t)
                let b2t = t * t

                var v = PatchVert()

                for cy in 0..<3 {
                    let bt: Float
                    switch cy {
                    case 0: bt = b0t
                    case 1: bt = b1t
                    default: bt = b2t
                    }
                    for cx in 0..<3 {
                        let bs: Float
                        switch cx {
                        case 0: bs = b0s
                        case 1: bs = b1s
                        default: bs = b2s
                        }

                        let w = bs * bt
                        let p = cp[cy][cx]
                        v.xyz += p.xyz * w
                        v.st += p.st * w
                        v.lightmap += p.lightmap * w
                        v.normal += p.normal * w
                        v.color += p.color * w
                    }
                }

                // Normalize normal
                let len = simd_length(v.normal)
                if len > 0.001 {
                    v.normal /= len
                }

                verts[i * size + j] = v
            }
        }

        // Generate triangle strip indices
        var indices: [UInt32] = []
        indices.reserveCapacity(steps * steps * 6)

        for i in 0..<steps {
            for j in 0..<steps {
                let v00 = UInt32(i * size + j) + baseVertex
                let v10 = UInt32((i + 1) * size + j) + baseVertex
                let v01 = UInt32(i * size + j + 1) + baseVertex
                let v11 = UInt32((i + 1) * size + j + 1) + baseVertex

                indices.append(v00)
                indices.append(v10)
                indices.append(v01)

                indices.append(v01)
                indices.append(v10)
                indices.append(v11)
            }
        }

        return (verts, indices)
    }
}
