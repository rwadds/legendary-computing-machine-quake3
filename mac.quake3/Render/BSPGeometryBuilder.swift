// BSPGeometryBuilder.swift — Convert BSP drawVerts + indices → Metal vertex/index buffers

import Foundation
import Metal
import simd

// GPU vertex format (matches Q3Vertex in ShaderTypes.h)
struct Q3GPUVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
    var lightmapCoord: SIMD2<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

// Draw call for a single surface
struct Q3DrawSurface {
    var shaderIndex: Int           // Index into shader array
    var lightmapIndex: Int         // Lightmap texture index (-1 = none)
    var fogIndex: Int              // Fog index (-1 = none)
    var surfaceType: BSPSurfaceType
    var firstIndex: Int            // Offset into combined index buffer
    var indexCount: Int
    var sort: Float                // Sort order
    var cullType: CullType
    var stateBits: UInt32          // First stage state bits
    var textureHandle: Int         // Resolved diffuse texture handle
    var lightmapHandle: Int        // Resolved lightmap handle
}

class BSPGeometryBuilder {
    let device: MTLDevice

    private(set) var vertexBuffer: MTLBuffer?
    private(set) var indexBuffer: MTLBuffer?
    private(set) var drawSurfaces: [Q3DrawSurface] = []
    private(set) var vertexCount: Int = 0
    private(set) var indexCount: Int = 0

    init(device: MTLDevice) {
        self.device = device
    }

