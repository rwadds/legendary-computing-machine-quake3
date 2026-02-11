// ServerSnapshot.swift — Build client snapshots for delta compression

import Foundation
import simd

class ServerSnapshot {
    static let shared = ServerSnapshot()

    // Snapshot entities ring buffer
    private var snapshotEntities: [EntityState] = []
    private var nextSnapshotEntities: Int = 0
    private let numSnapshotEntities: Int

    // Client snapshot data
    struct ClientSnapshot {
        var valid: Bool = false
        var serverTime: Int32 = 0
        var numEntities: Int = 0
        var firstEntity: Int = 0  // Index into snapshotEntities ring buffer
        var ps: PlayerState = PlayerState()
    }

    // Per-client snapshot history
    var clientSnapshots: [[ClientSnapshot]] = []  // [clientNum][frameNum]
    let packetBackup = 32

    private init() {
        let maxEntitiesPerSnapshot = MAX_GENTITIES
        numSnapshotEntities = MAX_CLIENTS * packetBackup * maxEntitiesPerSnapshot
        snapshotEntities = Array(repeating: EntityState(), count: max(1, numSnapshotEntities))
        clientSnapshots = []
    }

    func initialize(maxClients: Int) {
        clientSnapshots = (0..<maxClients).map { _ in
            Array(repeating: ClientSnapshot(), count: packetBackup)
        }
        nextSnapshotEntities = 0
    }

    // MARK: - Build Client Snapshot

    func buildClientSnapshot(clientNum: Int) {
        let sv = ServerMain.shared
        guard clientNum >= 0 && clientNum < sv.maxClients else { return }
        guard clientNum < clientSnapshots.count else { return }
        guard let vm = sv.gameVM else { return }

        sv.snapshotCounter += 1

        var snap = ClientSnapshot()
        snap.valid = true
        snap.serverTime = sv.time
        snap.firstEntity = nextSnapshotEntities

        // Read player state directly from VM memory
        if clientNum < sv.maxClients && sv.gameClientsBaseAddr != 0 && sv.gameClientSize > 0 {
            let psAddr = sv.gameClientsBaseAddr + Int32(clientNum * sv.gameClientSize)
            snap.ps = sv.readPlayerStateFromVM(vm: vm, addr: psAddr)

            // DEBUG: log weapon stats periodically
            if sv.snapshotCounter % 300 == 1 {
                let w = snap.ps.stats[2]  // STAT_WEAPONS bitmask
                let cur = snap.ps.weapon
                let ammoRL = snap.ps.ammo[5]  // WP_ROCKET_LAUNCHER ammo
                Q3Console.shared.print("[SNAP] stats[STAT_WEAPONS]=\(w) (0x\(String(w, radix: 16))) weapon=\(cur) RL_ammo=\(ammoRL)")
            }
        }

        // Add visible entities — read entity state from VM memory
        let viewOrigin = sv.gentities.count > clientNum ? sv.gentities[clientNum].r.currentOrigin : Vec3.zero

        for i in 0..<sv.numEntities {
            guard i < sv.gentities.count else { break }
            let ent = sv.gentities[i]

            // Skip unlinked entities
            guard ent.r.linked else { continue }

            // Skip noclient entities
            if ent.r.svFlags & SVFlags.noClient.rawValue != 0 { continue }

            // Simple distance-based PVS check
            let dist = simd_length(ent.r.currentOrigin - viewOrigin)
            if dist > 8192 { continue }  // Too far

            // Read entity state from VM memory
            let entAddr = sv.gentitiesBaseAddr + Int32(i * sv.gentitySize)
            let es = sv.readEntityStateFromVM(vm: vm, addr: entAddr)

            // Add to snapshot
            let snapshotIdx = nextSnapshotEntities % max(1, numSnapshotEntities)
            snapshotEntities[snapshotIdx] = es
            nextSnapshotEntities += 1
            snap.numEntities += 1
        }

        // Store in ring buffer
        let frameIdx = Int(sv.snapshotCounter) % packetBackup
        clientSnapshots[clientNum][frameIdx] = snap
    }

    // MARK: - Get Snapshot for Client

    func getCurrentSnapshotNumber() -> (number: Int32, serverTime: Int32) {
        let sv = ServerMain.shared
        return (sv.snapshotCounter, sv.time)
    }

    func getSnapshot(number: Int32, clientNum: Int) -> (snap: ClientSnapshot, entities: [EntityState])? {
        guard clientNum >= 0 && clientNum < clientSnapshots.count else { return nil }

        let frameIdx = Int(number) % packetBackup
        let snap = clientSnapshots[clientNum][frameIdx]
        guard snap.valid else { return nil }

        // Collect entities
        var entities: [EntityState] = []
        for i in 0..<snap.numEntities {
            let idx = (snap.firstEntity + i) % max(1, numSnapshotEntities)
            entities.append(snapshotEntities[idx])
        }

        return (snap, entities)
    }
}
