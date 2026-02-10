// QVMTypes.swift — QVM opcode enum, VM structure definitions

import Foundation

// MARK: - QVM Opcodes

enum QVMOpcode: UInt8 {
    case undef       = 0
    case ignore      = 1
    case breakOp     = 2
    case enter       = 3   // 4-byte operand: locals size
    case leave       = 4   // 4-byte operand: locals size
    case call        = 5   // call function or syscall
    case push        = 6
    case pop         = 7
    case const_      = 8   // 4-byte operand: constant value
    case local       = 9   // 4-byte operand: local offset
    case jump        = 10

    // Integer comparisons (4-byte operand: jump target)
    case eq          = 11
    case ne          = 12
    case lti         = 13  // signed <
    case lei         = 14  // signed <=
    case gti         = 15  // signed >
    case gei         = 16  // signed >=
    case ltu         = 17  // unsigned <
    case leu         = 18  // unsigned <=
    case gtu         = 19  // unsigned >
    case geu         = 20  // unsigned >=

    // Float comparisons (4-byte operand: jump target)
    case eqf         = 21
    case nef         = 22
    case ltf         = 23
    case lef         = 24
    case gtf         = 25
    case gef         = 26

    // Memory operations
    case load1       = 27  // load 1 byte
    case load2       = 28  // load 2 bytes
    case load4       = 29  // load 4 bytes
    case store1      = 30  // store 1 byte
    case store2      = 31  // store 2 bytes
    case store4      = 32  // store 4 bytes
    case arg         = 33  // 1-byte operand: param stack offset
    case blockCopy   = 34  // 4-byte operand: copy size

    // Sign extension
    case sex8        = 35
    case sex16       = 36

    // Integer arithmetic
    case negi        = 37
    case add         = 38
    case sub         = 39
    case divi        = 40  // signed
    case divu        = 41  // unsigned
    case modi        = 42  // signed modulo
    case modu        = 43  // unsigned modulo
    case muli        = 44  // signed multiply
    case mulu        = 45  // unsigned multiply

    // Bitwise
    case band        = 46
    case bor         = 47
    case bxor        = 48
    case bcom        = 49  // bitwise complement

    // Shifts
    case lsh         = 50  // left shift
    case rshi        = 51  // right shift signed
    case rshu        = 52  // right shift unsigned

    // Float arithmetic
    case negf        = 53
    case addf        = 54
    case subf        = 55
    case divf        = 56
    case mulf        = 57

    // Type conversion
    case cvif        = 58  // int to float
    case cvfi        = 59  // float to int

    var debugName: String {
        switch self {
        case .undef: return "UNDEF"; case .ignore: return "IGNORE"; case .breakOp: return "BREAK"
        case .enter: return "ENTER"; case .leave: return "LEAVE"; case .call: return "CALL"
        case .push: return "PUSH"; case .pop: return "POP"; case .const_: return "CONST"
        case .local: return "LOCAL"; case .jump: return "JUMP"
        case .eq: return "EQ"; case .ne: return "NE"
        case .lti: return "LTI"; case .lei: return "LEI"; case .gti: return "GTI"; case .gei: return "GEI"
        case .ltu: return "LTU"; case .leu: return "LEU"; case .gtu: return "GTU"; case .geu: return "GEU"
        case .eqf: return "EQF"; case .nef: return "NEF"
        case .ltf: return "LTF"; case .lef: return "LEF"; case .gtf: return "GTF"; case .gef: return "GEF"
        case .load1: return "LOAD1"; case .load2: return "LOAD2"; case .load4: return "LOAD4"
        case .store1: return "STORE1"; case .store2: return "STORE2"; case .store4: return "STORE4"
        case .arg: return "ARG"; case .blockCopy: return "BCOPY"
        case .sex8: return "SEX8"; case .sex16: return "SEX16"
        case .negi: return "NEGI"; case .add: return "ADD"; case .sub: return "SUB"
        case .divi: return "DIVI"; case .divu: return "DIVU"
        case .modi: return "MODI"; case .modu: return "MODU"
        case .muli: return "MULI"; case .mulu: return "MULU"
        case .band: return "BAND"; case .bor: return "BOR"; case .bxor: return "BXOR"; case .bcom: return "BCOM"
        case .lsh: return "LSH"; case .rshi: return "RSHI"; case .rshu: return "RSHU"
        case .negf: return "NEGF"; case .addf: return "ADDF"; case .subf: return "SUBF"
        case .divf: return "DIVF"; case .mulf: return "MULF"
        case .cvif: return "CVIF"; case .cvfi: return "CVFI"
        }
    }