    func build(bspFile: BSPFile, textureCache: TextureCache, lightmapAtlas: LightmapAtlas, shaderParser: ShaderParser) {
        Q3Console.shared.print("Building BSP geometry...")

        // Convert all BSP verts to GPU format
        var gpuVerts: [Q3GPUVertex] = []
        gpuVerts.reserveCapacity(bspFile.drawVerts.count)

        for dv in bspFile.drawVerts {
            gpuVerts.append(Q3GPUVertex(
                position: dv.xyz,
                texCoord: dv.st,
                lightmapCoord: dv.lightmap,
                normal: dv.normal,
                color: SIMD4<Float>(Float(dv.color.0) / 255.0, Float(dv.color.1) / 255.0,
                                    Float(dv.color.2) / 255.0, Float(dv.color.3) / 255.0)
            ))
        }

        // Build indices per-surface (Q3 BSP indices are relative to each surface's firstVert)
        var allIndices: [UInt32] = []
        allIndices.reserveCapacity(bspFile.drawIndexes.count)
        var patchVertexStart = gpuVerts.count

        // Process each surface
        for (_, surf) in bspFile.surfaces.enumerated() {
            guard let surfType = BSPSurfaceType(rawValue: surf.surfaceType) else {
                continue
            }

            let shaderName = surf.shaderNum >= 0 && surf.shaderNum < bspFile.shaders.count
                ? bspFile.shaders[Int(surf.shaderNum)].name : ""

            // Skip nodraw surfaces
            if surf.shaderNum >= 0 && surf.shaderNum < bspFile.shaders.count {
                let shaderEntry = bspFile.shaders[Int(surf.shaderNum)]
                if shaderEntry.surfaceFlags & SURF_NODRAW != 0 {
                    continue
                }
            }

            // Resolve shader
            let shaderDef = shaderParser.findShader(shaderName)

            // Resolve textures
            let textureHandle: Int
            if let def = shaderDef, !def.stages.isEmpty {
                let firstBundle = def.stages[0].bundles[0]
                if firstBundle.isLightmap {
                    textureHandle = textureCache.whiteTexture
                } else if let firstName = firstBundle.imageNames.first {
                    textureHandle = textureCache.findOrLoad(firstName)
                } else {
                    textureHandle = textureCache.findOrLoad(shaderName)
                }
            } else {
                textureHandle = textureCache.findOrLoad(shaderName)
            }

            let lightmapHandle: Int
            if surf.lightmapNum >= 0 && surf.lightmapNum < lightmapAtlas.lightmapTextures.count {
                lightmapHandle = textureCache.lightmapHandle(for: Int(surf.lightmapNum))
            } else {
                lightmapHandle = textureCache.whiteTexture
            }

            switch surfType {
            case .planar, .triangleSoup:
                // Offset indices by firstVert to make them absolute into the global vertex buffer
                let absoluteFirstIndex = allIndices.count
                let firstVert = UInt32(surf.firstVert)
                for i in 0..<Int(surf.numIndexes) {
                    let relIdx = UInt32(bspFile.drawIndexes[Int(surf.firstIndex) + i])
                    allIndices.append(relIdx + firstVert)
                }

                let drawSurf = Q3DrawSurface(
                    shaderIndex: Int(surf.shaderNum),
                    lightmapIndex: Int(surf.lightmapNum),
                    fogIndex: Int(surf.fogNum),
                    surfaceType: surfType,
                    firstIndex: absoluteFirstIndex,
                    indexCount: Int(surf.numIndexes),
                    sort: shaderDef?.sort ?? ShaderSort.opaque.rawValue,
                    cullType: shaderDef?.cullType ?? .frontSided,
                    stateBits: shaderDef?.stages.first?.stateBits ?? GLState.default.rawValue,
                    textureHandle: textureHandle,
                    lightmapHandle: lightmapHandle
                )
                drawSurfaces.append(drawSurf)

            case .patch:
                // Tessellate bezier patch
                let cpWidth = Int(surf.patchWidth)
                let cpHeight = Int(surf.patchHeight)
                let firstVert = Int(surf.firstVert)
                let numVerts = Int(surf.numVerts)

                guard firstVert + numVerts <= bspFile.drawVerts.count else { continue }
                let controlPoints = Array(bspFile.drawVerts[firstVert..<firstVert + numVerts])

                if let result = BezierPatch.tessellate(controlPoints: controlPoints, width: cpWidth, height: cpHeight) {
                    let patchIndexStart = allIndices.count

                    // Add tessellated vertices
                    for pv in result.verts {
                        gpuVerts.append(Q3GPUVertex(
                            position: pv.xyz,
                            texCoord: pv.st,
                            lightmapCoord: pv.lightmap,
                            normal: pv.normal,
                            color: pv.color
                        ))
                    }

                    // Add indices (already offset by baseVertex in tessellation)
                    let baseOffset = UInt32(patchVertexStart)
                    for idx in result.indices {
                        allIndices.append(idx + baseOffset - UInt32(result.verts.isEmpty ? 0 : 0))
                    }

                    // Actually, the tessellator returns indices relative to its own vertex array
                    // We need to offset them to where we placed the verts in our global array
                    // Fix: The tessellator uses baseVertex=0, so offset here
                    let fixStart = patchIndexStart
                    for i in fixStart..<allIndices.count {
                        allIndices[i] = result.indices[i - fixStart] + UInt32(patchVertexStart)
                    }

                    let drawSurf = Q3DrawSurface(
                        shaderIndex: Int(surf.shaderNum),
                        lightmapIndex: Int(surf.lightmapNum),
                        fogIndex: Int(surf.fogNum),
                        surfaceType: surfType,
                        firstIndex: patchIndexStart,
                        indexCount: result.indices.count,
                        sort: shaderDef?.sort ?? ShaderSort.opaque.rawValue,
                        cullType: shaderDef?.cullType ?? .frontSided,
                        stateBits: shaderDef?.stages.first?.stateBits ?? GLState.default.rawValue,
                        textureHandle: textureHandle,
                        lightmapHandle: lightmapHandle
                    )
                    drawSurfaces.append(drawSurf)

                    patchVertexStart += result.verts.count
                }

            case .flare, .bad:
                break
            }
        }

        // Create Metal buffers
        vertexCount = gpuVerts.count
        indexCount = allIndices.count

        if vertexCount > 0 {
            vertexBuffer = device.makeBuffer(bytes: gpuVerts, length: vertexCount * MemoryLayout<Q3GPUVertex>.stride, options: .storageModeShared)
            vertexBuffer?.label = "BSP Vertex Buffer"
        }

        if indexCount > 0 {
            indexBuffer = device.makeBuffer(bytes: allIndices, length: indexCount * MemoryLayout<UInt32>.stride, options: .storageModeShared)
            indexBuffer?.label = "BSP Index Buffer"
        }

        // Sort draw surfaces by sort order, then shader
        drawSurfaces.sort { a, b in
            if a.sort != b.sort { return a.sort < b.sort }
            if a.textureHandle != b.textureHandle { return a.textureHandle < b.textureHandle }
            return a.lightmapHandle < b.lightmapHandle
        }

        // Count texture statistics
        var defaultCount = 0
        var defaultNames = Set<String>()
        var uniqueTextures = Set<Int>()
        for surf in drawSurfaces {
            uniqueTextures.insert(surf.textureHandle)
            if surf.textureHandle == textureCache.defaultTexture {
                defaultCount += 1
                if surf.shaderIndex >= 0 && surf.shaderIndex < bspFile.shaders.count {
                    defaultNames.insert(bspFile.shaders[surf.shaderIndex].name)
                }
            }
        }
        Q3Console.shared.print("BSP geometry built: \(vertexCount) verts, \(indexCount) indices, \(drawSurfaces.count) draw surfaces")
        Q3Console.shared.print("Textures: \(uniqueTextures.count) unique, \(defaultCount) surfaces using default (fallback)")
        if !defaultNames.isEmpty {
            for name in defaultNames.sorted().prefix(15) {
                Q3Console.shared.print("  FALLBACK: '\(name)'")
            }
        }
        Q3Console.shared.print("Texture cache: \(textureCache.textureCount) total loaded")
    }
}
