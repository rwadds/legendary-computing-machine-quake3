// RenderMain.swift — Frame coordinator: camera, frustum, cull, draw world

import Foundation
import Metal
import MetalKit
import simd

class RenderMain: NSObject, MTKViewDelegate {
    let device: MTLDevice

    // Metal 4 objects
    let commandQueue: MTL4CommandQueue
    let commandBuffer: MTL4CommandBuffer
    let commandAllocators: [MTL4CommandAllocator]
    let endFrameEvent: MTLSharedEvent
    var frameIndex = 0
    let maxBuffersInFlight = 3

    // Argument tables (triple-buffered to prevent GPU/CPU race)
    let vertexArgumentTables: [MTL4ArgumentTable]
    let fragmentArgumentTables: [MTL4ArgumentTable]

    // Residency
    var residencySet: MTLResidencySet

    // Pipeline management
    var pipelineManager: MetalPipelineManager!

    // Uniform buffer
    var uniformBuffer: MTLBuffer
    var uniformBufferIndex = 0

    // Textures and shaders
    var textureCache: TextureCache
    var lightmapAtlas: LightmapAtlas

    // BSP
    var worldModel: BSPWorldModel?
    var geometry: BSPGeometryBuilder?
    var renderBSP: RenderBSP

    // Camera
    var cameraOrigin: Vec3 = Vec3(0, 0, 0)
    var cameraAngles: Vec3 = Vec3(0, 0, 0)  // pitch, yaw, roll
    var projectionMatrix: matrix_float4x4 = matrix_float4x4(1)

    // Input
    var moveForward: Float = 0
    var moveRight: Float = 0
    var moveUp: Float = 0
    var mouseDeltaX: Float = 0
    var mouseDeltaY: Float = 0
    var moveSpeed: Float = 400.0
    var sensitivity: Float = 0.15

    // View aspect ratio
    var viewAspect: Float = 16.0 / 9.0

    // Timing
    var lastFrameTime: Double = 0
    var frameTime: Float = 0

    // Map loaded?
    var mapLoaded = false
    private var lastResidencyTextureCount = 0

    // Entity rendering (triple-buffered to prevent GPU read/CPU write race)
    var entityVertexBuffers: [MTLBuffer] = []
    var entityIndexBuffers: [MTLBuffer] = []
    let maxEntityVertices = 65536
    let maxEntityIndices = 131072

    // 2D rendering (triple-buffered)
    var vertexBuffers2D: [MTLBuffer] = []
    var indexBuffers2D: [MTLBuffer] = []
    let max2DQuads = 4096

    // Game active — when true, camera is driven by cgame instead of free-fly
    var gameActive = false

