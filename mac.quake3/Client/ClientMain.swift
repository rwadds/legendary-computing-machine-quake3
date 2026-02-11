// ClientMain.swift — Client frame loop, connection state, CGame VM management

import Foundation
import simd

class ClientMain {
    static let shared = ClientMain()

    // Connection state
    var state: ConnectionState = .disconnected

    // Client-side state (wiped on new gamestate)
    var serverTime: Int32 = 0
    var oldServerTime: Int32 = 0
    var serverTimeDelta: Int32 = 0

    // Gamestate
    var gameState: GameState = GameState()
    var mapName: String = ""
    var clientNum: Int32 = 0

    // Snapshots
    var snap: ClientSnapshot = ClientSnapshot()
    var snapshots: [ClientSnapshot] = Array(repeating: ClientSnapshot(), count: 32)
    var newSnapshots = false
    var parseEntitiesNum: Int = 0
    var parseEntities: [EntityState] = Array(repeating: EntityState(), count: 2048)

    // Entity baselines
    var entityBaselines: [EntityState] = Array(repeating: EntityState(), count: MAX_GENTITIES)

    // Commands
    var cmds: [UserCmd] = Array(repeating: UserCmd(), count: 64)
    var cmdNumber: Int32 = 0

    // View
    var viewangles: Vec3 = .zero
    var cgameUserCmdValue: Int32 = 0
    var cgameSensitivity: Float = 1.0

    // Frame timing
    var frameTime: Int32 = 0
    var realTime: Int32 = 0

    // Debug counters
    var snapDebugCounter: Int = 0

    // Network channel
    var netchan: NetChannel = NetChannel()

    // CGame VM
    var cgameVM: QVM?
    var cgameStarted = false
    var cgameError = false

    // Renderer API
    var rendererAPI: RendererAPI?

    // Server ID
    var serverId: Int32 = 0

    private init() {}

    // MARK: - Initialization

    func initialize() {
        state = .disconnected
        ClientInput.shared.registerCommands()
        Q3Console.shared.print("Client initialized")
    }

    // MARK: - Key Event Processing

    /// Route a key event through keyCatcher and binding system (like CL_KeyEvent in Q3)
    func keyEvent(_ q3Key: Int32, down: Bool) {
        // Update key states for trap_Key_IsDown
        ClientUI.shared.keyStates[Int(q3Key)] = down

        let catcher = ClientUI.shared.keyCatcher

        // KEYCATCH_CGAME (8) — forward to cgame VM
        if catcher & 8 != 0 {
            if let cgvm = cgameVM {
                _ = QVMInterpreter.call(cgvm, command: CGExport.cgKeyEvent.rawValue,
                                        args: [q3Key, down ? 1 : 0])
            }
            return
        }

        // Normal gameplay: process key bindings
        guard let binding = ClientUI.shared.keyBindings[Int(q3Key)], !binding.isEmpty else { return }

        if binding.hasPrefix("+") {
            if down {
                Q3CommandBuffer.shared.addText(binding + "\n")
            } else {
                Q3CommandBuffer.shared.addText("-" + String(binding.dropFirst()) + "\n")
            }
        } else if down {
            Q3CommandBuffer.shared.addText(binding + "\n")
        }
    }

    // MARK: - Connect to Local Server

    func connectLocal() {
        Q3Console.shared.print("Connecting to local server...")

        // Reset state
        clearState()
        netchan.reset()
        NetManager.shared.connect()

        state = .connecting

        // For loopback, immediately transition to connected
        state = .connected

        // Connect server-side
        guard ServerMain.shared.connectLocalClient() else {
            Q3Console.shared.error("Failed to connect local client")
            state = .disconnected
            return
        }

        // Build and receive gamestate
        receiveGamestate()
    }

    func disconnect() {
        if let cgvm = cgameVM {
            _ = QVMInterpreter.call(cgvm, command: CGExport.cgShutdown.rawValue)
            cgameVM = nil
            cgameStarted = false
        }

        state = .disconnected
        NetManager.shared.disconnect()
    }

