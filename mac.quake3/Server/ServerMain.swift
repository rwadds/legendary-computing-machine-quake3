// ServerMain.swift — Server frame loop, initialization, entity management

import Foundation
import simd

class ServerMain {
    static let shared = ServerMain()

    // Server state
    var state: ServerState = .dead
    var serverId: Int32 = 0
    var restarting = false

    // Timing
    var time: Int32 = 0               // Server time (ms)
    var timeResidual: Int32 = 0
    let frameMsec: Int32 = 50         // 20 fps server frame rate (1000/20)

    // Config strings
    var configStrings: [String] = Array(repeating: "", count: MAX_CONFIGSTRINGS)

    // Entities
    var gentities: [SharedEntity] = []
    var gentitySize: Int = 0
    var numEntities: Int = 0
    var gentitiesBaseAddr: Int32 = 0  // VM memory address of gentity array
    var gameClientsBaseAddr: Int32 = 0  // VM memory address of playerState array

    // Clients
    var clients: [SVClient] = []
    var maxClients: Int = 1

    // SV entities (server-side bookkeeping)
    var svEntities: [SVEntity] = []

    // Game clients (playerState)
    var gameClients: [PlayerState] = []
    var gameClientSize: Int = 0

    // World spatial partitioning
    var worldSectors: [WorldSector] = []
    let areaNodes = 64

    // Entity parse point (for G_GET_ENTITY_TOKEN)
    var entityParsePoint: String.Index?
    var entityString: String = ""

    // Snap flag
    var snapFlagServerBit: Int32 = 0

    // Snapshot counter
    var snapshotCounter: Int32 = 0

    // Debug counters
    var entitiesInBoxCallCount: Int = 0
    var entityContactCallCount: Int = 0

    // Game VM
    var gameVM: QVM?

    private init() {}

    // MARK: - Initialization

    func initialize() {
        // Register server cvars (Q3A SV_Init equivalent)
        Q3CVar.shared.get("sv_maxclients", defaultValue: "8", flags: [.serverInfo, .latch])
        Q3CVar.shared.get("sv_hostname", defaultValue: "noname", flags: [.serverInfo])
        Q3CVar.shared.get("sv_pure", defaultValue: "0", flags: [.serverInfo])
        Q3CVar.shared.get("g_gametype", defaultValue: "0", flags: [.serverInfo, .latch])
        Q3CVar.shared.get("sv_cheats", defaultValue: "1", flags: [.rom])
        Q3CVar.shared.get("sv_floodProtect", defaultValue: "0")
        Q3CVar.shared.get("sv_allowDownload", defaultValue: "0")
        Q3CVar.shared.get("bot_enable", defaultValue: "1")
        Q3CVar.shared.get("sv_fps", defaultValue: "20")
        Q3CVar.shared.get("g_needpass", defaultValue: "0", flags: [.serverInfo])

        maxClients = Int(Q3CVar.shared.variableIntegerValue("sv_maxclients"))
        if maxClients < 1 { maxClients = 1 }
        if maxClients > MAX_CLIENTS { maxClients = MAX_CLIENTS }

        clients = (0..<maxClients).map { _ in SVClient() }
        svEntities = (0..<MAX_GENTITIES).map { _ in SVEntity() }

        Q3Console.shared.print("Server initialized with \(maxClients) client slots")
    }

    // MARK: - Spawn Server

    func spawnServer(_ mapName: String) {
        Q3Console.shared.print("------- Server Initialization -------")
        Q3Console.shared.print("Map: \(mapName)")

        // Shutdown existing game
        shutdownGameProgs()

        state = .loading
        serverId += 1
        snapFlagServerBit ^= 0x04  // SNAPFLAG_SERVERCOUNT

        // Clear server state
        clearServer()

        // Load collision map
        let bspPath = "maps/\(mapName).bsp"
        guard let bspData = Q3FileSystem.shared.loadFile(bspPath) else {
            Q3Console.shared.error("Couldn't load \(bspPath)")
            state = .dead
            return
        }

        let bspFile = BSPFile()
        guard bspFile.load(from: bspData) else {
            Q3Console.shared.error("Failed to parse BSP for collision")
            state = .dead
            return
        }

        // Load collision model
        CollisionModel.shared.load(from: bspFile)

        // Initialize world sectors for spatial queries
        clearWorld()

        // Set config strings
        configStrings[CS_SERVERINFO] = infoString(forServerInfo: mapName)
        configStrings[CS_SYSTEMINFO] = ""
        configStrings[Int(CS_MODELS) + 1] = "maps/\(mapName).bsp"

        // Store entity string for G_GET_ENTITY_TOKEN
        entityString = bspFile.entityString
        entityParsePoint = entityString.startIndex

        // Initialize game VM
        guard initGameProgs() else {
            state = .dead
            return
        }

        // Run 3 server frames to let game settle
        for _ in 0..<3 {
            time += frameMsec
            if let gvm = gameVM {
                _ = QVMInterpreter.call(gvm, command: GameExport.gameRunFrame.rawValue, args: [time])
            }
        }

        // Create baselines
        createBaselines()

        state = .game
        Q3Console.shared.print("------- Server Initialization Complete -------")
    }