    @MainActor
    init?(metalKitView: MTKView) {
        let device = metalKitView.device!
        self.device = device

        // Create Metal 4 command queue and buffer
        self.commandQueue = device.makeMTL4CommandQueue()!
        self.commandBuffer = device.makeCommandBuffer()!
        self.commandAllocators = (0...maxBuffersInFlight).map { _ in device.makeCommandAllocator()! }

        // Create argument tables (triple-buffered)
        var vertTables: [MTL4ArgumentTable] = []
        var fragTables: [MTL4ArgumentTable] = []
        for _ in 0..<maxBuffersInFlight {
            let vertArgDesc = MTL4ArgumentTableDescriptor()
            vertArgDesc.maxBufferBindCount = 5
            vertTables.append(try! device.makeArgumentTable(descriptor: vertArgDesc))

            let fragArgDesc = MTL4ArgumentTableDescriptor()
            fragArgDesc.maxBufferBindCount = 4
            fragArgDesc.maxTextureBindCount = 4
            fragTables.append(try! device.makeArgumentTable(descriptor: fragArgDesc))
        }
        self.vertexArgumentTables = vertTables
        self.fragmentArgumentTables = fragTables

        // Sync event
        self.endFrameEvent = device.makeSharedEvent()!
        self.frameIndex = maxBuffersInFlight
        self.endFrameEvent.signaledValue = UInt64(frameIndex - 1)

        // Uniform buffer (triple buffered)
        let uniformSize = (MemoryLayout<Q3FrameUniforms>.size + 0xFF) & ~0xFF
        self.uniformBuffer = device.makeBuffer(length: uniformSize * maxBuffersInFlight, options: .storageModeShared)!
        self.uniformBuffer.label = "Q3 Uniforms"

        // View configuration
        metalKitView.depthStencilPixelFormat = .depth32Float_stencil8
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 1

        // Create texture cache and lightmap atlas
        self.textureCache = TextureCache(device: device)
        self.lightmapAtlas = LightmapAtlas(device: device)
        self.renderBSP = RenderBSP()

        // Residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = 64
        self.residencySet = try! device.makeResidencySet(descriptor: resDesc)

        super.init()

        // Create pipeline manager
        do {
            self.pipelineManager = try MetalPipelineManager(device: device, view: metalKitView)
        } catch {
            Q3Console.shared.print("ERROR: Failed to create pipeline manager: \(error)")
            return nil
        }

        // Create 2D vertex/index buffers (triple-buffered)
        let vtx2DSize = MemoryLayout<Q3_2DVertex>.stride * 4 * max2DQuads
        let idx2DSize = MemoryLayout<UInt16>.stride * 6 * max2DQuads
        for i in 0..<maxBuffersInFlight {
            if let vb = device.makeBuffer(length: vtx2DSize, options: .storageModeShared) {
                vb.label = "Q3 2D Vertices \(i)"
                vertexBuffers2D.append(vb)
            }
            if let ib = device.makeBuffer(length: idx2DSize, options: .storageModeShared) {
                ib.label = "Q3 2D Indices \(i)"
                indexBuffers2D.append(ib)
            }
        }

        // Entity vertex/index buffers (triple-buffered)
        let evbSize = MemoryLayout<Q3GPUVertex>.stride * maxEntityVertices
        let eibSize = MemoryLayout<UInt32>.stride * maxEntityIndices
        for i in 0..<maxBuffersInFlight {
            if let vb = device.makeBuffer(length: evbSize, options: .storageModeShared) {
                vb.label = "Q3 Entity Vertices \(i)"
                entityVertexBuffers.append(vb)
            }
            if let ib = device.makeBuffer(length: eibSize, options: .storageModeShared) {
                ib.label = "Q3 Entity Indices \(i)"
                entityIndexBuffers.append(ib)
            }
        }

        // Force initial residency set with base buffers
        updateResidencySet()

        Q3Console.shared.print("Renderer initialized")
    }

    // MARK: - Map Loading

    func loadMap(_ name: String) {
        Q3Console.shared.print("Loading map: \(name)")

        let path = "maps/\(name).bsp"
        guard let data = Q3FileSystem.shared.loadFile(path) else {
            Q3Console.shared.print("ERROR: Could not load \(path)")
            return
        }

        // Parse BSP
        let bspFile = BSPFile()
        guard bspFile.load(from: data) else {
            Q3Console.shared.print("ERROR: Failed to parse BSP")
            return
        }

        // Load shaders
        ShaderParser.shared.loadAllShaders()

        // Create world model
        worldModel = BSPWorldModel(bspFile: bspFile)

        // Load lightmaps
        lightmapAtlas.loadFromBSP(bspFile, textureCache: textureCache, imageLoader: textureCache.imageLoader)

        // Build geometry
        let geom = BSPGeometryBuilder(device: device)
        geom.build(bspFile: bspFile, textureCache: textureCache, lightmapAtlas: lightmapAtlas, shaderParser: ShaderParser.shared)
        geometry = geom

        // Setup BSP renderer
        renderBSP.setup(worldModel: worldModel!, geometry: geom, textureCache: textureCache)

        // Setup sky
        renderBSP.setupSky(device: device, textureCache: textureCache)

        // Create stage uniform buffer
        renderBSP.createStageUniformBuffer(device: device)

        // Update residency set
        updateResidencySet()

        // Find spawn point
        if let world = worldModel {
            let entities = world.parseEntities()
            for ent in entities {
                if ent["classname"] == "info_player_deathmatch" || ent["classname"] == "info_player_start" {
                    if let originStr = ent["origin"] {
                        let parts = originStr.split(separator: " ")
                        if parts.count >= 3 {
                            cameraOrigin = Vec3(
                                Float(parts[0]) ?? 0,
                                Float(parts[1]) ?? 0,
                                Float(parts[2]) ?? 0
                            )
                        }
                    }
                    if let angleStr = ent["angle"] {
                        cameraAngles.y = Float(angleStr) ?? 0
                    }
                    break
                }
            }
        }

        mapLoaded = true
        Q3Console.shared.print("Map loaded successfully")

        // Update mapname cvar
        Q3CVar.shared.set("mapname", value: name, force: true)
    }

