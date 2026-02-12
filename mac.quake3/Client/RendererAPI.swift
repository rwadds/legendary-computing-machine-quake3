// RendererAPI.swift — Bridge between CGame VM and the Metal renderer

import Foundation
import simd

/// RefEntity used by cgame to describe entities to render
struct RefEntity {
    var reType: Int32 = 0           // RT_MODEL, RT_POLY, RT_SPRITE, etc.
    var renderfx: Int32 = 0
    var hModel: Int32 = 0           // Model handle
    var origin: Vec3 = .zero
    var axis: (Vec3, Vec3, Vec3) = (Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))
    var oldOrigin: Vec3 = .zero
    var frame: Int32 = 0
    var oldframe: Int32 = 0
    var backlerp: Float = 0
    var skinNum: Int32 = 0
    var customSkin: Int32 = 0
    var customShader: Int32 = 0
    var shaderRGBA: SIMD4<UInt8> = .init(255, 255, 255, 255)
    var shaderTexCoord: SIMD2<Float> = .zero
    var shaderTime: Float = 0
    var radius: Float = 0
    var rotation: Float = 0
}

/// RefDef — scene description for rendering
struct RefDef {
    var x: Int32 = 0
    var y: Int32 = 0
    var width: Int32 = 0
    var height: Int32 = 0
    var fovX: Float = 90
    var fovY: Float = 73.74
    var viewOrigin: Vec3 = .zero
    var viewAxis: (Vec3, Vec3, Vec3) = (Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))
    var time: Int32 = 0
}

/// DynamicLight for addLightToScene
struct DynamicLight {
    var origin: Vec3 = .zero
    var intensity: Float = 0
    var color: Vec3 = Vec3(1, 1, 1)
}

/// Scene polygon vertex (matches Q3 polyVert_t: 24 bytes)
struct PolyVertex {
    var position: Vec3
    var texCoord: SIMD2<Float>
    var color: SIMD4<UInt8>
}

/// Scene polygon added via trap_R_AddPolyToScene
struct ScenePoly {
    var shader: Int32
    var vertices: [PolyVertex]
}

class RendererAPI {
    // Registered resources
    var registeredModels: [String: Int32] = [:]
    var registeredShaders: [String: Int32] = [:]
    var registeredSkins: [String: Int32] = [:]
    var modelNames: [Int32: String] = [:]  // Reverse lookup: handle → path
    var nextModelHandle: Int32 = 1
    var nextShaderHandle: Int32 = 1
    var nextSkinHandle: Int32 = 1

    // Debug frame counter

    // Shader handle → texture cache handle mapping for 2D rendering
    var shaderToTexture: [Int32: Int] = [:]
    var shaderNames: [Int32: String] = [:]
    weak var textureCache: TextureCache?

    // Scene — entities accumulate across clearScene/renderScene pairs per frame
    var sceneEntities: [RefEntity] = []
    var sceneLights: [DynamicLight] = []
    var currentColor: SIMD4<Float>? = nil
    var currentRefdef: RefDef = RefDef()

    // Multi-pass entity accumulation:
    // cgame does: clearScene → add world ents → renderScene(world) → clearScene → add weapon ents → renderScene(weapon)
    // We capture entities from each pass so the renderer can draw both.
    var worldEntities: [RefEntity] = []
    var weaponEntities: [RefEntity] = []
    var weaponRefdef: RefDef?

    // Scene polygons (tracers, impact marks, etc.)
    var scenePolys: [ScenePoly] = []
    var worldPolys: [ScenePoly] = []

    // 2D draw commands
    struct DrawPicCmd {
        var x, y, w, h: Float
        var s1, t1, s2, t2: Float
        var shader: Int32
        var color: SIMD4<Float>
    }
    var drawPicCmds: [DrawPicCmd] = []

    // MARK: - Registration

    func registerModel(_ name: String) -> Int32 {
        let key = name.lowercased()
        if let existing = registeredModels[key] { return existing }
        let handle = nextModelHandle
        nextModelHandle += 1
        registeredModels[key] = handle
        modelNames[handle] = key
        return handle
    }

