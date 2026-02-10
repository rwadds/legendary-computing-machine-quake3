// BotAI.swift — AI behavior (goal selection, weapon choice, movement, character traits)

import Foundation
import simd

class BotAI {
    static let shared = BotAI()

    // Bot states keyed by client number
    var botStates: [Int: BotState] = [:]

    // AI module handles
    var nextCharacterHandle: Int32 = 1
    var nextChatHandle: Int32 = 1
    var nextMoveHandle: Int32 = 1
    var nextWeaponHandle: Int32 = 1
    var nextGoalHandle: Int32 = 1

    // Character traits (indexed by handle)
    var characters: [Int32: BotCharacter] = [:]

    private init() {}

    func shutdown() {
        botStates.removeAll()
        characters.removeAll()
    }

    // MARK: - Bot State Management

    func getBotState(_ clientNum: Int) -> BotState? {
        return botStates[clientNum]
    }

    func createBotState(_ clientNum: Int) -> BotState {
        let state = BotState(clientNum: clientNum)
        botStates[clientNum] = state
        return state
    }

    func removeBotState(_ clientNum: Int) {
        botStates.removeValue(forKey: clientNum)
    }

    // MARK: - AI Syscalls (500+)

    func handleSyscall(cmd: Int32, args: [Int32], vm: QVM) -> Int32 {
        switch cmd {
        // Character traits (500-506)
        case 500: // AI_LOAD_CHARACTER
            let name = vm.readString(at: args[1])
            let skill = Float(bitPattern: UInt32(bitPattern: args[2]))
            return loadCharacter(name: name, skill: skill)
        case 501: // AI_FREE_CHARACTER
            characters.removeValue(forKey: args[1])
            return 0
        case 502: // AI_CHARACTERISTIC_FLOAT
            return characteristicFloat(handle: args[1], index: Int(args[2]))
        case 503: // AI_CHARACTERISTIC_BFLOAT
            let val = characteristicFloat(handle: args[1], index: Int(args[2]))
            let fval = Float(bitPattern: UInt32(bitPattern: val))
            let min_ = Float(bitPattern: UInt32(bitPattern: args[3]))
            let max_ = Float(bitPattern: UInt32(bitPattern: args[4]))
            let clamped = max(min_, min(max_, fval))
            return Int32(bitPattern: clamped.bitPattern)
        case 504: // AI_CHARACTERISTIC_INTEGER
            return characteristicInt(handle: args[1], index: Int(args[2]))
        case 505: // AI_CHARACTERISTIC_BINTEGER
            let val = characteristicInt(handle: args[1], index: Int(args[2]))
            return max(args[3], min(args[4], val))
        case 506: // AI_CHARACTERISTIC_STRING
            vm.writeString(at: args[3], "", maxLen: Int(args[4]))
            return 0

        // Chat system (507-527)
        case 507: // AI_ALLOC_CHAT_STATE
            let handle = nextChatHandle
            nextChatHandle += 1
            return handle
        case 508: // AI_FREE_CHAT_STATE
            return 0
        case 509: // AI_QUEUE_CONSOLE_MESSAGE
            return 0
        case 510: // AI_REMOVE_CONSOLE_MESSAGE
            return 0
        case 511: // AI_NEXT_CONSOLE_MESSAGE
            return 0
        case 512: // AI_NUM_CONSOLE_MESSAGES
            return 0
        case 513: // AI_INITIAL_CHAT
            return 0
        case 514: // AI_NUM_INITIAL_CHATS
            return 0
        case 515: // AI_REPLY_CHAT
            return 0
        case 516: // AI_CHAT_LENGTH
            return 0
        case 517: // AI_ENTER_CHAT
            return 0
        case 518: // AI_GET_CHAT_MESSAGE
            vm.writeString(at: args[2], "", maxLen: Int(args[3]))
            return 0
        case 519: // AI_STRING_CONTAINS
            return 0
        case 520: // AI_FIND_MATCH
            return 0
        case 521: // AI_MATCH_VARIABLE
            return 0
        case 522: // AI_UNIFY_WHITE_SPACES
            return 0
        case 523: // AI_REPLACING_VARIABLES
            return 0
        case 524: // AI_LOAD_CHAT_FILE
            return 0
        case 525: // AI_SET_CHAT_GENDER
            return 0
        case 526: // AI_SET_CHAT_NAME
            return 0
        case 527: // AI_REMOVE_FROM_AVOID_GOALS
            return 0

        // Goal management (528-549)
        case 528: // AI_RESET_GOAL_STATE
            return 0
        case 529: // AI_RESET_AVOID_GOALS
            return 0
        case 530: // AI_PUSH_GOAL
            return 0
        case 531: // AI_POP_GOAL
            return 0
        case 532: // AI_EMPTY_GOAL_STACK
            return 0
        case 533: // AI_DUMP_AVOID_GOALS
            return 0
        case 534: // AI_DUMP_GOAL_STACK
            return 0
        case 535: // AI_GOAL_NAME
            vm.writeString(at: args[2], "", maxLen: Int(args[3]))
            return 0
        case 536: // AI_GET_TOP_GOAL
            return 0
        case 537: // AI_GET_SECOND_GOAL
            return 0
        case 538: // AI_CHOOSE_LTG_ITEM
            return 0
        case 539: // AI_CHOOSE_NBG_ITEM
            return 0
        case 540: // AI_TOUCHING_GOAL
            return 0
        case 541: // AI_ITEM_GOAL_IN_VIS_BUT_NOT_VISIBLE
            return 0
        case 542: // AI_GET_LEVEL_ITEM_GOAL
            return 0
        case 543: // AI_GET_NEXT_CAMP_SPOT_GOAL
            return 0
        case 544: // AI_GET_MAP_LOCATION_GOAL
            return 0
        case 545: // AI_AVOID_GOAL_TIME
            return 0
        case 546: // AI_SET_AVOID_GOAL_TIME
            return 0
        case 547: // AI_INIT_LEVEL_ITEMS
            return 0
        case 548: // AI_UPDATE_ENTITY_ITEMS
            return 0
        case 549: // AI_ALLOC_GOAL_STATE
            let handle = nextGoalHandle
            nextGoalHandle += 1
            return handle

        // Movement (550-563)
        case 550: // AI_RESET_MOVE_STATE
            return 0
        case 551: // AI_ADD_AVOID_SPOT
            return 0
        case 552: // AI_MOVE_TO_GOAL
            return 0
        case 553: // AI_MOVE_IN_DIRECTION
            return 0
        case 554: // AI_RESET_AVOID_REACH
            return 0
        case 555: // AI_RESET_LAST_AVOID_REACH
            return 0
        case 556: // AI_REACHABILITY_AREA
            return 0
        case 557: // AI_MOVEMENT_VIEW_TARGET
            return 0
        case 558: // AI_PREDICT_VISIBLE_POSITION
            return 0
        case 559: // AI_ALLOC_MOVE_STATE
            let handle = nextMoveHandle
            nextMoveHandle += 1
            return handle
        case 560: // AI_FREE_MOVE_STATE
            return 0
        case 561: // AI_INIT_MOVE_STATE
            return 0
        case 562: // AI_ADD_AVOID_SPOT_X (various extras)
            return 0
        case 563: // AI_CHOOSE_BEST_FIGHT_WEAPON
            return 0

        // Weapons (564-568)
        case 564: // AI_GET_WEAPON_INFO
            return 0
        case 565: // AI_ALLOC_WEAPON_STATE
            let handle = nextWeaponHandle
            nextWeaponHandle += 1
            return handle
        case 566: // AI_FREE_WEAPON_STATE
            return 0
        case 567: // AI_RESET_WEAPON_STATE
            return 0
        case 568: // AI_LOAD_WEAPON_WEIGHTS
            return 0

        // Genetic/interbreed (569+)
        case 569...589:
            return 0

        default:
            return 0
        }
    }

