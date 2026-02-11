// CollisionModel.swift — Brush-based collision (cm_trace.c equivalent)
// Matches ioquake3's CM_Trace, CM_TraceThroughTree, CM_TraceThroughBrush

import Foundation
import simd

private let SURFACE_CLIP_EPSILON: Float = 0.125

class CollisionModel {
    static let shared = CollisionModel()

    private var bspFile: BSPFile?
    private var planes: [BSPPlane] = []
    private var brushes: [BSPBrush] = []
    private var brushSides: [BSPBrushSide] = []
    private var leafs: [BSPLeaf] = []
    private var nodes: [BSPNode] = []
    private var shaders: [BSPShaderEntry] = []
    private var leafBrushes: [Int32] = []

    // Per-trace state (avoids passing many params through recursion)
    private var tw_start: Vec3 = .zero
    private var tw_end: Vec3 = .zero
    private var tw_offsets: [Vec3] = Array(repeating: .zero, count: 8)
    private var tw_extents: Vec3 = .zero
    private var tw_isPoint: Bool = true
    private var tw_contentMask: Int32 = 0
    private var tw_result: TraceResult = TraceResult()
    // Track which brushes we've already tested to avoid duplicates
    private var checkedBrushes: Set<Int> = []

    private init() {}

    func load(from bspFile: BSPFile) {
        self.bspFile = bspFile
        self.planes = bspFile.planes
        self.brushes = bspFile.brushes
        self.brushSides = bspFile.brushSides
        self.leafs = bspFile.leafs
        self.nodes = bspFile.nodes
        self.shaders = bspFile.shaders
        self.leafBrushes = bspFile.leafBrushes

        Q3Console.shared.print("Collision model loaded: \(brushes.count) brushes, \(brushSides.count) sides")
    }

    // MARK: - Inline Model Bounds

    /// Get bounds for an inline BSP model (e.g. "*1", "*2", etc.)
    func inlineModelBounds(_ modelIndex: Int) -> (mins: Vec3, maxs: Vec3)? {
        guard let bsp = bspFile, modelIndex >= 0 && modelIndex < bsp.models.count else { return nil }
        let model = bsp.models[modelIndex]
        return (model.mins, model.maxs)
    }

    // MARK: - Trace (CM_Trace equivalent)

    func trace(start: Vec3, end: Vec3, mins: Vec3, maxs: Vec3, contentMask: Int32) -> TraceResult {
        tw_result = TraceResult()
        tw_result.fraction = 1.0
        tw_result.endpos = end
        tw_contentMask = contentMask
        checkedBrushes.removeAll(keepingCapacity: true)

        guard bspFile != nil else { return tw_result }

        // Symmetrize the bounding box (ioquake3 CM_Trace)
        let offset = (mins + maxs) * 0.5
        let symmMins = mins - offset
        let symmMaxs = maxs - offset
        let adjustedStart = start + offset
        let adjustedEnd = end + offset

        tw_start = adjustedStart
        tw_end = adjustedEnd

        // Build offsets[8] — the 8 corners of the bbox indexed by signbits
        // signbits: bit0 = normal.x<0, bit1 = normal.y<0, bit2 = normal.z<0
        // offset[i][axis] = (signbit set for axis) ? maxs[axis] : mins[axis]
        for i in 0..<8 {
            tw_offsets[i] = Vec3(
                (i & 1) != 0 ? symmMaxs.x : symmMins.x,
                (i & 2) != 0 ? symmMaxs.y : symmMins.y,
                (i & 4) != 0 ? symmMaxs.z : symmMins.z
            )
        }

        // Detect point trace
        tw_isPoint = (symmMins.x == 0 && symmMins.y == 0 && symmMins.z == 0 &&
                      symmMaxs.x == 0 && symmMaxs.y == 0 && symmMaxs.z == 0)

        // Compute extents for tree traversal
        if tw_isPoint {
            tw_extents = .zero
        } else {
            tw_extents = Vec3(
                max(-symmMins.x, symmMaxs.x),
                max(-symmMins.y, symmMaxs.y),
                max(-symmMins.z, symmMaxs.z)
            )
        }

        // Traverse the BSP tree
        traceNode(0, p1f: 0, p2f: 1, p1: adjustedStart, p2: adjustedEnd)

        // Compute endpos from ORIGINAL (unadjusted) start/end
        if tw_result.fraction < 1.0 {
            tw_result.endpos = start + (end - start) * tw_result.fraction
        } else {
            tw_result.endpos = end
        }

        return tw_result
    }

