// LightmapAtlas.swift — Load 128x128 RGB lightmaps from BSP, create Metal textures

import Foundation
import Metal

class LightmapAtlas {
    private(set) var lightmapTextures: [MTLTexture] = []
    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func loadFromBSP(_ bspFile: BSPFile, textureCache: TextureCache, imageLoader: ImageLoader) {
        let lmSize = LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 3  // RGB
        let totalBytes = bspFile.lightmapData.count
        guard totalBytes > 0 else {
            Q3Console.shared.print("No lightmap data in BSP")
            return
        }

        let numLightmaps = totalBytes / lmSize
        Q3Console.shared.print("Loading \(numLightmaps) lightmaps...")

        bspFile.lightmapData.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!
            for i in 0..<numLightmaps {
                let offset = i * lmSize
                let rgbPtr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let rgbArray = Array(UnsafeBufferPointer(start: rgbPtr, count: lmSize))

                // Convert RGB to RGBA and apply overbright
                var rgba = [UInt8](repeating: 255, count: LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 4)
                for p in 0..<(LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT) {
                    // Apply overbright shift (multiply by 2, clamp to 255)
                    let r = min(Int(rgbArray[p * 3]) * 2, 255)
                    let g = min(Int(rgbArray[p * 3 + 1]) * 2, 255)
                    let b = min(Int(rgbArray[p * 3 + 2]) * 2, 255)
                    rgba[p * 4] = UInt8(r)
                    rgba[p * 4 + 1] = UInt8(g)
                    rgba[p * 4 + 2] = UInt8(b)
                    rgba[p * 4 + 3] = 255
                }

                if let tex = imageLoader.createTexture(from: rgba, width: LIGHTMAP_WIDTH, height: LIGHTMAP_HEIGHT, generateMipmaps: false) {
                    let handle = textureCache.addLightmap(tex, index: i)
                    lightmapTextures.append(tex)
                    _ = handle
                }
            }
        }

        Q3Console.shared.print("Loaded \(lightmapTextures.count) lightmap textures")
    }

    func getLightmap(_ index: Int) -> MTLTexture? {
        guard index >= 0 && index < lightmapTextures.count else { return nil }
        return lightmapTextures[index]
    }
}
