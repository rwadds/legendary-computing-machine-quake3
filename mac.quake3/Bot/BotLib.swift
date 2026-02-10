// BotLib.swift — Bot library syscall implementations (master dispatch)

import Foundation
import simd

class BotLib {
    static let shared = BotLib()

    var initialized = false
    var frameTime: Float = 0
    var mapLoaded = false

    // Sub-systems
    let aas = BotAAS.shared
    let ai = BotAI.shared

    // Bot client slots
    var botClients: [Int: BotClient] = [:]

    private init() {}

    // MARK: - Lifecycle

    func setup() -> Int32 {
        guard !initialized else { return 0 }
        initialized = true
        aas.initialize()
        Q3Console.shared.print("Bot library initialized")
        return 0
    }

    func shutdown() -> Int32 {
        initialized = false
        botClients.removeAll()
        aas.shutdown()
        ai.shutdown()
        return 0
    }

    func loadMap(_ mapName: String) -> Int32 {
        Q3Console.shared.print("BotLib: loading map \(mapName)")
        mapLoaded = true

        // Try to load AAS file for pathfinding
        let aasName = mapName.replacingOccurrences(of: ".bsp", with: ".aas")
        aas.loadAAS(aasName)

        return 0
    }

    func startFrame(_ time: Float) -> Int32 {
        frameTime = time
        aas.update(time: time)
        return 0
    }

    // MARK: - Bot Client Management

    func allocateClient() -> Int32 {
        // Find free client slot (starting from MAX_CLIENTS/2 to avoid conflicting with human players)
        for i in 1..<MAX_CLIENTS {
            if botClients[i] == nil {
                let client = BotClient(clientNum: i)
                botClients[i] = client
                return Int32(i)
            }
        }
        return -1
    }

    func freeClient(_ clientNum: Int) {
        botClients.removeValue(forKey: clientNum)
        ai.removeBotState(clientNum)
    }

    // MARK: - Syscall Dispatch

    func handleSyscall(cmd: Int32, args: [Int32], vm: QVM) -> Int32 {
        // Dispatch to appropriate sub-system based on syscall range
        switch cmd {
        // Core botlib (200-211)
        case 200: // BOTLIB_SETUP
            return setup()
        case 201: // BOTLIB_SHUTDOWN
            return shutdown()
        case 202: // BOTLIB_LIBVAR_SET
            return 0
        case 203: // BOTLIB_LIBVAR_GET
            return 0
        case 204: // BOTLIB_PC_ADD_GLOBAL_DEFINE
            return 0
        case 205: // BOTLIB_START_FRAME
            let time = Float(bitPattern: UInt32(bitPattern: args[1]))
            return startFrame(time)
        case 206: // BOTLIB_LOAD_MAP
            let name = vm.readString(at: args[1])
            return loadMap(name)
        case 207: // BOTLIB_UPDATEENTITY
            return updateEntity(entNum: Int(args[1]), vm: vm, stateAddr: args[2])
        case 208: // BOTLIB_TEST
            return 0
        case 209: // BOTLIB_GET_SNAPSHOT_ENTITY
            return 0
        case 210: // BOTLIB_GET_CONSOLE_MESSAGE
            vm.writeString(at: args[2], "", maxLen: Int(args[3]))
            return 0
        case 211: // BOTLIB_USER_COMMAND
            return 0

        // AAS syscalls (300-318)
        case 300...318:
            return aas.handleSyscall(cmd: cmd, args: args, vm: vm)

        // EA syscalls (400-427)
        case 400...427:
            return handleEASyscall(cmd: cmd, args: args, vm: vm)

        // AI syscalls (500+)
        case 500...589:
            return ai.handleSyscall(cmd: cmd, args: args, vm: vm)

        default:
            return 0
        }
    }

    // MARK: - Entity Updates

    private func updateEntity(entNum: Int, vm: QVM, stateAddr: Int32) -> Int32 {
        // Read bot_entitystate_t and update entity tracking
        aas.updateEntityInfo(entNum: entNum, vm: vm, addr: stateAddr)
        return 0
    }

    // MARK: - Elementary Action (EA) Syscalls

