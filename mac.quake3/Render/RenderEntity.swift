// RenderEntity.swift — Entity rendering dispatch (MD3 models, sprites, beams, rails)
// Vertices are pre-transformed to world space on the CPU to avoid per-entity
// uniform buffer writes that cause flickering (GPU may still be reading when CPU overwrites).

import Foundation
import Metal
import MetalKit
import simd

class RenderEntity {
    // Entity render types (from Q3)
    static let rtModel: Int32 = 0
    static let rtPoly: Int32 = 1
    static let rtSprite: Int32 = 2
    static let rtBeam: Int32 = 3
    static let rtRailCore: Int32 = 4
    static let rtRailRings: Int32 = 5
    static let rtLightning: Int32 = 6
    static let rtPortalSurface: Int32 = 7

    // renderfx flags (must match tr_types.h)
    static let rfMinlight: Int32 = 1
    static let rfThirdPerson: Int32 = 2
    static let rfFirstPerson: Int32 = 4
    static let rfDepthHack: Int32 = 8

    /// Render all scene entities with Metal GPU draw calls.
    /// All vertex positions are pre-transformed to world space on the CPU,
    /// so the GPU uses modelMatrix=identity (no per-entity uniform writes).
    static func renderEntities(
        entities: [RefEntity],
        encoder: any MTL4RenderCommandEncoder,
        vertexTable: MTL4ArgumentTable,
        fragmentTable: MTL4ArgumentTable,
        entityVertexBuffer: MTLBuffer,
        entityIndexBuffer: MTLBuffer,
        rendererAPI: RendererAPI,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int,
        view: MTKView,
        cameraOrigin: Vec3,
        vertexOffsetInOut: inout Int,
        indexOffsetInOut: inout Int
    ) {
        var vertexOffset = vertexOffsetInOut
        var indexOffset = indexOffsetInOut

        let maxVerts = entityVertexBuffer.length / MemoryLayout<Q3GPUVertex>.stride
        let maxIndices = entityIndexBuffer.length / MemoryLayout<UInt32>.stride

        let vertexPtr = entityVertexBuffer.contents().bindMemory(to: Q3GPUVertex.self, capacity: maxVerts)
        let indexPtr = entityIndexBuffer.contents().bindMemory(to: UInt32.self, capacity: maxIndices)

        // Set entity vertex buffer as the mesh source
        vertexTable.setAddress(entityVertexBuffer.gpuAddress, index: BufferIndex.meshPositions.rawValue)

        // Bind default white texture so we always have valid bindings
        if let whiteTex = textureCache.getTexture(textureCache.whiteTexture) {
            fragmentTable.setTexture(whiteTex.gpuResourceID, index: TextureIndex.color.rawValue)
            fragmentTable.setTexture(whiteTex.gpuResourceID, index: TextureIndex.lightmap.rawValue)
        }

        for entity in entities {
            switch entity.reType {
            case rtModel:
                renderModel(
                    entity,
                    encoder: encoder,
                    fragmentTable: fragmentTable,
                    vertexPtr: vertexPtr,
                    indexPtr: indexPtr,
                    vertexOffset: &vertexOffset,
                    indexOffset: &indexOffset,
                    maxVerts: maxVerts,
                    maxIndices: maxIndices,
                    entityIndexBuffer: entityIndexBuffer,
                    rendererAPI: rendererAPI,
                    textureCache: textureCache,
                    pipelineManager: pipelineManager,
                    stageUniformBuffer: stageUniformBuffer,
                    stageUniformDrawIndex: &stageUniformDrawIndex,
                    stageUniformAlignment: stageUniformAlignment,
                    view: view
                )
            case rtBeam, rtRailCore, rtLightning:
                renderBeam(
                    entity,
                    encoder: encoder,
                    fragmentTable: fragmentTable,
                    vertexPtr: vertexPtr,
                    indexPtr: indexPtr,
                    vertexOffset: &vertexOffset,
                    indexOffset: &indexOffset,
                    maxVerts: maxVerts,
                    maxIndices: maxIndices,
                    entityIndexBuffer: entityIndexBuffer,
                    rendererAPI: rendererAPI,
                    textureCache: textureCache,
                    pipelineManager: pipelineManager,
                    stageUniformBuffer: stageUniformBuffer,
                    stageUniformDrawIndex: &stageUniformDrawIndex,
                    stageUniformAlignment: stageUniformAlignment,
                    view: view,
                    cameraOrigin: cameraOrigin
                )
            case rtSprite:
                renderSprite(
                    entity,
                    encoder: encoder,
                    fragmentTable: fragmentTable,
                    vertexPtr: vertexPtr,
                    indexPtr: indexPtr,
                    vertexOffset: &vertexOffset,
                    indexOffset: &indexOffset,
                    maxVerts: maxVerts,
                    maxIndices: maxIndices,
                    entityIndexBuffer: entityIndexBuffer,
                    rendererAPI: rendererAPI,
                    textureCache: textureCache,
                    pipelineManager: pipelineManager,
                    stageUniformBuffer: stageUniformBuffer,
                    stageUniformDrawIndex: &stageUniformDrawIndex,
                    stageUniformAlignment: stageUniformAlignment,
                    view: view,
                    cameraOrigin: cameraOrigin
                )
            default:
                break
            }
        }

        // Write back offsets so next call continues where we left off
        vertexOffsetInOut = vertexOffset
        indexOffsetInOut = indexOffset
    }