    func registerShader(_ name: String) -> Int32 {
        if let existing = registeredShaders[name.lowercased()] { return existing }
        let handle = nextShaderHandle
        nextShaderHandle += 1
        registeredShaders[name.lowercased()] = handle
        shaderNames[handle] = name.lowercased()
        // Pre-load texture for 2D rendering
        if let tc = textureCache {
            shaderToTexture[handle] = tc.findOrLoad(name)
        }
        return handle
    }

    func registerShaderNoMip(_ name: String) -> Int32 {
        return registerShader(name)
    }

    /// Resolve a shader handle to a texture cache handle for 2D drawing
    func resolveShaderTexture(_ shaderHandle: Int32) -> Int {
        if let texHandle = shaderToTexture[shaderHandle] {
            return texHandle
        }
        // Lazy resolve — try loading now
        if let tc = textureCache, let name = shaderNames[shaderHandle] {
            let texHandle = tc.findOrLoad(name)
            shaderToTexture[shaderHandle] = texHandle
            return texHandle
        }
        return textureCache?.whiteTexture ?? 0
    }

    func registerSkin(_ name: String) -> Int32 {
        if let existing = registeredSkins[name.lowercased()] { return existing }
        let handle = nextSkinHandle
        nextSkinHandle += 1
        registeredSkins[name.lowercased()] = handle
        return handle
    }

    // MARK: - Scene Building

    func clearScene() {
        sceneEntities.removeAll(keepingCapacity: true)
        sceneLights.removeAll(keepingCapacity: true)
        scenePolys.removeAll(keepingCapacity: true)
        // Note: drawPicCmds are NOT cleared here — they accumulate across
        // clearScene/renderScene pairs and are consumed by render2D()
    }

