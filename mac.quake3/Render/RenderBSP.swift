// RenderBSP.swift — BSP rendering: collect visible surfaces, batch by shader, draw multi-stage

import Foundation
import Metal
import MetalKit
import simd

class RenderBSP {
    var worldModel: BSPWorldModel?
    var geometry: BSPGeometryBuilder?
    var visibleDrawSurfaces: [Int] = []  // Indices into geometry.drawSurfaces

    // Per-surface shader references (for multi-stage rendering)
    var surfaceShaders: [Int: Q3ShaderDef] = [:]

    // Stage uniform buffer (triple-buffered, per-draw-call offsets)
    var stageUniformBuffer: MTLBuffer?
    let stageUniformAlignment = 256  // Align to 256 bytes for GPU
    let maxDrawCallsPerFrame = 4096
    var stageUniformDrawIndex = 0    // Reset each frame, incremented per draw

    // Sky renderer
    var skyRenderer: RenderSky?

    // Map from BSP surface index → geometry.drawSurfaces index
    private var surfaceToDrawSurface: [Int: Int] = [:]

    func setup(worldModel: BSPWorldModel, geometry: BSPGeometryBuilder, textureCache: TextureCache) {
        self.worldModel = worldModel
        self.geometry = geometry

        // Build surface mapping
        surfaceToDrawSurface.removeAll()
        for (drawIdx, drawSurf) in geometry.drawSurfaces.enumerated() {
            surfaceToDrawSurface[drawSurf.shaderIndex] = drawIdx
        }

        // Resolve shader definitions for each draw surface
        surfaceShaders.removeAll()
        var noShaderCount = 0
        var emptyStagesCount = 0
        var emptyStageNames = Set<String>()
        for (idx, drawSurf) in geometry.drawSurfaces.enumerated() {
            let bsp = worldModel.bspFile
            if drawSurf.shaderIndex >= 0 && drawSurf.shaderIndex < bsp.shaders.count {
                let shaderName = bsp.shaders[drawSurf.shaderIndex].name
                if let def = ShaderParser.shared.findShader(shaderName) {
                    surfaceShaders[idx] = def
                    if def.stages.isEmpty {
                        emptyStagesCount += 1
                        emptyStageNames.insert(shaderName)
                    }
                } else {
                    noShaderCount += 1
                }
            }
        }
        // Pre-load ALL textures from all shader stages (including animated frames)
        // This ensures they're in the texture cache before residency set is built
        var preloadCount = 0
        for (_, shaderDef) in surfaceShaders {
            for stage in shaderDef.stages {
                for bundle in stage.bundles {
                    for imageName in bundle.imageNames {
                        if !imageName.isEmpty {
                            _ = textureCache.findOrLoad(imageName)
                            preloadCount += 1
                        }
                    }
                }
            }
        }

        Q3Console.shared.print("Shader stats: \(surfaceShaders.count) with defs, \(noShaderCount) without, \(emptyStagesCount) with empty stages, \(preloadCount) stage textures pre-loaded")
    }

    func setupSky(device: MTLDevice, textureCache: TextureCache) {
        // Find sky shader
        for (_, shaderDef) in surfaceShaders {
            if shaderDef.isSky {
                let sky = RenderSky()
                sky.setup(device: device, shaderDef: shaderDef, textureCache: textureCache)
                if sky.hasSky {
                    skyRenderer = sky
                    Q3Console.shared.print("Sky shader loaded: \(shaderDef.name)")
                }
                break
            }
        }
    }

    func createStageUniformBuffer(device: MTLDevice) {
        // Each draw call gets its own 256-byte aligned slot, triple-buffered
        let totalSize = maxDrawCallsPerFrame * stageUniformAlignment * 3
        stageUniformBuffer = device.makeBuffer(length: totalSize, options: .storageModeShared)
        stageUniformBuffer?.label = "Stage Uniforms"
    }