    // MARK: - Trace Through Tree (CM_TraceThroughTree equivalent)

    private func traceNode(_ nodeIdx: Int32, p1f: Float, p2f: Float, p1: Vec3, p2: Vec3) {
        // Early out if we already hit something closer
        if tw_result.fraction <= p1f {
            return
        }

        // Leaf node — test brushes
        if nodeIdx < 0 {
            let leafIdx = Int(-(nodeIdx + 1))
            guard leafIdx >= 0 && leafIdx < leafs.count else { return }
            let leaf = leafs[leafIdx]

            for i in 0..<Int(leaf.numLeafBrushes) {
                let brushIdx = Int(leafBrushes[Int(leaf.firstLeafBrush) + i])
                guard brushIdx >= 0 && brushIdx < brushes.count else { continue }

                // Skip already-tested brushes
                if checkedBrushes.contains(brushIdx) { continue }
                checkedBrushes.insert(brushIdx)

                let brush = brushes[brushIdx]

                // Check content flags
                if brush.shaderNum >= 0 && Int(brush.shaderNum) < shaders.count {
                    let shader = shaders[Int(brush.shaderNum)]
                    if shader.contentFlags & tw_contentMask == 0 { continue }
                }

                traceBrush(brush)
            }
            return
        }

        // Internal node — split by plane
        guard Int(nodeIdx) < nodes.count else { return }
        let node = nodes[Int(nodeIdx)]
        guard Int(node.planeNum) < planes.count else { return }
        let plane = planes[Int(node.planeNum)]

        // Compute plane distances from p1 and p2
        let t1: Float
        let t2: Float
        let offset: Float

        // Determine plane type: axial X(0), Y(1), Z(2), or non-axial(3)
        let normal = plane.normal
        let planeType: Int
        if normal.x == 1.0 || normal.x == -1.0 {
            planeType = 0
        } else if normal.y == 1.0 || normal.y == -1.0 {
            planeType = 1
        } else if normal.z == 1.0 || normal.z == -1.0 {
            planeType = 2
        } else {
            planeType = 3
        }

        if planeType < 3 {
            // Axial plane — fast path
            t1 = p1[planeType] - plane.dist
            t2 = p2[planeType] - plane.dist
            offset = tw_extents[planeType]
        } else {
            // Non-axial plane
            t1 = simd_dot(normal, p1) - plane.dist
            t2 = simd_dot(normal, p2) - plane.dist
            if tw_isPoint {
                offset = 0
            } else {
                // ioquake3 uses a conservative 2048 offset for non-axial traces
                // This is not ideal but correct — any brush that's close enough to matter
                // will be properly tested in traceBrush
                offset = 2048.0
            }
        }

        // Both sides in front — traverse front child only
        if t1 >= offset + 1 && t2 >= offset + 1 {
            traceNode(node.children.0, p1f: p1f, p2f: p2f, p1: p1, p2: p2)
            return
        }

        // Both sides in back — traverse back child only
        if t1 < -offset - 1 && t2 < -offset - 1 {
            traceNode(node.children.1, p1f: p1f, p2f: p2f, p1: p1, p2: p2)
            return
        }

        // Split — need to traverse both children
        let side: Int     // 0 = front near, 1 = back near
        let frac1: Float  // fraction to near side
        let frac2: Float  // fraction to far side

        if t1 < t2 {
            let idist = 1.0 / (t1 - t2)
            side = 1
            frac2 = (t1 + offset + SURFACE_CLIP_EPSILON) * idist
            frac1 = (t1 - offset + SURFACE_CLIP_EPSILON) * idist
        } else if t1 > t2 {
            let idist = 1.0 / (t1 - t2)
            side = 0
            frac2 = (t1 - offset - SURFACE_CLIP_EPSILON) * idist
            frac1 = (t1 + offset + SURFACE_CLIP_EPSILON) * idist
        } else {
            side = 0
            frac1 = 1
            frac2 = 0
        }

        // Clamp fractions
        let clampedFrac1 = max(0, min(1, frac1))
        let clampedFrac2 = max(0, min(1, frac2))

        // Calculate the midpoint for near side
        let midf1 = p1f + (p2f - p1f) * clampedFrac1
        let mid1 = p1 + (p2 - p1) * clampedFrac1

        // Traverse near side first
        let nearChild = side == 0 ? node.children.0 : node.children.1
        let farChild = side == 0 ? node.children.1 : node.children.0
        traceNode(nearChild, p1f: p1f, p2f: midf1, p1: p1, p2: mid1)

        // Calculate the midpoint for far side
        let midf2 = p1f + (p2f - p1f) * clampedFrac2
        let mid2 = p1 + (p2 - p1) * clampedFrac2

        // Traverse far side
        traceNode(farChild, p1f: midf2, p2f: p2f, p1: mid2, p2: p2)
    }

