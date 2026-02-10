// ClientSnapshot.swift — Snapshot interpolation, entity lerping

import Foundation
import simd

class ClientSnapshotManager {
    static let shared = ClientSnapshotManager()

    private init() {}

    // MARK: - Entity Interpolation

    /// Interpolate entity position between two snapshots
    static func lerpEntityState(from: EntityState, to: EntityState, frac: Float) -> EntityState {
        var result = to

        // Lerp origin
        result.origin = from.origin + (to.origin - from.origin) * frac

        // Lerp angles
        result.angles = Vec3(
            lerpAngle(from.angles.x, to.angles.x, frac),
            lerpAngle(from.angles.y, to.angles.y, frac),
            lerpAngle(from.angles.z, to.angles.z, frac)
        )

        return result
    }

    /// Evaluate trajectory at a given time
    static func evaluateTrajectory(_ tr: Trajectory, atTime time: Int32) -> Vec3 {
        switch tr.trType {
        case .stationary:
            return tr.trBase

        case .interpolate:
            return tr.trBase

        case .linear:
            let deltaTime = Float(time - tr.trTime) * 0.001
            return tr.trBase + tr.trDelta * deltaTime

        case .linearStop:
            if time > tr.trTime + tr.trDuration {
                let deltaTime = Float(tr.trDuration) * 0.001
                return tr.trBase + tr.trDelta * deltaTime
            }
            let deltaTime = Float(time - tr.trTime) * 0.001
            return tr.trBase + tr.trDelta * deltaTime

        case .sine:
            let deltaTime = Float(time - tr.trTime) / Float(tr.trDuration)
            let phase = sinf(deltaTime * Float.pi * 2)
            return tr.trBase + tr.trDelta * phase

        case .gravity:
            let deltaTime = Float(time - tr.trTime) * 0.001
            var result = tr.trBase + tr.trDelta * deltaTime
            result.z -= 0.5 * 800 * deltaTime * deltaTime  // DEFAULT_GRAVITY = 800
            return result
        }
    }

    /// Evaluate trajectory velocity at a given time
    static func evaluateTrajectoryDelta(_ tr: Trajectory, atTime time: Int32) -> Vec3 {
        switch tr.trType {
        case .stationary, .interpolate:
            return .zero

        case .linear:
            return tr.trDelta

        case .linearStop:
            if time > tr.trTime + tr.trDuration {
                return .zero
            }
            return tr.trDelta

        case .sine:
            let deltaTime = Float(time - tr.trTime) / Float(tr.trDuration)
            let phase = cosf(deltaTime * Float.pi * 2) * Float.pi * 2 / Float(tr.trDuration) * 1000
            return tr.trDelta * phase

        case .gravity:
            let deltaTime = Float(time - tr.trTime) * 0.001
            var result = tr.trDelta
            result.z -= 800 * deltaTime
            return result
        }
    }
}