    func updateVisibility(viewOrigin: Vec3, frustumPlanes: [Plane]) {
        guard let worldModel = worldModel, let geometry = geometry else { return }

        _ = worldModel.collectVisibleSurfaces(from: viewOrigin, frustumPlanes: frustumPlanes)

        // Map to draw surface indices
        visibleDrawSurfaces.removeAll(keepingCapacity: true)

        // For now, render all draw surfaces (full PVS culling requires per-surface mapping)
        visibleDrawSurfaces = Array(0..<geometry.drawSurfaces.count)
    }

    func renderWorld(
        encoder: any MTL4RenderCommandEncoder,
        vertexTable: MTL4ArgumentTable,
        fragmentTable: MTL4ArgumentTable,
        geometry: BSPGeometryBuilder,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        view: MTKView,
        time: Float = 0,
        frameIndex: Int = 0
    ) {
        guard let vertexBuffer = geometry.vertexBuffer,
              let indexBuffer = geometry.indexBuffer else { return }

        // Set vertex buffer in argument table
        vertexTable.setAddress(vertexBuffer.gpuAddress, index: 0)

        // Ensure stage uniform buffer exists
        if stageUniformBuffer == nil {
            createStageUniformBuffer(device: vertexBuffer.device)
        }

        // Reset per-draw uniform index for this frame's triple-buffer slot
        stageUniformDrawIndex = frameIndex * maxDrawCallsPerFrame

        // Render sky first (behind everything)
        if let sky = skyRenderer {
            sky.render(
                encoder: encoder,
                vertexTable: vertexTable,
                fragmentTable: fragmentTable,
                viewOrigin: Vec3.zero,
                pipelineManager: pipelineManager,
                textureCache: textureCache,
                view: view,
                stageUniformBuffer: stageUniformBuffer,
                stageUniformDrawIndex: &stageUniformDrawIndex,
                stageUniformAlignment: stageUniformAlignment
            )
            // Restore vertex buffer after sky
            vertexTable.setAddress(vertexBuffer.gpuAddress, index: 0)
        }

        // Bind default textures so fragment shader always has valid bindings
        if let whiteTex = textureCache.getTexture(textureCache.whiteTexture) {
            fragmentTable.setTexture(whiteTex.gpuResourceID, index: 0)
            fragmentTable.setTexture(whiteTex.gpuResourceID, index: 1)
        }

        var lastTextureHandle = -1
        var lastLightmapHandle = -1
        var lastStateBits: UInt32 = UInt32.max
        var lastCullType: CullType = .frontSided

        for drawIdx in visibleDrawSurfaces {
            let surf = geometry.drawSurfaces[drawIdx]
            guard surf.indexCount > 0 else { continue }

            // Validate draw parameters before sending to GPU
            let indexOffset = surf.firstIndex * MemoryLayout<UInt32>.stride
            let indexEnd = indexOffset + surf.indexCount * MemoryLayout<UInt32>.stride
            if indexOffset < 0 || indexEnd > indexBuffer.length {
                continue
            }

            let shaderDef = surfaceShaders[drawIdx]

            // Skip sky surfaces only if we have a skybox renderer for them
            if shaderDef?.isSky == true && skyRenderer?.hasSky == true { continue }

            let hasActiveStages = shaderDef.map { $0.stages.contains { $0.active } } ?? false
            if let shaderDef = shaderDef, hasActiveStages {
                // Multi-stage rendering
                renderMultiStage(
                    encoder: encoder,
                    vertexTable: vertexTable,
                    fragmentTable: fragmentTable,
                    surf: surf,
                    shaderDef: shaderDef,
                    indexBuffer: indexBuffer,
                    textureCache: textureCache,
                    pipelineManager: pipelineManager,
                    view: view,
                    time: time,
                    lastStateBits: &lastStateBits,
                    lastCullType: &lastCullType,
                    lastTextureHandle: &lastTextureHandle,
                    lastLightmapHandle: &lastLightmapHandle
                )
            } else {
                // Simple single-pass rendering (no shader def or no active stages)
                renderSimple(
                    encoder: encoder,
                    fragmentTable: fragmentTable,
                    surf: surf,
                    indexBuffer: indexBuffer,
                    textureCache: textureCache,
                    pipelineManager: pipelineManager,
                    view: view,
                    time: time,
                    lastStateBits: &lastStateBits,
                    lastCullType: &lastCullType,
                    lastTextureHandle: &lastTextureHandle,
                    lastLightmapHandle: &lastLightmapHandle
                )
            }
        }
    }

