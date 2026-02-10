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
}
