// ImageLoader.swift — TGA + JPEG loading from pk3s → MTLTexture

import Foundation
import Metal
import MetalKit

class ImageLoader {
    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func loadTexture(named name: String) -> MTLTexture? {
        let cleanName = name.lowercased().replacingOccurrences(of: "\\", with: "/")

        // Try exact path first
        if let tex = loadFromPath(cleanName) { return tex }

        // Try with extensions
        for ext in ["tga", "jpg", "jpeg", "png"] {
            let withExt: String
            if cleanName.hasSuffix(".\(ext)") {
                withExt = cleanName
            } else {
                // Strip existing extension and try new one
                let base = (cleanName as NSString).deletingPathExtension
                withExt = "\(base).\(ext)"
            }
            if let tex = loadFromPath(withExt) { return tex }
        }

        return nil
    }

    private func loadFromPath(_ path: String) -> MTLTexture? {
        guard let data = Q3FileSystem.shared.loadFile(path) else { return nil }

        let lower = path.lowercased()
        if lower.hasSuffix(".tga") {
            return loadTGA(data)
        } else if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return loadJPEG(data)
        } else if lower.hasSuffix(".png") {
            return loadPNG(data)
        }

        // Try TGA first, then JPEG
        if let tex = loadTGA(data) { return tex }
        if let tex = loadJPEG(data) { return tex }
        return nil
    }

    // MARK: - TGA Loading

    private func loadTGA(_ data: Data) -> MTLTexture? {
        guard data.count > 18 else { return nil }

        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!
            let idLength = Int(base.load(fromByteOffset: 0, as: UInt8.self))
            let colorMapType = base.load(fromByteOffset: 1, as: UInt8.self)
            let imageType = base.load(fromByteOffset: 2, as: UInt8.self)
            let width = Int(base.loadUnaligned(fromByteOffset: 12, as: UInt16.self).littleEndian)
            let height = Int(base.loadUnaligned(fromByteOffset: 14, as: UInt16.self).littleEndian)
            let bitsPerPixel = Int(base.load(fromByteOffset: 16, as: UInt8.self))
            let descriptor = base.load(fromByteOffset: 17, as: UInt8.self)

            guard width > 0 && height > 0 && width <= 4096 && height <= 4096 else { return nil as MTLTexture? }
            guard colorMapType == 0 else { return nil }

            let headerSize = 18 + idLength
            let isRLE = imageType == 10
            let isUncompressed = imageType == 2
            guard isRLE || isUncompressed else { return nil }

            let bytesPerPixel = bitsPerPixel / 8
            guard bytesPerPixel == 3 || bytesPerPixel == 4 else { return nil }

            var pixels = [UInt8](repeating: 255, count: width * height * 4)

            if isUncompressed {
                let pixelDataSize = width * height * bytesPerPixel
                guard headerSize + pixelDataSize <= data.count else { return nil }

                for i in 0..<(width * height) {
                    let srcOffset = headerSize + i * bytesPerPixel
                    let b = base.load(fromByteOffset: srcOffset, as: UInt8.self)
                    let g = base.load(fromByteOffset: srcOffset + 1, as: UInt8.self)
                    let r = base.load(fromByteOffset: srcOffset + 2, as: UInt8.self)
                    let a: UInt8 = bytesPerPixel == 4 ? base.load(fromByteOffset: srcOffset + 3, as: UInt8.self) : 255
                    pixels[i * 4] = r
                    pixels[i * 4 + 1] = g
                    pixels[i * 4 + 2] = b
                    pixels[i * 4 + 3] = a
                }
            } else {
                // RLE decoding
                var srcIdx = headerSize
                var pixelIdx = 0
                let totalPixels = width * height

                while pixelIdx < totalPixels && srcIdx < data.count {
                    let packet = base.load(fromByteOffset: srcIdx, as: UInt8.self)
                    srcIdx += 1
                    let count = Int(packet & 0x7F) + 1

                    if packet & 0x80 != 0 {
                        // RLE packet
                        guard srcIdx + bytesPerPixel <= data.count else { break }
                        let b = base.load(fromByteOffset: srcIdx, as: UInt8.self)
                        let g = base.load(fromByteOffset: srcIdx + 1, as: UInt8.self)
                        let r = base.load(fromByteOffset: srcIdx + 2, as: UInt8.self)
                        let a: UInt8 = bytesPerPixel == 4 ? base.load(fromByteOffset: srcIdx + 3, as: UInt8.self) : 255
                        srcIdx += bytesPerPixel
                        for _ in 0..<count {
                            if pixelIdx >= totalPixels { break }
                            pixels[pixelIdx * 4] = r
                            pixels[pixelIdx * 4 + 1] = g
                            pixels[pixelIdx * 4 + 2] = b
                            pixels[pixelIdx * 4 + 3] = a
                            pixelIdx += 1
                        }
                    } else {
                        // Raw packet
                        for _ in 0..<count {
                            if pixelIdx >= totalPixels || srcIdx + bytesPerPixel > data.count { break }
                            let b = base.load(fromByteOffset: srcIdx, as: UInt8.self)
                            let g = base.load(fromByteOffset: srcIdx + 1, as: UInt8.self)
                            let r = base.load(fromByteOffset: srcIdx + 2, as: UInt8.self)
                            let a: UInt8 = bytesPerPixel == 4 ? base.load(fromByteOffset: srcIdx + 3, as: UInt8.self) : 255
                            srcIdx += bytesPerPixel
                            pixels[pixelIdx * 4] = r
                            pixels[pixelIdx * 4 + 1] = g
                            pixels[pixelIdx * 4 + 2] = b
                            pixels[pixelIdx * 4 + 3] = a
                            pixelIdx += 1
                        }
                    }
                }
            }

            // Handle vertical flip (TGA origin is bottom-left unless bit 5 of descriptor is set)
            let topToBottom = (descriptor & 0x20) != 0
            if !topToBottom {
                for y in 0..<(height / 2) {
                    let y2 = height - 1 - y
                    for x in 0..<width {
                        let i1 = (y * width + x) * 4
                        let i2 = (y2 * width + x) * 4
                        for c in 0..<4 {
                            let tmp = pixels[i1 + c]
                            pixels[i1 + c] = pixels[i2 + c]
                            pixels[i2 + c] = tmp
                        }
                    }
                }
            }

            return createTexture(from: pixels, width: width, height: height)
        }
    }

    // MARK: - JPEG Loading

    private func loadJPEG(_ data: Data) -> MTLTexture? {
        // Use CGImage via NSImage for JPEG decoding
        guard let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 && width <= 4096 && height <= 4096 else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: width * 4,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return createTexture(from: pixels, width: width, height: height)
    }

    // MARK: - PNG Loading

    private func loadPNG(_ data: Data) -> MTLTexture? {
        return loadJPEG(data)  // Same CGImage path works for PNG
    }

    // MARK: - Texture Creation

    func createTexture(from pixels: [UInt8], width: Int, height: Int, generateMipmaps: Bool = true) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: generateMipmaps
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4
        )

        if generateMipmaps {
            generateMipmapsForTexture(texture)
        }

        return texture
    }

    func createLightmapTexture(from rgb: [UInt8], width: Int, height: Int) -> MTLTexture? {
        // Convert RGB to RGBA
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
            rgba[i * 4 + 3] = 255
        }
        return createTexture(from: rgba, width: width, height: height, generateMipmaps: false)
    }

    private func generateMipmapsForTexture(_ texture: MTLTexture) {
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.generateMipmaps(for: texture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Default Textures

    func createWhiteTexture() -> MTLTexture? {
        let pixels: [UInt8] = [255, 255, 255, 255]
        return createTexture(from: pixels, width: 1, height: 1, generateMipmaps: false)
    }

    func createDefaultTexture() -> MTLTexture? {
        // 8x8 checkerboard
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<8 {
                let i = (y * 8 + x) * 4
                let isWhite = (x + y) % 2 == 0
                let c: UInt8 = isWhite ? 255 : 128
                pixels[i] = c
                pixels[i + 1] = isWhite ? 128 : 255
                pixels[i + 2] = c
                pixels[i + 3] = 255
            }
        }
        return createTexture(from: pixels, width: 8, height: 8, generateMipmaps: false)
    }
}

// MARK: - NSImage extension for CGImage
import AppKit
