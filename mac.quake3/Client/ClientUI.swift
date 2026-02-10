// ClientUI.swift — UI VM syscall dispatch for menus, HUD, server browser

import Foundation
import simd

// MARK: - UI Import Syscalls (negative syscall numbers from ui.qvm)

enum UIImport: Int32 {
    case error = 0
    case print = 1
    case milliseconds = 2
    case cvarSet = 3
    case cvarVariableValue = 4
    case cvarVariableStringBuffer = 5
    case cvarSetValue = 6
    case cvarReset = 7
    case cvarCreate = 8
    case cvarInfoStringBuffer = 9
    case argc = 10
    case argv = 11
    case cmdExecuteText = 12
    case fsOpenFile = 13
    case fsRead = 14
    case fsWrite = 15
    case fsCloseFile = 16
    case fsGetFileList = 17
    case rRegisterModel = 18
    case rRegisterSkin = 19
    case rRegisterShaderNoMip = 20
    case rClearScene = 21
    case rAddRefEntityToScene = 22
    case rAddPolyToScene = 23
    case rAddLightToScene = 24
    case rRenderScene = 25
    case rSetColor = 26
    case rDrawStretchPic = 27
    case updateScreen = 28
    case cmLerpTag = 29
    case rModelBounds = 30
    case sRegisterSound = 31
    case sStartLocalSound = 32
    case keyKeynumToStringBuf = 33
    case keyGetBindingBuf = 34
    case keySetBinding = 35
    case keyIsDown = 36
    case keyGetOverstrikeMode = 37
    case keySetOverstrikeMode = 38
    case keyClearStates = 39
    case keyGetCatcher = 40
    case keySetCatcher = 41
    case getClipboardData = 42
    case getGLConfig = 43
    case getClientState = 44
    case getConfigString = 45
    case lanGetPingQueueCount = 46
    case lanClearPing = 47
    case lanGetPing = 48
    case lanGetPingInfo = 49
    case cvarRegister = 50
    case cvarUpdate = 51
    case memoryRemaining = 52
    case getCDKey = 53
    case setCDKey = 54
    case rRegisterFont = 55
    case rModelBounds2 = 56
    case pcAddGlobalDefine = 57
    case pcLoadSource = 58
    case pcFreeSource = 59
    case pcReadToken = 60
    case pcSourceFileAndLine = 61
    case sStopBackgroundTrack = 62
    case sStartBackgroundTrack = 63
    case realTime = 64
    case lanGetServerCount = 65
    case lanGetServerAddressString = 66
    case lanGetServerInfo = 67
    case lanMarkServerVisible = 68
    case lanUpdateVisiblePings = 69
    case lanResetPings = 70
    case lanLoadCachedServers = 71
    case lanSaveCachedServers = 72
    case lanAddServer = 73
    case lanRemoveServer = 74
    case cinPlayCinematic = 75
    case cinStopCinematic = 76
    case cinRunCinematic = 77
    case cinDrawCinematic = 78
    case cinSetExtents = 79
    case rRemapShader = 80
    case verifyCDKey = 81
    case lanServerStatus = 82
    case lanGetServerPing = 83
    case lanServerIsVisible = 84
    case lanCompareServers = 85
    case fsSeek = 86
    case setPBClStatus = 87
}

// MARK: - UI Menu Commands

enum UIMenuCommand: Int32 {
    case none = 0
    case main = 1
    case ingame = 2
    case needCD = 3
    case badCDKey = 4
    case team = 5
    case postgame = 6
}

// MARK: - Key Catcher Flags

struct KeyCatcher: OptionSet {
    let rawValue: Int32
    static let console = KeyCatcher(rawValue: 1)
    static let ui = KeyCatcher(rawValue: 2)
    static let message = KeyCatcher(rawValue: 4)
    static let cgame = KeyCatcher(rawValue: 8)
}

// MARK: - UI System

class ClientUI {
    static let shared = ClientUI()

    var uiVM: QVM?
    var initialized = false
    var keyCatcher: Int32 = 0
    var activeMenu: UIMenuCommand = .none
    var overstrikeMode = false
    // Key bindings
    var keyBindings: [Int: String] = [:]
    var keyStates: [Int: Bool] = [:]