    // MARK: - Trace Through Brush (CM_TraceThroughBrush equivalent)

    private func traceBrush(_ brush: BSPBrush) {
        guard brush.numSides > 0 else { return }

        var enterFrac: Float = -1.0
        var leaveFrac: Float = 1.0
        var startOut = false
        var getOut = false
        var hitPlane: BSPPlane?

        for i in 0..<Int(brush.numSides) {
            let sideIdx = Int(brush.firstSide) + i
            guard sideIdx < brushSides.count else { continue }
            let side = brushSides[sideIdx]
            guard Int(side.planeNum) < planes.count else { continue }
            let plane = planes[Int(side.planeNum)]

            // Compute signbits from plane normal
            let signbits = (plane.normal.x < 0 ? 1 : 0) |
                           (plane.normal.y < 0 ? 2 : 0) |
                           (plane.normal.z < 0 ? 4 : 0)

            // Adjust plane distance by bbox corner corresponding to signbits
            let dist = plane.dist - simd_dot(tw_offsets[signbits], plane.normal)

            let d1 = simd_dot(plane.normal, tw_start) - dist
            let d2 = simd_dot(plane.normal, tw_end) - dist

            if d1 > 0 { startOut = true }
            if d2 > 0 { getOut = true }

            // If completely in front of this side, trace misses the brush
            if d1 > 0 && (d2 >= SURFACE_CLIP_EPSILON || d2 >= d1) {
                return
            }

            // If completely behind this side, doesn't matter
            if d1 <= 0 && d2 <= 0 { continue }

            if d1 > d2 {
                // Entering the brush
                let f = (d1 - SURFACE_CLIP_EPSILON) / (d1 - d2)
                let fClamped = max(0, f)
                if fClamped > enterFrac {
                    enterFrac = fClamped
                    hitPlane = plane
                }
            } else {
                // Leaving the brush
                let f = (d1 + SURFACE_CLIP_EPSILON) / (d1 - d2)
                let fClamped = min(1, f)
                if fClamped < leaveFrac {
                    leaveFrac = fClamped
                }
            }
        }

        if !startOut {
            // Started inside the brush
            tw_result.startsolid = true
            if !getOut {
                tw_result.allsolid = true
                tw_result.fraction = 0
            }
            return
        }

        if enterFrac < leaveFrac && enterFrac > -1 && enterFrac < tw_result.fraction {
            tw_result.fraction = max(0, enterFrac)
            if let hp = hitPlane {
                tw_result.plane.normal = hp.normal
                tw_result.plane.dist = hp.dist
            }
        }
    }

    // MARK: - Point Contents