    private func clearServer() {
        configStrings = Array(repeating: "", count: MAX_CONFIGSTRINGS)
        gentities = []
        numEntities = 0
        snapshotCounter = 0
        time = 0
        timeResidual = 0

        for i in 0..<svEntities.count {
            svEntities[i] = SVEntity()
        }
    }

    private func infoString(forServerInfo mapName: String) -> String {
        var info = ""
        info += "\\mapname\\\(mapName)"
        info += "\\sv_maxclients\\\(maxClients)"
        info += "\\protocol\\\(PROTOCOL_VERSION)"
        info += "\\gamename\\baseq3"
        return info
    }

    // MARK: - Game VM

    @discardableResult
    func initGameProgs() -> Bool {
        Q3Console.shared.print("Loading game VM...")

        let vm = QVM(name: "game")
        guard let data = Q3FileSystem.shared.loadFile("vm/qagame.qvm") else {
            Q3Console.shared.error("Couldn't load vm/qagame.qvm")
            return false
        }

        guard vm.load(from: data) else {
            Q3Console.shared.error("Failed to load game QVM")
            return false
        }

        // Set up syscall handler
        vm.systemCall = { [weak self] args, numArgs, vm in
            return self?.gameSystemCall(args: args, numArgs: numArgs, vm: vm) ?? 0
        }

        self.gameVM = vm

        // Reset entity parse pointer (Q3A resets this before each GAME_INIT)
        entityParsePoint = entityString.startIndex

        // Call GAME_INIT
        let levelTime = time
        let randomSeed = Int32.random(in: 0..<Int32.max)
        let restart: Int32 = restarting ? 1 : 0

        _ = QVMInterpreter.call(vm, command: GameExport.gameInit.rawValue,
                                args: [levelTime, randomSeed, restart])

        if vm.aborted {
            Q3Console.shared.error("Game VM aborted during GAME_INIT")
            gameVM = nil
            return false
        }

        Q3Console.shared.print("Game VM initialized")
        return true
    }

    func shutdownGameProgs() {
        if let gvm = gameVM {
            _ = QVMInterpreter.call(gvm, command: GameExport.gameShutdown.rawValue, args: [0])
            gameVM = nil
        }
    }

    // MARK: - Server Frame

    func frame(msec: Int32) {
        guard state != .dead else { return }

        timeResidual += msec

        // Run game frames
        var gameFrames = 0
        while timeResidual >= frameMsec {
            timeResidual -= frameMsec
            time += frameMsec
            gameFrames += 1

            // Run client commands
            for i in 0..<maxClients {
                guard clients[i].state == .active else { continue }
                // Client think
                if let gvm = gameVM {
                    _ = QVMInterpreter.call(gvm, command: GameExport.gameClientThink.rawValue, args: [Int32(i)])
                }
            }

            // Run game frame
            if let gvm = gameVM {
                _ = QVMInterpreter.call(gvm, command: GameExport.gameRunFrame.rawValue, args: [time])
                // Tick bot AI
                _ = QVMInterpreter.call(gvm, command: GameExport.botAIStartFrame.rawValue, args: [time])
            }
        }

        // Send client messages
        sendClientMessages()
    }

    // MARK: - Client Connection

    func clientConnect(clientNum: Int, firstTime: Bool) -> String? {
        guard let gvm = gameVM else { return "Server not running" }

        let result = QVMInterpreter.call(gvm, command: GameExport.gameClientConnect.rawValue,
                                         args: [Int32(clientNum), firstTime ? 1 : 0, 0])

        if result != 0 {
            // Error string returned
            return gameVM?.readString(at: result) ?? "Connection refused"
        }

        clients[clientNum].state = .connected
        return nil
    }

    func clientBegin(clientNum: Int) {
        guard let gvm = gameVM else { return }
        clients[clientNum].state = .active
        _ = QVMInterpreter.call(gvm, command: GameExport.gameClientBegin.rawValue, args: [Int32(clientNum)])
    }

    func clientDisconnect(clientNum: Int) {
        guard let gvm = gameVM else { return }
        _ = QVMInterpreter.call(gvm, command: GameExport.gameClientDisconnect.rawValue, args: [Int32(clientNum)])
        clients[clientNum].state = .free
    }

    func clientCommand(clientNum: Int) {
        guard let gvm = gameVM else { return }
        _ = QVMInterpreter.call(gvm, command: GameExport.gameClientCommand.rawValue, args: [Int32(clientNum)])
    }

    // MARK: - Client Messages

    func sendClientMessages() {
        // For each active client, build and send snapshot
        for i in 0..<maxClients {
            guard clients[i].state == .active else { continue }
            ServerSnapshot.shared.buildClientSnapshot(clientNum: i)
        }
    }