    // Does this opcode have a 4-byte operand?
    var has4ByteOperand: Bool {
        switch self {
        case .enter, .leave, .const_, .local,
             .eq, .ne, .lti, .lei, .gti, .gei,
             .ltu, .leu, .gtu, .geu,
             .eqf, .nef, .ltf, .lef, .gtf, .gef,
             .blockCopy:
            return true
        default:
            return false
        }
    }

    // Does this opcode have a 1-byte operand?
    var has1ByteOperand: Bool {
        return self == .arg
    }
}

// MARK: - QVM Header

let QVM_MAGIC: UInt32 = 0x12721444
let QVM_STACK_SIZE = 0x20000  // 128KB stack

struct QVMHeader {
    let vmMagic: UInt32
    let instructionCount: Int32
    let codeOffset: Int32
    let codeLength: Int32
    let dataOffset: Int32
    let dataLength: Int32
    let litLength: Int32       // Literal data (subset of dataLength)
    let bssLength: Int32       // Uninitialized data (zero-filled)
}

// MARK: - Game Module Exports

enum GameExport: Int32 {
    case gameInit                 = 0   // (levelTime, randomSeed, restart)
    case gameShutdown             = 1
    case gameClientConnect        = 2   // (clientNum, firstTime, isBot) -> string
    case gameClientBegin          = 3   // (clientNum)
    case gameClientUserinfoChanged = 4  // (clientNum)
    case gameClientDisconnect     = 5   // (clientNum)
    case gameClientCommand        = 6   // (clientNum)
    case gameClientThink          = 7   // (clientNum)
    case gameRunFrame             = 8   // (levelTime)
    case gameConsoleCommand       = 9
    case botAIStartFrame          = 10  // (time)
}

// MARK: - Game Import (Syscalls)

enum GameImport: Int32 {
    case gPrint                   = 0
    case gError                   = 1
    case gMilliseconds            = 2
    case gCvarRegister            = 3
    case gCvarUpdate              = 4
    case gCvarSet                 = 5
    case gCvarVariableIntegerValue = 6
    case gCvarVariableStringBuffer = 7
    case gArgc                    = 8
    case gArgv                    = 9
    case gFSFopenFile             = 10
    case gFSRead                  = 11
    case gFSWrite                 = 12
    case gFSFcloseFile            = 13
    case gSendConsoleCommand      = 14
    case gLocateGameData          = 15
    case gDropClient              = 16
    case gSendServerCommand       = 17
    case gSetConfigstring         = 18
    case gGetConfigstring         = 19
    case gGetUserinfo             = 20
    case gSetUserinfo             = 21
    case gGetServerinfo           = 22
    case gSetBrushModel           = 23
    case gTrace                   = 24
    case gPointContents           = 25
    case gInPVS                   = 26
    case gInPVSIgnorePortals      = 27
    case gAdjustAreaPortalState   = 28
    case gAreasConnected          = 29
    case gLinkEntity              = 30
    case gUnlinkEntity            = 31
    case gEntitiesInBox           = 32
    case gEntityContact           = 33
    case gBotAllocateClient       = 34
    case gBotFreeClient           = 35
    case gGetUsercmd              = 36
    case gGetEntityToken          = 37
    case gFSGetFileList           = 38
    case gDebugPolygonCreate      = 39
    case gDebugPolygonDelete      = 40
    case gRealTime                = 41
    case gSnapVector              = 42
    case gTraceCapsule            = 43
    case gEntityContactCapsule    = 44
    case gFSSeek                  = 45

    // Bot library syscalls start at 200 (must match g_syscalls.asm)
    case botlibSetup              = 200
    case botlibShutdown           = 201
    case botlibVarSet             = 202
    case botlibVarGet             = 203
    case botlibDefine             = 204
    case botlibStartFrame         = 205
    case botlibLoadMap            = 206

