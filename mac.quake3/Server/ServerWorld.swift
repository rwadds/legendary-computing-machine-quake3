// ServerWorld.swift — Entity linking, spatial queries, trace

import Foundation
import simd

class ServerWorld {
    static let shared = ServerWorld()

    private init() {}

    // MARK: - Link Entity

    private var linkDebugCount: Int = 0
    func linkEntity(vm: QVM, entAddr: Int32) {
        let sv = ServerMain.shared

        // Read entity number from VM memory
        // entityState_t starts at entAddr, first field is number
        let entNum = Int(vm.readInt32(fromData: Int(entAddr)))
        guard entNum >= 0 && entNum < MAX_GENTITIES else { return }
        guard entNum < sv.gentities.count else { return }

        // Unlink first
        unlinkEntity(vm: vm, entAddr: entAddr)

        // Read shared entity data from VM memory
        // The entityShared_t follows entityState_t in the gentity structure
        // In Q3, gentity_t has: entityState_t s; entityShared_t r; (then game-private fields)
        // entityState_t is 208 bytes (Q3 reference layout)

        var ent = sv.gentities[entNum]
        ent.r.linked = true
        ent.r.linkCount += 1

        // Read entityState_t (208 bytes) from VM memory
        ent.s = sv.readEntityStateFromVM(vm: vm, addr: entAddr)

        // Read entityShared_t from VM memory (starts after entityState_t)
        let sharedBase = entAddr + 208  // entityState_t is 208 bytes
        ent.r.svFlags = vm.readInt32(fromData: Int(sharedBase) + 8)
        ent.r.singleClient = vm.readInt32(fromData: Int(sharedBase) + 12)
        ent.r.bmodel = vm.readInt32(fromData: Int(sharedBase) + 16) != 0
        ent.r.mins = sv.readVec3(vm: vm, addr: sharedBase + 20)
        ent.r.maxs = sv.readVec3(vm: vm, addr: sharedBase + 32)
        ent.r.contents = vm.readInt32(fromData: Int(sharedBase) + 44)
        ent.r.currentOrigin = sv.readVec3(vm: vm, addr: sharedBase + 72)
        ent.r.currentAngles = sv.readVec3(vm: vm, addr: sharedBase + 84)
        ent.r.ownerNum = vm.readInt32(fromData: Int(sharedBase) + 96)

        // DEBUG: log entity linking details for first 50 calls and any trigger entities
        linkDebugCount += 1
        let isTrigger = ent.r.contents & 0x40000000 != 0  // CONTENTS_TRIGGER
        if linkDebugCount <= 50 || isTrigger {
            Q3Console.shared.print("[LINK-DBG] ent#\(entNum) addr=\(entAddr) sharedBase=\(sharedBase) origin=\(ent.r.currentOrigin) mins=\(ent.r.mins) maxs=\(ent.r.maxs) contents=0x\(String(ent.r.contents, radix: 16)) eType=\(ent.s.eType)")
        }

        // Calculate absmin/absmax
        ent.r.absmin = ent.r.currentOrigin + ent.r.mins - Vec3(1, 1, 1)
        ent.r.absmax = ent.r.currentOrigin + ent.r.maxs + Vec3(1, 1, 1)

        sv.gentities[entNum] = ent

        // Link into world sector
        linkIntoWorldSector(entNum: entNum)
    }

    func unlinkEntity(vm: QVM, entAddr: Int32) {
        let sv = ServerMain.shared
        let entNum = Int(vm.readInt32(fromData: Int(entAddr)))
        guard entNum >= 0 && entNum < sv.gentities.count else { return }

        // Remove from world sector
        removeFromWorldSector(entNum: entNum)

        sv.gentities[entNum].r.linked = false
    }

    // MARK: - World Sector Operations

    private func linkIntoWorldSector(entNum: Int) {
        let sv = ServerMain.shared
        guard entNum < sv.gentities.count else { return }
        let ent = sv.gentities[entNum]

        // Find the appropriate world sector
        var sectorIdx = 0
        while true {
            guard sectorIdx < sv.worldSectors.count else { break }
            let sector = sv.worldSectors[sectorIdx]
            if sector.axis == -1 { break }  // Leaf node

            let axis = sector.axis
            if ent.r.absmin[axis] > sector.dist {
                sectorIdx = sector.children[0]
            } else if ent.r.absmax[axis] < sector.dist {
                sectorIdx = sector.children[1]
            } else {
                break  // Entity spans the split plane, link here
            }
        }

        guard sectorIdx >= 0 && sectorIdx < sv.worldSectors.count else { return }

        // Link entity into sector
        let svEnt = sv.svEntities[entNum]
        svEnt.worldSectorIndex = sectorIdx
        svEnt.nextEntityInSector = sv.worldSectors[sectorIdx].entities
        sv.worldSectors[sectorIdx].entities = entNum
    }

    private func removeFromWorldSector(entNum: Int) {
        let sv = ServerMain.shared
        let svEnt = sv.svEntities[entNum]
        guard svEnt.worldSectorIndex >= 0 && svEnt.worldSectorIndex < sv.worldSectors.count else { return }

        let sector = sv.worldSectors[svEnt.worldSectorIndex]

        // Remove from linked list
        if sector.entities == entNum {
            sector.entities = svEnt.nextEntityInSector
        } else {
            var prev = sector.entities
            while prev != -1 {
                let prevEnt = sv.svEntities[prev]
                if prevEnt.nextEntityInSector == entNum {
                    prevEnt.nextEntityInSector = svEnt.nextEntityInSector
                    break
                }
                prev = prevEnt.nextEntityInSector
            }
        }

        svEnt.worldSectorIndex = -1
        svEnt.nextEntityInSector = -1
    }

