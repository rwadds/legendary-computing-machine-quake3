// BSPFile.swift — BSP v46 file reader (17 lumps)

import Foundation
import simd

// MARK: - BSP Constants

let BSP_IDENT: UInt32 = (UInt32(Character("P").asciiValue!) << 24) |
                         (UInt32(Character("S").asciiValue!) << 16) |
                         (UInt32(Character("B").asciiValue!) << 8) |
                         UInt32(Character("I").asciiValue!)
let BSP_VERSION: Int32 = 46

let LIGHTMAP_WIDTH = 128
let LIGHTMAP_HEIGHT = 128

enum BSPLump: Int {
    case entities = 0
    case shaders
    case planes
    case nodes
    case leafs
    case leafSurfaces
    case leafBrushes
    case models
    case brushes
    case brushSides
    case drawVerts
    case drawIndexes
    case fogs
    case surfaces
    case lightmaps
    case lightGrid
    case visibility
    static let count = 17
}

enum BSPSurfaceType: Int32 {
    case bad = 0
    case planar
    case patch
    case triangleSoup
    case flare
}

// MARK: - BSP Lump Structures

struct BSPLumpEntry {
    var offset: Int32
    var length: Int32
}

struct BSPShaderEntry {
    var name: String        // 64 chars
    var surfaceFlags: Int32
    var contentFlags: Int32
}

struct BSPPlane {
    var normal: Vec3
    var dist: Float
}

struct BSPNode {
    var planeNum: Int32
    var children: (Int32, Int32)
    var mins: SIMD3<Int32>
    var maxs: SIMD3<Int32>
}

struct BSPLeaf {
    var cluster: Int32
    var area: Int32
    var mins: SIMD3<Int32>
    var maxs: SIMD3<Int32>
    var firstLeafSurface: Int32
    var numLeafSurfaces: Int32
    var firstLeafBrush: Int32
    var numLeafBrushes: Int32
}

struct BSPModel {
    var mins: Vec3
    var maxs: Vec3
    var firstSurface: Int32
    var numSurfaces: Int32
    var firstBrush: Int32
    var numBrushes: Int32
}

struct BSPBrush {
    var firstSide: Int32
    var numSides: Int32
    var shaderNum: Int32
}

struct BSPBrushSide {
    var planeNum: Int32
    var shaderNum: Int32
}

struct BSPDrawVert {
    var xyz: Vec3
    var st: SIMD2<Float>       // texture coords
    var lightmap: SIMD2<Float> // lightmap coords
    var normal: Vec3
    var color: (UInt8, UInt8, UInt8, UInt8)
}

struct BSPSurface {
    var shaderNum: Int32
    var fogNum: Int32
    var surfaceType: Int32
    var firstVert: Int32
    var numVerts: Int32
    var firstIndex: Int32
    var numIndexes: Int32
    var lightmapNum: Int32
    var lightmapX: Int32
    var lightmapY: Int32
    var lightmapWidth: Int32
    var lightmapHeight: Int32
    var lightmapOrigin: Vec3
    var lightmapVecs: (Vec3, Vec3, Vec3)
    var patchWidth: Int32
    var patchHeight: Int32
}

struct BSPFog {
    var name: String  // 64 chars
    var brushNum: Int32
    var visibleSide: Int32
}

struct BSPVisibility {
    var numClusters: Int32
    var clusterBytes: Int32
    var data: [UInt8]
}

// MARK: - BSP File Parser

class BSPFile {
    var shaders: [BSPShaderEntry] = []
    var planes: [BSPPlane] = []
    var nodes: [BSPNode] = []
    var leafs: [BSPLeaf] = []
    var leafSurfaces: [Int32] = []
    var leafBrushes: [Int32] = []
    var models: [BSPModel] = []
    var brushes: [BSPBrush] = []
    var brushSides: [BSPBrushSide] = []
    var drawVerts: [BSPDrawVert] = []
    var drawIndexes: [Int32] = []
    var fogs: [BSPFog] = []
    var surfaces: [BSPSurface] = []
    var lightmapData: Data = Data()
    var lightGridData: Data = Data()
    var visibility: BSPVisibility = BSPVisibility(numClusters: 0, clusterBytes: 0, data: [])
    var entityString: String = ""