    private func handleEASyscall(cmd: Int32, args: [Int32], vm: QVM) -> Int32 {
        let clientNum = Int(args[1])
        guard let client = botClients[clientNum] else { return 0 }

        switch cmd {
        case 400: // EA_SAY
            let text = vm.readString(at: args[2])
            BotChat.shared.say(clientNum: clientNum, text: text, teamOnly: false)
            return 0
        case 401: // EA_SAY_TEAM
            let text = vm.readString(at: args[2])
            BotChat.shared.say(clientNum: clientNum, text: text, teamOnly: true)
            return 0
        case 402: // EA_COMMAND
            let cmd = vm.readString(at: args[2])
            client.pendingCommands.append(cmd)
            return 0
        case 403: // EA_ACTION
            client.actionFlags |= args[2]
            return 0
        case 404: // EA_GESTURE
            client.actionFlags |= 1 << 8
            return 0
        case 405: // EA_TALK
            client.actionFlags |= 1 << 9
            return 0
        case 406: // EA_ATTACK
            client.actionFlags |= 1
            return 0
        case 407: // EA_USE
            client.actionFlags |= 1 << 2
            return 0
        case 408: // EA_RESPAWN
            client.actionFlags |= 1 << 3
            return 0
        case 409: // EA_CROUCH
            client.moveDir.z = -1
            return 0
        case 410: // EA_MOVE_UP
            client.moveDir.z = 1
            return 0
        case 411: // EA_MOVE_DOWN
            client.moveDir.z = -1
            return 0
        case 412: // EA_MOVE_FORWARD
            client.moveDir.y = 1
            return 0
        case 413: // EA_MOVE_BACK
            client.moveDir.y = -1
            return 0
        case 414: // EA_MOVE_LEFT
            client.moveDir.x = -1
            return 0
        case 415: // EA_MOVE_RIGHT
            client.moveDir.x = 1
            return 0
        case 416: // EA_SELECT_WEAPON
            client.selectedWeapon = Int(args[2])
            return 0
        case 417: // EA_JUMP
            client.actionFlags |= 1 << 4
            return 0
        case 418: // EA_DELAYED_JUMP
            client.actionFlags |= 1 << 5
            return 0
        case 419: // EA_MOVE
            if args.count > 2 {
                let dir = readVec3(vm: vm, at: args[2])
                client.moveDir = dir
            }
            return 0
        case 420: // EA_VIEW
            if args.count > 2 {
                let angles = readVec3(vm: vm, at: args[2])
                client.viewAngles = angles
            }
            return 0
        case 421: // EA_END_REGULAR
            return 0
        case 422: // EA_GET_INPUT
            writeBotInput(client: client, vm: vm, addr: args[3])
            return 0
        case 423: // EA_RESET_INPUT
            client.resetInput()
            return 0
        default:
            return 0
        }
    }

    private func writeBotInput(client: BotClient, vm: QVM, addr: Int32) {
        let a = Int(addr)
        // Write bot_input_t structure
        // thinktime (float)
        vm.writeInt32(toData: a, value: Int32(bitPattern: Float(0.05).bitPattern))
        // dir (vec3)
        writeVec3(client.moveDir, vm: vm, at: a + 4)
        // speed (float)
        let speed: Float = simd_length(client.moveDir) > 0.1 ? 400 : 0
        vm.writeInt32(toData: a + 16, value: Int32(bitPattern: speed.bitPattern))
        // viewangles (vec3)
        writeVec3(client.viewAngles, vm: vm, at: a + 20)
        // actionflags (int)
        vm.writeInt32(toData: a + 32, value: client.actionFlags)
        // weapon (int)
        vm.writeInt32(toData: a + 36, value: Int32(client.selectedWeapon))
    }

    // MARK: - Helpers

    private func readVec3(vm: QVM, at addr: Int32) -> Vec3 {
        let a = Int(addr)
        let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a)))
        let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 4)))
        let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 8)))
        return Vec3(x, y, z)
    }

    private func writeVec3(_ v: Vec3, vm: QVM, at addr: Int) {
        vm.writeInt32(toData: addr, value: Int32(bitPattern: v.x.bitPattern))
        vm.writeInt32(toData: addr + 4, value: Int32(bitPattern: v.y.bitPattern))
        vm.writeInt32(toData: addr + 8, value: Int32(bitPattern: v.z.bitPattern))
    }
}

// MARK: - Bot Client State

class BotClient {
    let clientNum: Int
    var moveDir: Vec3 = .zero
    var viewAngles: Vec3 = .zero
    var actionFlags: Int32 = 0
    var selectedWeapon: Int = 0
    var pendingCommands: [String] = []

    init(clientNum: Int) {
        self.clientNum = clientNum
    }

    func resetInput() {
        moveDir = .zero
        viewAngles = .zero
        actionFlags = 0
    }
}