    func updateResidencySet() {
        // Add all GPU buffers and textures to residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = textureCache.textureCount + 8

        if let newSet = try? device.makeResidencySet(descriptor: resDesc) {
            commandQueue.removeResidencySet(residencySet)

            // Add buffers
            var allocations: [any MTLAllocation] = [uniformBuffer]
            allocations.append(contentsOf: vertexBuffers2D)
            allocations.append(contentsOf: indexBuffers2D)
            allocations.append(contentsOf: entityVertexBuffers)
            allocations.append(contentsOf: entityIndexBuffers)
            if let vb = geometry?.vertexBuffer { allocations.append(vb) }
            if let ib = geometry?.indexBuffer { allocations.append(ib) }
            if let sub = renderBSP.stageUniformBuffer { allocations.append(sub) }
            if let svb = renderBSP.skyRenderer?.skyVertexBuffer { allocations.append(svb) }
            if let sib = renderBSP.skyRenderer?.skyIndexBuffer { allocations.append(sib) }

            // Add textures
            allocations.append(contentsOf: textureCache.allTextures())

            newSet.addAllocations(allocations)
            newSet.commit()
            commandQueue.addResidencySet(newSet)
            residencySet = newSet

            lastResidencyTextureCount = textureCache.textureCount
        }
    }

    // MARK: - Camera

    func updateCamera(deltaTime: Float) {
        // Update angles from mouse
        cameraAngles.y -= mouseDeltaX * sensitivity
        cameraAngles.x -= mouseDeltaY * sensitivity
        cameraAngles.x = max(-89, min(89, cameraAngles.x))
        mouseDeltaX = 0
        mouseDeltaY = 0

        // Calculate movement vectors
        let (forward, right, _) = angleVectors(cameraAngles)
        let speed = moveSpeed * deltaTime

        cameraOrigin += forward * (moveForward * speed)
        cameraOrigin += right * (moveRight * speed)
        cameraOrigin += Vec3(0, 0, 1) * (moveUp * speed)
    }

    func buildFrustumPlanes() -> [Plane] {
        let (forward, right, up) = angleVectors(cameraAngles)
        // fovX=90 → tan(45)=1.0, fovY depends on aspect ratio
        let xScale: Float = 1.0
        let yScale = xScale / viewAspect

        // Left plane
        let leftNormal = simd_normalize(forward + right * xScale)
        // Right plane
        let rightNormal = simd_normalize(forward - right * xScale)
        // Top plane
        let topNormal = simd_normalize(forward + up * yScale)
        // Bottom plane
        let bottomNormal = simd_normalize(forward - up * yScale)

        return [
            Plane(normal: leftNormal, dist: simd_dot(leftNormal, cameraOrigin)),
            Plane(normal: rightNormal, dist: simd_dot(rightNormal, cameraOrigin)),
            Plane(normal: topNormal, dist: simd_dot(topNormal, cameraOrigin)),
            Plane(normal: bottomNormal, dist: simd_dot(bottomNormal, cameraOrigin))
        ]
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        // Reset per-frame entity lists before engine frame runs cgame
        ClientMain.shared.rendererAPI?.beginFrame()

        // Engine frame
        Q3Engine.shared.frame()

        // Timing
        let now = ProcessInfo.processInfo.systemUptime
        if lastFrameTime > 0 {
            frameTime = Float(now - lastFrameTime)
        }
        lastFrameTime = now

        guard let drawable = view.currentDrawable else { return }
        guard let renderPassDescriptor = view.currentMTL4RenderPassDescriptor else { return }

        // Wait for GPU (guard against negative values for early frames)
        let previousValue = frameIndex - maxBuffersInFlight
        if previousValue > 0 {
            endFrameEvent.wait(untilSignaledValue: UInt64(previousValue), timeoutMS: 1000)
        }

        let allocator = commandAllocators[uniformBufferIndex]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        // Refresh residency BEFORE encoding — new textures from last frame need to be resident
        if textureCache.textureCount != lastResidencyTextureCount {
            updateResidencySet()
        }

        // Update uniform buffer index
        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        // Update camera — use cgame refdef when game is active, otherwise free-fly
        if gameActive, ClientMain.shared.cgameStarted,
           let refdef = ClientMain.shared.rendererAPI?.currentRefdef {
            cameraOrigin = refdef.viewOrigin
            let forward = refdef.viewAxis.0
            let pitch = asin(-forward.z) * (180.0 / .pi)
            let yaw = atan2(forward.y, forward.x) * (180.0 / .pi)
            cameraAngles = Vec3(pitch, yaw, 0)
        } else {
            updateCamera(deltaTime: frameTime)
        }

        // Update uniforms
        let uniformOffset = ((MemoryLayout<Q3FrameUniforms>.size + 0xFF) & ~0xFF) * uniformBufferIndex
        let uniformPtr = (uniformBuffer.contents() + uniformOffset).bindMemory(to: Q3FrameUniforms.self, capacity: 1)

        let (forward, _, _) = angleVectors(cameraAngles)
        let viewTarget = cameraOrigin + forward
        let viewMatrix = lookAt(eye: cameraOrigin, target: viewTarget, up: Vec3(0, 0, 1))

        uniformPtr.pointee.projectionMatrix = projectionMatrix
        uniformPtr.pointee.viewMatrix = viewMatrix
        uniformPtr.pointee.modelMatrix = matrix_float4x4(1)
        uniformPtr.pointee.viewOrigin = cameraOrigin
        uniformPtr.pointee.time = Float(now)

        // Create render encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.endCommandBuffer()
            return
        }

