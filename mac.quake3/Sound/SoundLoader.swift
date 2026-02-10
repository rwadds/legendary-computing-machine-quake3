// SoundLoader.swift — WAV file parsing from pk3s, sound caching

import Foundation

// MARK: - Sound Sample

struct SoundSample {
    var name: String = ""
    var samples: [Int16] = []       // Mono PCM data
    var numSamples: Int = 0
    var sampleRate: Int = 22050
    var numChannels: Int = 1
}

// MARK: - Sound Loader

class SoundLoader {
    static let shared = SoundLoader()

    private var cache: [String: SoundSample] = [:]

    private init() {}

    func loadSound(_ name: String) -> SoundSample? {
        let key = name.lowercased()
        if let cached = cache[key] { return cached }

        // Try loading from pk3 filesystem
        let paths = soundPaths(for: name)
        for path in paths {
            if let data = Q3FileSystem.shared.loadFile(path) {
                if let sample = parseWAV(data: data, name: key) {
                    cache[key] = sample
                    return sample
                }
            }
        }

        return nil
    }

    /// Generate search paths for a sound name
    private func soundPaths(for name: String) -> [String] {
        var paths: [String] = []

        // If already has extension, try as-is
        if name.contains(".") {
            paths.append(name)
            // Also try with sound/ prefix
            if !name.hasPrefix("sound/") {
                paths.append("sound/\(name)")
            }
        } else {
            // Try common extensions
            paths.append("sound/\(name).wav")
            paths.append("\(name).wav")
        }

        return paths
    }

    // MARK: - WAV Parser

    private func parseWAV(data: Data, name: String) -> SoundSample? {
        guard data.count >= 44 else { return nil }

        return data.withUnsafeBytes { ptr -> SoundSample? in
            let base = ptr.baseAddress!

            // Check RIFF header
            let riff = readFourCC(base, at: 0)
            guard riff == "RIFF" else { return nil }

            let wave = readFourCC(base, at: 8)
            guard wave == "WAVE" else { return nil }

            // Find fmt chunk
            var offset = 12
            var sampleRate: Int = 22050
            var numChannels: Int = 1
            var bitsPerSample: Int = 16
            var audioFormat: Int = 1  // PCM
            var dataOffset = 0
            var dataSize = 0

            while offset + 8 <= data.count {
                let chunkID = readFourCC(base, at: offset)
                let chunkSize = Int(base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))

                if chunkID == "fmt " {
                    guard offset + 16 <= data.count else { break }
                    audioFormat = Int(base.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self))
                    numChannels = Int(base.loadUnaligned(fromByteOffset: offset + 10, as: UInt16.self))
                    sampleRate = Int(base.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
                    // skip byterate(4) and blockalign(2)
                    if offset + 22 <= data.count {
                        bitsPerSample = Int(base.loadUnaligned(fromByteOffset: offset + 22, as: UInt16.self))
                    }
                } else if chunkID == "data" {
                    dataOffset = offset + 8
                    dataSize = chunkSize
                    break
                }

                offset += 8 + chunkSize
                // Align to 2 bytes
                if offset % 2 != 0 { offset += 1 }
            }

            guard audioFormat == 1 else {
                Q3Console.shared.print("WAV: unsupported format \(audioFormat) for \(name)")
                return nil
            }
            guard dataOffset > 0 && dataSize > 0 else {
                Q3Console.shared.print("WAV: no data chunk in \(name)")
                return nil
            }

            // Convert to mono Int16 samples
            var samples: [Int16] = []

            if bitsPerSample == 16 {
                let sampleCount = min(dataSize / (2 * numChannels), (data.count - dataOffset) / (2 * numChannels))
                samples.reserveCapacity(sampleCount)

                for i in 0..<sampleCount {
                    let sampleOffset = dataOffset + i * 2 * numChannels
                    guard sampleOffset + 2 <= data.count else { break }
                    let s = base.loadUnaligned(fromByteOffset: sampleOffset, as: Int16.self)
                    samples.append(s)
                }
            } else if bitsPerSample == 8 {
                let sampleCount = min(dataSize / numChannels, (data.count - dataOffset) / numChannels)
                samples.reserveCapacity(sampleCount)

                for i in 0..<sampleCount {
                    let sampleOffset = dataOffset + i * numChannels
                    guard sampleOffset + 1 <= data.count else { break }
                    let b = base.load(fromByteOffset: sampleOffset, as: UInt8.self)
                    // Convert unsigned 8-bit to signed 16-bit
                    let s = Int16((Int(b) - 128) * 256)
                    samples.append(s)
                }
            } else {
                Q3Console.shared.print("WAV: unsupported bits \(bitsPerSample) for \(name)")
                return nil
            }

            // Resample to 44100 if needed
            let targetRate = 44100
            if sampleRate != targetRate && sampleRate > 0 {
                samples = resample(samples, from: sampleRate, to: targetRate)
                sampleRate = targetRate
            }

            var sample = SoundSample()
            sample.name = name
            sample.samples = samples
            sample.numSamples = samples.count
            sample.sampleRate = sampleRate
            sample.numChannels = 1  // Always mono after conversion
            return sample
        }
    }

    // MARK: - Resampling

    private func resample(_ input: [Int16], from srcRate: Int, to dstRate: Int) -> [Int16] {
        guard srcRate > 0 && !input.isEmpty else { return input }

        let ratio = Double(srcRate) / Double(dstRate)
        let outputCount = Int(Double(input.count) / ratio)
        var output = [Int16](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcPos = Double(i) * ratio
            let srcIdx = Int(srcPos)
            let frac = Float(srcPos - Double(srcIdx))

            if srcIdx + 1 < input.count {
                let s0 = Float(input[srcIdx])
                let s1 = Float(input[srcIdx + 1])
                output[i] = Int16(clamping: Int(s0 + (s1 - s0) * frac))
            } else if srcIdx < input.count {
                output[i] = input[srcIdx]
            }
        }

        return output
    }

    // MARK: - Helpers

    private func readFourCC(_ ptr: UnsafeRawPointer, at offset: Int) -> String {
        var chars: [UInt8] = []
        for i in 0..<4 {
            chars.append(ptr.load(fromByteOffset: offset + i, as: UInt8.self))
        }
        return String(bytes: chars, encoding: .ascii) ?? ""
    }

    func clearCache() {
        cache.removeAll()
    }
}
