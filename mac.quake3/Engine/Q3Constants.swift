// Q3Constants.swift — Quake III Arena constants

import Foundation

// Protocol version
let PROTOCOL_VERSION: Int32 = 68

// Per-level limits
let MAX_CLIENTS: Int = 64
let MAX_LOCATIONS: Int = 64
let GENTITYNUM_BITS: Int = 10
let MAX_GENTITIES: Int = 1 << GENTITYNUM_BITS  // 1024
let ENTITYNUM_NONE: Int = MAX_GENTITIES - 1
let ENTITYNUM_WORLD: Int = MAX_GENTITIES - 2
let ENTITYNUM_MAX_NORMAL: Int = MAX_GENTITIES - 2

let MAX_MODELS: Int = 256
let MAX_SOUNDS: Int = 256
let MAX_CONFIGSTRINGS: Int = 1024

// Config string indices
let CS_SERVERINFO: Int = 0
let CS_SYSTEMINFO: Int = 1
let RESERVED_CONFIGSTRINGS: Int = 2
let CS_MUSIC: Int = 2
let CS_MESSAGE: Int = 3
let CS_MOTD: Int = 4
let CS_WARMUP: Int = 5
let CS_SCORES1: Int = 6
let CS_SCORES2: Int = 7
let CS_VOTE_TIME: Int = 8
let CS_VOTE_STRING: Int = 9
let CS_VOTE_YES: Int = 10
let CS_VOTE_NO: Int = 11
let CS_GAME_VERSION: Int = 12
let CS_LEVEL_START_TIME: Int = 13
let CS_INTERMISSION: Int = 14
let CS_FLAGSTATUS: Int = 15
let CS_SHADERSTATE: Int = 16
let CS_BOTINFO: Int = 17
let CS_ITEMS: Int = 27
let CS_MODELS: Int = 32
let CS_SOUNDS: Int = CS_MODELS + MAX_MODELS       // 288
let CS_PLAYERS: Int = CS_SOUNDS + MAX_SOUNDS       // 544
let CS_LOCATIONS: Int = CS_PLAYERS + MAX_CLIENTS   // 608

let MAX_GAMESTATE_CHARS: Int = 16000

// Player state array limits
let MAX_STATS: Int = 16
let MAX_PERSISTANT: Int = 16
let MAX_POWERUPS: Int = 16
let MAX_WEAPONS: Int = 16
let MAX_PS_EVENTS: Int = 2

// String limits
let MAX_STRING_CHARS: Int = 1024
let MAX_STRING_TOKENS: Int = 1024
let MAX_TOKEN_CHARS: Int = 1024
let MAX_INFO_STRING: Int = 1024
let BIG_INFO_STRING: Int = 8192
let MAX_QPATH: Int = 64
let MAX_OSPATH: Int = 256
let MAX_NAME_LENGTH: Int = 32

// Button flags
let BUTTON_ATTACK: Int = 1
let BUTTON_TALK: Int = 2
let BUTTON_USE_HOLDABLE: Int = 4
let BUTTON_GESTURE: Int = 8
let BUTTON_WALKING: Int = 16
let BUTTON_AFFIRMATIVE: Int = 32
let BUTTON_NEGATIVE: Int = 64
let BUTTON_GETFLAG: Int = 128
let BUTTON_GUARDBASE: Int = 256
let BUTTON_PATROL: Int = 512
let BUTTON_FOLLOWME: Int = 1024
let BUTTON_ANY: Int = 2048
let MOVE_RUN: Int = 120

// Entity solid
let SOLID_BMODEL: Int32 = 0xffffff

// Angle encoding
func ANGLE2SHORT(_ x: Float) -> Int {
    return Int((x * 65536.0 / 360.0)) & 65535
}

func SHORT2ANGLE(_ x: Int) -> Float {
    return Float(x) * (360.0 / 65536.0)
}

// CVar flags
struct CVarFlags: OptionSet {
    let rawValue: Int
    static let archive     = CVarFlags(rawValue: 1)
    static let userInfo    = CVarFlags(rawValue: 2)
    static let serverInfo  = CVarFlags(rawValue: 4)
    static let systemInfo  = CVarFlags(rawValue: 8)
    static let initOnly    = CVarFlags(rawValue: 16)
    static let latch       = CVarFlags(rawValue: 32)
    static let rom         = CVarFlags(rawValue: 64)
    static let userCreated = CVarFlags(rawValue: 128)
    static let temp        = CVarFlags(rawValue: 256)
    static let cheat       = CVarFlags(rawValue: 512)
    static let noRestart   = CVarFlags(rawValue: 1024)
}

// Snapshot flags
let SNAPFLAG_RATE_DELAYED: Int = 1
let SNAPFLAG_NOT_ACTIVE: Int = 2
let SNAPFLAG_SERVERCOUNT: Int = 4

// Contents flags (for traces)
let CONTENTS_SOLID: Int32 = 1
let CONTENTS_LAVA: Int32 = 8
let CONTENTS_SLIME: Int32 = 16
let CONTENTS_WATER: Int32 = 32
let CONTENTS_FOG: Int32 = 64
let CONTENTS_PLAYERCLIP: Int32 = 0x10000
let CONTENTS_MONSTERCLIP: Int32 = 0x20000
let CONTENTS_TELEPORTER: Int32 = 0x40000
let CONTENTS_JUMPPAD: Int32 = 0x80000
let CONTENTS_CLUSTERPORTAL: Int32 = 0x100000
let CONTENTS_DONOTENTER: Int32 = 0x200000
let CONTENTS_BODY: Int32 = 0x2000000
let CONTENTS_CORPSE: Int32 = 0x4000000
let CONTENTS_DETAIL: Int32 = 0x8000000
let CONTENTS_STRUCTURAL: Int32 = 0x10000000
let CONTENTS_TRANSLUCENT: Int32 = 0x20000000
let CONTENTS_TRIGGER: Int32 = 0x40000000
let CONTENTS_NODROP: Int32 = Int32(bitPattern: 0x80000000)

// Surface flags
let SURF_NODAMAGE: Int32 = 0x1
let SURF_SLICK: Int32 = 0x2
let SURF_SKY: Int32 = 0x4
let SURF_LADDER: Int32 = 0x8
let SURF_NOIMPACT: Int32 = 0x10
let SURF_NOMARKS: Int32 = 0x20
let SURF_FLESH: Int32 = 0x40
let SURF_NODRAW: Int32 = 0x80
let SURF_HINT: Int32 = 0x100
let SURF_SKIP: Int32 = 0x200
let SURF_NOLIGHTMAP: Int32 = 0x400
let SURF_POINTLIGHT: Int32 = 0x800
let SURF_METALSTEPS: Int32 = 0x1000
let SURF_NOSTEPS: Int32 = 0x2000
let SURF_NONSOLID: Int32 = 0x4000
let SURF_LIGHTFILTER: Int32 = 0x8000
let SURF_ALPHASHADOW: Int32 = 0x10000
let SURF_NODLIGHT: Int32 = 0x20000
