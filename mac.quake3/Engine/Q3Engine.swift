// Q3Engine.swift — Top-level Quake III engine

import Foundation
import Metal
import MetalKit

// MARK: - Debug Logging

/// Comprehensive debug logger — writes to stderr for immediate Xcode console output
/// Throttled version only logs once per second (~30 frames at 30fps)
private var _debugLogFrameCount: Int = 0
private var _debugLogLastTime: Double = 0
private var _debugLogShouldPrint: Bool = true

func q3DebugLog(_ msg: String, throttle: Bool = false) {
    if throttle && !_debugLogShouldPrint { return }
    let ts = ProcessInfo.processInfo.systemUptime
    let line = String(format: "[DBG %.3f f%d] %@\n", ts, _debugLogFrameCount, msg)
    fputs(line, stderr)
}

func q3DebugLogUpdateFrame() {
    _debugLogFrameCount += 1
    let now = ProcessInfo.processInfo.systemUptime
    if now - _debugLogLastTime >= 1.0 {
        _debugLogShouldPrint = true
        _debugLogLastTime = now
    } else {
        _debugLogShouldPrint = false
    }
}

// MARK: - Crash Handler

// File descriptor for crash log - opened at init, kept open
private var crashLogFD: Int32 = -1

private func writeCrashRaw(_ str: String) {
    // Use POSIX write() — async-signal-safe
    if crashLogFD >= 0 {
        str.withCString { ptr in
            _ = write(crashLogFD, ptr, strlen(ptr))
        }
    }
    // Also write to stderr (fd 2)
    str.withCString { ptr in
        _ = write(2, ptr, strlen(ptr))
    }
}

private func installCrashHandler() {
    // Pre-open the crash log file
    crashLogFD = open("/tmp/q3crash.log", O_WRONLY | O_CREAT | O_TRUNC, 0o644)

    let handler: @convention(c) (Int32) -> Void = { sig in
        // Only use async-signal-safe operations
        switch sig {
        case SIGTRAP: writeCrashRaw("\n=== CRASH: SIGTRAP ===\n")
        case SIGABRT: writeCrashRaw("\n=== CRASH: SIGABRT ===\n")
        case SIGBUS:  writeCrashRaw("\n=== CRASH: SIGBUS ===\n")
        case SIGSEGV: writeCrashRaw("\n=== CRASH: SIGSEGV ===\n")
        default:      writeCrashRaw("\n=== CRASH: SIGNAL ===\n")
        }
        // Try to get backtrace (backtrace() is technically async-signal-safe on macOS)
        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frames = backtrace(&callstack, 128)
        if crashLogFD >= 0 {
            backtrace_symbols_fd(&callstack, frames, crashLogFD)
        }
        backtrace_symbols_fd(&callstack, frames, 2) // stderr
        writeCrashRaw("=== END CRASH ===\n")
        // Re-raise for default handling
        signal(sig, SIG_DFL)
        raise(sig)
    }
    signal(SIGTRAP, handler)
    signal(SIGABRT, handler)
    signal(SIGBUS, handler)
    signal(SIGSEGV, handler)

    // Also register atexit handler
    atexit {
        writeCrashRaw("=== ATEXIT: frame \(Q3Engine.shared.frameCount) ===\n")
    }
}

class Q3Engine {
    static let shared = Q3Engine()

    // Subsystem references
    let console = Q3Console.shared
    let fileSystem = Q3FileSystem.shared
    let commandBuffer = Q3CommandBuffer.shared
    let cvarSystem = Q3CVar.shared

    // Engine state
    private(set) var initialized = false
    private(set) var frameCount: Int = 0
    private(set) var realTime: Int = 0      // msec since engine start
    private(set) var engineStartTime: Double = 0

    // Renderer reference (set by GameViewController after creating RenderMain)
    weak var renderMain: RenderMain?

    // Core CVars
    private(set) var developer: Q3CVar.CVar!
    private(set) var timescale: Q3CVar.CVar!
    private(set) var dedicated: Q3CVar.CVar!
    private(set) var sv_running: Q3CVar.CVar!
    private(set) var com_maxfps: Q3CVar.CVar!

    private init() {}

    // MARK: - Initialize