    // MARK: - Clear State

    func clearState() {
        serverTime = 0
        oldServerTime = 0
        serverTimeDelta = 0
        gameState = GameState()
        snap = ClientSnapshot()
        snapshots = Array(repeating: ClientSnapshot(), count: 32)
        newSnapshots = false
        parseEntitiesNum = 0
        entityBaselines = Array(repeating: EntityState(), count: MAX_GENTITIES)
        cmds = Array(repeating: UserCmd(), count: 64)
        cmdNumber = 0
        viewangles = .zero
        cgameUserCmdValue = 0
        cgameError = false
    }

    // MARK: - Receive Gamestate (Loopback)

    func receiveGamestate() {
        Q3Console.shared.print("Receiving gamestate from server...")

        let sv = ServerMain.shared

        // Copy server config strings directly (loopback optimization)
        var dataCount: Int32 = 1  // Leave index 0 for empty
        for i in 0..<MAX_CONFIGSTRINGS {
            let cs = sv.configStrings[i]
            guard !cs.isEmpty else { continue }

            let bytes = Array(cs.utf8) + [0]
            guard Int(dataCount) + bytes.count < MAX_GAMESTATE_CHARS else {
                Q3Console.shared.warning("Gamestate overflow at config string \(i)")
                break
            }

            gameState.stringOffsets[i] = dataCount
            for b in bytes {
                gameState.stringData[Int(dataCount)] = b
                dataCount += 1
            }
        }
        gameState.dataCount = dataCount

        // Set client number
        clientNum = 0  // Local client is always 0

        // Set server ID
        serverId = sv.serverId

        // Get map name
        let serverInfo = getConfigString(CS_SERVERINFO)
        if let range = serverInfo.range(of: "\\mapname\\") {
            let after = serverInfo[range.upperBound...]
            if let endRange = after.range(of: "\\") {
                mapName = String(after[..<endRange.lowerBound])
            } else {
                mapName = String(after)
            }
        }

        Q3Console.shared.print("Gamestate received: map=\(mapName), clientNum=\(clientNum)")

        // Transition to loading
        state = .loading
        initCGame()
    }

    // MARK: - CGame VM

    func initCGame() {
        Q3Console.shared.print("Loading cgame VM...")

        let vm = QVM(name: "cgame")
        guard let data = Q3FileSystem.shared.loadFile("vm/cgame.qvm") else {
            Q3Console.shared.error("Couldn't load vm/cgame.qvm")
            return
        }

        guard vm.load(from: data) else {
            Q3Console.shared.error("Failed to load cgame QVM")
            return
        }

        // Set up syscall handler
        vm.systemCall = { [weak self] args, numArgs, vm in
            return self?.cgameSystemCall(args: args, numArgs: numArgs, vm: vm) ?? 0
        }

        cgameVM = vm
        cgameStarted = true

        // Initialize renderer API
        if rendererAPI == nil {
            rendererAPI = RendererAPI()
        }

        // Call CG_INIT
        let serverMessageNum = netchan.serverCommandSequence
        let serverCommandSequence = netchan.serverCommandSequence
        _ = QVMInterpreter.call(vm, command: CGExport.cgInit.rawValue,
                                args: [serverMessageNum, serverCommandSequence, clientNum])

        if vm.aborted {
            Q3Console.shared.error("CGame VM aborted during CG_INIT")
            cgameVM = nil
            cgameStarted = false
            cgameError = true
            state = .disconnected
            return
        }

        state = .primed
        Q3Console.shared.print("CGame initialized")

        // Transition to active
        state = .active
    }

    // MARK: - Client Frame

    func frame(msec: Int32) {
        guard state != .disconnected else { return }

        realTime += msec
        frameTime = msec

        // Update server time
        if state == .active {
            serverTime += msec
            if serverTime < oldServerTime {
                serverTime = oldServerTime
            }
        }

        // Process server messages (loopback)
        processServerMessages()

        // Create user commands
        if state == .active || state == .primed {
            ClientInput.shared.createNewCommands()
        }

        // Run CGame frame
        if state == .active, cgameStarted {
            cgameRendering()
        }

        oldServerTime = serverTime
    }