        renderEncoder.label = "Q3 World Render"
        renderEncoder.setFrontFacing(.counterClockwise)

        // Set argument tables (frame-indexed to avoid GPU/CPU race)
        let vertexArgumentTable = vertexArgumentTables[uniformBufferIndex]
        let fragmentArgumentTable = fragmentArgumentTables[uniformBufferIndex]
        renderEncoder.setArgumentTable(vertexArgumentTable, stages: .vertex)
        renderEncoder.setArgumentTable(fragmentArgumentTable, stages: .fragment)

        // Set uniform buffer
        vertexArgumentTable.setAddress(uniformBuffer.gpuAddress + UInt64(uniformOffset), index: BufferIndex.uniforms.rawValue)
        fragmentArgumentTable.setAddress(uniformBuffer.gpuAddress + UInt64(uniformOffset), index: BufferIndex.uniforms.rawValue)

        if mapLoaded, let geom = geometry {
            // Update visibility
            let frustum = buildFrustumPlanes()
            renderBSP.updateVisibility(viewOrigin: cameraOrigin, frustumPlanes: frustum)

            // Set default pipeline
            renderEncoder.setRenderPipelineState(pipelineManager.defaultPipeline)
            renderEncoder.setDepthStencilState(pipelineManager.defaultDepthState)
            renderEncoder.setCullMode(.back)

            // Render world
            renderBSP.renderWorld(
                encoder: renderEncoder,
                vertexTable: vertexArgumentTable,
                fragmentTable: fragmentArgumentTable,
                geometry: geom,
                textureCache: textureCache,
                pipelineManager: pipelineManager,
                view: view,
                time: Float(now),
                frameIndex: uniformBufferIndex
            )

            // Render entities in two passes: world entities, then depth-clear, then weapon
            if gameActive, let rendererAPI = ClientMain.shared.rendererAPI,
               uniformBufferIndex < entityVertexBuffers.count,
               uniformBufferIndex < entityIndexBuffers.count {
                let evb = entityVertexBuffers[uniformBufferIndex]
                let eib = entityIndexBuffers[uniformBufferIndex]

                // Split by RF_DEPTHHACK on each entity — cgame submits all entities
                // in one renderScene call, so rendererAPI.weaponEntities may be empty.
                let allEnts = rendererAPI.worldEntities + rendererAPI.weaponEntities
                let worldEnts = allEnts.filter { $0.renderfx & RenderEntity.rfDepthHack == 0 }
                let weaponEnts = allEnts.filter { $0.renderfx & RenderEntity.rfDepthHack != 0 }

                // Shared buffer offsets — all entity/poly passes share one buffer
                var entityVertexOffset = 0
                var entityIndexOffset = 0

                // Render scene polygons (tracers, impact marks, etc.)
                let polys = rendererAPI.worldPolys
                if !polys.isEmpty {
                    RenderEntity.renderPolys(
                        polys: polys,
                        encoder: renderEncoder,
                        vertexTable: vertexArgumentTable,
                        fragmentTable: fragmentArgumentTable,
                        entityVertexBuffer: evb,
                        entityIndexBuffer: eib,
                        rendererAPI: rendererAPI,
                        textureCache: textureCache,
                        pipelineManager: pipelineManager,
                        stageUniformBuffer: renderBSP.stageUniformBuffer,
                        stageUniformDrawIndex: &renderBSP.stageUniformDrawIndex,
                        stageUniformAlignment: renderBSP.stageUniformAlignment,
                        view: view,
                        vertexOffsetInOut: &entityVertexOffset,
                        indexOffsetInOut: &entityIndexOffset
                    )
                }

                if !worldEnts.isEmpty || !weaponEnts.isEmpty {

                    // Pass 1: Render world entities (players, items — no RF_DEPTHHACK)
                    if !worldEnts.isEmpty {
                        RenderEntity.renderEntities(
                            entities: worldEnts,
                            encoder: renderEncoder,
                            vertexTable: vertexArgumentTable,
                            fragmentTable: fragmentArgumentTable,
                            entityVertexBuffer: evb,
                            entityIndexBuffer: eib,
                            rendererAPI: rendererAPI,
                            textureCache: textureCache,
                            pipelineManager: pipelineManager,
                            stageUniformBuffer: renderBSP.stageUniformBuffer,
                            stageUniformDrawIndex: &renderBSP.stageUniformDrawIndex,
                            stageUniformAlignment: renderBSP.stageUniformAlignment,
                            view: view,
                            cameraOrigin: cameraOrigin,
                            vertexOffsetInOut: &entityVertexOffset,
                            indexOffsetInOut: &entityIndexOffset
                        )
                    }

                    // Pass 2: Depth-clear + weapon entities (RF_DEPTHHACK)
                    if !weaponEnts.isEmpty {
                        // Draw fullscreen triangle to reset depth buffer to 1.0
                        renderEncoder.setRenderPipelineState(pipelineManager.depthClearPipeline)
                        renderEncoder.setDepthStencilState(pipelineManager.depthClearDepthState)
                        renderEncoder.setCullMode(.none)
                        renderEncoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)

                        // Render weapon viewmodel — depth tests only against itself
                        RenderEntity.renderEntities(
                            entities: weaponEnts,
                            encoder: renderEncoder,
                            vertexTable: vertexArgumentTable,
                            fragmentTable: fragmentArgumentTable,
                            entityVertexBuffer: evb,
                            entityIndexBuffer: eib,
                            rendererAPI: rendererAPI,
                            textureCache: textureCache,
                            pipelineManager: pipelineManager,
                            stageUniformBuffer: renderBSP.stageUniformBuffer,
                            stageUniformDrawIndex: &renderBSP.stageUniformDrawIndex,
                            stageUniformAlignment: renderBSP.stageUniformAlignment,
                            view: view,
                            cameraOrigin: cameraOrigin,
                            vertexOffsetInOut: &entityVertexOffset,
                            indexOffsetInOut: &entityIndexOffset
                        )
                    }
                }

                // Restore world vertex buffer for any subsequent world rendering
                if let vb = geom.vertexBuffer {
                    vertexArgumentTable.setAddress(vb.gpuAddress, index: 0)
                }
            }
        }

        // Refresh UI VM — only when menu is active (KEYCATCH_UI), not during gameplay
        if ClientUI.shared.initialized && (ClientUI.shared.keyCatcher & 2 != 0) {
            if let vm = ClientUI.shared.uiVM, !vm.aborted {
                let msTime = Int32(Q3Engine.shared.realTime & 0x7FFFFFFF)
                ClientUI.shared.refresh(msTime)
            }
        }

        // Render 2D UI overlay (menus, HUD)
        render2D(encoder: renderEncoder)

        renderEncoder.endEncoding()

        commandBuffer.useResidencySet(residencySet)
        commandBuffer.useResidencySet((view.layer as! CAMetalLayer).residencySet)
        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        commandQueue.signalEvent(endFrameEvent, value: UInt64(frameIndex))
        frameIndex += 1
        drawable.present()
    }

    // MARK: - 2D Rendering

    func render2D(encoder: any MTL4RenderCommandEncoder) {
        guard let rendererAPI = ClientMain.shared.rendererAPI else { return }
        let cmds = rendererAPI.drawPicCmds
        guard !cmds.isEmpty else { return }
        guard uniformBufferIndex < vertexBuffers2D.count,
              uniformBufferIndex < indexBuffers2D.count else { return }
        let vb = vertexBuffers2D[uniformBufferIndex]
        let ib = indexBuffers2D[uniformBufferIndex]

        let quadCount = min(cmds.count, max2DQuads)
        let vertexPtr = vb.contents().bindMemory(to: Q3_2DVertex.self, capacity: quadCount * 4)
        let indexPtr = ib.contents().bindMemory(to: UInt16.self, capacity: quadCount * 6)

        // Build all quads
        for i in 0..<quadCount {
            let cmd = cmds[i]
            let vi = i * 4
            let ii = i * 6
            let color = cmd.color

            // Top-left
            vertexPtr[vi + 0] = Q3_2DVertex(
                position: SIMD2<Float>(cmd.x, cmd.y),
                texCoord: SIMD2<Float>(cmd.s1, cmd.t1),
                color: color)
            // Top-right
            vertexPtr[vi + 1] = Q3_2DVertex(
                position: SIMD2<Float>(cmd.x + cmd.w, cmd.y),
                texCoord: SIMD2<Float>(cmd.s2, cmd.t1),
                color: color)
            // Bottom-right
            vertexPtr[vi + 2] = Q3_2DVertex(
                position: SIMD2<Float>(cmd.x + cmd.w, cmd.y + cmd.h),
                texCoord: SIMD2<Float>(cmd.s2, cmd.t2),
                color: color)
            // Bottom-left
            vertexPtr[vi + 3] = Q3_2DVertex(
                position: SIMD2<Float>(cmd.x, cmd.y + cmd.h),
                texCoord: SIMD2<Float>(cmd.s1, cmd.t2),
                color: color)

            // Two triangles: 0-1-2, 0-2-3
            indexPtr[ii + 0] = UInt16(vi + 0)
            indexPtr[ii + 1] = UInt16(vi + 1)
            indexPtr[ii + 2] = UInt16(vi + 2)
            indexPtr[ii + 3] = UInt16(vi + 0)
            indexPtr[ii + 4] = UInt16(vi + 2)
            indexPtr[ii + 5] = UInt16(vi + 3)
        }

        // Set 2D pipeline state
        encoder.setRenderPipelineState(pipelineManager.pipeline2D)
        encoder.setDepthStencilState(pipelineManager.depthState2D)
        encoder.setCullMode(.none)

        // Draw batches grouped by texture
        var batchStart = 0
        while batchStart < quadCount {
            let shaderHandle = cmds[batchStart].shader
            let texHandle = rendererAPI.resolveShaderTexture(shaderHandle)
            guard let texture = textureCache.getTexture(texHandle) else {
                batchStart += 1
                continue
            }

            // Find how many consecutive quads use the same shader
            var batchEnd = batchStart + 1
            while batchEnd < quadCount && cmds[batchEnd].shader == shaderHandle {
                batchEnd += 1
            }
            let batchQuads = batchEnd - batchStart

            // Bind vertex buffer and texture via argument tables
            let vertTable = vertexArgumentTables[uniformBufferIndex]
            let fragTable = fragmentArgumentTables[uniformBufferIndex]
            vertTable.setAddress(vb.gpuAddress, index: BufferIndex.twoDVertices.rawValue)
            fragTable.setTexture(texture.gpuResourceID, index: TextureIndex.color.rawValue)

            let indexOffset = batchStart * 6 * MemoryLayout<UInt16>.stride
            let indexLength = ib.length - indexOffset
            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: batchQuads * 6,
                indexType: .uint16,
                indexBuffer: ib.gpuAddress + UInt64(indexOffset),
                indexBufferLength: indexLength
            )

            batchStart = batchEnd
        }

        // Clear draw commands after rendering
        rendererAPI.drawPicCmds.removeAll(keepingCapacity: true)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewAspect = Float(size.width) / Float(size.height)
        // Q3 uses fovX=90, compute fovY from aspect ratio
        let fovXRad: Float = 90.0 * .pi / 180.0
        let fovYRad = 2.0 * atan(tan(fovXRad * 0.5) / viewAspect)
        projectionMatrix = matrix_perspective_right_hand(
            fovyRadians: fovYRad,
            aspectRatio: viewAspect,
            nearZ: 4.0,
            farZ: 16384.0
        )
    }

    // MARK: - View Matrix

    private func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> matrix_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)

        return matrix_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }
}
