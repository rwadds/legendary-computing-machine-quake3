// ClientInput.swift — Keyboard/mouse → usercmd_t generation

import Foundation
import simd

class ClientInput {
    static let shared = ClientInput()

    // Key states
    var keysDown: Set<UInt16> = []

    // Mouse accumulation
    var mouseDeltaX: Float = 0
    var mouseDeltaY: Float = 0
    var sensitivity: Float = 0.022

    // Movement speed
    let moveSpeed: Int8 = 127

    private init() {}

    // MARK: - Create New Commands

    func createNewCommands() {
        let cl = ClientMain.shared
        guard cl.state == .active || cl.state == .primed else { return }

        cl.cmdNumber += 1
        let cmdIdx = Int(cl.cmdNumber) & 63

        var cmd = UserCmd()
        cmd.serverTime = cl.serverTime

        // Mouse look
        cl.viewangles.y -= mouseDeltaX * sensitivity * (cl.cgameSensitivity > 0 ? cl.cgameSensitivity : 1.0)
        cl.viewangles.x -= mouseDeltaY * sensitivity * (cl.cgameSensitivity > 0 ? cl.cgameSensitivity : 1.0)

        // Clamp pitch
        cl.viewangles.x = max(-89, min(89, cl.viewangles.x))

        mouseDeltaX = 0
        mouseDeltaY = 0

        // Encode angles
        cmd.angles = SIMD3<Int32>(
            Int32(ANGLE2SHORT(cl.viewangles.x)),
            Int32(ANGLE2SHORT(cl.viewangles.y)),
            Int32(ANGLE2SHORT(cl.viewangles.z))
        )

        // Keyboard movement
        keyMove(&cmd)

        // Set weapon
        cmd.weapon = UInt8(cl.cgameUserCmdValue)

        cl.cmds[cmdIdx] = cmd
    }

    // MARK: - Key Movement

    private func keyMove(_ cmd: inout UserCmd) {
        var forward: Int = 0
        var side: Int = 0
        var up: Int = 0

        let speed = Int(moveSpeed)

        // WASD
        if keysDown.contains(13) || keysDown.contains(126) { forward += speed }  // W or Up
        if keysDown.contains(1) || keysDown.contains(125) { forward -= speed }   // S or Down
        if keysDown.contains(0) || keysDown.contains(123) { side -= speed }      // A or Left
        if keysDown.contains(2) || keysDown.contains(124) { side += speed }      // D or Right
        if keysDown.contains(49) { up += speed }                                   // Space
        if keysDown.contains(56) { up -= speed }                                   // Shift

        // Attack
        if keysDown.contains(46) { cmd.buttons |= Int32(BUTTON_ATTACK) }         // M key (temp)

        cmd.forwardmove = clampChar(forward)
        cmd.rightmove = clampChar(side)
        cmd.upmove = clampChar(up)
    }

    private func clampChar(_ value: Int) -> Int8 {
        if value > 127 { return 127 }
        if value < -128 { return -128 }
        return Int8(value)
    }

    // MARK: - Key Events

    func keyDown(_ keyCode: UInt16) {
        keysDown.insert(keyCode)
    }

    func keyUp(_ keyCode: UInt16) {
        keysDown.remove(keyCode)
    }

    func mouseMove(dx: Float, dy: Float) {
        mouseDeltaX += dx
        mouseDeltaY += dy
    }
}
