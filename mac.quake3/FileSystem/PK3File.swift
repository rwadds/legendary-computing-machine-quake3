// PK3File.swift — ZIP/PK3 file reader

import Foundation
import Compression

class PK3File {
    let url: URL
    let name: String
    private(set) var entries: [String: PK3Entry] = [:]

    struct PK3Entry {
        let fileName: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let compressionMethod: UInt16
    }

    init?(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard parseCentralDirectory(data) else {
            return nil
        }
    }

    private func parseCentralDirectory(_ data: Data) -> Bool {
        // Find End of Central Directory record (search backwards)
        let eocdSig: UInt32 = 0x06054b50
        var eocdOffset = -1

        let count = data.count
        let searchStart = max(0, count - 65557) // Max comment + EOCD size

        for i in stride(from: count - 22, through: searchStart, by: -1) {
            if readUInt32(data, at: i) == eocdSig {
                eocdOffset = i
                break
            }
        }

        guard eocdOffset >= 0 else { return false }

        let centralDirOffset = Int(readUInt32(data, at: eocdOffset + 16))
        let centralDirEntries = Int(readUInt16(data, at: eocdOffset + 10))

        var offset = centralDirOffset
        let centralDirSig: UInt32 = 0x02014b50

        for _ in 0..<centralDirEntries {
            guard offset + 46 <= count else { break }
            guard readUInt32(data, at: offset) == centralDirSig else { break }

            let compressionMethod = readUInt16(data, at: offset + 10)
            let compressedSize = readUInt32(data, at: offset + 20)
            let uncompressedSize = readUInt32(data, at: offset + 24)
            let fileNameLength = Int(readUInt16(data, at: offset + 28))
            let extraFieldLength = Int(readUInt16(data, at: offset + 30))
            let fileCommentLength = Int(readUInt16(data, at: offset + 32))
            let localHeaderOffset = readUInt32(data, at: offset + 42)

            guard offset + 46 + fileNameLength <= count else { break }
            let nameData = data[offset + 46 ..< offset + 46 + fileNameLength]
            guard let fileName = String(data: nameData, encoding: .utf8) else {
                offset += 46 + fileNameLength + extraFieldLength + fileCommentLength
                continue
            }

            // Skip directories
            if !fileName.hasSuffix("/") {
                let lowered = fileName.lowercased()
                entries[lowered] = PK3Entry(
                    fileName: fileName,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    compressionMethod: compressionMethod
                )
            }

            offset += 46 + fileNameLength + extraFieldLength + fileCommentLength
        }

        return true
    }

    func extractFile(named name: String) -> Data? {
        let lowered = name.lowercased()
        guard let entry = entries[lowered] else { return nil }

        guard let fileData = try? Data(contentsOf: url) else { return nil }

        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset + 30 <= fileData.count else { return nil }

        // Verify local file header signature
        let localSig: UInt32 = 0x04034b50
        guard readUInt32(fileData, at: localOffset) == localSig else { return nil }

        let localFileNameLength = Int(readUInt16(fileData, at: localOffset + 26))
        let localExtraLength = Int(readUInt16(fileData, at: localOffset + 28))
        let dataStart = localOffset + 30 + localFileNameLength + localExtraLength
        let dataEnd = dataStart + Int(entry.compressedSize)

        guard dataEnd <= fileData.count else { return nil }

        let compressedData = fileData[dataStart..<dataEnd]

        if entry.compressionMethod == 0 {
            // Stored (no compression)
            return Data(compressedData)
        } else if entry.compressionMethod == 8 {
            // Deflate
            return decompressDeflate(Data(compressedData), uncompressedSize: Int(entry.uncompressedSize))
        }

        return nil
    }

    private func decompressDeflate(_ data: Data, uncompressedSize: Int) -> Data? {
        // Use Apple's Compression framework (raw deflate)
        var decompressed = Data(count: uncompressedSize)
        let result = decompressed.withUnsafeMutableBytes { destBuffer in
            data.withUnsafeBytes { srcBuffer in
                compression_decode_buffer(
                    destBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    uncompressedSize,
                    srcBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard result > 0 else { return nil }
        decompressed.count = result
        return decompressed
    }

    func listFiles(inDirectory dir: String, withExtension ext: String? = nil) -> [String] {
        let prefix = dir.lowercased()
        return entries.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            if let ext = ext {
                guard key.hasSuffix(".\(ext.lowercased())") else { return nil }
            }
            return entries[key]?.fileName
        }
    }

    // MARK: - Binary Helpers

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