    private init() {}

    // MARK: - Initialization

    func initialize() {
        guard !initialized else { return }

        // Load UI QVM
        guard let data = Q3FileSystem.shared.loadFile("vm/ui.qvm") else {
            Q3Console.shared.print("WARNING: Could not load vm/ui.qvm")
            return
        }

        let vm = QVM(name: "ui")
        guard vm.load(from: data) else {
            Q3Console.shared.print("WARNING: Failed to load UI QVM")
            return
        }

        vm.systemCall = { [weak self] args, numArgs, vm in
            return self?.uiSystemCall(args: args, numArgs: numArgs, vm: vm) ?? 0
        }

        uiVM = vm
        initialized = true

        // Call UI_INIT
        let _ = QVMInterpreter.call(vm, command: UIExport.uiInit.rawValue, args: [0])
        Q3Console.shared.print("UI module initialized")
    }

    func shutdown() {
        if let vm = uiVM, initialized {
            let _ = QVMInterpreter.call(vm, command: UIExport.uiShutdown.rawValue, args: [])
        }
        uiVM = nil
        initialized = false
    }

    // MARK: - UI Events

    func keyEvent(_ key: Int32, down: Bool) {
        guard let vm = uiVM, initialized else { return }
        let _ = QVMInterpreter.call(vm, command: UIExport.uiKeyEvent.rawValue, args: [key, down ? 1 : 0])
    }

    func mouseEvent(_ dx: Int32, _ dy: Int32) {
        guard let vm = uiVM, initialized else { return }
        let _ = QVMInterpreter.call(vm, command: UIExport.uiMouseEvent.rawValue, args: [dx, dy])
    }

    func refresh(_ time: Int32) {
        guard let vm = uiVM, initialized else { return }
        let _ = QVMInterpreter.call(vm, command: UIExport.uiRefresh.rawValue, args: [time])
    }

    func isFullscreen() -> Bool {
        guard let vm = uiVM, initialized else { return false }
        return QVMInterpreter.call(vm, command: UIExport.uiIsFullscreen.rawValue, args: []) != 0
    }

    func setActiveMenu(_ menu: UIMenuCommand) {
        guard let vm = uiVM, initialized else { return }
        activeMenu = menu
        let _ = QVMInterpreter.call(vm, command: UIExport.uiSetActiveMenu.rawValue, args: [menu.rawValue])
    }

    func consoleCommand(_ realTime: Int32) -> Bool {
        guard let vm = uiVM, initialized else { return false }
        return QVMInterpreter.call(vm, command: UIExport.uiConsoleCommand.rawValue, args: [realTime]) != 0
    }

    func drawConnectScreen(_ overlay: Bool) {
        guard let vm = uiVM, initialized else { return }
        let _ = QVMInterpreter.call(vm, command: UIExport.uiDrawConnectScreen.rawValue, args: [overlay ? 1 : 0])
    }

    // MARK: - UI Syscall Dispatch