    func pointContents(at point: Vec3) -> Int32 {
        guard bspFile != nil else { return 0 }

        var nodeIdx: Int32 = 0
        while nodeIdx >= 0 {
            guard Int(nodeIdx) < nodes.count else { return 0 }
            let node = nodes[Int(nodeIdx)]
            guard Int(node.planeNum) < planes.count else { return 0 }
            let plane = planes[Int(node.planeNum)]

            let dist = simd_dot(plane.normal, point) - plane.dist
            if dist >= 0 {
                nodeIdx = node.children.0
            } else {
                nodeIdx = node.children.1
            }
        }

        let leafIdx = Int(-(nodeIdx + 1))
        guard leafIdx >= 0 && leafIdx < leafs.count else { return 0 }
        let leaf = leafs[leafIdx]

        var contents: Int32 = 0
        for i in 0..<Int(leaf.numLeafBrushes) {
            let brushIdx = leafBrushes[Int(leaf.firstLeafBrush) + i]
            guard brushIdx >= 0 && Int(brushIdx) < brushes.count else { continue }
            let brush = brushes[Int(brushIdx)]
            if brush.shaderNum >= 0 && Int(brush.shaderNum) < shaders.count {
                contents |= shaders[Int(brush.shaderNum)].contentFlags
            }
        }

        return contents
    }

    // MARK: - Mark Fragments (R_MarkFragments equivalent)

    // Per-markFragment state (avoids passing many params through recursion)
    private var mf_projDir: Vec3 = .zero
    private var mf_clipNormals: [Vec3] = []
    private var mf_clipDists: [Float] = []
    private var mf_bboxMins: Vec3 = .zero
    private var mf_bboxMaxs: Vec3 = .zero
    private var mf_vm: QVM?
    private var mf_pointBufAddr: Int = 0
    private var mf_fragBufAddr: Int = 0
    private var mf_maxPoints: Int = 0
    private var mf_maxFragments: Int = 0
    private var mf_totalPoints: Int = 0
    private var mf_totalFragments: Int = 0
    private var mf_checkedSurfaces: Set<Int> = []

    func markFragments(
        vm: QVM,
        numPoints: Int,
        pointsAddr: Int32,
        projectionAddr: Int32,
        maxPoints: Int,
        pointBufferAddr: Int32,
        maxFragments: Int,
        fragmentBufferAddr: Int32
    ) -> Int32 {
        guard let bspFile = bspFile else { return 0 }
        guard numPoints >= 3, numPoints <= 64 else { return 0 }
        guard maxPoints >= 3, maxFragments >= 1 else { return 0 }

        // Read input polygon points
        var points: [Vec3] = []
        for i in 0..<numPoints {
            let addr = Int(pointsAddr) + i * 12
            points.append(readVec3FromVM(vm, addr: addr))
        }

        // Read projection direction
        let projection = readVec3FromVM(vm, addr: Int(projectionAddr))
        let projLen = simd_length(projection)
        guard projLen > 0.001 else { return 0 }
        mf_projDir = projection / projLen

        // Build clipping planes from polygon edges + near/far
        mf_clipNormals = []
        mf_clipDists = []

        for i in 0..<numPoints {
            let j = (i + 1) % numPoints
            let edge = points[j] - points[i]
            var normal = simd_cross(mf_projDir, edge)
            let len = simd_length(normal)
            guard len > 0.001 else { continue }
            normal /= len
            mf_clipNormals.append(normal)
            mf_clipDists.append(simd_dot(normal, points[i]))
        }

        // Near plane: 32 units behind the polygon along -projection
        mf_clipNormals.append(mf_projDir)
        mf_clipDists.append(simd_dot(mf_projDir, points[0]) - 32)

        // Far plane: 20 units in front of polygon along projection
        mf_clipNormals.append(-mf_projDir)
        mf_clipDists.append(simd_dot(-mf_projDir, points[0]) - 20)

        // Compute bounding box of projected volume
        mf_bboxMins = Vec3(repeating: Float.greatestFiniteMagnitude)
        mf_bboxMaxs = Vec3(repeating: -Float.greatestFiniteMagnitude)
        for p in points {
            mf_bboxMins = simd_min(mf_bboxMins, p)
            mf_bboxMaxs = simd_max(mf_bboxMaxs, p)
            let projected = p + projection
            mf_bboxMins = simd_min(mf_bboxMins, projected)
            mf_bboxMaxs = simd_max(mf_bboxMaxs, projected)
        }
        mf_bboxMins -= Vec3(repeating: 1)
        mf_bboxMaxs += Vec3(repeating: 1)

        // Set up state for recursive walk
        mf_vm = vm
        mf_pointBufAddr = Int(pointBufferAddr)
        mf_fragBufAddr = Int(fragmentBufferAddr)
        mf_maxPoints = maxPoints
        mf_maxFragments = maxFragments
        mf_totalPoints = 0
        mf_totalFragments = 0
        mf_checkedSurfaces.removeAll(keepingCapacity: true)

        // Walk BSP tree
        markWalkNode(0, bspFile: bspFile)

        mf_vm = nil
        return Int32(mf_totalFragments)
    }

