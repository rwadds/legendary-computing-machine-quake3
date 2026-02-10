// TextureCache.swift — Texture name → MTLTexture lookup, default textures

import Foundation
import Metal

class TextureCache {
    let device: MTLDevice
    let imageLoader: ImageLoader

    private var textures: [String: Int] = [:]       // name → handle
    private var textureList: [MTLTexture] = []       // handle → texture

    var whiteTexture: Int = -1
    var defaultTexture: Int = -1

    init(device: MTLDevice) {
        self.device = device
        self.imageLoader = ImageLoader(device: device)
        createDefaultTextures()
    }

    private func createDefaultTextures() {
        if let white = imageLoader.createWhiteTexture() {
            whiteTexture = addTexture(white, name: "*white")
        }
        if let def = imageLoader.createDefaultTexture() {
            defaultTexture = addTexture(def, name: "*default")
        }
    }

    private func addTexture(_ tex: MTLTexture, name: String) -> Int {
        let handle = textureList.count
        textureList.append(tex)
        textures[name.lowercased()] = handle
        return handle
    }

    func findOrLoad(_ name: String) -> Int {
        let key = name.lowercased().replacingOccurrences(of: "\\", with: "/")

        if let handle = textures[key] {
            return handle
        }

        // Strip extension for lookup
        let baseName = (key as NSString).deletingPathExtension
        if let handle = textures[baseName] {
            return handle
        }

        if let tex = imageLoader.loadTexture(named: key) {
            return addTexture(tex, name: key)
        }

        return defaultTexture
    }

    func getTexture(_ handle: Int) -> MTLTexture? {
        guard handle >= 0 && handle < textureList.count else { return nil }
        return textureList[handle]
    }

    func addLightmap(_ texture: MTLTexture, index: Int) -> Int {
        let name = "*lightmap\(index)"
        return addTexture(texture, name: name)
    }

    func lightmapHandle(for index: Int) -> Int {
        return textures["*lightmap\(index)"] ?? whiteTexture
    }

    var textureCount: Int { textureList.count }

    func allTextures() -> [MTLTexture] { textureList }
}