    func uiSystemCall(args: UnsafePointer<Int32>, numArgs: Int, vm: QVM) -> Int32 {
        guard numArgs > 0 else { return 0 }
        let cmd = args[0]

        // Math/memory traps (100-108)
        if cmd >= 100 && cmd <= 108 {
            return handleMathTrap(cmd: cmd, args: args, vm: vm)
        }

        guard let syscall = UIImport(rawValue: cmd) else {
            return 0
        }

        let renderer = ClientMain.shared.rendererAPI

        switch syscall {
        case .error:
            let msg = vm.readString(at: args[1])
            Q3Console.shared.error("UI_ERROR: \(msg)")
            vm.aborted = true
            return -1

        case .print:
            let msg = vm.readString(at: args[1])
            Q3Console.shared.print(msg)
            return 0

        case .milliseconds:
            let ms = (ProcessInfo.processInfo.systemUptime - Q3Engine.shared.engineStartTime) * 1000
            return Int32(Int(ms) & 0x7FFFFFFF)

        case .cvarSet:
            let name = vm.readString(at: args[1])
            let value = vm.readString(at: args[2])
            _ = Q3CVar.shared.set(name, value: value, force: true)
            return 0

        case .cvarVariableValue:
            let name = vm.readString(at: args[1])
            if let cvar = Q3CVar.shared.find(name) {
                return Int32(bitPattern: cvar.value.bitPattern)
            }
            return 0

        case .cvarVariableStringBuffer:
            let name = vm.readString(at: args[1])
            let value = Q3CVar.shared.find(name)?.string ?? ""
            vm.writeString(at: args[2], value, maxLen: Int(args[3]))
            return 0

        case .cvarSetValue:
            let name = vm.readString(at: args[1])
            let fval = Float(bitPattern: UInt32(bitPattern: args[2]))
            _ = Q3CVar.shared.set(name, value: String(fval), force: true)
            return 0

        case .cvarReset:
            let name = vm.readString(at: args[1])
            _ = Q3CVar.shared.set(name, value: "")
            return 0

        case .cvarCreate:
            let name = vm.readString(at: args[1])
            let value = vm.readString(at: args[2])
            _ = Q3CVar.shared.get(name, defaultValue: value, flags: CVarFlags(rawValue: Int(args[3])))
            return 0

        case .cvarInfoStringBuffer:
            vm.writeString(at: args[2], "", maxLen: Int(args[3]))
            return 0

        case .argc:
            return Int32(Q3CommandBuffer.shared.argc)

        case .argv:
            let arg = Q3CommandBuffer.shared.commandArgv(Int(args[1]))
            vm.writeString(at: args[2], arg, maxLen: Int(args[3]))
            return 0

        case .cmdExecuteText:
            let execType = args[1]  // 0=EXEC_NOW, 1=EXEC_INSERT, 2=EXEC_APPEND
            let text = vm.readString(at: args[2])
            Q3Console.shared.print("UI cmdExecuteText(\(execType)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            if execType == 0 {
                // EXEC_NOW: execute immediately
                Q3CommandBuffer.shared.executeString(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if execType == 1 {
                // EXEC_INSERT: insert at front
                Q3CommandBuffer.shared.insertText(text)
            } else {
                // EXEC_APPEND
                Q3CommandBuffer.shared.addText(text)
            }
            return 0

        case .fsOpenFile:
            let path = vm.readString(at: args[1])
            let mode = args[3]
            if mode == 0 { // read
                let result = Q3FileSystem.shared.openFileRead(path)
                if result.handle != 0 {
                    if args[2] != 0 {
                        vm.writeInt32(toData: Int(args[2]), value: result.handle)
                    }
                    return result.length
                }
                return 0
            }
            return 0

        case .fsRead:
            let handle = args[3]
            let count = Int(args[2])
            let destAddr = Int(args[1])
            let tempBuf = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
            defer { tempBuf.deallocate() }
            let bytesRead = Q3FileSystem.shared.readFile(handle: handle, buffer: tempBuf, length: count)
            for i in 0..<bytesRead {
                let byte = tempBuf.load(fromByteOffset: i, as: UInt8.self)
                vm.writeUInt8(toData: destAddr + i, value: byte)
            }
            return 0

        case .fsWrite:
            return 0  // Stub

        case .fsCloseFile:
            Q3FileSystem.shared.closeFile(handle: args[1])
            return 0

        case .fsGetFileList:
            let path = vm.readString(at: args[1])
            let ext = vm.readString(at: args[2])
            let files = Q3FileSystem.shared.listFiles(inDirectory: path, withExtension: ext)
            var offset: Int32 = 0
            var count: Int32 = 0
            let maxSize = args[4]
            for file in files {
                let nameLen = Int32(file.utf8.count + 1)
                if offset + nameLen > maxSize { break }
                vm.writeString(at: args[3] + offset, file, maxLen: Int(nameLen))
                offset += nameLen
                count += 1
            }
            return count

        case .rRegisterModel:
            let name = vm.readString(at: args[1])
            return renderer?.registerModel(name) ?? 0

        case .rRegisterSkin:
            let name = vm.readString(at: args[1])
            return renderer?.registerSkin(name) ?? 0

        case .rRegisterShaderNoMip:
            let name = vm.readString(at: args[1])
            return renderer?.registerShaderNoMip(name) ?? 0

        case .rClearScene:
            renderer?.clearScene()
            return 0

        case .rAddRefEntityToScene:
            renderer?.addRefEntityToScene(vm: vm, addr: args[1])
            return 0

        case .rAddPolyToScene:
            return 0  // Stub

        case .rAddLightToScene:
            let origin = readVec3(vm: vm, at: args[1])
            let intensity = Float(bitPattern: UInt32(bitPattern: args[2]))
            let r = Float(bitPattern: UInt32(bitPattern: args[3]))
            let g = Float(bitPattern: UInt32(bitPattern: args[4]))
            let b = Float(bitPattern: UInt32(bitPattern: args[5]))
            renderer?.addLightToScene(origin: origin, intensity: intensity, r: r, g: g, b: b)
            return 0

        case .rRenderScene:
            renderer?.renderScene(vm: vm, refdefAddr: args[1])
            return 0

        case .rSetColor:
            if args[1] != 0 {
                let a1 = Int(args[1])
                let r = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a1)))
                let g = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a1 + 4)))
                let b = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a1 + 8)))
                let a = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a1 + 12)))
                renderer?.setColor(SIMD4<Float>(r, g, b, a))
            } else {
                renderer?.setColor(nil)
            }
            return 0

        case .rDrawStretchPic:
            let x = Float(bitPattern: UInt32(bitPattern: args[1]))
            let y = Float(bitPattern: UInt32(bitPattern: args[2]))
            let w = Float(bitPattern: UInt32(bitPattern: args[3]))
            let h = Float(bitPattern: UInt32(bitPattern: args[4]))
            let s1 = Float(bitPattern: UInt32(bitPattern: args[5]))
            let t1 = Float(bitPattern: UInt32(bitPattern: args[6]))
            let s2 = Float(bitPattern: UInt32(bitPattern: args[7]))
            let t2 = Float(bitPattern: UInt32(bitPattern: args[8]))
            let shader = args[9]
            renderer?.drawStretchPic(x: x, y: y, w: w, h: h, s1: s1, t1: t1, s2: s2, t2: t2, shader: shader)
            return 0

        case .updateScreen:
            return 0  // Handled by frame loop

        case .cmLerpTag:
            return 0  // Stub

        case .rModelBounds, .rModelBounds2:
            return 0  // Stub

        case .sRegisterSound:
            let name = vm.readString(at: args[1])
            return Q3SoundSystem.shared.registerSound(name)

        case .sStartLocalSound:
            Q3SoundSystem.shared.startLocalSound(args[1], channelNum: Int(args[2]))
            return 0

        case .keyKeynumToStringBuf:
            let keyStr = keyNumToString(Int(args[1]))
            vm.writeString(at: args[2], keyStr, maxLen: Int(args[3]))
            return 0

        case .keyGetBindingBuf:
            let binding = keyBindings[Int(args[1])] ?? ""
            vm.writeString(at: args[2], binding, maxLen: Int(args[3]))
            return 0

        case .keySetBinding:
            let cmd = vm.readString(at: args[2])
            keyBindings[Int(args[1])] = cmd
            return 0

        case .keyIsDown:
            return (keyStates[Int(args[1])] ?? false) ? 1 : 0

        case .keyGetOverstrikeMode:
            return overstrikeMode ? 1 : 0

        case .keySetOverstrikeMode:
            overstrikeMode = args[1] != 0
            return 0

        case .keyClearStates:
            keyStates.removeAll()
            return 0

        case .keyGetCatcher:
            return keyCatcher

        case .keySetCatcher:
            keyCatcher = args[1]
            return 0

        case .getClipboardData:
            vm.writeString(at: args[1], "", maxLen: Int(args[2]))
            return 0

        case .getClientState:
            // Write uiClientState_t
            if args[1] != 0 {
                let a = Int(args[1])
                let cs = ClientMain.shared.state
                vm.writeInt32(toData: a, value: cs.rawValue)
                vm.writeInt32(toData: a + 4, value: 0)                  // connectPacketCount
                vm.writeInt32(toData: a + 8, value: 0)                  // clientNum
                vm.writeString(at: Int32(a + 12), "", maxLen: 1024)     // servername
                vm.writeString(at: Int32(a + 1036), "", maxLen: 256)    // updateInfoString
                vm.writeString(at: Int32(a + 1292), "", maxLen: 256)    // messageString
            }
            return 0

        case .getGLConfig:
            writeGLConfig(vm: vm, at: args[1])
            return 0

        case .getConfigString:
            let str = ClientMain.shared.getConfigString(Int(args[1]))
            vm.writeString(at: args[2], str, maxLen: Int(args[3]))
            return Int32(str.utf8.count)

        case .lanGetPingQueueCount:
            return 0

        case .lanClearPing, .lanResetPings, .lanLoadCachedServers, .lanSaveCachedServers:
            return 0

        case .lanGetPing, .lanGetPingInfo:
            return 0

        case .cvarRegister:
            let name = vm.readString(at: args[2])
            let defaultValue = vm.readString(at: args[3])
            let cvar = Q3CVar.shared.get(name, defaultValue: defaultValue, flags: CVarFlags(rawValue: Int(args[4])))
            if args[1] != 0 {
                ServerMain.shared.writeVMCVar(vm: vm, addr: args[1], cvar: cvar)
            }
            return 0

        case .cvarUpdate:
            return 0

        case .memoryRemaining:
            return 4 * 1024 * 1024

        case .getCDKey:
            vm.writeString(at: args[1], "AAAA-AAAA-AAAA-AAAA", maxLen: Int(args[2]))
            return 0

        case .setCDKey:
            return 0

        case .rRegisterFont:
            // args[1] = fontName, args[2] = pointSize, args[3] = fontInfo_t dest addr
            let fontName = vm.readString(at: args[1])
            let pointSize = args[2]
            registerFont(vm: vm, fontName: fontName, pointSize: pointSize, destAddr: args[3])
            return 0

        case .pcAddGlobalDefine:
            return 0

        case .pcLoadSource:
            return 0

        case .pcFreeSource:
            return 0

        case .pcReadToken:
            return 0

        case .pcSourceFileAndLine:
            return 0

        case .sStopBackgroundTrack:
            Q3MusicPlayer.shared.stopBackgroundTrack()
            return 0

        case .sStartBackgroundTrack:
            let intro = vm.readString(at: args[1])
            let loop = vm.readString(at: args[2])
            Q3MusicPlayer.shared.startBackgroundTrack(intro, loop)
            return 0

        case .realTime:
            if args[1] != 0 {
                let a = Int(args[1])
                let now = Date()
                let calendar = Calendar.current
                let components = calendar.dateComponents([.second, .minute, .hour, .day, .month, .year, .weekday, .dayOfYear], from: now)
                vm.writeInt32(toData: a, value: Int32(components.second ?? 0))
                vm.writeInt32(toData: a + 4, value: Int32(components.minute ?? 0))
                vm.writeInt32(toData: a + 8, value: Int32(components.hour ?? 0))
                vm.writeInt32(toData: a + 12, value: Int32(components.day ?? 1))
                vm.writeInt32(toData: a + 16, value: Int32((components.month ?? 1) - 1))
                vm.writeInt32(toData: a + 20, value: Int32((components.year ?? 2024) - 1900))
                vm.writeInt32(toData: a + 24, value: Int32(components.weekday ?? 0))
                vm.writeInt32(toData: a + 28, value: Int32(components.dayOfYear ?? 0))
                vm.writeInt32(toData: a + 32, value: 0)  // isdst
            }
            return Int32(Date().timeIntervalSince1970)

        case .lanGetServerCount:
            return 0

        case .lanGetServerAddressString, .lanGetServerInfo:
            vm.writeString(at: args[3], "", maxLen: Int(args[4]))
            return 0

        case .lanMarkServerVisible, .lanUpdateVisiblePings:
            return 0

        case .lanAddServer, .lanRemoveServer:
            return 0

        case .cinPlayCinematic, .cinStopCinematic, .cinRunCinematic, .cinDrawCinematic, .cinSetExtents:
            return 0

        case .rRemapShader:
            return 0

        case .verifyCDKey:
            return 1

        case .lanServerStatus:
            return 0

        case .lanGetServerPing:
            return 0

        case .lanServerIsVisible:
            return 1

        case .lanCompareServers:
            return 0

        case .fsSeek:
            return Int32(Q3FileSystem.shared.seekFile(handle: args[1], offset: Int(args[2]), origin: Int(args[3])))

        case .setPBClStatus:
            return 0
        }
    }

    // MARK: - Helpers

    private func handleMathTrap(cmd: Int32, args: UnsafePointer<Int32>, vm: QVM) -> Int32 {
        switch cmd {
        case 100: // memset
            let count = Int(args[3])
            let val = UInt8(truncatingIfNeeded: args[2])
            let dest = Int(args[1])
            for i in 0..<count {
                vm.writeUInt8(toData: dest + i, value: val)
            }
            return args[1]
        case 101: // memcpy
            let count = Int(args[3])
            let src = Int(args[2])
            let dest = Int(args[1])
            for i in 0..<count {
                let byte = vm.readUInt8(fromData: src + i)
                vm.writeUInt8(toData: dest + i, value: byte)
            }
            return args[1]
        case 102: // strncpy
            let src = vm.readString(at: args[2])
            vm.writeString(at: args[1], src, maxLen: Int(args[3]))
            return args[1]
        case 103: // sin
            let v = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: sinf(v).bitPattern)
        case 104: // cos
            let v = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: cosf(v).bitPattern)
        case 105: // atan2
            let y = Float(bitPattern: UInt32(bitPattern: args[1]))
            let x = Float(bitPattern: UInt32(bitPattern: args[2]))
            return Int32(bitPattern: atan2f(y, x).bitPattern)
        case 106: // sqrt
            let v = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: sqrtf(v).bitPattern)
        case 107: // floor
            let v = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: floorf(v).bitPattern)
        case 108: // ceil
            let v = Float(bitPattern: UInt32(bitPattern: args[1]))
            return Int32(bitPattern: ceilf(v).bitPattern)
        default:
            return 0
        }
    }

    private func readVec3(vm: QVM, at addr: Int32) -> Vec3 {
        let a = Int(addr)
        let x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a)))
        let y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 4)))
        let z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 8)))
        return Vec3(x, y, z)
    }

    private func writeGLConfig(vm: QVM, at addr: Int32) {
        let a = Int(addr)
        // glconfig_t layout: see ClientGame.swift writeGLConfig for full documentation
        vm.writeString(at: addr, "Metal 4", maxLen: MAX_STRING_CHARS)
        vm.writeString(at: Int32(a + MAX_STRING_CHARS), "Apple", maxLen: MAX_STRING_CHARS)
        vm.writeString(at: Int32(a + MAX_STRING_CHARS * 2), "1.0", maxLen: MAX_STRING_CHARS)

        let intBase = a + MAX_STRING_CHARS * 3 + BIG_INFO_STRING  // +11264
        vm.writeInt32(toData: intBase + 0, value: 4096)   // maxTextureSize
        vm.writeInt32(toData: intBase + 4, value: 8)      // maxActiveTextures
        vm.writeInt32(toData: intBase + 8, value: 32)     // colorBits
        vm.writeInt32(toData: intBase + 12, value: 32)    // depthBits
        vm.writeInt32(toData: intBase + 16, value: 8)     // stencilBits
        vm.writeInt32(toData: intBase + 20, value: 0)     // driverType
        vm.writeInt32(toData: intBase + 24, value: 0)     // hardwareType
        vm.writeInt32(toData: intBase + 28, value: 0)     // deviceSupportsGamma
        vm.writeInt32(toData: intBase + 32, value: 0)     // textureCompression
        vm.writeInt32(toData: intBase + 36, value: 1)     // textureEnvAddAvailable
        vm.writeInt32(toData: intBase + 40, value: 640)   // vidWidth  (Q3 virtual screen)
        vm.writeInt32(toData: intBase + 44, value: 480)   // vidHeight (Q3 virtual screen)
        vm.writeInt32(toData: intBase + 48, value: Int32(bitPattern: Float(4.0/3.0).bitPattern)) // windowAspect
        vm.writeInt32(toData: intBase + 52, value: 120)   // displayFrequency
        vm.writeInt32(toData: intBase + 56, value: 0)     // isFullscreen
        vm.writeInt32(toData: intBase + 60, value: 0)     // stereoEnabled
        vm.writeInt32(toData: intBase + 64, value: 0)     // smpActive
    }

    // MARK: - Font Registration

    /// Load a Q3 font .dat file and write fontInfo_t struct to VM memory
    /// Font .dat layout: 256 x glyphInfo_t (76 bytes each) + glyphScale(4) + name(64)
    /// glyphInfo_t: height(4) top(4) bottom(4) pitch(4) xSkip(4) imageWidth(4) imageHeight(4)
    ///              s(4) t(4) s2(4) t2(4) glyph/shaderHandle(4) shaderName(32) = 76 bytes
    private func registerFont(vm: QVM, fontName: String, pointSize: Int32, destAddr: Int32) {
        let path = "fonts/\(fontName)_\(pointSize).dat"
        guard let data = Q3FileSystem.shared.loadFile(path) else {
            Q3Console.shared.warning("Font not found: \(path)")
            return
        }

        let glyphSize = 76
        let glyphCount = 256
        let expectedMin = glyphSize * glyphCount  // 19456 minimum

        guard data.count >= expectedMin else {
            Q3Console.shared.warning("Font file too small: \(path) (\(data.count) bytes)")
            return
        }

        let renderer = ClientMain.shared.rendererAPI
        let dest = Int(destAddr)

        data.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.baseAddress!

            for i in 0..<glyphCount {
                let glyphOffset = i * glyphSize
                let outOffset = dest + i * glyphSize

                // Copy first 44 bytes (11 int32 fields: height through t2)
                for f in 0..<11 {
                    let val = ptr.load(fromByteOffset: glyphOffset + f * 4, as: Int32.self)
                    vm.writeInt32(toData: outOffset + f * 4, value: val)
                }

                // Read shader name (32 bytes at offset 44 within glyph)
                let nameOffset = glyphOffset + 44
                var nameBytes: [UInt8] = []
                for b in 0..<32 {
                    let byte = ptr.load(fromByteOffset: nameOffset + b, as: UInt8.self)
                    if byte == 0 { break }
                    nameBytes.append(byte)
                }
                let shaderName = String(bytes: nameBytes, encoding: .utf8) ?? ""

                // Register the glyph's shader
                var shaderHandle: Int32 = 0
                if !shaderName.isEmpty {
                    shaderHandle = renderer?.registerShaderNoMip(shaderName) ?? 0
                }

                // Write shader handle at offset 44 (glyph field) in output
                vm.writeInt32(toData: outOffset + 44, value: shaderHandle)

                // Write shader name string (32 bytes) at offset 48
                vm.writeString(at: Int32(outOffset + 48), shaderName, maxLen: 32)
            }

            // Copy glyphScale (float at offset 19456)
            if data.count >= expectedMin + 4 {
                let scale = ptr.load(fromByteOffset: expectedMin, as: Int32.self)
                vm.writeInt32(toData: dest + expectedMin, value: scale)
            }

            // Copy name (64 bytes at offset 19460)
            if data.count >= expectedMin + 4 + 64 {
                let nameStart = expectedMin + 4
                var fontNameBytes: [UInt8] = []
                for b in 0..<64 {
                    let byte = ptr.load(fromByteOffset: nameStart + b, as: UInt8.self)
                    if byte == 0 { break }
                    fontNameBytes.append(byte)
                }
                let name = String(bytes: fontNameBytes, encoding: .utf8) ?? ""
                vm.writeString(at: Int32(dest + nameStart), name, maxLen: 64)
            }
        }

        Q3Console.shared.print("Registered font: \(path)")
    }

    private func keyNumToString(_ keynum: Int) -> String {
        switch keynum {
        case 13: return "ENTER"
        case 27: return "ESCAPE"
        case 32: return "SPACE"
        case 127: return "BACKSPACE"
        case 0..<32: return "CTRL+\(Character(UnicodeScalar(keynum + 64)!))"
        default:
            if keynum >= 32 && keynum < 127 {
                return String(Character(UnicodeScalar(keynum)!))
            }
            return "KEY\(keynum)"
        }
    }
}