    // MARK: - Entity Access

    func gentityNum(_ num: Int) -> SharedEntity? {
        guard num >= 0 && num < gentities.count else { return nil }
        return gentities[num]
    }

    func setGentity(_ num: Int, entity: SharedEntity) {
        guard num >= 0 && num < gentities.count else { return }
        gentities[num] = entity
    }

    func svEntityForNum(_ num: Int) -> SVEntity {
        guard num >= 0 && num < svEntities.count else { return SVEntity() }
        return svEntities[num]
    }

    // MARK: - Config Strings

    func setConfigString(_ index: Int, value: String) {
        guard index >= 0 && index < MAX_CONFIGSTRINGS else { return }
        configStrings[index] = value
    }

    func getConfigString(_ index: Int) -> String {
        guard index >= 0 && index < MAX_CONFIGSTRINGS else { return "" }
        return configStrings[index]
    }

    // MARK: - Entity Token Parsing

    func getEntityToken(maxLen: Int) -> String? {
        guard let parsePoint = entityParsePoint, parsePoint < entityString.endIndex else {
            return nil
        }

        // Skip whitespace
        var idx = parsePoint
        while idx < entityString.endIndex && entityString[idx].isWhitespace {
            idx = entityString.index(after: idx)
        }

        guard idx < entityString.endIndex else {
            entityParsePoint = entityString.endIndex
            return nil
        }

        // Read token
        var token = ""
        let ch = entityString[idx]

        if ch == "{" || ch == "}" {
            token = String(ch)
            idx = entityString.index(after: idx)
        } else if ch == "\"" {
            // Quoted string
            idx = entityString.index(after: idx)
            while idx < entityString.endIndex && entityString[idx] != "\"" {
                token.append(entityString[idx])
                idx = entityString.index(after: idx)
            }
            if idx < entityString.endIndex {
                idx = entityString.index(after: idx) // skip closing quote
            }
        } else {
            // Unquoted token
            while idx < entityString.endIndex && !entityString[idx].isWhitespace {
                token.append(entityString[idx])
                idx = entityString.index(after: idx)
            }
        }

        entityParsePoint = idx
        return String(token.prefix(maxLen))
    }

    // MARK: - Baselines

    func createBaselines() {
        guard let vm = gameVM else { return }
        for i in 0..<numEntities {
            guard i < gentities.count else { break }
            let ent = gentities[i]
            if ent.r.linked {
                // Read entity state from VM memory for baseline
                let entAddr = gentitiesBaseAddr + Int32(i * gentitySize)
                svEntities[i].baseline = readEntityStateFromVM(vm: vm, addr: entAddr)
            }
        }
    }

    // MARK: - World Sectors

    func clearWorld() {
        worldSectors = (0..<areaNodes).map { _ in WorldSector() }
        createWorldSectors(nodeIndex: 0, depth: 0,
                           mins: Vec3(-4096, -4096, -4096),
                           maxs: Vec3(4096, 4096, 4096))
    }

    private func createWorldSectors(nodeIndex: Int, depth: Int, mins: Vec3, maxs: Vec3) {
        guard nodeIndex < worldSectors.count else { return }

        let sector = worldSectors[nodeIndex]

        if depth == 4 {
            sector.axis = -1
            return
        }

        let size = maxs - mins
        if size.x > size.y {
            sector.axis = 0
        } else {
            sector.axis = 1
        }

        sector.dist = 0.5 * (maxs[sector.axis] + mins[sector.axis])

        let child0 = nodeIndex * 2 + 1
        let child1 = nodeIndex * 2 + 2
        sector.children = [child0, child1]

        var mins1 = mins
        var maxs0 = maxs
        maxs0[sector.axis] = sector.dist
        mins1[sector.axis] = sector.dist

        if child0 < worldSectors.count {
            createWorldSectors(nodeIndex: child0, depth: depth + 1, mins: mins, maxs: maxs0)
        }
        if child1 < worldSectors.count {
            createWorldSectors(nodeIndex: child1, depth: depth + 1, mins: mins1, maxs: maxs)
        }
    }
}

// MARK: - SVClient

class SVClient {
    var state: SVClientState = .free
    var userinfo: String = ""
    var name: String = ""
    var gentityNum: Int = -1

    var lastUsercmd: UserCmd = UserCmd()
    var lastMessageNum: Int32 = 0
    var lastClientCommand: Int32 = 0

    // Reliable commands
    var reliableCommands: [String] = Array(repeating: "", count: 64)
    var reliableSequence: Int32 = 0
    var reliableAcknowledge: Int32 = 0

    var deltaMessage: Int32 = -1
    var ping: Int32 = 0
    var rate: Int32 = 25000

    var gamestateMessageNum: Int32 = -1
    var snapshotMsec: Int32 = 50
    var nextSnapshotTime: Int32 = 0
}