    // Memory/Math traps (must match g_syscalls.asm ordering)
    case trapMemset               = 100
    case trapMemcpy               = 101
    case trapStrncpy              = 102
    case trapSin                  = 103
    case trapCos                  = 104
    case trapAtan2                = 105
    case trapSqrt                 = 106
    case trapMatrixMultiply       = 107
    case trapAngleVectors         = 108
    case trapPerpendicularVector  = 109
    case trapFloor                = 110
    case trapCeil                 = 111
    case trapTestPrintInt         = 112
    case trapTestPrintFloat       = 113
    case trapAcos                 = 114
}

// MARK: - CGame Exports

enum CGExport: Int32 {
    case cgInit                    = 0   // (serverMessageNum, serverCommandSequence, clientNum)
    case cgShutdown                = 1
    case cgConsoleCommand          = 2
    case cgDrawActiveFrame         = 3   // (serverTime, stereoView, demoPlayback)
    case cgCrosshairPlayer         = 4
    case cgLastAttacker            = 5
    case cgKeyEvent                = 6   // (key, down)
    case cgMouseEvent              = 7   // (dx, dy)
    case cgEventHandling           = 8
}

// MARK: - CGame Imports (Syscalls)

enum CGImport: Int32 {
    // Must match cg_syscalls.asm ordering exactly
    case cgPrint                   = 0
    case cgError                   = 1
    case cgMilliseconds            = 2
    case cgCvarRegister            = 3
    case cgCvarUpdate              = 4
    case cgCvarSet                 = 5
    case cgCvarVariableStringBuffer = 6
    case cgArgc                    = 7
    case cgArgv                    = 8
    case cgArgs                    = 9
    case cgFSFopenFile             = 10
    case cgFSRead                  = 11
    case cgFSWrite                 = 12
    case cgFSFcloseFile            = 13
    case cgSendConsoleCommand      = 14
    case cgAddCommand              = 15
    case cgSendClientCommand       = 16
    case cgUpdateScreen            = 17
    case cgCmLoadMap               = 18
    case cgCmNumInlineModels       = 19
    case cgCmInlineModel           = 20
    case cgCmLoadModel             = 21
    case cgCmTempBoxModel          = 22
    case cgCmPointContents         = 23
    case cgCmTransformedPointContents = 24
    case cgCmBoxTrace              = 25
    case cgCmTransformedBoxTrace   = 26
    case cgCmMarkFragments         = 27

    // Sound
    case cgSStartSound             = 28
    case cgSStartLocalSound        = 29
    case cgSClearLoopingSounds     = 30
    case cgSAddLoopingSound        = 31
    case cgSUpdateEntityPosition   = 32
    case cgSRespatialize           = 33
    case cgSRegisterSound          = 34
    case cgSStartBackgroundTrack   = 35

    // Renderer
    case cgRLoadWorldMap           = 36
    case cgRRegisterModel          = 37
    case cgRRegisterSkin           = 38
    case cgRRegisterShader         = 39
    case cgRClearScene             = 40
    case cgRAddRefEntityToScene    = 41
    case cgRAddPolyToScene         = 42
    case cgRAddLightToScene        = 43
    case cgRRenderScene            = 44
    case cgRSetColor               = 45
    case cgRDrawStretchPic         = 46
    case cgRModelBounds            = 47
    case cgRLerpTag                = 48

    // Game State
    case cgGetGlconfig             = 49
    case cgGetGameState            = 50
    case cgGetCurrentSnapshotNumber = 51
    case cgGetSnapshot             = 52
    case cgGetServerCommand        = 53
    case cgGetCurrentCmdNumber     = 54
    case cgGetUserCmd              = 55
    case cgSetUserCmdValue         = 56
    case cgRRegisterShaderNoMip    = 57
    case cgMemoryRemaining         = 58
    case cgRRegisterFont           = 59

    // Keys
    case cgKeyIsDown               = 60
    case cgKeyGetCatcher           = 61
    case cgKeySetCatcher           = 62
    case cgKeyGetKey               = 63

    // Script parsing
    case cgPCAddGlobalDefine       = 64
    case cgPCLoadSource            = 65
    case cgPCFreeSource            = 66
    case cgPCReadToken             = 67
    case cgPCSourceFileAndLine     = 68

    case cgSStopBackgroundTrack    = 69
    case cgRealTime                = 70
    case cgSnapVector              = 71
    case cgRemoveCommand           = 72
    case cgRLightForPoint          = 73

