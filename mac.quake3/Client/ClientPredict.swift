// ClientPredict.swift — Client-side movement prediction (simplified Pmove)

import Foundation
import simd

class Pmove {
    // Movement constants
    static let stopSpeed: Float = 100.0
    static let duckScale: Float = 0.25
    static let swimScale: Float = 0.50

    static let accelerate: Float = 10.0
    static let airAccelerate: Float = 1.0
    static let waterAccelerate: Float = 4.0

    static let friction: Float = 6.0
    static let waterFriction: Float = 1.0

    static let gravity: Float = 800.0
    static let jumpVelocity: Float = 270.0

    static let maxSpeed: Float = 320.0

    // MARK: - Execute Movement

    /// Run player movement prediction
    static func execute(ps: inout PlayerState, cmd: UserCmd) {
        let msec = cmd.serverTime - ps.commandTime
        guard msec > 0 && msec <= 200 else { return }

        ps.commandTime = cmd.serverTime
        let frametime = Float(msec) * 0.001

        // Decode view angles
        let viewAngles = Vec3(
            SHORT2ANGLE(Int(cmd.angles.x)),
            SHORT2ANGLE(Int(cmd.angles.y)),
            SHORT2ANGLE(Int(cmd.angles.z))
        )
        ps.viewangles = viewAngles

        // Get forward/right/up from angles
        let (forward, right, _) = angleVectors(viewAngles)

        // Compute wish velocity from input
        let fmove = Float(cmd.forwardmove)
        let smove = Float(cmd.rightmove)

        var wishvel = forward * fmove + right * smove
        wishvel.z = 0

        let wishspeed = min(simd_length(wishvel), maxSpeed)
        let wishdir = wishspeed > 0 ? simd_normalize(wishvel) : Vec3.zero

        // Check ground
        let groundTrace = CollisionModel.shared.trace(
            start: ps.origin,
            end: ps.origin - Vec3(0, 0, 0.25),
            mins: Vec3(-15, -15, -24),
            maxs: Vec3(15, 15, 32),
            contentMask: CONTENTS_SOLID
        )

        let onGround = groundTrace.fraction < 1.0 && groundTrace.plane.normal.z > 0.7

        if onGround {
            ps.groundEntityNum = Int32(ENTITYNUM_WORLD)

            // Jump
            if cmd.upmove > 10 {
                ps.velocity.z = jumpVelocity
                ps.groundEntityNum = Int32(ENTITYNUM_NONE)
            } else {
                // Ground movement
                applyFriction(ps: &ps, frametime: frametime)
                groundAccelerate(ps: &ps, wishdir: wishdir, wishspeed: wishspeed, frametime: frametime)
                ps.velocity.z = 0  // Snap to ground
            }
        } else {
            ps.groundEntityNum = Int32(ENTITYNUM_NONE)

            // Apply gravity
            ps.velocity.z -= gravity * frametime

            // Air acceleration (limited)
            airAccelerate(ps: &ps, wishdir: wishdir, wishspeed: wishspeed, frametime: frametime)
        }

        // Clip and slide
        slideMove(ps: &ps, frametime: frametime, onGround: onGround)
    }

    // MARK: - Friction

    private static func applyFriction(ps: inout PlayerState, frametime: Float) {
        var vel = ps.velocity
        vel.z = 0

        let speed = simd_length(vel)
        guard speed > 0.1 else {
            ps.velocity.x = 0
            ps.velocity.y = 0
            return
        }

        let control = max(speed, stopSpeed)
        let drop = control * friction * frametime

        var newSpeed = speed - drop
        if newSpeed < 0 { newSpeed = 0 }
        newSpeed /= speed

        ps.velocity.x *= newSpeed
        ps.velocity.y *= newSpeed
    }

    // MARK: - Acceleration

    private static func groundAccelerate(ps: inout PlayerState, wishdir: Vec3, wishspeed: Float, frametime: Float) {
        let currentspeed = simd_dot(ps.velocity, wishdir)
        let addspeed = wishspeed - currentspeed
        guard addspeed > 0 else { return }

        var accelspeed = accelerate * frametime * wishspeed
        if accelspeed > addspeed { accelspeed = addspeed }

        ps.velocity += wishdir * accelspeed
    }

    private static func airAccelerate(ps: inout PlayerState, wishdir: Vec3, wishspeed: Float, frametime: Float) {
        let clampedWishspeed = min(wishspeed, 30.0)  // Air control limited

        let currentspeed = simd_dot(ps.velocity, wishdir)
        let addspeed = clampedWishspeed - currentspeed
        guard addspeed > 0 else { return }

        var accelspeed = airAccelerate * frametime * wishspeed
        if accelspeed > addspeed { accelspeed = addspeed }

        ps.velocity += wishdir * accelspeed
    }

    // MARK: - Slide Movement

    private static func slideMove(ps: inout PlayerState, frametime: Float, onGround: Bool) {
        var timeLeft = frametime
        var velocity = ps.velocity
        var origin = ps.origin

        let maxBumps = 4
        var planes: [Vec3] = []

        // Add ground plane if on ground
        if onGround {
            planes.append(Vec3(0, 0, 1))
        }

        // Add velocity plane
        let velLen = simd_length(velocity)
        if velLen > 0 {
            planes.append(simd_normalize(velocity))
        }

        for _ in 0..<maxBumps {
            guard timeLeft > 0.001 else { break }

            let end = origin + velocity * timeLeft
            let trace = CollisionModel.shared.trace(
                start: origin,
                end: end,
                mins: Vec3(-15, -15, -24),
                maxs: Vec3(15, 15, 32),
                contentMask: CONTENTS_SOLID
            )

            if trace.allsolid {
                velocity.z = 0
                break
            }

            if trace.fraction > 0 {
                origin = trace.endpos
            }

            if trace.fraction >= 1.0 {
                break
            }

            timeLeft -= timeLeft * trace.fraction

            // Clip velocity against the plane
            planes.append(trace.plane.normal)
            velocity = clipVelocity(velocity, normal: trace.plane.normal, overbounce: 1.001)

            // Check if we're going back into a previous plane
            var blocked = false
            for plane in planes {
                if simd_dot(velocity, plane) < 0 {
                    blocked = true
                    break
                }
            }
            if blocked {
                velocity = .zero
                break
            }
        }

        ps.origin = origin
        ps.velocity = velocity
    }

    // MARK: - Clip Velocity

    static func clipVelocity(_ velocity: Vec3, normal: Vec3, overbounce: Float) -> Vec3 {
        var backoff = simd_dot(velocity, normal)
        if backoff < 0 {
            backoff *= overbounce
        } else {
            backoff /= overbounce
        }
        return velocity - normal * backoff
    }
}