    func addRefEntityToScene(vm: QVM, addr: Int32) {
        var ent = RefEntity()
        let a = Int(addr)

        ent.reType = vm.readInt32(fromData: a + 0)
        ent.renderfx = vm.readInt32(fromData: a + 4)
        ent.hModel = vm.readInt32(fromData: a + 8)
        // lightingOrigin at a+12 (skip)
        // shadowPlane at a+24 (skip)
        // axis 3x3 at a+28
        for row in 0..<3 {
            let offset = a + 28 + row * 12
            let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset)))
            let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 4)))
            let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 8)))
            switch row {
            case 0: ent.axis.0 = Vec3(x, y, z)
            case 1: ent.axis.1 = Vec3(x, y, z)
            case 2: ent.axis.2 = Vec3(x, y, z)
            default: break
            }
        }
        // nonNormalizedAxes at a+64 (skip)
        ent.origin = ServerMain.shared.readVec3(vm: vm, addr: Int32(a + 68))
        ent.frame = vm.readInt32(fromData: a + 80)
        ent.oldOrigin = ServerMain.shared.readVec3(vm: vm, addr: Int32(a + 84))
        ent.oldframe = vm.readInt32(fromData: a + 96)
        ent.backlerp = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 100)))
        ent.skinNum = vm.readInt32(fromData: a + 104)
        ent.customSkin = vm.readInt32(fromData: a + 108)
        ent.customShader = vm.readInt32(fromData: a + 112)
        // shaderRGBA at a+116
        let rgba0 = vm.readUInt8(fromData: a + 116)
        let rgba1 = vm.readUInt8(fromData: a + 117)
        let rgba2 = vm.readUInt8(fromData: a + 118)
        let rgba3 = vm.readUInt8(fromData: a + 119)
        ent.shaderRGBA = SIMD4<UInt8>(rgba0, rgba1, rgba2, rgba3)
        // shaderTexCoord[2] at offset 120
        let stcS = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 120)))
        let stcT = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 124)))
        ent.shaderTexCoord = SIMD2<Float>(stcS, stcT)
        // shaderTime at offset 128
        ent.shaderTime = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 128)))
        // radius at offset 132, rotation at offset 136
        ent.radius = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 132)))
        ent.rotation = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 136)))

        sceneEntities.append(ent)
    }

    /// Parse polyVert_t array from VM memory and add polygon to scene
    func addPolyToScene(vm: QVM, shader: Int32, numVerts: Int, vertsAddr: Int32) {
        guard numVerts >= 3, numVerts <= 64 else { return }
        let base = Int(vertsAddr)
        // polyVert_t: xyz (12 bytes) + st (8 bytes) + modulate (4 bytes) = 24 bytes
        let stride = 24
        var verts: [PolyVertex] = []
        verts.reserveCapacity(numVerts)
        for i in 0..<numVerts {
            let offset = base + i * stride
            let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset)))
            let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 4)))
            let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 8)))
            let s = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 12)))
            let t = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 16)))
            let r = vm.readUInt8(fromData: offset + 20)
            let g = vm.readUInt8(fromData: offset + 21)
            let b = vm.readUInt8(fromData: offset + 22)
            let a = vm.readUInt8(fromData: offset + 23)
            verts.append(PolyVertex(
                position: Vec3(x, y, z),
                texCoord: SIMD2<Float>(s, t),
                color: SIMD4<UInt8>(r, g, b, a)
            ))
        }
        scenePolys.append(ScenePoly(shader: shader, vertices: verts))
    }

    func addLightToScene(origin: Vec3, intensity: Float, r: Float, g: Float, b: Float) {
        var light = DynamicLight()
        light.origin = origin
        light.intensity = intensity
        light.color = Vec3(r, g, b)
        sceneLights.append(light)
    }

    func renderScene(vm: QVM, refdefAddr: Int32) {
        let a = Int(refdefAddr)

        var refdef = RefDef()
        refdef.x = vm.readInt32(fromData: a + 0)
        refdef.y = vm.readInt32(fromData: a + 4)
        refdef.width = vm.readInt32(fromData: a + 8)
        refdef.height = vm.readInt32(fromData: a + 12)
        refdef.fovX = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 16)))
        refdef.fovY = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 20)))
        refdef.viewOrigin = ServerMain.shared.readVec3(vm: vm, addr: Int32(a + 24))

        for row in 0..<3 {
            let offset = a + 36 + row * 12
            let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset)))
            let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 4)))
            let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: offset + 8)))
            switch row {
            case 0: refdef.viewAxis.0 = Vec3(x, y, z)
            case 1: refdef.viewAxis.1 = Vec3(x, y, z)
            case 2: refdef.viewAxis.2 = Vec3(x, y, z)
            default: break
            }
        }

        refdef.time = vm.readInt32(fromData: a + 72)
        let rdflags = vm.readInt32(fromData: a + 76)

        // RDF_NOWORLDMODEL = 1 — weapon/HUD renders have this flag set
        if rdflags & 1 == 0 {
            // World render pass — capture world entities/polys and primary refdef
            currentRefdef = refdef
            worldEntities.append(contentsOf: sceneEntities)
            worldPolys.append(contentsOf: scenePolys)
        } else {
            // Weapon/viewmodel render pass — capture weapon entities and weapon refdef
            weaponEntities.append(contentsOf: sceneEntities)
            weaponRefdef = refdef
        }

    }

    /// Called by RenderMain at start of frame to reset per-frame entity lists
    func beginFrame() {
        worldEntities.removeAll(keepingCapacity: true)
        weaponEntities.removeAll(keepingCapacity: true)
        worldPolys.removeAll(keepingCapacity: true)
        weaponRefdef = nil
    }

    func setColor(_ color: SIMD4<Float>?) {
        currentColor = color
    }

    func drawStretchPic(x: Float, y: Float, w: Float, h: Float,
                        s1: Float, t1: Float, s2: Float, t2: Float, shader: Int32) {
        drawPicCmds.append(DrawPicCmd(
            x: x, y: y, w: w, h: h,
            s1: s1, t1: t1, s2: s2, t2: t2,
            shader: shader,
            color: currentColor ?? SIMD4<Float>(1, 1, 1, 1)
        ))
    }
}
