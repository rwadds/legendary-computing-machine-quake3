// RenderLight.swift — Light grid sampling, dynamic light application

import Foundation
import simd

class RenderLight {

    // Dynamic lights active this frame
    var dynamicLights: [DynamicLight] = []

    // MARK: - Light Grid

    /// Sample the BSP light grid at a world position
    static func sampleLightGrid(at point: Vec3) -> (ambient: Vec3, directed: Vec3, direction: Vec3) {
        // Simplified: return default lighting
        let ambient = Vec3(0.3, 0.3, 0.3)
        let directed = Vec3(0.7, 0.7, 0.7)
        let direction = simd_normalize(Vec3(0.5, 0.3, 1.0))
        return (ambient, directed, direction)
    }

    // MARK: - Dynamic Light Contribution

    /// Calculate dynamic light contribution at a surface point
    static func dynamicLightContribution(at point: Vec3, normal: Vec3, lights: [DynamicLight]) -> Vec3 {
        var totalLight = Vec3.zero

        for light in lights {
            let dir = light.origin - point
            let dist = simd_length(dir)
            guard dist > 0 && dist < light.intensity else { continue }

            let normalizedDir = dir / dist
            let dot = max(0, simd_dot(normal, normalizedDir))
            let attenuation = 1.0 - dist / light.intensity

            totalLight += light.color * (dot * attenuation)
        }

        return totalLight
    }

    // MARK: - Setup Dynamic Lights from Scene

    func setupDynamicLights(from sceneLights: [DynamicLight]) {
        dynamicLights = sceneLights
    }

    func clearDynamicLights() {
        dynamicLights.removeAll(keepingCapacity: true)
    }
}
