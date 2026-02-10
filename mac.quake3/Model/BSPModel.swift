// BSPModel.swift — Runtime BSP world model with PVS and traversal

import Foundation
import simd

class BSPWorldModel {
    var bspFile: BSPFile

    init(bspFile: BSPFile) {
        self.bspFile = bspFile
    }

    // MARK: - PVS (Potentially Visible Set)

    func isClusterVisible(from viewCluster: Int32, to testCluster: Int32) -> Bool {
        let vis = bspFile.visibility
        if vis.numClusters <= 0 || vis.data.isEmpty { return true }
        if viewCluster < 0 { return true }
        if testCluster < 0 { return false }

        let byteOffset = Int(viewCluster) * Int(vis.clusterBytes) + Int(testCluster >> 3)
        guard byteOffset < vis.data.count else { return true }

        return (vis.data[byteOffset] & (1 << (testCluster & 7))) != 0
    }

    // MARK: - Leaf Finding

    func findLeaf(at point: Vec3) -> Int {
        var nodeIndex: Int32 = 0

        while nodeIndex >= 0 {
            guard Int(nodeIndex) < bspFile.nodes.count else { return 0 }
            let node = bspFile.nodes[Int(nodeIndex)]

            guard Int(node.planeNum) < bspFile.planes.count else { return 0 }
            let plane = bspFile.planes[Int(node.planeNum)]

            let dist = simd_dot(plane.normal, point) - plane.dist

            if dist >= 0 {
                nodeIndex = node.children.0
            } else {
                nodeIndex = node.children.1
            }
        }

        return Int(-(nodeIndex + 1))
    }

    func getCluster(at point: Vec3) -> Int32 {
        let leafIdx = findLeaf(at: point)
        guard leafIdx >= 0 && leafIdx < bspFile.leafs.count else { return -1 }
        return bspFile.leafs[leafIdx].cluster
    }

    // MARK: - Visible Surface Collection

    func collectVisibleSurfaces(from viewOrigin: Vec3, frustumPlanes: [Plane]) -> [Int] {
        let viewCluster = getCluster(at: viewOrigin)
        var visibleSurfaces: [Int] = []
        var surfaceMarked = [Bool](repeating: false, count: bspFile.surfaces.count)

        // Walk all leaves
        for leaf in bspFile.leafs {
            // PVS check
            if !isClusterVisible(from: viewCluster, to: leaf.cluster) { continue }

            // Frustum cull the leaf
            let leafMins = Vec3(Float(leaf.mins.x), Float(leaf.mins.y), Float(leaf.mins.z))
            let leafMaxs = Vec3(Float(leaf.maxs.x), Float(leaf.maxs.y), Float(leaf.maxs.z))
            if !boxInFrustum(mins: leafMins, maxs: leafMaxs, frustumPlanes: frustumPlanes) { continue }

            // Add all surfaces in this leaf
            let firstSurf = Int(leaf.firstLeafSurface)
            let numSurfs = Int(leaf.numLeafSurfaces)

            for i in 0..<numSurfs {
                let surfIdx = Int(bspFile.leafSurfaces[firstSurf + i])
                if surfIdx >= 0 && surfIdx < bspFile.surfaces.count && !surfaceMarked[surfIdx] {
                    surfaceMarked[surfIdx] = true
                    visibleSurfaces.append(surfIdx)
                }
            }
        }

        return visibleSurfaces
    }

    // MARK: - Frustum Culling

    private func boxInFrustum(mins: Vec3, maxs: Vec3, frustumPlanes: [Plane]) -> Bool {
        for plane in frustumPlanes {
            // Find the positive vertex (corner farthest along plane normal)
            var pVert = Vec3.zero
            pVert.x = plane.normal.x >= 0 ? maxs.x : mins.x
            pVert.y = plane.normal.y >= 0 ? maxs.y : mins.y
            pVert.z = plane.normal.z >= 0 ? maxs.z : mins.z

            if simd_dot(plane.normal, pVert) + plane.dist < 0 {
                return false
            }
        }
        return true
    }

    // MARK: - Entity String Parsing

    func parseEntities() -> [[String: String]] {
        var entities: [[String: String]] = []
        var current: [String: String]? = nil
        var chars = entityString.makeIterator()
        var inEntity = false

        func nextToken() -> String? {
            // Skip whitespace
            var ch: Character?
            repeat {
                ch = chars.next()
            } while ch != nil && (ch == " " || ch == "\t" || ch == "\n" || ch == "\r")

            guard let first = ch else { return nil }

            if first == "{" { return "{" }
            if first == "}" { return "}" }

            if first == "\"" {
                var token = ""
                while let c = chars.next() {
                    if c == "\"" { break }
                    token.append(c)
                }
                return token
            }

            var token = String(first)
            while let c = chars.next() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { break }
                token.append(c)
            }
            return token
        }

        let entityString = bspFile.entityString
        // Reset iterator
        chars = entityString.makeIterator()

        while let token = nextToken() {
            if token == "{" {
                current = [:]
                inEntity = true
            } else if token == "}" {
                if let entity = current {
                    entities.append(entity)
                }
                current = nil
                inEntity = false
            } else if inEntity {
                let key = token
                if let value = nextToken() {
                    current?[key] = value
                }
            }
        }

        return entities
    }

    var entityString: String { bspFile.entityString }
}