    // MARK: - Area Queries

    func entitiesInBox(mins: Vec3, maxs: Vec3, listAddr: Int32, maxCount: Int, vm: QVM) -> Int {
        var result: [Int32] = []
        collectEntitiesInBox(sectorIdx: 0, mins: mins, maxs: maxs, result: &result, maxCount: maxCount)

        // Write to VM memory
        for i in 0..<result.count {
            vm.writeInt32(toData: Int(listAddr) + i * 4, value: result[i])
        }
        return result.count
    }

    private func collectEntitiesInBox(sectorIdx: Int, mins: Vec3, maxs: Vec3,
                                       result: inout [Int32], maxCount: Int) {
        let sv = ServerMain.shared
        guard sectorIdx >= 0 && sectorIdx < sv.worldSectors.count else { return }
        guard result.count < maxCount else { return }

        let sector = sv.worldSectors[sectorIdx]

        // Check entities in this sector
        var entNum = sector.entities
        while entNum != -1 && result.count < maxCount {
            guard entNum >= 0 && entNum < sv.gentities.count else { break }
            let ent = sv.gentities[entNum]

            if ent.r.absmin.x <= maxs.x && ent.r.absmax.x >= mins.x &&
               ent.r.absmin.y <= maxs.y && ent.r.absmax.y >= mins.y &&
               ent.r.absmin.z <= maxs.z && ent.r.absmax.z >= mins.z {
                result.append(Int32(entNum))
            }

            entNum = sv.svEntities[entNum].nextEntityInSector
        }

        // Recurse into children
        if sector.axis != -1 {
            if maxs[sector.axis] > sector.dist {
                collectEntitiesInBox(sectorIdx: sector.children[0], mins: mins, maxs: maxs,
                                     result: &result, maxCount: maxCount)
            }
            if mins[sector.axis] < sector.dist {
                collectEntitiesInBox(sectorIdx: sector.children[1], mins: mins, maxs: maxs,
                                     result: &result, maxCount: maxCount)
            }
        }
    }

    // MARK: - Trace

    func trace(start: Vec3, end: Vec3, mins: Vec3, maxs: Vec3,
               passEntityNum: Int, contentMask: Int32) -> TraceResult {
        // First, trace against the world (BSP)
        var result = CollisionModel.shared.trace(start: start, end: end, mins: mins, maxs: maxs, contentMask: contentMask)

        // Then, trace against entities
        let sv = ServerMain.shared
        let traceMins = start + mins - Vec3(1, 1, 1)
        let traceMaxs = end + maxs + Vec3(1, 1, 1)
        let expandedMins = Vec3(min(traceMins.x, traceMaxs.x), min(traceMins.y, traceMaxs.y), min(traceMins.z, traceMaxs.z))
        let expandedMaxs = Vec3(max(traceMins.x, traceMaxs.x), max(traceMins.y, traceMaxs.y), max(traceMins.z, traceMaxs.z))

        var touchList: [Int32] = []
        collectEntitiesInBox(sectorIdx: 0, mins: expandedMins, maxs: expandedMaxs,
                             result: &touchList, maxCount: MAX_GENTITIES)

        for entNumI32 in touchList {
            let entNum = Int(entNumI32)
            guard entNum != passEntityNum else { continue }
            guard entNum < sv.gentities.count else { continue }
            let ent = sv.gentities[entNum]

            // Check content mask
            if ent.r.contents & contentMask == 0 { continue }

            // Skip owner
            if ent.r.ownerNum == Int32(passEntityNum) { continue }

            // Simple AABB test against entity
            let entResult = traceAgainstEntity(start: start, end: end, mins: mins, maxs: maxs, entity: ent)
            if entResult.fraction < result.fraction {
                result = entResult
                result.entityNum = entNumI32
            }
        }

        return result
    }

    private func traceAgainstEntity(start: Vec3, end: Vec3, mins: Vec3, maxs: Vec3,
                                     entity: SharedEntity) -> TraceResult {
        // Simple AABB sweep against entity AABB
        var result = TraceResult()
        result.fraction = 1.0
        result.endpos = end

        let entMins = entity.r.absmin
        let entMaxs = entity.r.absmax

        // Minkowski expansion
        let expandedMins = entMins + mins
        let expandedMaxs = entMaxs + maxs

        // Ray-AABB intersection
        var tMin: Float = 0
        var tMax: Float = 1.0
        var hitNormal = Vec3.zero

        for i in 0..<3 {
            let dir = end[i] - start[i]
            if abs(dir) < 0.001 {
                if start[i] < expandedMins[i] || start[i] > expandedMaxs[i] {
                    return result // No intersection
                }
            } else {
                let invDir = 1.0 / dir
                var t1 = (expandedMins[i] - start[i]) * invDir
                var t2 = (expandedMaxs[i] - start[i]) * invDir

                var normal = Vec3.zero
                normal[i] = -1

                if t1 > t2 {
                    swap(&t1, &t2)
                    normal[i] = 1
                }

                if t1 > tMin {
                    tMin = t1
                    hitNormal = normal
                }
                tMax = min(tMax, t2)

                if tMin > tMax { return result }
            }
        }

        if tMin < result.fraction {
            result.fraction = max(0, tMin - 0.125 / max(0.001, simd_length(end - start)))
            result.endpos = start + (end - start) * result.fraction
            result.plane.normal = hitNormal
            result.contents = entity.r.contents
        }

        return result
    }
}
