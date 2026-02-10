// MathLib.swift — Quake III math utilities

import simd
import Foundation

// MARK: - Angle Operations

func angleMod(_ a: Float) -> Float {
    return (a * (65536.0 / 360.0)).truncatingRemainder(dividingBy: 65536).rounded(.towardZero) * (360.0 / 65536.0)
}

func lerpAngle(_ from: Float, _ to: Float, _ frac: Float) -> Float {
    var diff = to - from
    if diff > 180 { diff -= 360 }
    if diff < -180 { diff += 360 }
    return from + frac * diff
}

func angleSubtract(_ a1: Float, _ a2: Float) -> Float {
    var diff = a1 - a2
    while diff > 180 { diff -= 360 }
    while diff < -180 { diff += 360 }
    return diff
}

func anglesSubtract(_ v1: Vec3, _ v2: Vec3) -> Vec3 {
    return Vec3(angleSubtract(v1.x, v2.x),
                angleSubtract(v1.y, v2.y),
                angleSubtract(v1.z, v2.z))
}

// MARK: - Angle Vectors

/// Converts euler angles (pitch, yaw, roll) to forward/right/up vectors
func angleVectors(_ angles: Vec3) -> (forward: Vec3, right: Vec3, up: Vec3) {
    let pitch = angles.x * Float.pi / 180.0
    let yaw = angles.y * Float.pi / 180.0
    let roll = angles.z * Float.pi / 180.0

    let sp = sinf(pitch)
    let cp = cosf(pitch)
    let sy = sinf(yaw)
    let cy = cosf(yaw)
    let sr = sinf(roll)
    let cr = cosf(roll)

    let forward = Vec3(cp * cy, cp * sy, -sp)
    let right = Vec3((-sr * sp * cy + cr * sy),
                     (-sr * sp * sy - cr * cy),
                     (-sr * cp))
    let up = Vec3((cr * sp * cy + sr * sy),
                  (cr * sp * sy - sr * cy),
                  (cr * cp))

    return (forward, right, up)
}

/// Returns only the forward vector from angles
func angleToForward(_ angles: Vec3) -> Vec3 {
    let pitch = angles.x * Float.pi / 180.0
    let yaw = angles.y * Float.pi / 180.0
    let cp = cosf(pitch)
    let cy = cosf(yaw)
    let sp = sinf(pitch)
    let sy = sinf(yaw)
    return Vec3(cp * cy, cp * sy, -sp)
}

// MARK: - Vector Operations

func vectorNormalize(_ v: Vec3) -> (Vec3, Float) {
    let len = simd_length(v)
    if len > 0 {
        return (v / len, len)
    }
    return (.zero, 0)
}

func perpendicular(to src: Vec3) -> Vec3 {
    // Find the smallest component and use that axis
    let ax = abs(src.x)
    let ay = abs(src.y)
    let az = abs(src.z)

    var dst: Vec3
    if ax < ay && ax < az {
        dst = Vec3(0, -src.z, src.y)
    } else if ay < az {
        dst = Vec3(-src.z, 0, src.x)
    } else {
        dst = Vec3(-src.y, src.x, 0)
    }
    return simd_normalize(dst)
}

func crossProduct(_ a: Vec3, _ b: Vec3) -> Vec3 {
    return simd_cross(a, b)
}

func dotProduct(_ a: Vec3, _ b: Vec3) -> Float {
    return simd_dot(a, b)
}

func vectorMA(_ start: Vec3, _ scale: Float, _ dir: Vec3) -> Vec3 {
    return start + dir * scale
}

func vectorScale(_ v: Vec3, _ scale: Float) -> Vec3 {
    return v * scale
}

func vectorCopy(_ src: Vec3) -> Vec3 {
    return src
}

func distance(_ a: Vec3, _ b: Vec3) -> Float {
    return simd_length(a - b)
}

func distanceSquared(_ a: Vec3, _ b: Vec3) -> Float {
    return simd_length_squared(a - b)
}

// MARK: - Interpolation

func lerpPosition(_ from: Vec3, _ to: Vec3, _ frac: Float) -> Vec3 {
    return from + (to - from) * frac
}

// MARK: - Bounds

struct Bounds {
    var mins: Vec3 = Vec3(repeating: .greatestFiniteMagnitude)
    var maxs: Vec3 = Vec3(repeating: -.greatestFiniteMagnitude)

    mutating func addPoint(_ v: Vec3) {
        mins = simd_min(mins, v)
        maxs = simd_max(maxs, v)
    }

    mutating func clear() {
        mins = Vec3(repeating: .greatestFiniteMagnitude)
        maxs = Vec3(repeating: -.greatestFiniteMagnitude)
    }

    var center: Vec3 {
        return (mins + maxs) * 0.5
    }

    var radius: Float {
        return simd_length(maxs - mins) * 0.5
    }
}

// MARK: - Plane

struct Plane {
    var normal: Vec3 = .zero
    var dist: Float = 0

    func pointDistance(_ point: Vec3) -> Float {
        return dotProduct(normal, point) - dist
    }

    enum Side: Int {
        case front = 0
        case back = 1
        case on = 2
        case cross = 3
    }

