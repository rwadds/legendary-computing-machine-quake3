// ServerGame.swift — Game VM syscall dispatch (SV_GameSystemCalls equivalent)

import Foundation
import simd

extension ServerMain {

    // Throttled game syscall log counter
    private static var _gameSyscallLogCounter: Int = 0

    /// Handle syscalls from the game QVM
    func gameSystemCall(args: UnsafePointer<Int32>, numArgs: Int, vm: QVM) -> Int32 {
        let syscallNum = args[0]

        // Try math traps first (these are common)
        if let mathResult = handleMathTrap(syscallNum, args: args, vm: vm) {
            return mathResult
        }

        // Try memory traps
        if let memResult = handleMemoryTrap(syscallNum, args: args, vm: vm) {
            return memResult
        }

        // Bot library syscalls (200+) — dispatch before GameImport guard
        // since the enum includes botlib cases but the main switch doesn't handle them
        if syscallNum >= 200 {
            return handleBotLibSyscall(syscallNum, args: args, vm: vm)
        }

        guard let import_ = GameImport(rawValue: syscallNum) else {
            // Syscalls 46-99 are extended traps (not in standard Q3A but present in some builds)
            if syscallNum >= 46 && syscallNum < 100 {
                return 0  // Stub: return 0 for unknown extended syscalls
            }
            Q3Console.shared.warning("Game syscall \(syscallNum) not implemented")
            return 0
        }

        switch import_ {
        case .gPrint:
            let str = vm.readString(at: args[1])
            if !str.isEmpty { Q3Console.shared.print(str) }
            return 0

        case .gError:
            let str = vm.readString(at: args[1])
            Q3Console.shared.error("Game Error: \(str)")
            vm.aborted = true
            return -1

        case .gMilliseconds:
            // Use live wall-clock time so bot AI time-quota loops work during spawnServer()
            let ms = (ProcessInfo.processInfo.systemUptime - Q3Engine.shared.engineStartTime) * 1000
            return Int32(Int(ms) & 0x7FFFFFFF)

        case .gCvarRegister:
            let vmcvarAddr = args[1]
            let name = vm.readString(at: args[2])
            let defaultVal = vm.readString(at: args[3])
            let flags = CVarFlags(rawValue: Int(args[4]))
            let cvar = Q3CVar.shared.get(name, defaultValue: defaultVal, flags: flags)

            // Write VMCVar back to VM memory
            if vmcvarAddr != 0 {
                writeVMCVar(vm: vm, addr: vmcvarAddr, cvar: cvar)
            }
            return 0

        case .gCvarUpdate:
            let vmcvarAddr = args[1]
            if vmcvarAddr != 0 {
                // Read handle from VM memory
                let handle = vm.readInt32(fromData: Int(vmcvarAddr))
                // Handle is not really used in our simple implementation
                // Just re-read the cvar name and update
                _ = handle  // suppress warning
            }
            return 0

        case .gCvarSet:
            let name = vm.readString(at: args[1])
            let value = vm.readString(at: args[2])
            _ = Q3CVar.shared.set(name, value: value, force: true)
            return 0

        case .gCvarVariableIntegerValue:
            let name = vm.readString(at: args[1])
            return Q3CVar.shared.variableIntegerValue(name)

        case .gCvarVariableStringBuffer:
            let name = vm.readString(at: args[1])
            let value = Q3CVar.shared.variableString(name)
            vm.writeString(at: args[2], value, maxLen: Int(args[3]))
            return 0

        case .gArgc:
            return Int32(Q3CommandBuffer.shared.argc)

        case .gArgv:
            let n = Int(args[1])
            let str = Q3CommandBuffer.shared.commandArgv(n)
            vm.writeString(at: args[2], str, maxLen: Int(args[3]))
            return 0

        case .gFSFopenFile:
            let path = vm.readString(at: args[1])
            let handleAddr = args[2]
            let mode = args[3]

            if mode == 0 { // FS_READ
                let (handle, length) = Q3FileSystem.shared.openFileRead(path)
                if handleAddr != 0 {
                    vm.writeInt32(toData: Int(handleAddr), value: handle)
                }
                return length
            } else if mode == 1 { // FS_WRITE
                let handle = Q3FileSystem.shared.openFileWrite(path)
                if handleAddr != 0 {
                    vm.writeInt32(toData: Int(handleAddr), value: handle)
                }
                return 0
            }
            return -1

        case .gFSRead:
            let bufAddr = args[1]
            let length = Int(args[2])
            let handle = args[3]
            var tempBuf = [UInt8](repeating: 0, count: length)
            let bytesRead = tempBuf.withUnsafeMutableBufferPointer { buf in
                Q3FileSystem.shared.readFile(handle: handle, buffer: buf.baseAddress!, length: length)
            }
            // Copy to VM memory
            for i in 0..<bytesRead {
                vm.dataBase[(Int(bufAddr) + i) & vm.dataMask] = tempBuf[i]
            }
            return 0

        case .gFSWrite:
            let bufAddr = args[1]
            let length = Int(args[2])
            let handle = args[3]
            var tempBuf = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                tempBuf[i] = vm.dataBase[(Int(bufAddr) + i) & vm.dataMask]
            }
            _ = tempBuf.withUnsafeBufferPointer { buf in
                Q3FileSystem.shared.writeFile(handle: handle, data: buf.baseAddress!, length: length)
            }
            return 0

        case .gFSFcloseFile:
            Q3FileSystem.shared.closeFile(handle: args[1])
            return 0

        case .gSendConsoleCommand:
            let execType = args[1]  // 0=EXEC_NOW, 1=EXEC_INSERT, 2=EXEC_APPEND
            let text = vm.readString(at: args[2])
            // Ignore map_restart during initialization — we handle the map lifecycle
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("map_restart") {
                return 0
            }
            if execType == 1 {
                // EXEC_INSERT: insert at front of command buffer
                Q3CommandBuffer.shared.insertText(text)
            } else {
                // EXEC_NOW or EXEC_APPEND: add to end
                Q3CommandBuffer.shared.addText(text)
            }
            return 0

        case .gLocateGameData:
            // args[1] = gentities base address in VM memory
            // args[2] = num_entities
            // args[3] = gentitySize (sizeof(gentity_t))
            // args[4] = playerStates base address
            // args[5] = playerState size
            locateGameData(vm: vm,
                           gentitiesAddr: args[1],
                           gentitySize: Int(args[3]),
                           numEntities: Int(args[2]),
                           gameClientsAddr: args[4],
                           gameClientSize: Int(args[5]))
            return 0

        case .gDropClient:
            let clientNum = Int(args[1])
            let reason = vm.readString(at: args[2])
            Q3Console.shared.print("Client \(clientNum) dropped: \(reason)")
            if clientNum >= 0 && clientNum < maxClients {
                clients[clientNum].state = .free
            }
            return 0

        case .gSendServerCommand:
            let clientNum = Int(args[1])
            let cmd = vm.readString(at: args[2])
            sendServerCommand(clientNum: clientNum, command: cmd)
            return 0

        case .gSetConfigstring:
            let index = Int(args[1])
            let value = vm.readString(at: args[2])
            setConfigString(index, value: value)
            return 0

        case .gGetConfigstring:
            let index = Int(args[1])
            let value = getConfigString(index)
            vm.writeString(at: args[2], value, maxLen: Int(args[3]))
            return 0

        case .gSetUserinfo:
            let clientNum = Int(args[1])
            let info = vm.readString(at: args[2])
            if clientNum >= 0 && clientNum < maxClients {
                clients[clientNum].userinfo = info
            }
            return 0

        case .gGetUserinfo:
            let clientNum = Int(args[1])
            let info = (clientNum >= 0 && clientNum < maxClients) ? clients[clientNum].userinfo : ""
            vm.writeString(at: args[2], info, maxLen: Int(args[3]))
            return 0

        case .gGetServerinfo:
            let info = configStrings[CS_SERVERINFO]
            vm.writeString(at: args[1], info, maxLen: Int(args[2]))
            return 0

        case .gSetBrushModel:
            // Set brush model bounds from BSP inline model
            let entAddr = args[1]
            let modelStr = vm.readString(at: args[2])
            setBrushModel(vm: vm, entAddr: entAddr, modelName: modelStr)
            return 0

        case .gTrace:
            performTrace(vm: vm,
                         resultAddr: args[1],
                         startAddr: args[2],
                         minsAddr: args[3],
                         maxsAddr: args[4],
                         endAddr: args[5],
                         passEntityNum: Int(args[6]),
                         contentMask: args[7])
            return 0

        case .gPointContents:
            let point = readVec3(vm: vm, addr: args[1])
            return CollisionModel.shared.pointContents(at: point)

        case .gInPVS, .gInPVSIgnorePortals:
            // Simplified: always return true for now
            return 1

        case .gAdjustAreaPortalState:
            // Stub
            return 0

        case .gAreasConnected:
            // Simplified: always connected
            return 1

        case .gLinkEntity:
            let entAddr = args[1]
            ServerWorld.shared.linkEntity(vm: vm, entAddr: entAddr)
            return 0

        case .gUnlinkEntity:
            let entAddr = args[1]
            ServerWorld.shared.unlinkEntity(vm: vm, entAddr: entAddr)
            return 0

        case .gEntitiesInBox:
            let mins = readVec3(vm: vm, addr: args[1])
            let maxs = readVec3(vm: vm, addr: args[2])
            let listAddr = args[3]
            let maxCount = Int(args[4])
            let count = ServerWorld.shared.entitiesInBox(mins: mins, maxs: maxs,
                                                         listAddr: listAddr, maxCount: maxCount, vm: vm)
            // DEBUG: periodic log of EntitiesInBox results
            entitiesInBoxCallCount += 1
            if entitiesInBoxCallCount % 600 == 1 {
                // Also count linked entities with CONTENTS_TRIGGER
                var triggerCount = 0
                var totalLinked = 0
                for i in 0..<numEntities {
                    guard i < gentities.count else { break }
                    if gentities[i].r.linked {
                        totalLinked += 1
                        if gentities[i].r.contents & 0x40000000 != 0 { // CONTENTS_TRIGGER
                            triggerCount += 1
                        }
                    }
                }
                Q3Console.shared.print("[EIB-DBG] query mins=\(mins) maxs=\(maxs) → \(count) found (linked=\(totalLinked) triggers=\(triggerCount))")
            }
            return Int32(count)

        case .gEntityContact:
            // Test if world-space box (mins, maxs) overlaps entity's bounds
            let ecMins = readVec3(vm: vm, addr: args[1])
            let ecMaxs = readVec3(vm: vm, addr: args[2])
            // args[3] is a gentity_t pointer in VM; first field (entityState_t.number) is the entity index
            let ecEntNum = Int(vm.readInt32(fromData: Int(args[3])))
            let contact = entityContact(mins: ecMins, maxs: ecMaxs, entNum: ecEntNum)
            // DEBUG: log entity contact checks
            entityContactCallCount += 1
            if entityContactCallCount % 600 == 1 {
                let entType = ecEntNum < gentities.count ? gentities[ecEntNum].s.eType : -1
                let entContents = ecEntNum < gentities.count ? gentities[ecEntNum].r.contents : 0
                Q3Console.shared.print("[EC-DBG] contact ent#\(ecEntNum) type=\(entType) contents=0x\(String(entContents, radix: 16)) → \(contact)")
            }
            return contact ? 1 : 0

        case .gBotAllocateClient:
            return allocateBotClient()

        case .gBotFreeClient:
            let clientNum = Int(args[1])
            if clientNum >= 0 && clientNum < maxClients {
                clients[clientNum].state = .free
            }
            return 0

        case .gGetUsercmd:
            let clientNum = Int(args[1])
            if clientNum >= 0 && clientNum < maxClients {
                writeUserCmd(vm: vm, addr: args[2], cmd: clients[clientNum].lastUsercmd)
            }
            return 0

        case .gGetEntityToken:
            if let token = getEntityToken(maxLen: Int(args[2])) {
                vm.writeString(at: args[1], token, maxLen: Int(args[2]))
                return 1
            }
            return 0

        case .gFSGetFileList:
            let path = vm.readString(at: args[1])
            let ext = vm.readString(at: args[2])
            let files = Q3FileSystem.shared.listFiles(inDirectory: path, withExtension: ext)
            // Write file list as null-separated strings
            var offset = 0
            let bufAddr = Int(args[3])
            let bufSize = Int(args[4])
            var count = 0
            for file in files {
                let bytes = Array(file.utf8) + [0]
                if offset + bytes.count > bufSize { break }
                for b in bytes {
                    vm.dataBase[(bufAddr + offset) & vm.dataMask] = b
                    offset += 1
                }
                count += 1
            }
            return Int32(count)

        case .gDebugPolygonCreate, .gDebugPolygonDelete:
            return 0

        case .gRealTime:
            // Write time structure
            let now = Date()
            let calendar = Calendar.current
            let comp = calendar.dateComponents([.second, .minute, .hour, .day, .month, .year, .weekday, .dayOfYear], from: now)
            let addr = Int(args[1])
            vm.writeInt32(toData: addr + 0, value: Int32(comp.second ?? 0))
            vm.writeInt32(toData: addr + 4, value: Int32(comp.minute ?? 0))
            vm.writeInt32(toData: addr + 8, value: Int32(comp.hour ?? 0))
            vm.writeInt32(toData: addr + 12, value: Int32(comp.day ?? 0))
            vm.writeInt32(toData: addr + 16, value: Int32((comp.month ?? 1) - 1))
            vm.writeInt32(toData: addr + 20, value: Int32((comp.year ?? 2024) - 1900))
            vm.writeInt32(toData: addr + 24, value: Int32((comp.weekday ?? 1) - 1))
            vm.writeInt32(toData: addr + 28, value: Int32(comp.dayOfYear ?? 0))
            vm.writeInt32(toData: addr + 32, value: 0) // isdst
            return 0

        case .gSnapVector:
            let addr = Int(args[1])
            for i in 0..<3 {
                let f = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: addr + i * 4)))
                let snapped = roundf(f)
                vm.writeInt32(toData: addr + i * 4, value: Int32(bitPattern: snapped.bitPattern))
            }
            return 0

        case .gTraceCapsule:
            // Same as trace for now
            performTrace(vm: vm,
                         resultAddr: args[1],
                         startAddr: args[2],
                         minsAddr: args[3],
                         maxsAddr: args[4],
                         endAddr: args[5],
                         passEntityNum: Int(args[6]),
                         contentMask: args[7])
            return 0

        case .gEntityContactCapsule:
            let eccMins = readVec3(vm: vm, addr: args[1])
            let eccMaxs = readVec3(vm: vm, addr: args[2])
            let eccEntNum = Int(vm.readInt32(fromData: Int(args[3])))
            return entityContact(mins: eccMins, maxs: eccMaxs, entNum: eccEntNum) ? 1 : 0

        case .gFSSeek:
            let handle = args[1]
            let offset = Int(args[2])
            let origin = Int(args[3])
            return Int32(Q3FileSystem.shared.seekFile(handle: handle, offset: offset, origin: origin))

        default:
            Q3Console.shared.warning("Unhandled game syscall: \(import_)")
            return 0
        }
    }

    // MARK: - Entity Contact Test

    /// Test if a world-space box (mins, maxs) overlaps the given entity's bounds.
    /// Used by G_TouchTriggers in the game VM to detect trigger contacts.
    private func entityContact(mins: Vec3, maxs: Vec3, entNum: Int) -> Bool {
        guard entNum >= 0 && entNum < gentities.count else { return false }
        let ent = gentities[entNum]
        guard ent.r.linked else { return false }

        // AABB overlap test
        return mins.x <= ent.r.absmax.x && maxs.x >= ent.r.absmin.x &&
               mins.y <= ent.r.absmax.y && maxs.y >= ent.r.absmin.y &&
               mins.z <= ent.r.absmax.z && maxs.z >= ent.r.absmin.z
    }

    // MARK: - Syscall Helpers

    private func locateGameData(vm: QVM, gentitiesAddr: Int32, gentitySize: Int,
                                numEntities: Int, gameClientsAddr: Int32, gameClientSize: Int) {
        self.gentitySize = gentitySize
        self.numEntities = numEntities
        self.gameClientSize = gameClientSize
        self.gentitiesBaseAddr = gentitiesAddr
        self.gameClientsBaseAddr = gameClientsAddr

        // Initialize entity array to proper size
        if gentities.count < numEntities {
            gentities = (0..<MAX_GENTITIES).map { i in
                var ent = SharedEntity()
                ent.s.number = Int32(i)
                return ent
            }
        }

        if numEntities <= 64 || numEntities >= MAX_GENTITIES - 1 {
            Q3Console.shared.print("G_LOCATE_GAME_DATA: entities=\(numEntities) entitySize=\(gentitySize) gameClientSize=\(gameClientSize)")
        }
    }

    private func sendServerCommand(clientNum: Int, command: String) {
        if clientNum == -1 {
            // Broadcast
            for i in 0..<maxClients {
                guard clients[i].state >= .connected else { continue }
                let seq = clients[i].reliableSequence + 1
                clients[i].reliableSequence = seq
                let idx = Int(seq) & 63
                clients[i].reliableCommands[idx] = command
            }
        } else if clientNum >= 0 && clientNum < maxClients {
            let seq = clients[clientNum].reliableSequence + 1
            clients[clientNum].reliableSequence = seq
            let idx = Int(seq) & 63
            clients[clientNum].reliableCommands[idx] = command
        }
    }

    private func setBrushModel(vm: QVM, entAddr: Int32, modelName: String) {
        // Parse "*N" model name
        guard modelName.hasPrefix("*"), let modelNum = Int(modelName.dropFirst()) else { return }

        // Get inline model bounds from BSP
        guard let bounds = CollisionModel.shared.inlineModelBounds(modelNum) else {
            Q3Console.shared.warning("SetBrushModel: no bounds for inline model \(modelNum)")
            return
        }

        // Write modelindex to entityState_t (offset 160)
        vm.writeInt32(toData: Int(entAddr) + 160, value: Int32(modelNum))

        // Write to entityShared_t (starts at entAddr + 208)
        let sharedBase = Int(entAddr) + 208

        // bmodel = 1 (offset 16)
        vm.writeInt32(toData: sharedBase + 16, value: 1)

        // mins (offset 20, 3 floats)
        vm.writeInt32(toData: sharedBase + 20, value: Int32(bitPattern: bounds.mins.x.bitPattern))
        vm.writeInt32(toData: sharedBase + 24, value: Int32(bitPattern: bounds.mins.y.bitPattern))
        vm.writeInt32(toData: sharedBase + 28, value: Int32(bitPattern: bounds.mins.z.bitPattern))

        // maxs (offset 32, 3 floats)
        vm.writeInt32(toData: sharedBase + 32, value: Int32(bitPattern: bounds.maxs.x.bitPattern))
        vm.writeInt32(toData: sharedBase + 36, value: Int32(bitPattern: bounds.maxs.y.bitPattern))
        vm.writeInt32(toData: sharedBase + 40, value: Int32(bitPattern: bounds.maxs.z.bitPattern))

        // contents = -1 (CONTENTS_SOLID default, game will override)
        vm.writeInt32(toData: sharedBase + 44, value: -1)

        // Link entity so absmin/absmax get computed and it enters world sectors
        ServerWorld.shared.linkEntity(vm: vm, entAddr: entAddr)
    }

    private func performTrace(vm: QVM, resultAddr: Int32, startAddr: Int32,
                              minsAddr: Int32, maxsAddr: Int32, endAddr: Int32,
                              passEntityNum: Int, contentMask: Int32) {
        let start = readVec3(vm: vm, addr: startAddr)
        let end = readVec3(vm: vm, addr: endAddr)
        let mins = minsAddr != 0 ? readVec3(vm: vm, addr: minsAddr) : Vec3.zero
        let maxs = maxsAddr != 0 ? readVec3(vm: vm, addr: maxsAddr) : Vec3.zero

        // Use ServerWorld.trace which does BSP world + entity collision
        let result = ServerWorld.shared.trace(start: start, end: end,
                                               mins: mins, maxs: maxs,
                                               passEntityNum: passEntityNum,
                                               contentMask: contentMask)

        // Write trace result to VM memory
        writeTraceResult(vm: vm, addr: resultAddr, result: result)
    }

    private func allocateBotClient() -> Int32 {
        for i in 0..<maxClients {
            if clients[i].state == .free {
                clients[i].state = .connected
                return Int32(i)
            }
        }
        return -1
    }

    // MARK: - VM Memory Read/Write Helpers

    func readVec3(vm: QVM, addr: Int32) -> Vec3 {
        let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(addr))))
        let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(addr) + 4)))
        let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(addr) + 8)))
        return Vec3(x, y, z)
    }

    func writeVec3(vm: QVM, addr: Int32, vec: Vec3) {
        vm.writeInt32(toData: Int(addr), value: Int32(bitPattern: vec.x.bitPattern))
        vm.writeInt32(toData: Int(addr) + 4, value: Int32(bitPattern: vec.y.bitPattern))
        vm.writeInt32(toData: Int(addr) + 8, value: Int32(bitPattern: vec.z.bitPattern))
    }

    func writeVMCVar(vm: QVM, addr: Int32, cvar: Q3CVar.CVar) {
        let a = Int(addr)
        vm.writeInt32(toData: a + 0, value: 0) // handle
        vm.writeInt32(toData: a + 4, value: Int32(cvar.modificationCount))
        vm.writeInt32(toData: a + 8, value: Int32(bitPattern: cvar.value.bitPattern))
        vm.writeInt32(toData: a + 12, value: cvar.integer)
        vm.writeString(at: Int32(a + 16), cvar.string, maxLen: 256)
    }

    func writeUserCmd(vm: QVM, addr: Int32, cmd: UserCmd) {
        // Q3 usercmd_t layout (24 bytes):
        // 0: serverTime(4), 4: angles[3](12), 16: buttons(4),
        // 20: weapon(1), 21: forwardmove(1), 22: rightmove(1), 23: upmove(1)
        let a = Int(addr)
        vm.writeInt32(toData: a + 0, value: cmd.serverTime)
        vm.writeInt32(toData: a + 4, value: cmd.angles.x)
        vm.writeInt32(toData: a + 8, value: cmd.angles.y)
        vm.writeInt32(toData: a + 12, value: cmd.angles.z)
        vm.writeInt32(toData: a + 16, value: Int32(cmd.buttons))
        vm.dataBase[(a + 20) & vm.dataMask] = UInt8(cmd.weapon & 0xFF)
        vm.dataBase[(a + 21) & vm.dataMask] = UInt8(bitPattern: cmd.forwardmove)
        vm.dataBase[(a + 22) & vm.dataMask] = UInt8(bitPattern: cmd.rightmove)
        vm.dataBase[(a + 23) & vm.dataMask] = UInt8(bitPattern: cmd.upmove)
    }

    func writeTraceResult(vm: QVM, addr: Int32, result: TraceResult) {
        // Q3 trace_t layout (56 bytes total):
        // 0: allsolid (4), 4: startsolid (4), 8: fraction (4), 12: endpos (12)
        // 24: plane.normal (12), 36: plane.dist (4)
        // 40: plane.type (1) + plane.signbits (1) + pad (2)
        // 44: surfaceFlags (4), 48: contents (4), 52: entityNum (4)
        let a = Int(addr)
        vm.writeInt32(toData: a + 0, value: result.allsolid ? 1 : 0)
        vm.writeInt32(toData: a + 4, value: result.startsolid ? 1 : 0)
        vm.writeInt32(toData: a + 8, value: Int32(bitPattern: result.fraction.bitPattern))
        writeVec3(vm: vm, addr: Int32(a + 12), vec: result.endpos)
        writeVec3(vm: vm, addr: Int32(a + 24), vec: result.plane.normal)
        vm.writeInt32(toData: a + 36, value: Int32(bitPattern: result.plane.dist.bitPattern))
        // type (byte) + signbits (byte) + pad (2 bytes) = pack as one int32
        vm.writeInt32(toData: a + 40, value: 0) // type=0, signbits=0, pad=0
        vm.writeInt32(toData: a + 44, value: result.surfaceFlags)
        vm.writeInt32(toData: a + 48, value: result.contents)
        vm.writeInt32(toData: a + 52, value: result.entityNum)
    }

    // MARK: - Math Traps

    private func handleMathTrap(_ num: Int32, args: UnsafePointer<Int32>, vm: QVM) -> Int32? {
        switch num {
        case GameImport.trapSin.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: sinf(f).bitPattern)

        case GameImport.trapCos.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: cosf(f).bitPattern)

        case GameImport.trapAtan2.rawValue:
            let y = Float(bitPattern: UInt32(bitPattern: args[1]))
            let x = Float(bitPattern: UInt32(bitPattern: args[2]))
            return Int32(bitPattern: atan2f(y, x).bitPattern)

        case GameImport.trapSqrt.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: sqrtf(f).bitPattern)

        case GameImport.trapFloor.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: floorf(f).bitPattern)

        case GameImport.trapCeil.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: ceilf(f).bitPattern)

        case GameImport.trapAcos.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            let clamped = max(-1.0, min(1.0, f))
            return Int32(bitPattern: acosf(clamped).bitPattern)

        case GameImport.trapTestPrintInt.rawValue:
            let str = vm.readString(at: args[1])
            let val = args[2]
            Q3Console.shared.print("\(str) \(val)")
            return 0

        case GameImport.trapTestPrintFloat.rawValue:
            let str = vm.readString(at: args[1])
            let f = Float(bitPattern: UInt32(bitPattern: args[2]))
            Q3Console.shared.print("\(str) \(f)")
            return 0

        case GameImport.trapAngleVectors.rawValue:
            let angles = readVec3(vm: vm, addr: args[1])
            let (forward, right, up) = angleVectors(angles)
            if args[2] != 0 { writeVec3(vm: vm, addr: args[2], vec: forward) }
            if args[3] != 0 { writeVec3(vm: vm, addr: args[3], vec: right) }
            if args[4] != 0 { writeVec3(vm: vm, addr: args[4], vec: up) }
            return 0

        case GameImport.trapPerpendicularVector.rawValue:
            let src = readVec3(vm: vm, addr: args[2])
            let perp = perpendicular(to: src)
            writeVec3(vm: vm, addr: args[1], vec: perp)
            return 0

        case GameImport.trapMatrixMultiply.rawValue:
            // 3x3 matrix multiply
            let aAddr = Int(args[1])
            let bAddr = Int(args[2])
            let outAddr = Int(args[3])
            for i in 0..<3 {
                for j in 0..<3 {
                    var sum: Float = 0
                    for k in 0..<3 {
                        let a = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: aAddr + (i * 3 + k) * 4)))
                        let b = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: bAddr + (k * 3 + j) * 4)))
                        sum += a * b
                    }
                    vm.writeInt32(toData: outAddr + (i * 3 + j) * 4, value: Int32(bitPattern: sum.bitPattern))
                }
            }
            return 0

        default:
            return nil
        }
    }

    // MARK: - Memory Traps

    private func handleMemoryTrap(_ num: Int32, args: UnsafePointer<Int32>, vm: QVM) -> Int32? {
        switch num {
        case GameImport.trapMemset.rawValue:
            let destAddr = Int(args[1])
            let value = UInt8(truncatingIfNeeded: args[2])
            let count = Int(args[3])
            for i in 0..<count {
                vm.dataBase[(destAddr + i) & vm.dataMask] = value
            }
            return args[1]

        case GameImport.trapMemcpy.rawValue:
            let destAddr = Int(args[1])
            let srcAddr = Int(args[2])
            let count = Int(args[3])
            // Copy through temp buffer to handle overlap
            var temp = [UInt8](repeating: 0, count: count)
            for i in 0..<count {
                temp[i] = vm.dataBase[(srcAddr + i) & vm.dataMask]
            }
            for i in 0..<count {
                vm.dataBase[(destAddr + i) & vm.dataMask] = temp[i]
            }
            return args[1]

        case GameImport.trapStrncpy.rawValue:
            let destAddr = Int(args[1])
            let srcAddr = Int(args[2])
            let count = Int(args[3])
            var hitNull = false
            for i in 0..<count {
                if hitNull {
                    vm.dataBase[(destAddr + i) & vm.dataMask] = 0
                } else {
                    let c = vm.dataBase[(srcAddr + i) & vm.dataMask]
                    vm.dataBase[(destAddr + i) & vm.dataMask] = c
                    if c == 0 { hitNull = true }
                }
            }
            return args[1]

        default:
            return nil
        }
    }

    // MARK: - VM Entity/PlayerState Readers

    /// Read entityState_t (208 bytes) from VM memory at the given address
    func readEntityStateFromVM(vm: QVM, addr: Int32) -> EntityState {
        let a = Int(addr)
        var es = EntityState()
        es.number = vm.readInt32(fromData: a + 0)
        es.eType = vm.readInt32(fromData: a + 4)
        es.eFlags = vm.readInt32(fromData: a + 8)
        // pos trajectory (offset 12-47)
        es.pos.trType = TrajectoryType(rawValue: vm.readInt32(fromData: a + 12)) ?? .stationary
        es.pos.trTime = vm.readInt32(fromData: a + 16)
        es.pos.trDuration = vm.readInt32(fromData: a + 20)
        es.pos.trBase = readVec3(vm: vm, addr: Int32(a + 24))
        es.pos.trDelta = readVec3(vm: vm, addr: Int32(a + 36))
        // apos trajectory (offset 48-83)
        es.apos.trType = TrajectoryType(rawValue: vm.readInt32(fromData: a + 48)) ?? .stationary
        es.apos.trTime = vm.readInt32(fromData: a + 52)
        es.apos.trDuration = vm.readInt32(fromData: a + 56)
        es.apos.trBase = readVec3(vm: vm, addr: Int32(a + 60))
        es.apos.trDelta = readVec3(vm: vm, addr: Int32(a + 72))
        // Remaining fields
        es.time = vm.readInt32(fromData: a + 84)
        es.time2 = vm.readInt32(fromData: a + 88)
        es.origin = readVec3(vm: vm, addr: Int32(a + 92))
        es.origin2 = readVec3(vm: vm, addr: Int32(a + 104))
        es.angles = readVec3(vm: vm, addr: Int32(a + 116))
        es.angles2 = readVec3(vm: vm, addr: Int32(a + 128))
        es.otherEntityNum = vm.readInt32(fromData: a + 140)
        es.otherEntityNum2 = vm.readInt32(fromData: a + 144)
        es.groundEntityNum = vm.readInt32(fromData: a + 148)
        es.constantLight = vm.readInt32(fromData: a + 152)
        es.loopSound = vm.readInt32(fromData: a + 156)
        es.modelindex = vm.readInt32(fromData: a + 160)
        es.modelindex2 = vm.readInt32(fromData: a + 164)
        es.clientNum = vm.readInt32(fromData: a + 168)
        es.frame = vm.readInt32(fromData: a + 172)
        es.solid = vm.readInt32(fromData: a + 176)
        es.event = vm.readInt32(fromData: a + 180)
        es.eventParm = vm.readInt32(fromData: a + 184)
        es.powerups = vm.readInt32(fromData: a + 188)
        es.weapon = vm.readInt32(fromData: a + 192)
        es.legsAnim = vm.readInt32(fromData: a + 196)
        es.torsoAnim = vm.readInt32(fromData: a + 200)
        es.generic1 = vm.readInt32(fromData: a + 204)
        return es
    }

    /// Read playerState_t (468 bytes) from VM memory at the given address
    func readPlayerStateFromVM(vm: QVM, addr: Int32) -> PlayerState {
        let a = Int(addr)
        var ps = PlayerState()
        ps.commandTime = vm.readInt32(fromData: a + 0)
        ps.pm_type = vm.readInt32(fromData: a + 4)
        ps.bobCycle = vm.readInt32(fromData: a + 8)
        ps.pm_flags = vm.readInt32(fromData: a + 12)
        ps.pm_time = vm.readInt32(fromData: a + 16)
        ps.origin = readVec3(vm: vm, addr: Int32(a + 20))
        ps.velocity = readVec3(vm: vm, addr: Int32(a + 32))
        ps.weaponTime = vm.readInt32(fromData: a + 44)
        ps.gravity = vm.readInt32(fromData: a + 48)
        ps.speed = vm.readInt32(fromData: a + 52)
        ps.delta_angles = SIMD3<Int32>(
            vm.readInt32(fromData: a + 56),
            vm.readInt32(fromData: a + 60),
            vm.readInt32(fromData: a + 64))
        ps.groundEntityNum = vm.readInt32(fromData: a + 68)
        ps.legsTimer = vm.readInt32(fromData: a + 72)
        ps.legsAnim = vm.readInt32(fromData: a + 76)
        ps.torsoTimer = vm.readInt32(fromData: a + 80)
        ps.torsoAnim = vm.readInt32(fromData: a + 84)
        ps.movementDir = vm.readInt32(fromData: a + 88)
        ps.grapplePoint = readVec3(vm: vm, addr: Int32(a + 92))
        ps.eFlags = vm.readInt32(fromData: a + 104)
        ps.eventSequence = vm.readInt32(fromData: a + 108)
        ps.events = (vm.readInt32(fromData: a + 112), vm.readInt32(fromData: a + 116))
        ps.eventParms = (vm.readInt32(fromData: a + 120), vm.readInt32(fromData: a + 124))
        ps.externalEvent = vm.readInt32(fromData: a + 128)
        ps.externalEventParm = vm.readInt32(fromData: a + 132)
        ps.externalEventTime = vm.readInt32(fromData: a + 136)
        ps.clientNum = vm.readInt32(fromData: a + 140)
        ps.weapon = vm.readInt32(fromData: a + 144)
        ps.weaponstate = vm.readInt32(fromData: a + 148)
        ps.viewangles = readVec3(vm: vm, addr: Int32(a + 152))
        ps.viewheight = vm.readInt32(fromData: a + 164)
        ps.damageEvent = vm.readInt32(fromData: a + 168)
        ps.damageYaw = vm.readInt32(fromData: a + 172)
        ps.damagePitch = vm.readInt32(fromData: a + 176)
        ps.damageCount = vm.readInt32(fromData: a + 180)
        for i in 0..<MAX_STATS {
            ps.stats[i] = vm.readInt32(fromData: a + 184 + i * 4)
        }
        for i in 0..<MAX_PERSISTANT {
            ps.persistant[i] = vm.readInt32(fromData: a + 248 + i * 4)
        }
        for i in 0..<MAX_POWERUPS {
            ps.powerups[i] = vm.readInt32(fromData: a + 312 + i * 4)
        }
        for i in 0..<MAX_WEAPONS {
            ps.ammo[i] = vm.readInt32(fromData: a + 376 + i * 4)
        }
        ps.generic1 = vm.readInt32(fromData: a + 440)
        ps.loopSound = vm.readInt32(fromData: a + 444)
        ps.jumppad_ent = vm.readInt32(fromData: a + 448)
        ps.ping = vm.readInt32(fromData: a + 452)
        ps.pmove_framecount = vm.readInt32(fromData: a + 456)
        ps.jumppad_frame = vm.readInt32(fromData: a + 460)
        ps.entityEventSequence = vm.readInt32(fromData: a + 464)
        return ps
    }

    // MARK: - Bot Library Stubs

    private func handleBotLibSyscall(_ num: Int32, args: UnsafePointer<Int32>, vm: QVM) -> Int32 {
        // Convert UnsafePointer args to Array for BotLib dispatch
        let maxArgs = 13
        var argsArray = [Int32](repeating: 0, count: maxArgs)
        for i in 0..<maxArgs {
            argsArray[i] = args[i]
        }
        return BotLib.shared.handleSyscall(cmd: num, args: argsArray, vm: vm)
    }
}