    func load(from data: Data) -> Bool {
        guard data.count >= 148 else {  // header = 4 + 4 + 17*8 = 144 min
            Q3Console.shared.print("BSP file too small")
            return false
        }

        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!

            // Verify ident and version
            let ident = readInt32(base, at: 0)
            let version = readInt32(base, at: 4)

            if UInt32(bitPattern: ident) != BSP_IDENT {
                Q3Console.shared.print("Not a valid BSP file (bad ident)")
                return false
            }
            if version != BSP_VERSION {
                Q3Console.shared.print("Wrong BSP version: \(version) (expected \(BSP_VERSION))")
                return false
            }

            // Read lump directory
            var lumps: [BSPLumpEntry] = []
            for i in 0..<BSPLump.count {
                let offset = 8 + i * 8
                let lumpOffset = readInt32(base, at: offset)
                let lumpLength = readInt32(base, at: offset + 4)
                lumps.append(BSPLumpEntry(offset: lumpOffset, length: lumpLength))
            }

            // Parse each lump
            parseEntities(base, lump: lumps[BSPLump.entities.rawValue])
            parseShaders(base, lump: lumps[BSPLump.shaders.rawValue])
            parsePlanes(base, lump: lumps[BSPLump.planes.rawValue])
            parseNodes(base, lump: lumps[BSPLump.nodes.rawValue])
            parseLeafs(base, lump: lumps[BSPLump.leafs.rawValue])
            parseLeafSurfaces(base, lump: lumps[BSPLump.leafSurfaces.rawValue])
            parseLeafBrushes(base, lump: lumps[BSPLump.leafBrushes.rawValue])
            parseModels(base, lump: lumps[BSPLump.models.rawValue])
            parseBrushes(base, lump: lumps[BSPLump.brushes.rawValue])
            parseBrushSides(base, lump: lumps[BSPLump.brushSides.rawValue])
            parseDrawVerts(base, lump: lumps[BSPLump.drawVerts.rawValue])
            parseDrawIndexes(base, lump: lumps[BSPLump.drawIndexes.rawValue])
            parseFogs(base, lump: lumps[BSPLump.fogs.rawValue])
            parseSurfaces(base, lump: lumps[BSPLump.surfaces.rawValue])
            parseLightmaps(data, lump: lumps[BSPLump.lightmaps.rawValue])
            parseLightGrid(data, lump: lumps[BSPLump.lightGrid.rawValue])
            parseVisibility(base, lump: lumps[BSPLump.visibility.rawValue], dataCount: data.count)

            Q3Console.shared.print("BSP loaded: \(shaders.count) shaders, \(planes.count) planes, \(nodes.count) nodes, \(leafs.count) leafs")
            Q3Console.shared.print("  \(drawVerts.count) verts, \(drawIndexes.count) indexes, \(surfaces.count) surfaces")
            Q3Console.shared.print("  \(models.count) models, \(brushes.count) brushes, \(fogs.count) fogs")
            Q3Console.shared.print("  \(visibility.numClusters) vis clusters")

            return true
        }
    }

    // MARK: - Lump Parsers

    private func parseEntities(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        guard lump.length > 0 else { return }
        let ptr = base.advanced(by: Int(lump.offset))
        if let str = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(lump.length)), encoding: .utf8) {
            entityString = str.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
    }

    private func parseShaders(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 72  // 64 + 4 + 4
        let count = Int(lump.length) / stride
        shaders.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            let name = readString(base, at: offset, maxLen: 64)
            let surfFlags = readInt32(base, at: offset + 64)
            let contFlags = readInt32(base, at: offset + 68)
            shaders.append(BSPShaderEntry(name: name, surfaceFlags: surfFlags, contentFlags: contFlags))
        }
    }

    private func parsePlanes(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 16  // 3*4 + 4
        let count = Int(lump.length) / stride
        planes.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            let normal = readVec3(base, at: offset)
            let dist = readFloat(base, at: offset + 12)
            planes.append(BSPPlane(normal: normal, dist: dist))
        }
    }

    private func parseNodes(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 36  // 4 + 2*4 + 3*4 + 3*4
        let count = Int(lump.length) / stride
        nodes.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            let planeNum = readInt32(base, at: offset)
            let child0 = readInt32(base, at: offset + 4)
            let child1 = readInt32(base, at: offset + 8)
            let mins = SIMD3<Int32>(readInt32(base, at: offset + 12), readInt32(base, at: offset + 16), readInt32(base, at: offset + 20))
            let maxs = SIMD3<Int32>(readInt32(base, at: offset + 24), readInt32(base, at: offset + 28), readInt32(base, at: offset + 32))
            nodes.append(BSPNode(planeNum: planeNum, children: (child0, child1), mins: mins, maxs: maxs))
        }
    }

    private func parseLeafs(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 48  // 4+4+3*4+3*4+4+4+4+4
        let count = Int(lump.length) / stride
        leafs.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            leafs.append(BSPLeaf(
                cluster: readInt32(base, at: offset),
                area: readInt32(base, at: offset + 4),
                mins: SIMD3<Int32>(readInt32(base, at: offset + 8), readInt32(base, at: offset + 12), readInt32(base, at: offset + 16)),
                maxs: SIMD3<Int32>(readInt32(base, at: offset + 20), readInt32(base, at: offset + 24), readInt32(base, at: offset + 28)),
                firstLeafSurface: readInt32(base, at: offset + 32),
                numLeafSurfaces: readInt32(base, at: offset + 36),
                firstLeafBrush: readInt32(base, at: offset + 40),
                numLeafBrushes: readInt32(base, at: offset + 44)
            ))
        }
    }

    private func parseLeafSurfaces(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let count = Int(lump.length) / 4
        leafSurfaces.reserveCapacity(count)
        for i in 0..<count {
            leafSurfaces.append(readInt32(base, at: Int(lump.offset) + i * 4))
        }
    }

    private func parseLeafBrushes(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let count = Int(lump.length) / 4
        leafBrushes.reserveCapacity(count)
        for i in 0..<count {
            leafBrushes.append(readInt32(base, at: Int(lump.offset) + i * 4))
        }
    }

    private func parseModels(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 40  // 3*4 + 3*4 + 4 + 4 + 4 + 4
        let count = Int(lump.length) / stride
        models.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            models.append(BSPModel(
                mins: readVec3(base, at: offset),
                maxs: readVec3(base, at: offset + 12),
                firstSurface: readInt32(base, at: offset + 24),
                numSurfaces: readInt32(base, at: offset + 28),
                firstBrush: readInt32(base, at: offset + 32),
                numBrushes: readInt32(base, at: offset + 36)
            ))
        }
    }

    private func parseBrushes(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 12
        let count = Int(lump.length) / stride
        brushes.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            brushes.append(BSPBrush(
                firstSide: readInt32(base, at: offset),
                numSides: readInt32(base, at: offset + 4),
                shaderNum: readInt32(base, at: offset + 8)
            ))
        }
    }

    private func parseBrushSides(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 8
        let count = Int(lump.length) / stride
        brushSides.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            brushSides.append(BSPBrushSide(
                planeNum: readInt32(base, at: offset),
                shaderNum: readInt32(base, at: offset + 4)
            ))
        }
    }

    private func parseDrawVerts(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 44  // 3*4 + 2*4 + 2*4 + 3*4 + 4
        let count = Int(lump.length) / stride
        drawVerts.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            let xyz = readVec3(base, at: offset)
            let st = SIMD2<Float>(readFloat(base, at: offset + 12), readFloat(base, at: offset + 16))
            let lm = SIMD2<Float>(readFloat(base, at: offset + 20), readFloat(base, at: offset + 24))
            let normal = readVec3(base, at: offset + 28)
            let r = base.load(fromByteOffset: offset + 40, as: UInt8.self)
            let g = base.load(fromByteOffset: offset + 41, as: UInt8.self)
            let b = base.load(fromByteOffset: offset + 42, as: UInt8.self)
            let a = base.load(fromByteOffset: offset + 43, as: UInt8.self)
            drawVerts.append(BSPDrawVert(xyz: xyz, st: st, lightmap: lm, normal: normal, color: (r, g, b, a)))
        }
    }

    private func parseDrawIndexes(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let count = Int(lump.length) / 4
        drawIndexes.reserveCapacity(count)
        for i in 0..<count {
            drawIndexes.append(readInt32(base, at: Int(lump.offset) + i * 4))
        }
    }

    private func parseFogs(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 72  // 64 + 4 + 4
        let count = Int(lump.length) / stride
        fogs.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            let name = readString(base, at: offset, maxLen: 64)
            let brushNum = readInt32(base, at: offset + 64)
            let visibleSide = readInt32(base, at: offset + 68)
            fogs.append(BSPFog(name: name, brushNum: brushNum, visibleSide: visibleSide))
        }
    }

    private func parseSurfaces(_ base: UnsafeRawPointer, lump: BSPLumpEntry) {
        let stride = 104  // 12*4 + 3*12 + 2*4
        let count = Int(lump.length) / stride
        surfaces.reserveCapacity(count)

        for i in 0..<count {
            let offset = Int(lump.offset) + i * stride
            surfaces.append(BSPSurface(
                shaderNum: readInt32(base, at: offset),
                fogNum: readInt32(base, at: offset + 4),
                surfaceType: readInt32(base, at: offset + 8),
                firstVert: readInt32(base, at: offset + 12),
                numVerts: readInt32(base, at: offset + 16),
                firstIndex: readInt32(base, at: offset + 20),
                numIndexes: readInt32(base, at: offset + 24),
                lightmapNum: readInt32(base, at: offset + 28),
                lightmapX: readInt32(base, at: offset + 32),
                lightmapY: readInt32(base, at: offset + 36),
                lightmapWidth: readInt32(base, at: offset + 40),
                lightmapHeight: readInt32(base, at: offset + 44),
                lightmapOrigin: readVec3(base, at: offset + 48),
                lightmapVecs: (readVec3(base, at: offset + 60), readVec3(base, at: offset + 72), readVec3(base, at: offset + 84)),
                patchWidth: readInt32(base, at: offset + 96),
                patchHeight: readInt32(base, at: offset + 100)
            ))
        }
    }

    private func parseLightmaps(_ data: Data, lump: BSPLumpEntry) {
        guard lump.length > 0 else { return }
        lightmapData = data[Int(lump.offset)..<Int(lump.offset + lump.length)]
    }

    private func parseLightGrid(_ data: Data, lump: BSPLumpEntry) {
        guard lump.length > 0 else { return }
        lightGridData = data[Int(lump.offset)..<Int(lump.offset + lump.length)]
    }

    private func parseVisibility(_ base: UnsafeRawPointer, lump: BSPLumpEntry, dataCount: Int) {
        guard lump.length > 8 else { return }
        let offset = Int(lump.offset)
        let numClusters = readInt32(base, at: offset)
        let clusterBytes = readInt32(base, at: offset + 4)
        let visDataSize = Int(lump.length) - 8
        var visData = [UInt8](repeating: 0, count: visDataSize)
        if visDataSize > 0 {
            memcpy(&visData, base.advanced(by: offset + 8), visDataSize)
        }
        visibility = BSPVisibility(numClusters: numClusters, clusterBytes: clusterBytes, data: visData)
    }

    // MARK: - Binary Read Helpers

    private func readInt32(_ base: UnsafeRawPointer, at offset: Int) -> Int32 {
        return base.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
    }

    private func readFloat(_ base: UnsafeRawPointer, at offset: Int) -> Float {
        return Float(bitPattern: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
    }

    private func readVec3(_ base: UnsafeRawPointer, at offset: Int) -> Vec3 {
        return Vec3(readFloat(base, at: offset), readFloat(base, at: offset + 4), readFloat(base, at: offset + 8))
    }

    private func readString(_ base: UnsafeRawPointer, at offset: Int, maxLen: Int) -> String {
        var bytes: [UInt8] = []
        for i in 0..<maxLen {
            let b = base.load(fromByteOffset: offset + i, as: UInt8.self)
            if b == 0 { break }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
