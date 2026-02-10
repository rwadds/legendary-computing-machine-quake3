// RenderEffects.swift — Marks (decals), particle polys, flares

import Foundation
import simd

// MARK: - Particle System

struct Q3Particle {
    var origin: Vec3 = .zero
    var velocity: Vec3 = .zero
    var accel: Vec3 = .zero
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var endColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    var startTime: Float = 0
    var endTime: Float = 0
    var startSize: Float = 1
    var endSize: Float = 0
    var type: Int32 = 0
}

class Q3ParticleSystem {
    static let shared = Q3ParticleSystem()

    private var particles: [Q3Particle] = []
    let maxParticles = 4096

    private init() {}

    func addParticle(_ particle: Q3Particle) {
        if particles.count < maxParticles {
            particles.append(particle)
        }
    }

    func update(time: Float, deltaTime: Float) {
        // Remove expired particles
        particles.removeAll { p in
            time >= p.endTime
        }

        // Update positions
        for i in 0..<particles.count {
            particles[i].origin += particles[i].velocity * deltaTime
            particles[i].velocity += particles[i].accel * deltaTime
        }
    }

    func getActiveParticles() -> [Q3Particle] {
        return particles
    }

    func clear() {
        particles.removeAll(keepingCapacity: true)
    }

    // MARK: - Common Effects

    func explosion(at origin: Vec3, time: Float) {
        for _ in 0..<20 {
            var p = Q3Particle()
            p.origin = origin
            p.velocity = Vec3(
                Float.random(in: -150...150),
                Float.random(in: -150...150),
                Float.random(in: -150...150)
            )
            p.accel = Vec3(0, 0, -400)
            p.color = SIMD4<Float>(1.0, 0.8, 0.4, 1.0)
            p.endColor = SIMD4<Float>(0.5, 0.2, 0.0, 0.0)
            p.startTime = time
            p.endTime = time + Float.random(in: 0.5...1.5)
            p.startSize = 3
            p.endSize = 0
            addParticle(p)
        }
    }

    func bulletImpact(at origin: Vec3, normal: Vec3, time: Float) {
        for _ in 0..<5 {
            var p = Q3Particle()
            p.origin = origin
            p.velocity = normal * Float.random(in: 50...150) + Vec3(
                Float.random(in: -50...50),
                Float.random(in: -50...50),
                Float.random(in: -50...50)
            )
            p.accel = Vec3(0, 0, -400)
            p.color = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
            p.endColor = SIMD4<Float>(0.4, 0.4, 0.4, 0.0)
            p.startTime = time
            p.endTime = time + Float.random(in: 0.3...0.8)
            p.startSize = 2
            p.endSize = 0
            addParticle(p)
        }
    }
}

// MARK: - Decal/Mark System

struct Q3Mark {
    var origin: Vec3 = .zero
    var normal: Vec3 = Vec3(0, 0, 1)
    var size: Float = 16
    var shader: Int32 = 0
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var startTime: Float = 0
    var duration: Float = 10  // seconds
}

class Q3MarkSystem {
    static let shared = Q3MarkSystem()

    private var marks: [Q3Mark] = []
    let maxMarks = 512

    private init() {}

    func addMark(_ mark: Q3Mark) {
        if marks.count >= maxMarks {
            marks.removeFirst()
        }
        marks.append(mark)
    }

    func update(time: Float) {
        marks.removeAll { m in
            time - m.startTime > m.duration
        }
    }

    func getActiveMarks() -> [Q3Mark] {
        return marks
    }

    func clear() {
        marks.removeAll(keepingCapacity: true)
    }
}
