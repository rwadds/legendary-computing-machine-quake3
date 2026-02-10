// FileSystem.swift — PK3-based virtual file system

import Foundation

class Q3FileSystem {
    static let shared = Q3FileSystem()

    private var searchPaths: [PK3File] = []
    private var basePath: String = ""
    private var fileCache: [String: (pk3: PK3File, entry: PK3File.PK3Entry)] = [:]

    private init() {}

    func initialize() {
        // Find baseq3 directory - check bundle first, then app directory
        let bundlePath = Bundle.main.bundlePath
        let appDir = (bundlePath as NSString).deletingLastPathComponent

        // Try paths in order of preference
        let possiblePaths = [
            bundlePath + "/Contents/Resources/baseq3",
            appDir + "/baseq3",
            (bundlePath as NSString).deletingLastPathComponent + "/baseq3",
            // For development: look relative to project
            findBaseQ3Path()
        ].compactMap { $0 }

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                basePath = path
                break
            }
        }

        if basePath.isEmpty {
            Q3Console.shared.print("WARNING: Could not find baseq3 directory")
            return
        }

        Q3Console.shared.print("File system base path: \(basePath)")
        loadPK3Files()
    }

    private func findBaseQ3Path() -> String? {
        // For development, look for baseq3 relative to the built app
        let bundlePath = Bundle.main.bundlePath
        var dir = (bundlePath as NSString).deletingLastPathComponent

        // Walk up directory tree looking for baseq3
        for _ in 0..<10 {
            let candidate = dir + "/baseq3"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            // Also check inside mac.quake3 project directory
            let projectCandidate = dir + "/mac.quake3/baseq3"
            if FileManager.default.fileExists(atPath: projectCandidate) {
                return projectCandidate
            }
            dir = (dir as NSString).deletingLastPathComponent
        }

        // Hardcoded fallback for known project location
        let knownPath = NSHomeDirectory() + "/Documents/quake/mac.quake3/baseq3"
        if FileManager.default.fileExists(atPath: knownPath) {
            return knownPath
        }

        return nil
    }

    private func loadPK3Files() {
        guard !basePath.isEmpty else { return }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else { return }

        // Sort pk3 files so higher numbers override lower
        let pk3Names = contents.filter { $0.lowercased().hasSuffix(".pk3") }.sorted()

        for name in pk3Names {
            let url = URL(fileURLWithPath: basePath + "/" + name)
            if let pk3 = PK3File(url: url) {
                searchPaths.append(pk3)
                Q3Console.shared.print("Loaded \(name) (\(pk3.entries.count) files)")

                // Cache all entries for fast lookup
                for (key, entry) in pk3.entries {
                    fileCache[key] = (pk3: pk3, entry: entry)
                }
            }
        }

        Q3Console.shared.print("File system initialized: \(searchPaths.count) pk3 files, \(fileCache.count) total files")
    }

    // MARK: - File Access

    func loadFile(_ path: String) -> Data? {
        let lowered = path.lowercased().replacingOccurrences(of: "\\", with: "/")

        // Search pk3 files (later pk3s override earlier ones, search reverse)
        for pk3 in searchPaths.reversed() {
            if let data = pk3.extractFile(named: lowered) {
                return data
            }
        }

        // Try loading from filesystem directly
        if !basePath.isEmpty {
            let fullPath = basePath + "/" + path
            if let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) {
                return data
            }
        }

        return nil
    }

    func fileExists(_ path: String) -> Bool {
        let lowered = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        if fileCache[lowered] != nil { return true }

        if !basePath.isEmpty {
            let fullPath = basePath + "/" + path
            return FileManager.default.fileExists(atPath: fullPath)
        }
        return false
    }

    func listFiles(inDirectory dir: String, withExtension ext: String? = nil) -> [String] {
        var results: Set<String> = []
        let prefix = dir.lowercased()

        for pk3 in searchPaths {
            let files = pk3.listFiles(inDirectory: prefix, withExtension: ext)
            for f in files {
                results.insert(f)
            }
        }

        return Array(results).sorted()
    }

    // MARK: - File Handle API (for QVM syscalls)

    private var openFiles: [Int32: FileHandle_Q3] = [:]
    private var nextHandle: Int32 = 1

    struct FileHandle_Q3 {
        var data: Data
        var position: Int
        var mode: FileMode
    }

    enum FileMode {
        case read
        case write
        case append
    }

    func openFileRead(_ path: String) -> (handle: Int32, length: Int32) {
        guard let data = loadFile(path) else {
            return (0, -1)
        }
        let handle = nextHandle
        nextHandle += 1
        openFiles[handle] = FileHandle_Q3(data: data, position: 0, mode: .read)
        return (handle, Int32(data.count))
    }

    func openFileWrite(_ path: String) -> Int32 {
        let handle = nextHandle
        nextHandle += 1
        openFiles[handle] = FileHandle_Q3(data: Data(), position: 0, mode: .write)
        return handle
    }

    func readFile(handle: Int32, buffer: UnsafeMutableRawPointer, length: Int) -> Int {
        guard var file = openFiles[handle] else { return 0 }
        let available = file.data.count - file.position
        let toRead = min(length, available)
        if toRead <= 0 { return 0 }

        file.data.withUnsafeBytes { ptr in
            let src = ptr.baseAddress!.advanced(by: file.position)
            buffer.copyMemory(from: src, byteCount: toRead)
        }
        file.position += toRead
        openFiles[handle] = file
        return toRead
    }

    func writeFile(handle: Int32, data: UnsafeRawPointer, length: Int) -> Int {
        guard var file = openFiles[handle] else { return 0 }
        let bytes = Data(bytes: data, count: length)
        file.data.append(bytes)
        file.position += length
        openFiles[handle] = file
        return length
    }

    func closeFile(handle: Int32) {
        if let file = openFiles[handle], file.mode == .write {
            // Could write to disk here if needed
        }
        openFiles.removeValue(forKey: handle)
    }

    func seekFile(handle: Int32, offset: Int, origin: Int) -> Int {
        guard var file = openFiles[handle] else { return -1 }
        switch origin {
        case 0: // SEEK_SET
            file.position = offset
        case 1: // SEEK_CUR
            file.position += offset
        case 2: // SEEK_END
            file.position = file.data.count + offset
        default:
            return -1
        }
        file.position = max(0, min(file.position, file.data.count))
        openFiles[handle] = file
        return 0
    }

    var baseQ3Path: String { basePath }
}
