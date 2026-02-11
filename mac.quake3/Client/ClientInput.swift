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

    // Active +/- action commands (from key bindings)
    var activeActions: Set<String> = []

    private var commandsRegistered = false

    private init() {}

    /// Register +/- action commands (called once from ClientMain.initialize)
    func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let cb = Q3CommandBuffer.shared
        let actions = ["attack", "back", "forward", "moveleft", "moveright",
                       "moveup", "movedown", "left", "right", "speed",
                       "strafe", "lookup", "lookdown", "button0", "button1",
                       "button2", "scores", "zoom"]
        for action in actions {
            let name = action
            cb.addCommand("+\(name)") { ClientInput.shared.activeActions.insert(name) }
            cb.addCommand("-\(name)") { ClientInput.shared.activeActions.remove(name) }
        }
    }

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

        // WASD (direct macOS key codes — always work regardless of bindings)
        if keysDown.contains(13) || keysDown.contains(126) { forward += speed }  // W or Up
        if keysDown.contains(1) || keysDown.contains(125) { forward -= speed }   // S or Down
        if keysDown.contains(0) || keysDown.contains(123) { side -= speed }      // A or Left
        if keysDown.contains(2) || keysDown.contains(124) { side += speed }      // D or Right
        if keysDown.contains(49) { up += speed }                                   // Space
        if keysDown.contains(56) { up -= speed }                                   // Shift

        // +/- actions from key bindings
        if activeActions.contains("forward") { forward += speed }
        if activeActions.contains("back") { forward -= speed }
        if activeActions.contains("moveleft") { side -= speed }
        if activeActions.contains("moveright") { side += speed }
        if activeActions.contains("moveup") { up += speed }
        if activeActions.contains("movedown") { up -= speed }

        // Attack (from +attack binding, e.g. mouse1)
        if activeActions.contains("attack") || activeActions.contains("button0") {
            cmd.buttons |= Int32(BUTTON_ATTACK)
        }

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