    // MARK: - Model Rendering

    private static func renderModel(
        _ entity: RefEntity,
        encoder: any MTL4RenderCommandEncoder,
        fragmentTable: MTL4ArgumentTable,
        vertexPtr: UnsafeMutablePointer<Q3GPUVertex>,
        indexPtr: UnsafeMutablePointer<UInt32>,
        vertexOffset: inout Int,
        indexOffset: inout Int,
        maxVerts: Int,
        maxIndices: Int,
        entityIndexBuffer: MTLBuffer,
        rendererAPI: RendererAPI,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int,
        view: MTKView
    ) {
        // Skip RF_THIRD_PERSON entities (player's own body)
        if entity.renderfx & rfThirdPerson != 0 { return }

        // Look up model path
        guard let modelPath = rendererAPI.modelNames[entity.hModel] else { return }

        // Load MD3
        guard let model = ModelCache.shared.loadModel(modelPath) else { return }

        // Build model matrix for CPU-side transform
        let modelMatrix = buildModelMatrix(entity: entity)

        // Entity color (normalized from RGBA8 to float)
        // Q3: shaderRGBA=(0,0,0,0) means "unset" — treat as full white.
        // Only rgbGen entity shaders use the entity color; without lighting
        // we default to white so the texture renders at full brightness.
        let rgba = entity.shaderRGBA
        let entColor: SIMD4<Float>
        if rgba.x == 0 && rgba.y == 0 && rgba.z == 0 && rgba.w == 0 {
            entColor = SIMD4<Float>(1, 1, 1, 1)
        } else {
            entColor = SIMD4<Float>(
                Float(rgba.x) / 255.0,
                Float(rgba.y) / 255.0,
                Float(rgba.z) / 255.0,
                Float(rgba.w) / 255.0
            )
        }

        let frame = max(0, min(Int(entity.frame), model.numFrames - 1))
        let oldFrame = max(0, min(Int(entity.oldframe), model.numFrames - 1))

        for surface in model.surfaces {
            let numVerts = surface.numVerts
            let numTris = surface.numTriangles
            let numIndices = numTris * 3

            // Check buffer capacity
            guard vertexOffset + numVerts <= maxVerts,
                  indexOffset + numIndices <= maxIndices else { continue }

            // Interpolate vertex positions in model space
            let localPositions = interpolateSurface(surface, frame: frame, oldFrame: oldFrame, backlerp: entity.backlerp)
            guard localPositions.count == numVerts else { continue }

            // Interpolate normals in model space
            let localNormals = interpolateNormals(surface, frame: frame, oldFrame: oldFrame, backlerp: entity.backlerp)

            // Build GPU vertices — transform positions and normals to world space on CPU
            let baseVertex = vertexOffset
            for i in 0..<numVerts {
                let tc: SIMD2<Float>
                if i < surface.texCoords.count {
                    tc = SIMD2<Float>(surface.texCoords[i].s, surface.texCoords[i].t)
                } else {
                    tc = SIMD2<Float>(0, 0)
                }
                let localN: Vec3 = i < localNormals.count ? localNormals[i] : Vec3(0, 0, 1)

                // Transform position: worldPos = modelMatrix * (localPos, 1)
                let lp = localPositions[i]
                let worldPos = transformPoint(lp, by: modelMatrix)

                // Transform normal (rotation only, no translation): worldN = mat3x3 * localN
                let worldN = transformDirection(localN, by: modelMatrix)

                let vert = Q3GPUVertex(
                    position: worldPos,
                    texCoord: tc,
                    lightmapCoord: SIMD2<Float>(0, 0),
                    normal: worldN,
                    color: entColor
                )
                vertexPtr[vertexOffset] = vert
                vertexOffset += 1
            }

            // Build indices
            let baseIndex = indexOffset
            for tri in surface.triangles {
                indexPtr[indexOffset] = UInt32(baseVertex) + UInt32(tri.indexes.0)
                indexPtr[indexOffset + 1] = UInt32(baseVertex) + UInt32(tri.indexes.1)
                indexPtr[indexOffset + 2] = UInt32(baseVertex) + UInt32(tri.indexes.2)
                indexOffset += 3
            }

            // Resolve texture
            let texHandle: Int
            if entity.customShader > 0, let shaderName = rendererAPI.shaderNames[entity.customShader] {
                texHandle = textureCache.findOrLoad(shaderName)
            } else if !surface.shaders.isEmpty {
                texHandle = textureCache.findOrLoad(surface.shaders[0].name)
            } else {
                texHandle = textureCache.whiteTexture
            }

            if let tex = textureCache.getTexture(texHandle) {
                fragmentTable.setTexture(tex.gpuResourceID, index: TextureIndex.color.rawValue)
            }

            // Entity models always use the default opaque pipeline.
            // Shader-aware blending applies to world BSP surfaces, not MD3 models.
            encoder.setRenderPipelineState(pipelineManager.defaultPipeline)
            encoder.setDepthStencilState(pipelineManager.defaultDepthState)
            // Weapon viewmodels (RF_DEPTHHACK) often have mirrored axes — disable culling
            encoder.setCullMode((entity.renderfx & rfDepthHack) != 0 ? .none : .back)

            // Write stage uniforms (default entity rendering)
            writeEntityStageUniforms(
                fragmentTable: fragmentTable,
                stageUniformBuffer: stageUniformBuffer,
                stageUniformDrawIndex: &stageUniformDrawIndex,
                stageUniformAlignment: stageUniformAlignment,
                color: entColor
            )

            // Draw
            let idxByteOffset = baseIndex * MemoryLayout<UInt32>.stride
            let remainingLength = entityIndexBuffer.length - idxByteOffset
            guard remainingLength > 0 else { continue }

            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: numIndices,
                indexType: .uint32,
                indexBuffer: entityIndexBuffer.gpuAddress + UInt64(idxByteOffset),
                indexBufferLength: remainingLength
            )
        }
    }

    // MARK: - Sprite Rendering

    private static func renderSprite(
        _ entity: RefEntity,
        encoder: any MTL4RenderCommandEncoder,
        fragmentTable: MTL4ArgumentTable,
        vertexPtr: UnsafeMutablePointer<Q3GPUVertex>,
        indexPtr: UnsafeMutablePointer<UInt32>,
        vertexOffset: inout Int,
        indexOffset: inout Int,
        maxVerts: Int,
        maxIndices: Int,
        entityIndexBuffer: MTLBuffer,
        rendererAPI: RendererAPI,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int,
        view: MTKView,
        cameraOrigin: Vec3
    ) {
        guard vertexOffset + 4 <= maxVerts, indexOffset + 6 <= maxIndices else { return }
        guard entity.radius > 0 else { return }

        // Sprites are already in world space — no modelMatrix needed

        // Build camera-facing quad
        let toCamera = simd_normalize(cameraOrigin - entity.origin)
        let worldUp = Vec3(0, 0, 1)
        var right = simd_cross(toCamera, worldUp)
        let rightLen = simd_length(right)

        // Handle degenerate case (camera directly above/below)
        if rightLen < 0.001 {
            right = Vec3(1, 0, 0)
        } else {
            right = right / rightLen
        }
        let up = simd_cross(right, toCamera)

        let r = entity.radius
        let origin = entity.origin
        let srgba = entity.shaderRGBA
        let entColor: SIMD4<Float>
        if srgba.x == 0 && srgba.y == 0 && srgba.z == 0 && srgba.w == 0 {
            entColor = SIMD4<Float>(1, 1, 1, 1)
        } else {
            entColor = SIMD4<Float>(
                Float(srgba.x) / 255.0,
                Float(srgba.y) / 255.0,
                Float(srgba.z) / 255.0,
                Float(srgba.w) / 255.0
            )
        }

        let baseVertex = vertexOffset

        // Quad corners: bottom-left, bottom-right, top-right, top-left
        let rRight = right * r
        let rUp = up * r
        let p0 = origin - rRight - rUp
        let p1 = origin + rRight - rUp
        let p2 = origin + rRight + rUp
        let p3 = origin - rRight + rUp
        let positions = [p0, p1, p2, p3]
        let texCoords: [SIMD2<Float>] = [
            SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)
        ]

        for i in 0..<4 {
            let vert = Q3GPUVertex(
                position: positions[i],
                texCoord: texCoords[i],
                lightmapCoord: SIMD2<Float>(0, 0),
                normal: toCamera,
                color: entColor
            )
            vertexPtr[vertexOffset] = vert
            vertexOffset += 1
        }

        // Two triangles: 0-1-2, 0-2-3
        let baseIdx = indexOffset
        indexPtr[indexOffset] = UInt32(baseVertex)
        indexPtr[indexOffset + 1] = UInt32(baseVertex + 1)
        indexPtr[indexOffset + 2] = UInt32(baseVertex + 2)
        indexPtr[indexOffset + 3] = UInt32(baseVertex)
        indexPtr[indexOffset + 4] = UInt32(baseVertex + 2)
        indexPtr[indexOffset + 5] = UInt32(baseVertex + 3)
        indexOffset += 6

        // Resolve texture
        let texHandle: Int
        if entity.customShader > 0, let shaderName = rendererAPI.shaderNames[entity.customShader] {
            texHandle = textureCache.findOrLoad(shaderName)
        } else {
            texHandle = textureCache.whiteTexture
        }

        if let tex = textureCache.getTexture(texHandle) {
            fragmentTable.setTexture(tex.gpuResourceID, index: TextureIndex.color.rawValue)
        }

        // Alpha-blended pipeline for sprites
        let key = PipelineKey(
            srcBlend: 0x05,   // GLS_SRCBLEND_SRC_ALPHA
            dstBlend: 0x06,   // GLS_DSTBLEND_ONE_MINUS_SRC_ALPHA
            depthWrite: false,
            depthTest: true,
            cullMode: 2,      // two-sided
            alphaTest: 0
        )
        if let pipeline = try? pipelineManager.getOrCreatePipeline(key: key, view: view) {
            encoder.setRenderPipelineState(pipeline)
        }
        let depthState = pipelineManager.getDepthState(write: false, test: true)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        // Write stage uniforms
        writeEntityStageUniforms(
            fragmentTable: fragmentTable,
            stageUniformBuffer: stageUniformBuffer,
            stageUniformDrawIndex: &stageUniformDrawIndex,
            stageUniformAlignment: stageUniformAlignment,
            color: entColor
        )

        // Draw
        let idxByteOffset = baseIdx * MemoryLayout<UInt32>.stride
        let remainingLength = entityIndexBuffer.length - idxByteOffset
        guard remainingLength > 0 else { return }

        encoder.drawIndexedPrimitives(
            primitiveType: .triangle,
            indexCount: 6,
            indexType: .uint32,
            indexBuffer: entityIndexBuffer.gpuAddress + UInt64(idxByteOffset),
            indexBufferLength: remainingLength
        )
    }

    // MARK: - Scene Polygon Rendering (tracers, impact marks, trails)

    static func renderPolys(
        polys: [ScenePoly],
        encoder: any MTL4RenderCommandEncoder,
        vertexTable: MTL4ArgumentTable,
        fragmentTable: MTL4ArgumentTable,
        entityVertexBuffer: MTLBuffer,
        entityIndexBuffer: MTLBuffer,
        rendererAPI: RendererAPI,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int,
        view: MTKView,
        vertexOffsetInOut: inout Int,
        indexOffsetInOut: inout Int
    ) {
        var vertexOffset = vertexOffsetInOut
        var indexOffset = indexOffsetInOut

        let maxVerts = entityVertexBuffer.length / MemoryLayout<Q3GPUVertex>.stride
        let maxIndices = entityIndexBuffer.length / MemoryLayout<UInt32>.stride

        let vertexPtr = entityVertexBuffer.contents().bindMemory(to: Q3GPUVertex.self, capacity: maxVerts)
        let indexPtr = entityIndexBuffer.contents().bindMemory(to: UInt32.self, capacity: maxIndices)

        // Set entity vertex buffer as the mesh source
        vertexTable.setAddress(entityVertexBuffer.gpuAddress, index: BufferIndex.meshPositions.rawValue)

        // Bind default white texture
        if let whiteTex = textureCache.getTexture(textureCache.whiteTexture) {
            fragmentTable.setTexture(whiteTex.gpuResourceID, index: TextureIndex.color.rawValue)
            fragmentTable.setTexture(whiteTex.gpuResourceID, index: TextureIndex.lightmap.rawValue)
        }

        for poly in polys {
            let numVerts = poly.vertices.count
            guard numVerts >= 3 else { continue }
            let numTris = numVerts - 2
            let numIndices = numTris * 3

            guard vertexOffset + numVerts <= maxVerts,
                  indexOffset + numIndices <= maxIndices else { continue }

            let baseVertex = vertexOffset

            // Write vertices
            for pv in poly.vertices {
                let color = SIMD4<Float>(
                    Float(pv.color.x) / 255.0,
                    Float(pv.color.y) / 255.0,
                    Float(pv.color.z) / 255.0,
                    Float(pv.color.w) / 255.0
                )
                vertexPtr[vertexOffset] = Q3GPUVertex(
                    position: pv.position,
                    texCoord: pv.texCoord,
                    lightmapCoord: SIMD2<Float>(0, 0),
                    normal: Vec3(0, 0, 1),
                    color: color
                )
                vertexOffset += 1
            }

            // Triangle fan indices (0-1-2, 0-2-3, 0-3-4, ...)
            let baseIndex = indexOffset
            for t in 0..<numTris {
                indexPtr[indexOffset]     = UInt32(baseVertex)
                indexPtr[indexOffset + 1] = UInt32(baseVertex + t + 1)
                indexPtr[indexOffset + 2] = UInt32(baseVertex + t + 2)
                indexOffset += 3
            }

            // Resolve shader → texture and blend mode from shader definition
            var texHandle = textureCache.whiteTexture
            var srcBits: UInt32 = 0x05   // default: SRC_ALPHA
            var dstBits: UInt32 = 0x06   // default: ONE_MINUS_SRC_ALPHA
            if let shaderName = rendererAPI.shaderNames[poly.shader] {
                if let shaderDef = ShaderParser.shared.findShader(shaderName),
                   !shaderDef.stages.isEmpty {
                    let stage = shaderDef.stages[0]
                    // Get texture from first stage's first bundle
                    if !stage.bundles[0].imageNames.isEmpty {
                        texHandle = textureCache.findOrLoad(stage.bundles[0].imageNames[0])
                    } else {
                        texHandle = textureCache.findOrLoad(shaderName)
                    }
                    // Extract blend mode from stateBits
                    let sb = stage.stateBits & GLState.srcBlendBits.rawValue
                    let db = (stage.stateBits & GLState.dstBlendBits.rawValue) >> 4
                    if sb != 0 || db != 0 {
                        srcBits = sb
                        dstBits = db
                    }
                } else {
                    texHandle = textureCache.findOrLoad(shaderName)
                }
            }

            if let tex = textureCache.getTexture(texHandle) {
                fragmentTable.setTexture(tex.gpuResourceID, index: TextureIndex.color.rawValue)
            }

            // Set pipeline with shader-specific blend mode
            let blendKey = PipelineKey(
                srcBlend: srcBits,
                dstBlend: dstBits,
                depthWrite: false,
                depthTest: true,
                cullMode: 2,
                alphaTest: 0
            )
            if let pipeline = try? pipelineManager.getOrCreatePipeline(key: blendKey, view: view) {
                encoder.setRenderPipelineState(pipeline)
            }
            let depthState = pipelineManager.getDepthState(write: false, test: true)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)

            // Write stage uniforms with vertex color enabled
            if let uniformBuf = stageUniformBuffer {
                let offset = stageUniformDrawIndex * stageUniformAlignment
                if offset + MemoryLayout<Q3StageUniforms>.size <= uniformBuf.length {
                    let ptr = (uniformBuf.contents() + offset).bindMemory(to: Q3StageUniforms.self, capacity: 1)
                    var su = Q3StageUniforms()
                    su.color = SIMD4<Float>(1, 1, 1, 1)
                    su.tcGen = 3
                    su.useLightmap = 0
                    su.tcModMat = simd_float2x2(SIMD2<Float>(1, 0), SIMD2<Float>(0, 1))
                    su.tcModOffset = SIMD2<Float>(0, 0)
                    su.alphaTestFunc = 0
                    su.useVertexColor = 1   // Polys use per-vertex color
                    su.useVertexAlpha = 1
                    ptr.pointee = su
                    fragmentTable.setAddress(uniformBuf.gpuAddress + UInt64(offset), index: BufferIndex.stageUniforms.rawValue)
                    stageUniformDrawIndex += 1
                }
            }

            // Draw
            let idxByteOffset = baseIndex * MemoryLayout<UInt32>.stride
            let remainingLength = entityIndexBuffer.length - idxByteOffset
            guard remainingLength > 0 else { continue }

            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: numIndices,
                indexType: .uint32,
                indexBuffer: entityIndexBuffer.gpuAddress + UInt64(idxByteOffset),
                indexBufferLength: remainingLength
            )
        }

        vertexOffsetInOut = vertexOffset
        indexOffsetInOut = indexOffset
    }

    // MARK: - Beam / Lightning / Rail Rendering

    private static func renderBeam(
        _ entity: RefEntity,
        encoder: any MTL4RenderCommandEncoder,
        fragmentTable: MTL4ArgumentTable,
        vertexPtr: UnsafeMutablePointer<Q3GPUVertex>,
        indexPtr: UnsafeMutablePointer<UInt32>,
        vertexOffset: inout Int,
        indexOffset: inout Int,
        maxVerts: Int,
        maxIndices: Int,
        entityIndexBuffer: MTLBuffer,
        rendererAPI: RendererAPI,
        textureCache: TextureCache,
        pipelineManager: MetalPipelineManager,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int,
        view: MTKView,
        cameraOrigin: Vec3
    ) {
        guard vertexOffset + 4 <= maxVerts, indexOffset + 6 <= maxIndices else { return }

        let start = entity.origin
        let end = entity.oldOrigin
        let direction = end - start
        let len = simd_length(direction)
        guard len > 0.1 else { return }

        let dirNorm = direction / len
        let midpoint = (start + end) * 0.5
        let toCamera = simd_normalize(cameraOrigin - midpoint)
        var right = simd_cross(dirNorm, toCamera)
        let rightLen = simd_length(right)
        if rightLen < 0.001 { return }
        right = right / rightLen

        // RT_BEAM uses entity.frame as diameter; others use entity.radius or a default
        let width: Float
        if entity.reType == rtBeam {
            width = max(Float(entity.frame) * 0.5, 2.0)
        } else {
            width = max(entity.radius, 4.0)
        }

        let p0 = start - right * width
        let p1 = start + right * width
        let p2 = end + right * width
        let p3 = end - right * width

        let brgba = entity.shaderRGBA
        let entColor: SIMD4<Float>
        if brgba.x == 0 && brgba.y == 0 && brgba.z == 0 && brgba.w == 0 {
            entColor = SIMD4<Float>(1, 1, 1, 1)
        } else {
            entColor = SIMD4<Float>(
                Float(brgba.x) / 255.0,
                Float(brgba.y) / 255.0,
                Float(brgba.z) / 255.0,
                Float(brgba.w) / 255.0
            )
        }

        let baseVertex = vertexOffset
        let positions = [p0, p1, p2, p3]
        let texCoords: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)
        ]

        for i in 0..<4 {
            vertexPtr[vertexOffset] = Q3GPUVertex(
                position: positions[i],
                texCoord: texCoords[i],
                lightmapCoord: SIMD2<Float>(0, 0),
                normal: toCamera,
                color: entColor
            )
            vertexOffset += 1
        }

        let baseIdx = indexOffset
        indexPtr[indexOffset]     = UInt32(baseVertex)
        indexPtr[indexOffset + 1] = UInt32(baseVertex + 1)
        indexPtr[indexOffset + 2] = UInt32(baseVertex + 2)
        indexPtr[indexOffset + 3] = UInt32(baseVertex)
        indexPtr[indexOffset + 4] = UInt32(baseVertex + 2)
        indexPtr[indexOffset + 5] = UInt32(baseVertex + 3)
        indexOffset += 6

        // Resolve texture
        let texHandle: Int
        if entity.customShader > 0, let shaderName = rendererAPI.shaderNames[entity.customShader] {
            texHandle = textureCache.findOrLoad(shaderName)
        } else {
            texHandle = textureCache.whiteTexture
        }

        if let tex = textureCache.getTexture(texHandle) {
            fragmentTable.setTexture(tex.gpuResourceID, index: TextureIndex.color.rawValue)
        }

        // Additive blending for beams/lightning/rails
        let key = PipelineKey(
            srcBlend: 0x02,   // GLS_SRCBLEND_ONE
            dstBlend: 0x02,   // GLS_DSTBLEND_ONE
            depthWrite: false,
            depthTest: true,
            cullMode: 2,      // two-sided
            alphaTest: 0
        )
        if let pipeline = try? pipelineManager.getOrCreatePipeline(key: key, view: view) {
            encoder.setRenderPipelineState(pipeline)
        }
        let depthState = pipelineManager.getDepthState(write: false, test: true)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        writeEntityStageUniforms(
            fragmentTable: fragmentTable,
            stageUniformBuffer: stageUniformBuffer,
            stageUniformDrawIndex: &stageUniformDrawIndex,
            stageUniformAlignment: stageUniformAlignment,
            color: entColor
        )

        let idxByteOffset = baseIdx * MemoryLayout<UInt32>.stride
        let remainingLength = entityIndexBuffer.length - idxByteOffset
        guard remainingLength > 0 else { return }

        encoder.drawIndexedPrimitives(
            primitiveType: .triangle,
            indexCount: 6,
            indexType: .uint32,
            indexBuffer: entityIndexBuffer.gpuAddress + UInt64(idxByteOffset),
            indexBufferLength: remainingLength
        )
    }

    // MARK: - Helpers

    /// Transform a point by a 4x4 matrix (position: applies full transform including translation)
    private static func transformPoint(_ p: Vec3, by m: matrix_float4x4) -> Vec3 {
        let v = m * SIMD4<Float>(p.x, p.y, p.z, 1.0)
        return Vec3(v.x, v.y, v.z)
    }

    /// Transform a direction by a 4x4 matrix (normal: rotation only, no translation)
    private static func transformDirection(_ d: Vec3, by m: matrix_float4x4) -> Vec3 {
        let v = Vec3(
            m.columns.0.x * d.x + m.columns.1.x * d.y + m.columns.2.x * d.z,
            m.columns.0.y * d.x + m.columns.1.y * d.y + m.columns.2.y * d.z,
            m.columns.0.z * d.x + m.columns.1.z * d.y + m.columns.2.z * d.z
        )
        let len = simd_length(v)
        return len > 0.001 ? v / len : Vec3(0, 0, 1)
    }

    private static func buildModelMatrix(entity: RefEntity) -> matrix_float4x4 {
        let a0 = entity.axis.0
        let a1 = entity.axis.1
        let a2 = entity.axis.2
        let o = entity.origin

        return matrix_float4x4(columns: (
            SIMD4<Float>(a0.x, a0.y, a0.z, 0),
            SIMD4<Float>(a1.x, a1.y, a1.z, 0),
            SIMD4<Float>(a2.x, a2.y, a2.z, 0),
            SIMD4<Float>(o.x,  o.y,  o.z,  1)
        ))
    }

    private static func writeEntityStageUniforms(
        fragmentTable: MTL4ArgumentTable,
        stageUniformBuffer: MTLBuffer?,
        stageUniformDrawIndex: inout Int,
        stageUniformAlignment: Int,
        color: SIMD4<Float>
    ) {
        guard let uniformBuf = stageUniformBuffer else { return }
        let offset = stageUniformDrawIndex * stageUniformAlignment
        guard offset + MemoryLayout<Q3StageUniforms>.size <= uniformBuf.length else {
            Q3Console.shared.warning("Stage uniform buffer overflow at draw \(stageUniformDrawIndex)")
            return
        }

        let ptr = (uniformBuf.contents() + offset).bindMemory(to: Q3StageUniforms.self, capacity: 1)
        var stageUniforms = Q3StageUniforms()
        stageUniforms.color = color
        stageUniforms.tcGen = 3  // texture coords
        stageUniforms.useLightmap = 0
        stageUniforms.tcModMat = simd_float2x2(
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 1)
        )
        stageUniforms.tcModOffset = SIMD2<Float>(0, 0)
        stageUniforms.alphaTestFunc = 0
        stageUniforms.useVertexColor = 0
        stageUniforms.useVertexAlpha = 0
        ptr.pointee = stageUniforms

        fragmentTable.setAddress(uniformBuf.gpuAddress + UInt64(offset), index: BufferIndex.stageUniforms.rawValue)
        stageUniformDrawIndex += 1
    }

    // MARK: - MD3 Frame Interpolation

    /// Build interpolated vertex positions for an MD3 surface
    static func interpolateSurface(_ surface: MD3Surface, frame: Int, oldFrame: Int, backlerp: Float) -> [Vec3] {
        let numVerts = surface.numVerts
        guard frame < surface.numFrames && oldFrame < surface.numFrames else { return [] }

        let frac = 1.0 - backlerp
        var result = [Vec3](repeating: .zero, count: numVerts)

        let newBase = frame * numVerts
        let oldBase = oldFrame * numVerts

        for i in 0..<numVerts {
            guard newBase + i < surface.vertices.count && oldBase + i < surface.vertices.count else { break }
            let newPos = surface.vertices[newBase + i].position
            let oldPos = surface.vertices[oldBase + i].position
            result[i] = oldPos * backlerp + newPos * frac
        }

        return result
    }

    /// Build interpolated normals for an MD3 surface
    static func interpolateNormals(_ surface: MD3Surface, frame: Int, oldFrame: Int, backlerp: Float) -> [Vec3] {
        let numVerts = surface.numVerts
        guard frame < surface.numFrames && oldFrame < surface.numFrames else { return [] }

        let frac = 1.0 - backlerp
        var result = [Vec3](repeating: .zero, count: numVerts)

        let newBase = frame * numVerts
        let oldBase = oldFrame * numVerts

        for i in 0..<numVerts {
            guard newBase + i < surface.vertices.count && oldBase + i < surface.vertices.count else { break }
            let newNorm = surface.vertices[newBase + i].decodedNormal
            let oldNorm = surface.vertices[oldBase + i].decodedNormal
            result[i] = simd_normalize(oldNorm * backlerp + newNorm * frac)
        }

        return result
    }
}
