// RenderSky.swift — Skybox rendering for Q3

import Foundation
import Metal
import MetalKit
import simd

class RenderSky {
    // Skybox face order: right, back, left, front, up, down
    // Matches Q3 convention: _rt, _bk, _lf, _ft, _up, _dn
    static let faceSuffixes = ["_rt", "_bk", "_lf", "_ft", "_up", "_dn"]

    var skyTextureHandles: [Int] = []
    var hasSky = false
    var skyVertexBuffer: MTLBuffer?
    var skyIndexBuffer: MTLBuffer?
    var skyVertexCount = 0
    var skyIndexCount = 0

    struct SkyVertex {
        var position: SIMD3<Float>
        var texCoord: SIMD2<Float>
    }

    // MARK: - Setup

    func setup(device: MTLDevice, shaderDef: Q3ShaderDef, textureCache: TextureCache) {
        guard shaderDef.isSky && !shaderDef.skyBoxNames.isEmpty else {
            hasSky = false
            return
        }

        // Load sky textures
        skyTextureHandles = shaderDef.skyBoxNames.map { name in
            textureCache.findOrLoad(name)
        }

        guard skyTextureHandles.count == 6 else {
            hasSky = false
            return
        }

        hasSky = true
        buildSkyGeometry(device: device)
    }

    private func buildSkyGeometry(device: MTLDevice) {
        // Build 6 face quads at a large distance
        let size: Float = 4096.0

        // Define the 8 corners of a cube
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(-size, -size, -size), // 0: left  front bottom
            SIMD3<Float>( size, -size, -size), // 1: right front bottom
            SIMD3<Float>( size,  size, -size), // 2: right back  bottom
            SIMD3<Float>(-size,  size, -size), // 3: left  back  bottom
            SIMD3<Float>(-size, -size,  size), // 4: left  front top
            SIMD3<Float>( size, -size,  size), // 5: right front top
            SIMD3<Float>( size,  size,  size), // 6: right back  top
            SIMD3<Float>(-size,  size,  size), // 7: left  back  top
        ]

        // Face definitions (4 corners per face, CCW winding from outside)
        // Q3 order: right(+X), back(+Y), left(-X), front(-Y), up(+Z), down(-Z)
        let faceIndices: [[Int]] = [
            [1, 2, 6, 5], // right  (+X)
            [2, 3, 7, 6], // back   (+Y)
            [3, 0, 4, 7], // left   (-X)
            [0, 1, 5, 4], // front  (-Y)
            [4, 5, 6, 7], // up     (+Z)
            [3, 2, 1, 0], // down   (-Z)
        ]

        let uvs: [SIMD2<Float>] = [
            SIMD2<Float>(0, 1),
            SIMD2<Float>(1, 1),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 0),
        ]

        var vertices: [Q3GPUVertex] = []
        var indices: [UInt32] = []

        for face in 0..<6 {
            let baseVert = UInt32(vertices.count)
            let fi = faceIndices[face]

            for j in 0..<4 {
                let v = Q3GPUVertex(
                    position: corners[fi[j]],
                    texCoord: uvs[j],
                    lightmapCoord: .zero,
                    normal: .zero,
                    color: SIMD4<Float>(1, 1, 1, 1)
                )
                vertices.append(v)
            }

            // Two triangles per face
            indices.append(contentsOf: [
                baseVert + 0, baseVert + 1, baseVert + 2,
                baseVert + 0, baseVert + 2, baseVert + 3,
            ])
        }

        skyVertexCount = vertices.count
        skyIndexCount = indices.count

        skyVertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Q3GPUVertex>.stride, options: .storageModeShared)
        skyVertexBuffer?.label = "Sky Vertex Buffer"

        skyIndexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        skyIndexBuffer?.label = "Sky Index Buffer"
    }

    // MARK: - Render

    func render(
        encoder: any MTL4RenderCommandEncoder,
        vertexTable: MTL4ArgumentTable,
        fragmentTable: MTL4ArgumentTable,
        viewOrigin: Vec3,
        pipelineManager: MetalPipelineManager,
        textureCache: TextureCache,
        view: MTKView,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int
    ) {
        guard hasSky,
              let vb = skyVertexBuffer,
              let ib = skyIndexBuffer else { return }

        // Use a pipeline with no depth write, depth test always
        let key = PipelineKey(srcBlend: 0, dstBlend: 0, depthWrite: false, depthTest: false, cullMode: 2, alphaTest: 0)
        if let pipeline = try? pipelineManager.getOrCreatePipeline(key: key, view: view) {
            encoder.setRenderPipelineState(pipeline)
        }

        let depthState = pipelineManager.getDepthState(write: false, test: false)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        // Set vertex buffer
        vertexTable.setAddress(vb.gpuAddress, index: 0)

        // Render each face with its texture
        let indicesPerFace = 6
        for face in 0..<min(6, skyTextureHandles.count) {
            if let tex = textureCache.getTexture(skyTextureHandles[face]) {
                fragmentTable.setTexture(tex.gpuResourceID, index: 0)
            }

            // Also set lightmap to white for sky (no lightmap)
            if let white = textureCache.getTexture(textureCache.whiteTexture) {
                fragmentTable.setTexture(white.gpuResourceID, index: 1)
            }

            // Set stage uniforms for sky (default: white color, tcGen=texture, no alpha test)
            if let uniformBuf = stageUniformBuffer {
                var stageUniforms = Q3StageUniforms()
                stageUniforms.useLightmap = 0
                let offset = stageUniformDrawIndex * stageUniformAlignment
                guard offset + MemoryLayout<Q3StageUniforms>.size <= uniformBuf.length else { continue }
                let ptr = (uniformBuf.contents() + offset).bindMemory(to: Q3StageUniforms.self, capacity: 1)
                ptr.pointee = stageUniforms
                fragmentTable.setAddress(uniformBuf.gpuAddress + UInt64(offset), index: BufferIndex.stageUniforms.rawValue)
                stageUniformDrawIndex += 1
            }

            let offset = face * indicesPerFace * MemoryLayout<UInt32>.stride
            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: indicesPerFace,
                indexType: .uint32,
                indexBuffer: ib.gpuAddress + UInt64(offset),
                indexBufferLength: ib.length - offset
            )
        }
    }
}