    // MARK: - Character Loading

    private func loadCharacter(name: String, skill: Float) -> Int32 {
        let handle = nextCharacterHandle
        nextCharacterHandle += 1

        var character = BotCharacter()
        character.name = name
        character.skill = skill

        // Set default traits based on skill level (0-5)
        let skillFrac = skill / 5.0
        character.traits[0] = skillFrac            // aggression
        character.traits[1] = 0.3 + skillFrac * 0.5 // aim accuracy
        character.traits[2] = 0.5 + skillFrac * 0.3 // alertness
        character.traits[3] = skillFrac * 0.8        // reaction time (lower = faster)
        character.traits[4] = 0.3 + skillFrac * 0.7  // weapon skill

        characters[handle] = character
        return handle
    }

    private func characteristicFloat(handle: Int32, index: Int) -> Int32 {
        let val = characters[handle]?.traits[index] ?? 0.5
        return Int32(bitPattern: val.bitPattern)
    }

    private func characteristicInt(handle: Int32, index: Int) -> Int32 {
        let fval = characters[handle]?.traits[index] ?? 0.5
        return Int32(fval * 10)
    }
}

// MARK: - Bot State

class BotState {
    let clientNum: Int
    var moveStateHandle: Int32 = 0
    var goalStateHandle: Int32 = 0
    var chatStateHandle: Int32 = 0
    var weaponStateHandle: Int32 = 0
    var characterHandle: Int32 = 0

    var origin: Vec3 = .zero
    var velocity: Vec3 = .zero
    var viewAngles: Vec3 = .zero

    var health: Int = 100
    var armor: Int = 0
    var currentWeapon: Int = 1

    init(clientNum: Int) {
        self.clientNum = clientNum
    }
}

// MARK: - Bot Character

struct BotCharacter {
    var name: String = ""
    var skill: Float = 1.0
    var traits: [Int: Float] = [:]  // Index → value
}
