// Q3Types.swift — Core Quake III Arena data types

import simd

// MARK: - Vector type alias
typealias Vec3 = SIMD3<Float>

// MARK: - Trajectory

enum TrajectoryType: Int32 {
    case stationary = 0
    case interpolate
    case linear
    case linearStop
    case sine
    case gravity
}

struct Trajectory {
    var trType: TrajectoryType = .stationary
    var trTime: Int32 = 0
    var trDuration: Int32 = 0
    var trBase: Vec3 = .zero
    var trDelta: Vec3 = .zero
}

// MARK: - Entity State

struct EntityState {
    var number: Int32 = 0
    var eType: Int32 = 0
    var eFlags: Int32 = 0

    var pos: Trajectory = Trajectory()
    var apos: Trajectory = Trajectory()

    var time: Int32 = 0
    var time2: Int32 = 0

    var origin: Vec3 = .zero
    var origin2: Vec3 = .zero

    var angles: Vec3 = .zero
    var angles2: Vec3 = .zero

    var otherEntityNum: Int32 = 0
    var otherEntityNum2: Int32 = 0

    var groundEntityNum: Int32 = Int32(ENTITYNUM_NONE)

    var constantLight: Int32 = 0
    var loopSound: Int32 = 0

    var modelindex: Int32 = 0
    var modelindex2: Int32 = 0
    var clientNum: Int32 = 0
    var frame: Int32 = 0

    var solid: Int32 = 0

    var event: Int32 = 0
    var eventParm: Int32 = 0

    var powerups: Int32 = 0
    var weapon: Int32 = 0
    var legsAnim: Int32 = 0
    var torsoAnim: Int32 = 0

    var generic1: Int32 = 0
}

// MARK: - Player State

struct PlayerState {
    var commandTime: Int32 = 0
    var pm_type: Int32 = 0
    var bobCycle: Int32 = 0
    var pm_flags: Int32 = 0
    var pm_time: Int32 = 0

    var origin: Vec3 = .zero
    var velocity: Vec3 = .zero
    var weaponTime: Int32 = 0
    var gravity: Int32 = 0
    var speed: Int32 = 0
    var delta_angles: SIMD3<Int32> = .zero

    var groundEntityNum: Int32 = Int32(ENTITYNUM_NONE)

    var legsTimer: Int32 = 0
    var legsAnim: Int32 = 0
    var torsoTimer: Int32 = 0
    var torsoAnim: Int32 = 0

    var movementDir: Int32 = 0
    var grapplePoint: Vec3 = .zero

    var eFlags: Int32 = 0

    var eventSequence: Int32 = 0
    var events: (Int32, Int32) = (0, 0)
    var eventParms: (Int32, Int32) = (0, 0)

    var externalEvent: Int32 = 0
    var externalEventParm: Int32 = 0
    var externalEventTime: Int32 = 0

    var clientNum: Int32 = 0
    var weapon: Int32 = 0
    var weaponstate: Int32 = 0

    var viewangles: Vec3 = .zero
    var viewheight: Int32 = 0

    var damageEvent: Int32 = 0
    var damageYaw: Int32 = 0
    var damagePitch: Int32 = 0
    var damageCount: Int32 = 0

    var stats: [Int32] = Array(repeating: 0, count: MAX_STATS)
    var persistant: [Int32] = Array(repeating: 0, count: MAX_PERSISTANT)
    var powerups: [Int32] = Array(repeating: 0, count: MAX_POWERUPS)
    var ammo: [Int32] = Array(repeating: 0, count: MAX_WEAPONS)

    var generic1: Int32 = 0
    var loopSound: Int32 = 0
    var jumppad_ent: Int32 = 0

    var ping: Int32 = 0
    var pmove_framecount: Int32 = 0
    var jumppad_frame: Int32 = 0
    var entityEventSequence: Int32 = 0
}

// MARK: - User Command

struct UserCmd {
    var serverTime: Int32 = 0
    var angles: SIMD3<Int32> = .zero
    var buttons: Int32 = 0
    var weapon: UInt8 = 0
    var forwardmove: Int8 = 0
    var rightmove: Int8 = 0
    var upmove: Int8 = 0
}

// MARK: - Game State

struct GameState {
    var stringOffsets: [Int32] = Array(repeating: 0, count: MAX_CONFIGSTRINGS)
    var stringData: [UInt8] = Array(repeating: 0, count: MAX_GAMESTATE_CHARS)
    var dataCount: Int32 = 0
}

// MARK: - Connection State

enum ConnectionState: Int32 {
    case uninitialized = 0
    case disconnected
    case authorizing
    case connecting
    case challenging
    case connected
    case loading
    case primed
    case active
    case cinematic
}

// MARK: - Trace Result

struct TraceResult {
    var allsolid: Bool = false
    var startsolid: Bool = false
    var fraction: Float = 1.0
    var endpos: Vec3 = .zero
    var plane: TracePlane = TracePlane()
    var surfaceFlags: Int32 = 0
    var contents: Int32 = 0
    var entityNum: Int32 = Int32(ENTITYNUM_NONE)
}

struct TracePlane {
    var normal: Vec3 = .zero
    var dist: Float = 0
    var type: Int32 = 0
    var signbits: Int32 = 0
}

// MARK: - VM CVar (for QVM interface)

struct VMCVar {
    var handle: Int32 = 0
    var modificationCount: Int32 = 0
    var value: Float = 0
    var integer: Int32 = 0
    var string: String = ""
}

// MARK: - Orientation

struct Orientation {
    var origin: Vec3 = .zero
    var axis: (Vec3, Vec3, Vec3) = (.init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1))
}

// MARK: - Entity Type

enum EntityType: Int32 {
    case general = 0
    case player
    case item
    case missile
    case mover
    case beam
    case portal
    case speaker
    case pushTrigger
    case teleportTrigger
    case invisible
    case grapple
    case team
    case events = 99
}

// MARK: - pmtype_t

enum PMType: Int32 {
    case normal = 0
    case noclip
    case spectator
    case dead
    case freeze
    case intermission
    case spintermission
}