    func initialize() {
        guard !initialized else { return }

        installCrashHandler()

        console.print("--- Q3Engine Initializing ---")

        // Register core cvars
        developer = cvarSystem.get("developer", defaultValue: "0")
        timescale = cvarSystem.get("timescale", defaultValue: "1", flags: [.cheat])
        dedicated = cvarSystem.get("dedicated", defaultValue: "0", flags: [.latch])
        sv_running = cvarSystem.get("sv_running", defaultValue: "0", flags: .rom)
        com_maxfps = cvarSystem.get("com_maxfps", defaultValue: "120", flags: .archive)

        // Register engine cvars
        cvarSystem.get("version", defaultValue: "Q3A Swift 1.0", flags: .rom)
        cvarSystem.get("com_protocol", defaultValue: String(PROTOCOL_VERSION), flags: .rom)
        cvarSystem.get("fs_basepath", defaultValue: "", flags: .rom)
        cvarSystem.get("mapname", defaultValue: "nomap", flags: [.serverInfo, .rom])

        // Initialize file system
        fileSystem.initialize()

        // Execute default config
        commandBuffer.addText("exec default.cfg\n")
        commandBuffer.addText("exec q3config.cfg\n")
        commandBuffer.addText("exec autoexec.cfg\n")
        commandBuffer.executeBuffer()

        engineStartTime = ProcessInfo.processInfo.systemUptime

        // Register map commands (engine owns these, not renderer)
        Q3CommandBuffer.shared.addCommand("map") { [weak self] in
            let mapName = Q3CommandBuffer.shared.commandArgv(1)
            if !mapName.isEmpty {
                self?.startMap(mapName)
            } else {
                Q3Console.shared.print("Usage: map <mapname>")
            }
        }

        // spmap: single-player map launch (sets gametype, then loads map)
        Q3CommandBuffer.shared.addCommand("spmap") { [weak self] in
            let mapName = Q3CommandBuffer.shared.commandArgv(1)
            if !mapName.isEmpty {
                Q3CVar.shared.set("g_gametype", value: "2", force: true)  // GT_SINGLE_PLAYER
                Q3CVar.shared.set("sv_pure", value: "0", force: true)
                Q3CVar.shared.set("sv_maxclients", value: "8", force: true)
                self?.startMap(mapName)
            }
        }

        // Verify filesystem
        verifyGameData()

        // Initialize RendererAPI early so UI VM can register shaders
        if ClientMain.shared.rendererAPI == nil {
            ClientMain.shared.rendererAPI = RendererAPI()
        }

        // Unlock all single-player arenas — set perfect scores across all skill levels
        let allScores = (0...30).map { "\\l\($0)\\1" }.joined()
        for skill in 1...5 {
            Q3CVar.shared.set("g_spScores\(skill)", value: allScores)
        }

        // Initialize UI VM and show main menu
        ClientUI.shared.initialize()
        if ClientUI.shared.initialized {
            ClientUI.shared.keyCatcher = 2  // KEYCATCH_UI
            ClientUI.shared.setActiveMenu(.main)
        }

        initialized = true
        console.print("--- Q3Engine Initialized ---")
    }

    // MARK: - Frame

    func frame() {
        guard initialized else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let oldRealTime = realTime
        realTime = Int((now - engineStartTime) * 1000)
        var msec = Int32(realTime - oldRealTime)
        // Cap frame time to 200ms to prevent huge time jumps (especially first frame after init)
        if msec > 200 { msec = 200 }
        if msec < 1 { msec = 1 }

        // Execute pending commands (may trigger startMap via "map" cmd)
        commandBuffer.executeBuffer()

        // Transfer client usercmd to server (loopback)
        let cl = ClientMain.shared
        if cl.state == .active, cl.cmdNumber > 0 {
            let cmdIdx = Int(cl.cmdNumber) & 63
            ServerMain.shared.clientThink(clientNum: Int(cl.clientNum), cmd: cl.cmds[cmdIdx])
        }

        // Tick server and client
        ServerMain.shared.frame(msec: msec)
        ClientMain.shared.frame(msec: msec)

        frameCount += 1
    }

    // MARK: - Start Map

    func startMap(_ mapName: String) {
        console.print("--- Starting map: \(mapName) ---")

        // Dismiss UI menu
        ClientUI.shared.keyCatcher = 0

        // Disconnect existing game
        ClientMain.shared.disconnect()

        // Initialize and spawn server
        ServerMain.shared.initialize()
        console.print("Server maxClients=\(ServerMain.shared.maxClients), sv_maxclients=\(Q3CVar.shared.variableIntegerValue("sv_maxclients"))")
        ServerSnapshot.shared.initialize(maxClients: ServerMain.shared.maxClients)
        ServerMain.shared.spawnServer(mapName)

        guard ServerMain.shared.state == .game else {
            console.error("Server failed to start map \(mapName)")
            return
        }

        // Load map geometry in renderer
        renderMain?.loadMap(mapName)

        // Initialize and connect client
        ClientMain.shared.initialize()
        ClientMain.shared.connectLocal()

        console.print("Client state after connect: \(ClientMain.shared.state)")

        // Enable game camera — collision detection now works
        renderMain?.gameActive = true
    }

    // MARK: - Shutdown

    func shutdown() {
        guard initialized else { return }
        console.print("--- Q3Engine Shutting Down (frame \(frameCount)) ---")
        // Log backtrace to find who triggered shutdown
        let symbols = Thread.callStackSymbols
        for (i, sym) in symbols.prefix(15).enumerated() {
            console.print("  shutdown[\(i)]: \(sym)")
        }
        initialized = false
    }

    // MARK: - Verification

    private func verifyGameData() {
        // Check that we can load a known file from pak0.pk3
        let testFiles = [
            "maps/q3dm1.bsp",
            "gfx/2d/bigchars.tga",
            "scripts/common.shader"
        ]

        for file in testFiles {
            if let data = fileSystem.loadFile(file) {
                console.print("  Verified: \(file) (\(data.count) bytes)")
            } else {
                console.warning("  Missing: \(file)")
            }
        }
    }
}