    // Cinematic
    case cgCinPlayCinematic        = 74
    case cgCinStopCinematic        = 75
    case cgCinRunCinematic         = 76
    case cgCinDrawCinematic        = 77
    case cgCinSetExtents           = 78

    case cgRRemapShader            = 79
    case cgSAddRealLoopingSound    = 80
    case cgSStopLoopingSound       = 81
    case cgCmTempCapsuleModel      = 82
    case cgCmCapsuleTrace          = 83
    case cgCmTransformedCapsuleTrace = 84
    case cgRAddAdditiveLightToScene = 85
    case cgGetEntityToken          = 86
    case cgRAddPolysToScene        = 87
    case cgRInPVS                  = 88
    case cgFSSeek                  = 89

    // Memory/Math traps (must match cg_syscalls.asm ordering)
    case cgMemset                  = 100
    case cgMemcpy                  = 101
    case cgStrncpy                 = 102
    case cgSin                     = 103
    case cgCos                     = 104
    case cgAtan2                   = 105
    case cgSqrt                    = 106
    case cgFloor                   = 107
    case cgCeil                    = 108
    case cgTestPrintInt            = 109
    case cgTestPrintFloat          = 110
    case cgAcos                    = 111
}

// MARK: - UI Exports

enum UIExport: Int32 {
    case uiGetApiVersion           = 0
    case uiInit                    = 1
    case uiShutdown                = 2
    case uiKeyEvent                = 3
    case uiMouseEvent              = 4
    case uiRefresh                 = 5
    case uiIsFullscreen            = 6
    case uiSetActiveMenu           = 7
    case uiConsoleCommand          = 8
    case uiDrawConnectScreen       = 9
}

// MARK: - Server Entity Flags

struct SVFlags: OptionSet {
    let rawValue: Int32

    static let noClient           = SVFlags(rawValue: 0x00000001)
    static let clientMask         = SVFlags(rawValue: 0x00000002)
    static let bot                = SVFlags(rawValue: 0x00000008)
    static let broadcast          = SVFlags(rawValue: 0x00000020)
    static let portal             = SVFlags(rawValue: 0x00000040)
    static let useCurrentOrigin   = SVFlags(rawValue: 0x00000080)
    static let singleClient       = SVFlags(rawValue: 0x00000100)
    static let noServerInfo       = SVFlags(rawValue: 0x00000200)
    static let capsule            = SVFlags(rawValue: 0x00000400)
    static let notSingleClient    = SVFlags(rawValue: 0x00000800)
}

// MARK: - Server State

enum ServerState: Int32 {
    case dead     = 0
    case loading  = 1
    case game     = 2
}

// MARK: - Client State (Server-side)

enum SVClientState: Int32, Comparable {
    case free       = 0
    case zombie     = 1
    case connected  = 2
    case primed     = 3
    case active     = 4

    static func < (lhs: SVClientState, rhs: SVClientState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Shared Entity

struct EntityShared {
    var linked: Bool = false
    var linkCount: Int32 = 0
    var svFlags: Int32 = 0
    var singleClient: Int32 = 0
    var bmodel: Bool = false
    var mins: Vec3 = .zero
    var maxs: Vec3 = .zero
    var contents: Int32 = 0
    var absmin: Vec3 = .zero
    var absmax: Vec3 = .zero
    var currentOrigin: Vec3 = .zero
    var currentAngles: Vec3 = .zero
    var ownerNum: Int32 = Int32(ENTITYNUM_NONE)
}

struct SharedEntity {
    var s: EntityState
    var r: EntityShared

    init() {
        self.s = EntityState()
        self.r = EntityShared()
    }
}

// MARK: - SVEntity (server-side bookkeeping per entity)

class SVEntity {
    var worldSectorIndex: Int = -1
    var nextEntityInSector: Int = -1      // Entity number or -1

    var baseline: EntityState = EntityState()
    var numClusters: Int = 0
    var clusterNums: [Int] = Array(repeating: 0, count: 16)
    var lastCluster: Int = 0
    var areaNum: Int = 0
    var areaNum2: Int = 0
    var snapshotCounter: Int = 0
}

// MARK: - World Sector (for SV_LinkEntity spatial partitioning)

class WorldSector {
    var axis: Int = -1           // -1 = leaf
    var dist: Float = 0
    var children: [Int] = [-1, -1]  // Indices into worldSectors array
    var entities: Int = -1       // First entity number in linked list, -1 = none
}