    func classify(_ point: Vec3, epsilon: Float = 0.1) -> Side {
        let d = pointDistance(point)
        if d > epsilon { return .front }
        if d < -epsilon { return .back }
        return .on
    }
}

// MARK: - Trajectory Evaluation

func evaluateTrajectory(_ tr: Trajectory, atTime time: Int32) -> Vec3 {
    let deltaTime: Float
    switch tr.trType {
    case .stationary:
        return tr.trBase
    case .interpolate:
        return tr.trBase
    case .linear:
        deltaTime = Float(time - tr.trTime) * 0.001
        return tr.trBase + tr.trDelta * deltaTime
    case .linearStop:
        if time > tr.trTime + tr.trDuration {
            deltaTime = Float(tr.trDuration) * 0.001
        } else {
            deltaTime = Float(time - tr.trTime) * 0.001
        }
        return tr.trBase + tr.trDelta * deltaTime
    case .sine:
        deltaTime = Float(time - tr.trTime) / Float(tr.trDuration)
        let phase = sinf(deltaTime * Float.pi * 2)
        return tr.trBase + tr.trDelta * phase
    case .gravity:
        deltaTime = Float(time - tr.trTime) * 0.001
        let gravity: Float = 800 // DEFAULT_GRAVITY
        var result = tr.trBase + tr.trDelta * deltaTime
        result.z -= 0.5 * gravity * deltaTime * deltaTime
        return result
    }
}

func evaluateTrajectoryDelta(_ tr: Trajectory, atTime time: Int32) -> Vec3 {
    let deltaTime: Float
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
        deltaTime = Float(time - tr.trTime) / Float(tr.trDuration)
        let phase = cosf(deltaTime * Float.pi * 2)
        return tr.trDelta * (phase * Float.pi * 2 / Float(tr.trDuration) * 1000)
    case .gravity:
        deltaTime = Float(time - tr.trTime) * 0.001
        let gravity: Float = 800
        var result = tr.trDelta
        result.z -= gravity * deltaTime
        return result
    }
}

// MARK: - Matrix Utilities

func matrix4x4_lookAt(eye: Vec3, center: Vec3, up: Vec3) -> matrix_float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)

    return matrix_float4x4(columns: (
        SIMD4<Float>(s.x, u.x, -f.x, 0),
        SIMD4<Float>(s.y, u.y, -f.y, 0),
        SIMD4<Float>(s.z, u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

func matrix4x4_perspective(fovyRadians fovy: Float, aspect: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
    let ys = 1.0 / tanf(fovy * 0.5)
    let xs = ys / aspect
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, zs * nearZ, 0)
    ))
}

func matrix4x4_identity() -> matrix_float4x4 {
    return matrix_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

// MARK: - Wave Table

let FUNCTABLE_SIZE = 1024

class WaveTable {
    static let shared = WaveTable()
    let sinTable: [Float]
    let squareTable: [Float]
    let triangleTable: [Float]
    let sawtoothTable: [Float]

    private init() {
        var sin = [Float](repeating: 0, count: FUNCTABLE_SIZE)
        var square = [Float](repeating: 0, count: FUNCTABLE_SIZE)
        var triangle = [Float](repeating: 0, count: FUNCTABLE_SIZE)
        var sawtooth = [Float](repeating: 0, count: FUNCTABLE_SIZE)

        for i in 0..<FUNCTABLE_SIZE {
            let f = Float(i) / Float(FUNCTABLE_SIZE)
            sin[i] = sinf(f * 2.0 * Float.pi)
            square[i] = f < 0.5 ? 1.0 : -1.0
            sawtooth[i] = f
            if f < 0.25 {
                triangle[i] = f * 4.0
            } else if f < 0.75 {
                triangle[i] = 2.0 - f * 4.0
            } else {
                triangle[i] = f * 4.0 - 4.0
            }
        }

        self.sinTable = sin
        self.squareTable = square
        self.triangleTable = triangle
        self.sawtoothTable = sawtooth
    }

    func evaluate(_ waveType: Int, phase: Float) -> Float {
        let index = Int(phase * Float(FUNCTABLE_SIZE)) & (FUNCTABLE_SIZE - 1)
        switch waveType {
        case 0: return sinTable[index]      // sin
        case 1: return squareTable[index]   // square
        case 2: return triangleTable[index] // triangle
        case 3: return sawtoothTable[index] // sawtooth
        case 4: return sawtoothTable[(FUNCTABLE_SIZE - 1 - index) & (FUNCTABLE_SIZE - 1)] // inverse sawtooth
        default: return sinTable[index]
        }
    }
}

// MARK: - Bit Operations

func countBits(_ v: Int32) -> Int {
    var count = 0
    var val = v
    while val != 0 {
        count += 1
        val &= val - 1
    }
    return count
}

func isPowerOfTwo(_ x: Int) -> Bool {
    return x > 0 && (x & (x - 1)) == 0
}

func nextPowerOfTwo(_ x: Int) -> Int {
    var v = x - 1
    v |= v >> 1
    v |= v >> 2
    v |= v >> 4
    v |= v >> 8
    v |= v >> 16
    return v + 1
}
