// BotAAS.swift — Area Awareness System (pathfinding, reachability)

import Foundation
import simd

class BotAAS {
    static let shared = BotAAS()

    var initialized = false
    var aasLoaded = false

    // Entity tracking
    var entityInfos: [Int: BotEntityInfo] = [:]

    // Simplified area system (without full AAS file parsing)
    var numAreas: Int = 0

    private init() {}

    // MARK: - Lifecycle

    func initialize() {
        initialized = true
    }

    func shutdown() {
        initialized = false
        aasLoaded = false
        entityInfos.removeAll()
    }

    func loadAAS(_ name: String) {
        // Try to load the AAS file from pk3
        if let data = Q3FileSystem.shared.loadFile(name) {
            Q3Console.shared.print("AAS file loaded: \(name) (\(data.count) bytes)")
            // Full AAS parsing would go here - for now just mark as loaded
            aasLoaded = true
        } else {
            Q3Console.shared.print("AAS file not found: \(name) (bots will have limited navigation)")
            aasLoaded = false
        }
    }

    func update(time: Float) {
        // Update routing tables, entity positions, etc.
    }

    // MARK: - Entity Info

    func updateEntityInfo(entNum: Int, vm: QVM, addr: Int32) {
        var info = BotEntityInfo()
        info.valid = true
        info.entityNum = entNum

        // Read bot_entitystate_t from VM memory
        // type, flags, origin, angles, etc.
        let a = Int(addr)
        info.origin.x = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 8)))
        info.origin.y = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 12)))
        info.origin.z = Float(bitPattern: UInt32(bitPattern: vm.readInt32(fromData: a + 16)))

        entityInfos[entNum] = info
    }

    // MARK: - AAS Syscalls (300-318)

    func handleSyscall(cmd: Int32, args: [Int32], vm: QVM) -> Int32 {
        switch cmd {
        case 300: // AAS_ENABLE_ROUTING_AREA
            return 0

        case 301: // AAS_BBOX_AREAS
            return 0  // No areas found

        case 302: // AAS_AREA_INFO
            return 0

        case 303: // AAS_ENTITY_INFO
            let entNum = Int(args[1])
            if let info = entityInfos[entNum], args[2] != 0 {
                let a = Int(args[2])
                // Write aas_entityinfo_t
                vm.writeInt32(toData: a, value: 1)  // valid
                vm.writeInt32(toData: a + 4, value: Int32(entNum))  // number
                // origin
                vm.writeInt32(toData: a + 8, value: Int32(bitPattern: info.origin.x.bitPattern))
                vm.writeInt32(toData: a + 12, value: Int32(bitPattern: info.origin.y.bitPattern))
                vm.writeInt32(toData: a + 16, value: Int32(bitPattern: info.origin.z.bitPattern))
            }
            return 0

        case 304: // AAS_INITIALIZED
            return aasLoaded ? 1 : 0

        case 305: // AAS_PRESENCE_TYPE_BOUNDING_BOX
            // Write default player bounding box
            if args[2] != 0 {
                let a = Int(args[2])
                // mins
                vm.writeInt32(toData: a, value: Int32(bitPattern: Float(-15).bitPattern))
                vm.writeInt32(toData: a + 4, value: Int32(bitPattern: Float(-15).bitPattern))
                vm.writeInt32(toData: a + 8, value: Int32(bitPattern: Float(-24).bitPattern))
            }
            if args[3] != 0 {
                let a = Int(args[3])
                // maxs
                vm.writeInt32(toData: a, value: Int32(bitPattern: Float(15).bitPattern))
                vm.writeInt32(toData: a + 4, value: Int32(bitPattern: Float(15).bitPattern))
                vm.writeInt32(toData: a + 8, value: Int32(bitPattern: Float(32).bitPattern))
            }
            return 0

        case 306: // AAS_TIME
            return Int32(bitPattern: BotLib.shared.frameTime.bitPattern)

        case 307: // AAS_POINT_AREA_NUM
            // Return area 1 for any point (simplified)
            return aasLoaded ? 1 : 0

        case 308: // AAS_TRACE_AREAS
            return 0

        case 309: // AAS_POINT_CONTENTS
            return 0  // Empty contents

        case 310: // AAS_NEXT_BSP_ENTITY
            return 0  // No more entities (0 = done, not -1)

        case 311: // AAS_VALUE_FOR_BSP_EPAIR_KEY
            vm.writeString(at: args[3], "", maxLen: Int(args[4]))
            return 0

        case 312: // AAS_VECTOR_FOR_BSP_EPAIR_KEY
            return 0

        case 313: // AAS_FLOAT_FOR_BSP_EPAIR_KEY
            return 0

        case 314: // AAS_INT_FOR_BSP_EPAIR_KEY
            return 0

        case 315: // AAS_AREA_REACHABILITY
            return 0  // No reachability

        case 316: // AAS_AREA_TRAVEL_TIME_TO_GOAL_AREA
            return 1  // Minimal travel time

        case 317: // AAS_SWIMMING
            return 0  // Not swimming

        case 318: // AAS_PREDICT_CLIENT_MOVEMENT
            return 0

        default:
            return 0
        }
    }
}

// MARK: - Bot Entity Info

struct BotEntityInfo {
    var valid = false
    var entityNum = 0
    var origin: Vec3 = .zero
    var angles: Vec3 = .zero
    var modelIndex = 0
    var type = 0
    var flags = 0
}