    // MARK: - Multi-Stage Rendering

    private func renderMultiStage(
        encoder: any MTL4RenderCommandEncoder,
        vertexTable: MTL4ArgumentTable,
        fragmentTable: MTL4ArgumentTable,
        surf: Q3DrawSurface,
        shaderDef: Q3ShaderDef,
        indexBuffer: MTLBuffer,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        view: MTKView,
        time: Float,
        lastStateBits: inout UInt32,
        lastCullType: inout CullType,
        lastTextureHandle: inout Int,
        lastLightmapHandle: inout Int
    ) {
        let shaderEval = ShaderEval.shared

        // Apply polygon offset for decals/marks to prevent z-fighting
        if shaderDef.polygonOffset {
            encoder.setDepthBias(-1.0, slopeScale: -1.0, clamp: 0)
        }

        for (_, stage) in shaderDef.stages.enumerated() {
            guard stage.active else { continue }

            // Compute per-stage uniforms
            var stageUniforms = shaderEval.computeStageUniforms(stage: stage, time: time)

            let bundle = stage.bundles[0]

            // Update pipeline state if needed
            let newBits = stage.stateBits
            let newCull = shaderDef.cullType
            if newBits != lastStateBits || newCull != lastCullType {
                let key = pipelineManager.pipelineKeyFromStateBits(newBits, cullType: newCull)
                if let pipeline = try? pipelineManager.getOrCreatePipeline(key: key, view: view) {
                    encoder.setRenderPipelineState(pipeline)
                }

                let depthWrite = (newBits & GLState.depthMaskTrue.rawValue) != 0
                let depthTest = (newBits & GLState.depthTestDisable.rawValue) == 0
                let depthEqual = (newBits & GLState.depthFuncEqual.rawValue) != 0
                let depthState = pipelineManager.getDepthState(write: depthWrite, test: depthTest, equal: depthEqual)
                encoder.setDepthStencilState(depthState)

                lastStateBits = newBits
                lastCullType = newCull
            }

            // Set texture for this stage
            let textureHandle: Int
            if bundle.isLightmap {
                textureHandle = surf.lightmapHandle
            } else if let firstName = bundle.imageNames.first {
                // Handle animated textures
                if bundle.imageNames.count > 1 && bundle.imageAnimationSpeed > 0 {
                    let frameIdx = Int(time * bundle.imageAnimationSpeed) % bundle.imageNames.count
                    textureHandle = textureCache.findOrLoad(bundle.imageNames[frameIdx])
                } else {
                    textureHandle = textureCache.findOrLoad(firstName)
                }
            } else {
                textureHandle = surf.textureHandle
            }

            if textureHandle != lastTextureHandle {
                if let tex = textureCache.getTexture(textureHandle) {
                    fragmentTable.setTexture(tex.gpuResourceID, index: 0)
                }
                lastTextureHandle = textureHandle
            }

            // Set lightmap for non-lightmap stages
            if !bundle.isLightmap && surf.lightmapHandle != lastLightmapHandle {
                if let tex = textureCache.getTexture(surf.lightmapHandle) {
                    fragmentTable.setTexture(tex.gpuResourceID, index: 1)
                }
                lastLightmapHandle = surf.lightmapHandle
            }

            // Write stage uniforms to a unique buffer slot for this draw call
            if let uniformBuf = stageUniformBuffer {
                let offset = stageUniformDrawIndex * stageUniformAlignment
                guard offset + MemoryLayout<Q3StageUniforms>.size <= uniformBuf.length else { continue }
                let ptr = (uniformBuf.contents() + offset).bindMemory(to: Q3StageUniforms.self, capacity: 1)
                ptr.pointee = stageUniforms
                fragmentTable.setAddress(uniformBuf.gpuAddress + UInt64(offset), index: BufferIndex.stageUniforms.rawValue)
                stageUniformDrawIndex += 1
            }

            // Draw
            let indexOffset = surf.firstIndex * MemoryLayout<UInt32>.stride
            let remainingLength = indexBuffer.length - indexOffset
            if remainingLength <= 0 { continue }
            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: surf.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer.gpuAddress + UInt64(indexOffset),
                indexBufferLength: remainingLength
            )
        }