    private func markWalkNode(_ nodeIdx: Int32, bspFile: BSPFile) {
        if mf_totalFragments >= mf_maxFragments { return }

        if nodeIdx < 0 {
            // Leaf node — check surfaces
            let leafIdx = Int(-(nodeIdx + 1))
            guard leafIdx < leafs.count else { return }
            let leaf = leafs[leafIdx]

            for i in 0..<Int(leaf.numLeafSurfaces) {
                let idx = Int(leaf.firstLeafSurface) + i
                guard idx < bspFile.leafSurfaces.count else { continue }
                let surfIdx = Int(bspFile.leafSurfaces[idx])
                if mf_checkedSurfaces.contains(surfIdx) { continue }
                mf_checkedSurfaces.insert(surfIdx)
                markProcessSurface(surfIdx, bspFile: bspFile)
                if mf_totalFragments >= mf_maxFragments { return }
            }
            return
        }

        // Internal node — split by plane
        guard Int(nodeIdx) < nodes.count else { return }
        let node = nodes[Int(nodeIdx)]
        guard Int(node.planeNum) < planes.count else { return }
        let plane = planes[Int(node.planeNum)]

        let side = markBoxOnPlaneSide(plane)
        if side == 1 {
            markWalkNode(node.children.0, bspFile: bspFile)
        } else if side == 2 {
            markWalkNode(node.children.1, bspFile: bspFile)
        } else {
            markWalkNode(node.children.0, bspFile: bspFile)
            markWalkNode(node.children.1, bspFile: bspFile)
        }
    }

    private func markBoxOnPlaneSide(_ plane: BSPPlane) -> Int {
        let n = plane.normal
        let front = Vec3(
            n.x >= 0 ? mf_bboxMaxs.x : mf_bboxMins.x,
            n.y >= 0 ? mf_bboxMaxs.y : mf_bboxMins.y,
            n.z >= 0 ? mf_bboxMaxs.z : mf_bboxMins.z
        )
        let back = Vec3(
            n.x >= 0 ? mf_bboxMins.x : mf_bboxMaxs.x,
            n.y >= 0 ? mf_bboxMins.y : mf_bboxMaxs.y,
            n.z >= 0 ? mf_bboxMins.z : mf_bboxMaxs.z
        )
        if simd_dot(n, front) - plane.dist <= 0 { return 2 }
        if simd_dot(n, back) - plane.dist >= 0 { return 1 }
        return 3
    }