    // MARK: - Server Message Processing (Loopback)

    func processServerMessages() {
        // For loopback, directly read snapshots from server
        let sv = ServerMain.shared
        guard sv.state == .game else { return }

        // Update snapshots
        let (snapNum, snapTime) = ServerSnapshot.shared.getCurrentSnapshotNumber()
        if snapNum > 0 {
            if let (snapData, entities) = ServerSnapshot.shared.getSnapshot(number: snapNum, clientNum: Int(clientNum)) {
                var newSnap = ClientSnapshot()
                newSnap.valid = true
                newSnap.serverTime = snapData.serverTime
                newSnap.messageNum = snapNum
                newSnap.ps = snapData.ps
                newSnap.numEntities = entities.count
                newSnap.firstEntity = parseEntitiesNum

                // Store entities in parse buffer
                for ent in entities {
                    let idx = parseEntitiesNum % 2048
                    parseEntities[idx] = ent
                    parseEntitiesNum += 1
                }

                // Save snapshot
                let snapIdx = Int(snapNum) & 31
                snapshots[snapIdx] = newSnap
                snap = newSnap
                newSnapshots = true

                // Update server time
                serverTime = snapTime
            }
        }
    }

    // MARK: - CGame Rendering

    func cgameRendering() {
        guard let cgvm = cgameVM, !cgameError else { return }

        // Call CG_DRAW_ACTIVE_FRAME
        _ = QVMInterpreter.call(cgvm, command: CGExport.cgDrawActiveFrame.rawValue,
                                args: [serverTime, 0, 0])

        if cgvm.aborted {
            cgameError = true
        }
    }

    // MARK: - Config String Access

    func getConfigString(_ index: Int) -> String {
        guard index >= 0 && index < MAX_CONFIGSTRINGS else { return "" }
        let offset = Int(gameState.stringOffsets[index])
        guard offset > 0 && offset < MAX_GAMESTATE_CHARS else { return "" }

        var chars: [UInt8] = []
        var idx = offset
        while idx < MAX_GAMESTATE_CHARS {
            let c = gameState.stringData[idx]
            if c == 0 { break }
            chars.append(c)
            idx += 1
        }
        return String(bytes: chars, encoding: .utf8) ?? ""
    }

    // MARK: - Usercmd Access (for CGame syscalls)

    func getCurrentCmdNumber() -> Int32 {
        return cmdNumber
    }

    func getUserCmd(_ cmdNum: Int32) -> UserCmd? {
        guard cmdNum >= 0 else { return nil }
        let idx = Int(cmdNum) & 63
        return cmds[idx]
    }

    func setUserCmdValue(_ userCmdValue: Int32, _ sensitivity: Float) {
        cgameUserCmdValue = userCmdValue
        cgameSensitivity = sensitivity
    }

    // MARK: - Server Command Access

    func getServerCommand(_ serverCommandNumber: Int32) -> Bool {
        // For loopback, check the server's reliable command buffer
        if let cmd = netchan.getServerCommand(sequence: serverCommandNumber) {
            Q3CommandBuffer.shared.tokenize(cmd)
            return true
        }
        return false
    }

    func addReliableCommand(_ cmd: String) {
        netchan.addReliableCommand(cmd)
    }
}

// MARK: - Client Snapshot Structure

struct ClientSnapshot {
    var valid: Bool = false
    var snapFlags: Int32 = 0
    var serverTime: Int32 = 0
    var messageNum: Int32 = 0
    var deltaNum: Int32 = -1
    var ping: Int32 = 999
    var ps: PlayerState = PlayerState()
    var numEntities: Int = 0
    var firstEntity: Int = 0
    var serverCommandNum: Int32 = 0
}
