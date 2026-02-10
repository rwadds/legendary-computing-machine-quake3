// ClientGame.swift — CGame VM syscall dispatch

import Foundation
import simd

extension ClientMain {

    /// Handle syscalls from the cgame QVM
    func cgameSystemCall(args: UnsafePointer<Int32>, numArgs: Int, vm: QVM) -> Int32 {
        let syscallNum = args[0]

        // Math traps
        if let mathResult = handleCGMathTrap(syscallNum, args: args, vm: vm) {
            return mathResult
        }

        // Memory traps
        if let memResult = handleCGMemoryTrap(syscallNum, args: args, vm: vm) {
            return memResult
        }

        guard let import_ = CGImport(rawValue: syscallNum) else {
            // Gap between regular syscalls (89) and math/memory traps (100)
            if syscallNum >= 90 && syscallNum < 100 {
                return 0
            }
            Q3Console.shared.warning("CGame syscall \(syscallNum) not implemented")
            return 0
        }

        switch import_ {
        case .cgPrint:
            let str = vm.readString(at: args[1])
            if !str.isEmpty { Q3Console.shared.print(str) }
            return 0

        case .cgError:
            let str = vm.readString(at: args[1])
            Q3Console.shared.error("CGame Error: \(str)")
            vm.aborted = true
            return -1

        case .cgMilliseconds:
            let ms = (ProcessInfo.processInfo.systemUptime - Q3Engine.shared.engineStartTime) * 1000
            return Int32(Int(ms) & 0x7FFFFFFF)

        case .cgCvarRegister:
            let vmcvarAddr = args[1]
            let name = vm.readString(at: args[2])
            let defaultVal = vm.readString(at: args[3])
            let flags = CVarFlags(rawValue: Int(args[4]))
            let cvar = Q3CVar.shared.get(name, defaultValue: defaultVal, flags: flags)
            if vmcvarAddr != 0 {
                ServerMain.shared.writeVMCVar(vm: vm, addr: vmcvarAddr, cvar: cvar)
            }
            return 0

        case .cgCvarUpdate:
            return 0

        case .cgCvarSet:
            let name = vm.readString(at: args[1])
            let value = vm.readString(at: args[2])
            _ = Q3CVar.shared.set(name, value: value, force: true)
            return 0

        case .cgCvarVariableStringBuffer:
            let name = vm.readString(at: args[1])
            let value = Q3CVar.shared.variableString(name)
            vm.writeString(at: args[2], value, maxLen: Int(args[3]))
            return 0

        case .cgArgc:
            return Int32(Q3CommandBuffer.shared.argc)

        case .cgArgv:
            let str = Q3CommandBuffer.shared.commandArgv(Int(args[1]))
            vm.writeString(at: args[2], str, maxLen: Int(args[3]))
            return 0

        case .cgArgs:
            let str = Q3CommandBuffer.shared.commandArgs()
            vm.writeString(at: args[1], str, maxLen: Int(args[2]))
            return 0

        case .cgFSFopenFile:
            let path = vm.readString(at: args[1])
            let handleAddr = args[2]
            let mode = args[3]
            if mode == 0 {
                let (handle, length) = Q3FileSystem.shared.openFileRead(path)
                if handleAddr != 0 { vm.writeInt32(toData: Int(handleAddr), value: handle) }
                return length
            } else {
                let handle = Q3FileSystem.shared.openFileWrite(path)
                if handleAddr != 0 { vm.writeInt32(toData: Int(handleAddr), value: handle) }
                return 0
            }

        case .cgFSRead:
            let bufAddr = args[1]
            let length = Int(args[2])
            let handle = args[3]
            var tempBuf = [UInt8](repeating: 0, count: length)
            let bytesRead = tempBuf.withUnsafeMutableBufferPointer { buf in
                Q3FileSystem.shared.readFile(handle: handle, buffer: buf.baseAddress!, length: length)
            }
            for i in 0..<bytesRead {
                vm.dataBase[(Int(bufAddr) + i) & vm.dataMask] = tempBuf[i]
            }
            return 0

        case .cgFSWrite:
            return 0

        case .cgFSFcloseFile:
            Q3FileSystem.shared.closeFile(handle: args[1])
            return 0

        case .cgSendConsoleCommand:
            let text = vm.readString(at: args[1])
            Q3Console.shared.print("CGame console cmd: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            Q3CommandBuffer.shared.addText(text)
            return 0

        case .cgAddCommand:
            let cmdName = vm.readString(at: args[1])
            Q3CommandBuffer.shared.addCommand(cmdName) {
                // Forward to cgame
            }
            return 0

        case .cgRemoveCommand:
            let cmdName = vm.readString(at: args[1])
            Q3CommandBuffer.shared.removeCommand(cmdName)
            return 0

        case .cgSendClientCommand:
            let cmd = vm.readString(at: args[1])
            addReliableCommand(cmd)
            return 0

        case .cgUpdateScreen:
            return 0

        // MARK: - Collision

        case .cgCmLoadMap:
            // Map already loaded by renderer
            return 0

        case .cgCmNumInlineModels:
            return 0

        case .cgCmInlineModel, .cgCmLoadModel, .cgCmTempBoxModel:
            return 0

        case .cgCmBoxTrace:
            let start = ServerMain.shared.readVec3(vm: vm, addr: args[2])
            let end = ServerMain.shared.readVec3(vm: vm, addr: args[3])
            let mins = args[4] != 0 ? ServerMain.shared.readVec3(vm: vm, addr: args[4]) : Vec3.zero
            let maxs = args[5] != 0 ? ServerMain.shared.readVec3(vm: vm, addr: args[5]) : Vec3.zero
            let contentMask = args[7]
            let result = CollisionModel.shared.trace(start: start, end: end, mins: mins, maxs: maxs, contentMask: contentMask)
            ServerMain.shared.writeTraceResult(vm: vm, addr: args[1], result: result)
            return 0

        case .cgCmTransformedBoxTrace:
            // Same as box trace for now (ignore transform)
            let start = ServerMain.shared.readVec3(vm: vm, addr: args[2])
            let end = ServerMain.shared.readVec3(vm: vm, addr: args[3])
            let mins = args[4] != 0 ? ServerMain.shared.readVec3(vm: vm, addr: args[4]) : Vec3.zero
            let maxs = args[5] != 0 ? ServerMain.shared.readVec3(vm: vm, addr: args[5]) : Vec3.zero
            let contentMask = args[7]
            let result = CollisionModel.shared.trace(start: start, end: end, mins: mins, maxs: maxs, contentMask: contentMask)
            ServerMain.shared.writeTraceResult(vm: vm, addr: args[1], result: result)
            return 0

        case .cgCmPointContents:
            let point = ServerMain.shared.readVec3(vm: vm, addr: args[1])
            return CollisionModel.shared.pointContents(at: point)

        case .cgCmTransformedPointContents:
            let point = ServerMain.shared.readVec3(vm: vm, addr: args[1])
            return CollisionModel.shared.pointContents(at: point)

        // MARK: - Renderer

        case .cgRRegisterModel:
            let name = vm.readString(at: args[1])
            return rendererAPI?.registerModel(name) ?? 0

        case .cgRRegisterSkin:
            let name = vm.readString(at: args[1])
            return rendererAPI?.registerSkin(name) ?? 0

        case .cgRRegisterShader:
            let name = vm.readString(at: args[1])
            return rendererAPI?.registerShader(name) ?? 0

        case .cgRRegisterShaderNoMip:
            let name = vm.readString(at: args[1])
            return rendererAPI?.registerShaderNoMip(name) ?? 0

        case .cgRClearScene:
            rendererAPI?.clearScene()
            return 0

        case .cgRAddRefEntityToScene:
            rendererAPI?.addRefEntityToScene(vm: vm, addr: args[1])
            return 0

        case .cgRAddPolyToScene:
            // args[1] = shader handle, args[2] = numVerts, args[3] = polyVert_t* verts
            rendererAPI?.addPolyToScene(vm: vm, shader: args[1], numVerts: Int(args[2]), vertsAddr: args[3])
            return 0

        case .cgRAddLightToScene:
            let origin = ServerMain.shared.readVec3(vm: vm, addr: args[1])
            let intensity = Float(bitPattern: UInt32(bitPattern: args[2]))
            let r = Float(bitPattern: UInt32(bitPattern: args[3]))
            let g = Float(bitPattern: UInt32(bitPattern: args[4]))
            let b = Float(bitPattern: UInt32(bitPattern: args[5]))
            rendererAPI?.addLightToScene(origin: origin, intensity: intensity, r: r, g: g, b: b)
            return 0

        case .cgRRenderScene:
            rendererAPI?.renderScene(vm: vm, refdefAddr: args[1])
            return 0

        case .cgRSetColor:
            if args[1] != 0 {
                let r = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(args[1]))))
                let g = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(args[1]) + 4)))
                let b = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(args[1]) + 8)))
                let a = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: Int(args[1]) + 12)))
                rendererAPI?.setColor(SIMD4<Float>(r, g, b, a))
            } else {
                rendererAPI?.setColor(nil)
            }
            return 0

        case .cgRDrawStretchPic:
            let x = Float(bitPattern: UInt32(bitPattern: args[1]))
            let y = Float(bitPattern: UInt32(bitPattern: args[2]))
            let w = Float(bitPattern: UInt32(bitPattern: args[3]))
            let h = Float(bitPattern: UInt32(bitPattern: args[4]))
            let s1 = Float(bitPattern: UInt32(bitPattern: args[5]))
            let t1 = Float(bitPattern: UInt32(bitPattern: args[6]))
            let s2 = Float(bitPattern: UInt32(bitPattern: args[7]))
            let t2 = Float(bitPattern: UInt32(bitPattern: args[8]))
            let shader = args[9]
            rendererAPI?.drawStretchPic(x: x, y: y, w: w, h: h, s1: s1, t1: t1, s2: s2, t2: t2, shader: shader)
            return 0

        case .cgRModelBounds:
            // Write zero bounds
            if args[2] != 0 { ServerMain.shared.writeVec3(vm: vm, addr: args[2], vec: Vec3(-16, -16, -24)) }
            if args[3] != 0 { ServerMain.shared.writeVec3(vm: vm, addr: args[3], vec: Vec3(16, 16, 32)) }
            return 0

        case .cgRLerpTag:
            return 0

        // MARK: - Game State

        case .cgGetGlconfig:
            writeGLConfig(vm: vm, addr: args[1])
            return 0

        case .cgGetGameState:
            writeGameState(vm: vm, addr: args[1])
            return 0

        case .cgGetCurrentSnapshotNumber:
            let (num, time) = ServerSnapshot.shared.getCurrentSnapshotNumber()
            vm.writeInt32(toData: Int(args[1]), value: num)
            vm.writeInt32(toData: Int(args[2]), value: time)
            return 0

        case .cgGetSnapshot:
            return getSnapshot(vm: vm, snapshotNumber: args[1], snapshotAddr: args[2]) ? 1 : 0

        case .cgGetServerCommand:
            return getServerCommand(args[1]) ? 1 : 0

        case .cgGetCurrentCmdNumber:
            return getCurrentCmdNumber()

        case .cgGetUserCmd:
            if let cmd = getUserCmd(args[1]) {
                ServerMain.shared.writeUserCmd(vm: vm, addr: args[2], cmd: cmd)
                return 1
            }
            return 0

        case .cgSetUserCmdValue:
            let weaponValue = args[1]
            let sensitivity = Float(bitPattern: UInt32(bitPattern: args[2]))
            setUserCmdValue(weaponValue, sensitivity)
            return 0

        case .cgMemoryRemaining:
            return 1024 * 1024 * 16  // 16MB available

        case .cgRealTime:
            // Write current time structure
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
            return 0

        case .cgSnapVector:
            let addr = Int(args[1])
            for i in 0..<3 {
                let f = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: addr + i * 4)))
                vm.writeInt32(toData: addr + i * 4, value: Int32(bitPattern: roundf(f).bitPattern))
            }
            return 0

        // MARK: - Sound

        case .cgSStartSound:
            // args: origin(1), entityNum(2), channel(3), sfxHandle(4)
            let origin: Vec3?
            if args[1] != 0 {
                origin = ServerMain.shared.readVec3(vm: vm, addr: args[1])
            } else {
                origin = nil
            }
            Q3SoundSystem.shared.startSound(origin: origin, entityNum: Int(args[2]), channel: Int(args[3]), sfxHandle: args[4])
            return 0

        case .cgSStartLocalSound:
            Q3SoundSystem.shared.startLocalSound(args[1], channelNum: Int(args[2]))
            return 0

        case .cgSClearLoopingSounds:
            Q3SoundSystem.shared.clearLoopingSounds()
            return 0

        case .cgSAddLoopingSound:
            // args: entityNum(1), origin(2), velocity(3), sfxHandle(4)
            let origin = ServerMain.shared.readVec3(vm: vm, addr: args[2])
            let velocity = ServerMain.shared.readVec3(vm: vm, addr: args[3])
            Q3SoundSystem.shared.addLoopingSound(entityNum: Int(args[1]), origin: origin, velocity: velocity, sfxHandle: args[4])
            return 0

        case .cgSAddRealLoopingSound:
            // Same as addLoopingSound for now
            let origin = ServerMain.shared.readVec3(vm: vm, addr: args[2])
            let velocity = ServerMain.shared.readVec3(vm: vm, addr: args[3])
            Q3SoundSystem.shared.addLoopingSound(entityNum: Int(args[1]), origin: origin, velocity: velocity, sfxHandle: args[4])
            return 0

        case .cgSStopLoopingSound:
            Q3SoundSystem.shared.stopLoopingSound(entityNum: Int(args[1]))
            return 0

        case .cgSUpdateEntityPosition:
            let origin = ServerMain.shared.readVec3(vm: vm, addr: args[2])
            Q3SoundSystem.shared.updateEntityPosition(entityNum: Int(args[1]), origin: origin)
            return 0

        case .cgSRespatialize:
            // args: entityNum(1), origin(2), axis(3), inwater(4)
            let origin = ServerMain.shared.readVec3(vm: vm, addr: args[2])
            let axisAddr = Int(args[3])
            let forward = Vec3(
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr))),
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 4))),
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 8)))
            )
            let right = Vec3(
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 12))),
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 16))),
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 20)))
            )
            let up = Vec3(
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 24))),
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 28))),
                Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: axisAddr + 32)))
            )
            Q3SoundSystem.shared.updateListener(origin: origin, forward: forward, right: right, up: up)
            return 0

        case .cgSRegisterSound:
            let name = vm.readString(at: args[1])
            return Q3SoundSystem.shared.registerSound(name)

        case .cgSStartBackgroundTrack:
            let intro = vm.readString(at: args[1])
            let loop = vm.readString(at: args[2])
            Q3Console.shared.print("Background track: intro=\(intro) loop=\(loop)")
            return 0

        case .cgSStopBackgroundTrack:
            return 0

        // MARK: - Keys

        case .cgKeyIsDown:
            return ClientUI.shared.keyStates[Int(args[1])] == true ? 1 : 0

        case .cgKeyGetCatcher:
            return ClientUI.shared.keyCatcher

        case .cgKeySetCatcher:
            ClientUI.shared.keyCatcher = args[1]
            return 0

        case .cgKeyGetKey:
            return 0

        // MARK: - Script parsing (stubs)
        case .cgPCAddGlobalDefine, .cgPCLoadSource, .cgPCFreeSource,
             .cgPCReadToken, .cgPCSourceFileAndLine:
            return 0

        // MARK: - Cinematic (stubs)
        case .cgCinPlayCinematic, .cgCinStopCinematic, .cgCinRunCinematic,
             .cgCinDrawCinematic, .cgCinSetExtents:
            return 0

        // MARK: - Additional entries
        case .cgCmMarkFragments:
            return 0

        case .cgRLoadWorldMap:
            // Map already loaded by renderer
            return 0

        case .cgRRegisterFont:
            return 0

        case .cgRLightForPoint:
            return 0

        case .cgRRemapShader:
            return 0

        case .cgCmTempCapsuleModel, .cgCmCapsuleTrace, .cgCmTransformedCapsuleTrace:
            return 0

        case .cgRAddAdditiveLightToScene:
            let origin = ServerMain.shared.readVec3(vm: vm, addr: args[1])
            let intensity = Float(bitPattern: UInt32(bitPattern: args[2]))
            let r = Float(bitPattern: UInt32(bitPattern: args[3]))
            let g = Float(bitPattern: UInt32(bitPattern: args[4]))
            let b = Float(bitPattern: UInt32(bitPattern: args[5]))
            rendererAPI?.addLightToScene(origin: origin, intensity: intensity, r: r, g: g, b: b)
            return 0

        case .cgGetEntityToken:
            if let token = ServerMain.shared.getEntityToken(maxLen: Int(args[2])) {
                vm.writeString(at: args[1], token, maxLen: Int(args[2]))
                return 1
            }
            return 0

        case .cgRAddPolysToScene:
            return 0

        case .cgRInPVS:
            return 1 // Always visible

        case .cgFSSeek:
            return 0

        case .cgTestPrintInt, .cgTestPrintFloat:
            return 0

        default:
            Q3Console.shared.warning("Unhandled cgame syscall: \(import_)")
            return 0
        }
    }

    // MARK: - Helpers

    private func writeGLConfig(vm: QVM, addr: Int32) {
        let a = Int(addr)
        // glconfig_t layout (Q3 cgame/tr_types.h):
        //   char renderer_string[MAX_STRING_CHARS];     // +0     (1024)
        //   char vendor_string[MAX_STRING_CHARS];       // +1024  (1024)
        //   char version_string[MAX_STRING_CHARS];      // +2048  (1024)
        //   char extensions_string[BIG_INFO_STRING];    // +3072  (8192)
        //   int  maxTextureSize;                        // +11264
        //   int  maxActiveTextures;                     // +11268
        //   int  colorBits, depthBits, stencilBits;     // +11272, +11276, +11280
        //   int  driverType;                            // +11284  (glDriverType_t)
        //   int  hardwareType;                          // +11288  (glHardwareType_t)
        //   int  deviceSupportsGamma;                   // +11292
        //   int  textureCompression;                    // +11296  (textureCompression_t)
        //   int  textureEnvAddAvailable;                // +11300
        //   int  vidWidth, vidHeight;                   // +11304, +11308
        //   float windowAspect;                         // +11312
        //   int  displayFrequency;                      // +11316
        //   int  isFullscreen;                          // +11320
        //   int  stereoEnabled;                         // +11324
        //   int  smpActive;                             // +11328

        vm.writeString(at: addr, "Metal 4", maxLen: MAX_STRING_CHARS)
        vm.writeString(at: Int32(a + MAX_STRING_CHARS), "Apple", maxLen: MAX_STRING_CHARS)
        vm.writeString(at: Int32(a + MAX_STRING_CHARS * 2), "1.0", maxLen: MAX_STRING_CHARS)

        let intBase = a + MAX_STRING_CHARS * 3 + BIG_INFO_STRING  // +11264
        vm.writeInt32(toData: intBase + 0, value: 4096)   // maxTextureSize
        vm.writeInt32(toData: intBase + 4, value: 8)      // maxActiveTextures
        vm.writeInt32(toData: intBase + 8, value: 32)     // colorBits
        vm.writeInt32(toData: intBase + 12, value: 32)    // depthBits
        vm.writeInt32(toData: intBase + 16, value: 8)     // stencilBits
        vm.writeInt32(toData: intBase + 20, value: 0)     // driverType (GLDRV_ICD)
        vm.writeInt32(toData: intBase + 24, value: 0)     // hardwareType (GLHW_GENERIC)
        vm.writeInt32(toData: intBase + 28, value: 0)     // deviceSupportsGamma
        vm.writeInt32(toData: intBase + 32, value: 0)     // textureCompression (TC_NONE)
        vm.writeInt32(toData: intBase + 36, value: 1)     // textureEnvAddAvailable
        vm.writeInt32(toData: intBase + 40, value: 1920)  // vidWidth
        vm.writeInt32(toData: intBase + 44, value: 1080)  // vidHeight
        vm.writeInt32(toData: intBase + 48, value: Int32(bitPattern: Float(16.0/9.0).bitPattern)) // windowAspect
        vm.writeInt32(toData: intBase + 52, value: 120)   // displayFrequency
        vm.writeInt32(toData: intBase + 56, value: 0)     // isFullscreen
        vm.writeInt32(toData: intBase + 60, value: 0)     // stereoEnabled
        vm.writeInt32(toData: intBase + 64, value: 0)     // smpActive
    }

    private func writeGameState(vm: QVM, addr: Int32) {
        let a = Int(addr)
        // Write stringOffsets array
        for i in 0..<MAX_CONFIGSTRINGS {
            vm.writeInt32(toData: a + i * 4, value: gameState.stringOffsets[i])
        }
        // Write string data
        let dataOffset = a + MAX_CONFIGSTRINGS * 4
        for i in 0..<Int(gameState.dataCount) {
            vm.dataBase[(dataOffset + i) & vm.dataMask] = gameState.stringData[i]
        }
        // Write dataCount
        vm.writeInt32(toData: dataOffset + MAX_GAMESTATE_CHARS, value: gameState.dataCount)
    }

    private func getSnapshot(vm: QVM, snapshotNumber: Int32, snapshotAddr: Int32) -> Bool {
        let snapIdx = Int(snapshotNumber) & 31
        let snap = snapshots[snapIdx]
        guard snap.valid else { return false }

        let a = Int(snapshotAddr)

        // Q3 snapshot_t layout:
        // 0: snapFlags(4), 4: ping(4), 8: serverTime(4), 12: areamask(32),
        // 44: playerState_t(468), 512: numEntities(4), 516: entities[](208 each),
        // after entities: numServerCommands(4), serverCommandSequence(4)
        vm.writeInt32(toData: a + 0, value: snap.snapFlags)
        vm.writeInt32(toData: a + 4, value: snap.ping)
        vm.writeInt32(toData: a + 8, value: snap.serverTime)

        // areamask — 32 bytes at offset 12 (zero for now)
        for i in 0..<8 {
            vm.writeInt32(toData: a + 12 + i * 4, value: 0)
        }

        // playerState_t at offset 44 (468 bytes)
        writePlayerState(vm: vm, addr: Int32(a + 44), ps: snap.ps)

        // numEntities at offset 512
        let count = min(snap.numEntities, 256)  // MAX_ENTITIES_IN_SNAPSHOT
        vm.writeInt32(toData: a + 512, value: Int32(count))

        // Entity states at offset 516, stride 208
        for i in 0..<count {
            let parseIdx = (snap.firstEntity + i) % 2048
            let ent = parseEntities[parseIdx]
            writeEntityState(vm: vm, addr: Int32(a + 516 + i * 208), es: ent)
        }

        // numServerCommands and serverCommandSequence after entities
        let afterEntities = a + 516 + 256 * 208  // 53764
        vm.writeInt32(toData: afterEntities, value: 0)  // numServerCommands
        vm.writeInt32(toData: afterEntities + 4, value: snap.serverCommandNum)  // serverCommandSequence

        return true
    }

    private func writePlayerState(vm: QVM, addr: Int32, ps: PlayerState) {
        // Q3 playerState_t layout (468 bytes total)
        let a = Int(addr)
        vm.writeInt32(toData: a + 0, value: ps.commandTime)
        vm.writeInt32(toData: a + 4, value: ps.pm_type)
        vm.writeInt32(toData: a + 8, value: ps.bobCycle)
        vm.writeInt32(toData: a + 12, value: ps.pm_flags)
        vm.writeInt32(toData: a + 16, value: ps.pm_time)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 20), vec: ps.origin)     // 20-31
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 32), vec: ps.velocity)   // 32-43
        vm.writeInt32(toData: a + 44, value: ps.weaponTime)
        vm.writeInt32(toData: a + 48, value: ps.gravity)
        vm.writeInt32(toData: a + 52, value: ps.speed)
        vm.writeInt32(toData: a + 56, value: ps.delta_angles.x)
        vm.writeInt32(toData: a + 60, value: ps.delta_angles.y)
        vm.writeInt32(toData: a + 64, value: ps.delta_angles.z)
        vm.writeInt32(toData: a + 68, value: ps.groundEntityNum)
        vm.writeInt32(toData: a + 72, value: ps.legsTimer)
        vm.writeInt32(toData: a + 76, value: ps.legsAnim)
        vm.writeInt32(toData: a + 80, value: ps.torsoTimer)
        vm.writeInt32(toData: a + 84, value: ps.torsoAnim)
        vm.writeInt32(toData: a + 88, value: ps.movementDir)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 92), vec: ps.grapplePoint) // 92-103
        vm.writeInt32(toData: a + 104, value: ps.eFlags)
        vm.writeInt32(toData: a + 108, value: ps.eventSequence)
        vm.writeInt32(toData: a + 112, value: ps.events.0)
        vm.writeInt32(toData: a + 116, value: ps.events.1)
        vm.writeInt32(toData: a + 120, value: ps.eventParms.0)
        vm.writeInt32(toData: a + 124, value: ps.eventParms.1)
        vm.writeInt32(toData: a + 128, value: ps.externalEvent)
        vm.writeInt32(toData: a + 132, value: ps.externalEventParm)
        vm.writeInt32(toData: a + 136, value: ps.externalEventTime)
        vm.writeInt32(toData: a + 140, value: ps.clientNum)
        vm.writeInt32(toData: a + 144, value: ps.weapon)
        vm.writeInt32(toData: a + 148, value: ps.weaponstate)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 152), vec: ps.viewangles) // 152-163
        vm.writeInt32(toData: a + 164, value: ps.viewheight)
        vm.writeInt32(toData: a + 168, value: ps.damageEvent)
        vm.writeInt32(toData: a + 172, value: ps.damageYaw)
        vm.writeInt32(toData: a + 176, value: ps.damagePitch)
        vm.writeInt32(toData: a + 180, value: ps.damageCount)
        for i in 0..<MAX_STATS {
            vm.writeInt32(toData: a + 184 + i * 4, value: ps.stats[i])
        }
        for i in 0..<MAX_PERSISTANT {
            vm.writeInt32(toData: a + 248 + i * 4, value: ps.persistant[i])
        }
        for i in 0..<MAX_POWERUPS {
            vm.writeInt32(toData: a + 312 + i * 4, value: ps.powerups[i])
        }
        for i in 0..<MAX_WEAPONS {
            vm.writeInt32(toData: a + 376 + i * 4, value: ps.ammo[i])
        }
        vm.writeInt32(toData: a + 440, value: ps.generic1)
        vm.writeInt32(toData: a + 444, value: ps.loopSound)
        vm.writeInt32(toData: a + 448, value: ps.jumppad_ent)
        vm.writeInt32(toData: a + 452, value: ps.ping)
        vm.writeInt32(toData: a + 456, value: ps.pmove_framecount)
        vm.writeInt32(toData: a + 460, value: ps.jumppad_frame)
        vm.writeInt32(toData: a + 464, value: ps.entityEventSequence)
    }

    private func writeEntityState(vm: QVM, addr: Int32, es: EntityState) {
        // Q3 entityState_t layout (208 bytes total):
        // trajectory_t = 36 bytes: trType(4) + trTime(4) + trDuration(4) + trBase(12) + trDelta(12)
        let a = Int(addr)
        vm.writeInt32(toData: a + 0, value: es.number)
        vm.writeInt32(toData: a + 4, value: es.eType)
        vm.writeInt32(toData: a + 8, value: es.eFlags)
        // pos trajectory (36 bytes, offset 12-47)
        vm.writeInt32(toData: a + 12, value: es.pos.trType.rawValue)
        vm.writeInt32(toData: a + 16, value: es.pos.trTime)
        vm.writeInt32(toData: a + 20, value: es.pos.trDuration)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 24), vec: es.pos.trBase)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 36), vec: es.pos.trDelta)
        // apos trajectory (36 bytes, offset 48-83)
        vm.writeInt32(toData: a + 48, value: es.apos.trType.rawValue)
        vm.writeInt32(toData: a + 52, value: es.apos.trTime)
        vm.writeInt32(toData: a + 56, value: es.apos.trDuration)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 60), vec: es.apos.trBase)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 72), vec: es.apos.trDelta)
        // Remaining fields at correct Q3 offsets
        vm.writeInt32(toData: a + 84, value: es.time)
        vm.writeInt32(toData: a + 88, value: es.time2)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 92), vec: es.origin)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 104), vec: es.origin2)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 116), vec: es.angles)
        ServerMain.shared.writeVec3(vm: vm, addr: Int32(a + 128), vec: es.angles2)
        vm.writeInt32(toData: a + 140, value: es.otherEntityNum)
        vm.writeInt32(toData: a + 144, value: es.otherEntityNum2)
        vm.writeInt32(toData: a + 148, value: es.groundEntityNum)
        vm.writeInt32(toData: a + 152, value: es.constantLight)
        vm.writeInt32(toData: a + 156, value: es.loopSound)
        vm.writeInt32(toData: a + 160, value: es.modelindex)
        vm.writeInt32(toData: a + 164, value: es.modelindex2)
        vm.writeInt32(toData: a + 168, value: es.clientNum)
        vm.writeInt32(toData: a + 172, value: es.frame)
        vm.writeInt32(toData: a + 176, value: es.solid)
        vm.writeInt32(toData: a + 180, value: es.event)
        vm.writeInt32(toData: a + 184, value: es.eventParm)
        vm.writeInt32(toData: a + 188, value: es.powerups)
        vm.writeInt32(toData: a + 192, value: es.weapon)
        vm.writeInt32(toData: a + 196, value: es.legsAnim)
        vm.writeInt32(toData: a + 200, value: es.torsoAnim)
        vm.writeInt32(toData: a + 204, value: es.generic1)
    }

    // MARK: - CGame Math Traps

    private func handleCGMathTrap(_ num: Int32, args: UnsafePointer<Int32>, vm: QVM) -> Int32? {
        switch num {
        case CGImport.cgSin.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: sinf(f).bitPattern)
        case CGImport.cgCos.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: cosf(f).bitPattern)
        case CGImport.cgAtan2.rawValue:
            let y = Float(bitPattern: UInt32(bitPattern: args[1]))
            let x = Float(bitPattern: UInt32(bitPattern: args[2]))
            return Int32(bitPattern: atan2f(y, x).bitPattern)
        case CGImport.cgSqrt.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: sqrtf(f).bitPattern)
        case CGImport.cgFloor.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: floorf(f).bitPattern)
        case CGImport.cgCeil.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: ceilf(f).bitPattern)
        case CGImport.cgAcos.rawValue:
            let f = Float(bitPattern: UInt32(bitPattern: args[1]))
            let clamped = max(-1.0, min(1.0, f))
            return Int32(bitPattern: acosf(clamped).bitPattern)
        default:
            return nil
        }
    }

    private func handleCGMemoryTrap(_ num: Int32, args: UnsafePointer<Int32>, vm: QVM) -> Int32? {
        switch num {
        case CGImport.cgMemset.rawValue:
            let destAddr = Int(args[1])
            let value = UInt8(truncatingIfNeeded: args[2])
            let count = Int(args[3])
            for i in 0..<count {
                vm.dataBase[(destAddr + i) & vm.dataMask] = value
            }
            return args[1]
        case CGImport.cgMemcpy.rawValue:
            let destAddr = Int(args[1])
            let srcAddr = Int(args[2])
            let count = Int(args[3])
            var temp = [UInt8](repeating: 0, count: count)
            for i in 0..<count { temp[i] = vm.dataBase[(srcAddr + i) & vm.dataMask] }
            for i in 0..<count { vm.dataBase[(destAddr + i) & vm.dataMask] = temp[i] }
            return args[1]
        case CGImport.cgStrncpy.rawValue:
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

}