    private func markProcessSurface(_ surfIdx: Int, bspFile: BSPFile) {
        guard surfIdx < bspFile.surfaces.count else { return }
        let surface = bspFile.surfaces[surfIdx]

        // Only planar faces (1) and triangle soups (3)
        guard surface.surfaceType == 1 || surface.surfaceType == 3 else { return }

        // Check SURF_NOMARKS (0x80) and SURF_NOIMPACT (0x10)
        if surface.shaderNum >= 0 && Int(surface.shaderNum) < shaders.count {
            let flags = shaders[Int(surface.shaderNum)].surfaceFlags
            if flags & 0x80 != 0 || flags & 0x10 != 0 { return }
        }

        // Get surface normal from first vertex
        guard surface.numVerts > 0 else { return }
        let firstVert = Int(surface.firstVert)
        guard firstVert < bspFile.drawVerts.count else { return }
        let surfNormal = bspFile.drawVerts[firstVert].normal

        // Surface must face toward the projection (dot < -0.5)
        if simd_dot(surfNormal, mf_projDir) > -0.5 { return }

        guard let vm = mf_vm else { return }

        // Process each triangle
        let numTris = Int(surface.numIndexes) / 3
        for t in 0..<numTris {
            if mf_totalFragments >= mf_maxFragments { return }

            let baseIdx = Int(surface.firstIndex) + t * 3
            guard baseIdx + 2 < bspFile.drawIndexes.count else { continue }
            let i0 = Int(bspFile.drawIndexes[baseIdx])
            let i1 = Int(bspFile.drawIndexes[baseIdx + 1])
            let i2 = Int(bspFile.drawIndexes[baseIdx + 2])

            guard firstVert + i0 < bspFile.drawVerts.count,
                  firstVert + i1 < bspFile.drawVerts.count,
                  firstVert + i2 < bspFile.drawVerts.count else { continue }

            let v0 = bspFile.drawVerts[firstVert + i0].xyz
            let v1 = bspFile.drawVerts[firstVert + i1].xyz
            let v2 = bspFile.drawVerts[firstVert + i2].xyz

            // Quick bbox reject
            let triMin = simd_min(simd_min(v0, v1), v2)
            let triMax = simd_max(simd_max(v0, v1), v2)
            if triMax.x < mf_bboxMins.x || triMin.x > mf_bboxMaxs.x ||
               triMax.y < mf_bboxMins.y || triMin.y > mf_bboxMaxs.y ||
               triMax.z < mf_bboxMins.z || triMin.z > mf_bboxMaxs.z {
                continue
            }

            // Clip triangle against all clipping planes (Sutherland-Hodgman)
            var poly: [Vec3] = [v0, v1, v2]
            for p in 0..<mf_clipNormals.count {
                guard poly.count >= 3 else { break }
                poly = clipPolyByPlane(poly, normal: mf_clipNormals[p], dist: mf_clipDists[p])
            }

            guard poly.count >= 3 else { continue }
            guard mf_totalPoints + poly.count <= mf_maxPoints else { continue }

            // Write clipped points to output buffer
            let firstPoint = mf_totalPoints
            for v in poly {
                let outAddr = mf_pointBufAddr + mf_totalPoints * 12
                writeFloatToVM(vm, addr: outAddr, value: v.x)
                writeFloatToVM(vm, addr: outAddr + 4, value: v.y)
                writeFloatToVM(vm, addr: outAddr + 8, value: v.z)
                mf_totalPoints += 1
            }

            // Write fragment entry (firstPoint, numPoints)
            let fragAddr = mf_fragBufAddr + mf_totalFragments * 8
            vm.writeInt32(toData: fragAddr, value: Int32(firstPoint))
            vm.writeInt32(toData: fragAddr + 4, value: Int32(poly.count))
            mf_totalFragments += 1
        }
    }

    private func clipPolyByPlane(_ poly: [Vec3], normal: Vec3, dist: Float) -> [Vec3] {
        var result: [Vec3] = []
        let count = poly.count

        for i in 0..<count {
            let curr = poly[i]
            let next = poly[(i + 1) % count]
            let currDist = simd_dot(normal, curr) - dist
            let nextDist = simd_dot(normal, next) - dist

            if currDist >= 0 {
                result.append(curr)
            }

            if (currDist > 0 && nextDist < 0) || (currDist < 0 && nextDist > 0) {
                let t = currDist / (currDist - nextDist)
                result.append(curr + (next - curr) * t)
            }
        }

        return result
    }

    private func readVec3FromVM(_ vm: QVM, addr: Int) -> Vec3 {
        let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: addr)))
        let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: addr + 4)))
        let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: addr + 8)))
        return Vec3(x, y, z)
    }

    private func writeFloatToVM(_ vm: QVM, addr: Int, value: Float) {
        vm.writeInt32(toData: addr, value: Int32(bitPattern: value.bitPattern))
    }
}