        // Reset polygon offset
        if shaderDef.polygonOffset {
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
    }

    // MARK: - Simple Rendering (fallback for surfaces without shader definitions)

    private func renderSimple(
        encoder: any MTL4RenderCommandEncoder,
        fragmentTable: MTL4ArgumentTable,
        surf: Q3DrawSurface,
        indexBuffer: MTLBuffer,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        view: MTKView,
        time: Float,
        lastStateBits: inout UInt32,
        lastCullType: inout CullType,
        lastTextureHandle: inout Int,
        lastLightmapHandle: inout Int
    ) {
        // Update pipeline state if needed
        let newBits = surf.stateBits
        let newCull = surf.cullType
        if newBits != lastStateBits || newCull != lastCullType {
            let key = pipelineManager.pipelineKeyFromStateBits(newBits, cullType: newCull)
            if let pipeline = try? pipelineManager.getOrCreatePipeline(key: key, view: view) {
                encoder.setRenderPipelineState(pipeline)
            }

            let depthWrite = (newBits & GLState.depthMaskTrue.rawValue) != 0
            let depthTest = (newBits & GLState.depthTestDisable.rawValue) == 0
            let depthEqual = (newBits & GLState.depthFuncEqual.rawValue) != 0
            let depthState = pipelineManager.getDepthState(write: depthWrite, test: depthTest, equal: depthEqual)
            encoder.setDepthStencilState(depthState)

            // DIAG: Override to no culling
            encoder.setCullMode(.none)

            lastStateBits = newBits
            lastCullType = newCull
        }

        // Update textures if needed
        if surf.textureHandle != lastTextureHandle {
            if let tex = textureCache.getTexture(surf.textureHandle) {
                fragmentTable.setTexture(tex.gpuResourceID, index: 0)
            }
            lastTextureHandle = surf.textureHandle
        }

        if surf.lightmapHandle != lastLightmapHandle {
            if let tex = textureCache.getTexture(surf.lightmapHandle) {
                fragmentTable.setTexture(tex.gpuResourceID, index: 1)
            }
            lastLightmapHandle = surf.lightmapHandle
        }

        // Write default stage uniforms to a unique buffer slot for this draw call
        if let uniformBuf = stageUniformBuffer {
            var stageUniforms = Q3StageUniforms()
            stageUniforms.useLightmap = 1  // Default: modulate with lightmap
            let offset = stageUniformDrawIndex * stageUniformAlignment
            guard offset + MemoryLayout<Q3StageUniforms>.size <= uniformBuf.length else { return }
            let ptr = (uniformBuf.contents() + offset).bindMemory(to: Q3StageUniforms.self, capacity: 1)
            ptr.pointee = stageUniforms
            fragmentTable.setAddress(uniformBuf.gpuAddress + UInt64(offset), index: BufferIndex.stageUniforms.rawValue)
            stageUniformDrawIndex += 1
        }

        // Draw
        let indexOffset = surf.firstIndex * MemoryLayout<UInt32>.stride
        let remainingLength = indexBuffer.length - indexOffset
        if remainingLength <= 0 { return }
        encoder.drawIndexedPrimitives(
            primitiveType: .triangle,
            indexCount: surf.indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer.gpuAddress + UInt64(indexOffset),
            indexBufferLength: remainingLength
        )
    }
}
