// GameViewController.swift — Main view controller with engine and renderer integration

import Cocoa
import MetalKit

class GameViewController: NSViewController {

    var renderMain: RenderMain!
    var mtkView: MTKView!

    // Track which keys are pressed
    private var keysDown: Set<UInt16> = []

    // Mouse capture state
    private var mouseCaptured = false
    private var cursorHidden = false
    private var appIsActive = true

    override func viewDidLoad() {
        super.viewDidLoad()

        // Initialize the engine first
        Q3Engine.shared.initialize()

        guard let mtkView = self.view as? MTKView else {
            print("View attached to GameViewController is not an MTKView")
            return
        }
        self.mtkView = mtkView
        mtkView.autoresizingMask = [.width, .height]
        mtkView.preferredFramesPerSecond = 120

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return
        }

        if !defaultDevice.supportsFamily(.metal4) {
            print("Metal 4 is not supported")
            return
        }

        mtkView.device = defaultDevice
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        // Ensure the Metal layer is opaque — macOS compositor uses alpha for transparency
        // which makes rendered pixels with alpha < 1.0 appear transparent
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.isOpaque = true
        }

        guard let renderer = RenderMain(metalKitView: mtkView) else {
            print("Renderer cannot be initialized")
            return
        }

        renderMain = renderer
        renderMain.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        mtkView.delegate = renderMain

        // Give engine a reference to the renderer
        Q3Engine.shared.renderMain = renderMain

        // Wire textureCache to RendererAPI so shader→texture resolution works
        ClientMain.shared.rendererAPI?.textureCache = renderMain.textureCache

        // Setup input
        setupInput()
    }

    // MARK: - Mouse Capture

    /// Capture the mouse: hide cursor, lock to window center, enable delta mode
    func captureMouse() {
        guard !mouseCaptured else { return }
        mouseCaptured = true
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
        warpCursorToWindowCenter()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    /// Release the mouse: show cursor, unlock
    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    /// Warp the OS cursor to the center of the game window so it can't drift to screen edges
    private func warpCursorToWindowCenter() {
        guard let window = view.window, let screen = window.screen else { return }
        let windowFrame = window.frame
        let centerX = windowFrame.midX
        // macOS screen coords: origin bottom-left; CGWarp uses top-left origin
        let centerY = screen.frame.height - windowFrame.midY
        CGWarpMouseCursorPosition(CGPoint(x: centerX, y: centerY))
    }

    /// Update cursor visibility and capture state based on game mode
    func updateCursorState() {
        guard appIsActive else { return }
        let inGame = !uiActive && (renderMain?.gameActive == true)
        if inGame {
            // Gameplay: fully captured
            if !mouseCaptured { captureMouse() }
        } else if uiActive {
            // UI menu: hidden cursor but free to move (Q3 draws its own cursor)
            if mouseCaptured {
                // Release delta lock but keep cursor hidden
                CGAssociateMouseAndMouseCursorPosition(1)
                mouseCaptured = false
            }
            if !cursorHidden {
                NSCursor.hide()
                cursorHidden = true
            }
        } else {
            // Neither game nor UI active — release everything
            releaseMouse()
        }
    }

    // MARK: - Input Handling

    private func setupInput() {
        // Monitor mouse/flags events; key events handled via responder chain overrides
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        // Capture mouse
        if let window = view.window {
            window.acceptsMouseMovedEvents = true
        }

        // Watch for app activation changes to release/re-capture mouse
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        appIsActive = true
        view.window?.makeFirstResponder(self)
        updateCursorState()
    }

    @objc private func appDidResignActive() {
        appIsActive = false
        // Release mouse so user can interact with other apps
        if mouseCaptured {
            CGAssociateMouseAndMouseCursorPosition(1)
            mouseCaptured = false
        }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.acceptsMouseMovedEvents = true
        view.window?.makeFirstResponder(self)
        updateCursorState()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        releaseMouse()
    }

    /// Whether the UI is currently catching input
    private var uiActive: Bool {
        return ClientUI.shared.keyCatcher & 2 != 0  // KEYCATCH_UI
    }

    private func handleEvent(_ event: NSEvent) {
        updateCursorState()
        if uiActive {
            handleUIEvent(event)
        } else {
            handleGameEvent(event)
        }
    }

    /// Handle input when UI menu is active
    private func handleUIEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let q3Key = macKeyToQ3(event.keyCode)
            ClientUI.shared.keyEvent(q3Key, down: true)
            // Also handle character input for text fields
            if let chars = event.characters, let c = chars.first, c.isASCII {
                let charVal = Int32(c.asciiValue ?? 0)
                if charVal >= 32 && charVal < 127 && charVal != q3Key {
                    ClientUI.shared.keyEvent(charVal, down: true)
                }
            }
        case .keyUp:
            let q3Key = macKeyToQ3(event.keyCode)
            ClientUI.shared.keyEvent(q3Key, down: false)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            // Scale pixel deltas to Q3 640x480 virtual screen
            let viewSize = view.bounds.size
            let scaleX = 640.0 / viewSize.width
            let scaleY = 480.0 / viewSize.height
            let dx = Int32(event.deltaX * scaleX)
            let dy = Int32(event.deltaY * scaleY)
            if dx != 0 || dy != 0 {
                ClientUI.shared.mouseEvent(dx, dy)
            }
        default:
            break
        }
    }

    /// Handle input during gameplay
    private func handleGameEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            keysDown.insert(event.keyCode)
            updateMovement()
            ClientInput.shared.keyDown(event.keyCode)
            // Toggle console with tilde/backtick
            if event.keyCode == 50 { // backtick key
                Q3Console.shared.isOpen = !Q3Console.shared.isOpen
            } else {
                // Route through binding system
                let q3Key = macKeyToQ3(event.keyCode)
                ClientMain.shared.keyEvent(q3Key, down: true)
            }
        case .keyUp:
            keysDown.remove(event.keyCode)
            updateMovement()
            ClientInput.shared.keyUp(event.keyCode)
            // Route through binding system
            let q3Key = macKeyToQ3(event.keyCode)
            ClientMain.shared.keyEvent(q3Key, down: false)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            renderMain?.mouseDeltaX += Float(event.deltaX)
            renderMain?.mouseDeltaY += Float(event.deltaY)
            ClientInput.shared.mouseMove(dx: Float(event.deltaX), dy: Float(event.deltaY))
            // Re-warp cursor to center so it never reaches screen edges
            if mouseCaptured {
                warpCursorToWindowCenter()
            }
        default:
            break
        }
    }

    private func updateMovement() {
        guard let rm = renderMain else { return }

        // WASD movement
        rm.moveForward = 0
        rm.moveRight = 0
        rm.moveUp = 0

        if keysDown.contains(13) || keysDown.contains(126) { rm.moveForward += 1 }  // W or Up
        if keysDown.contains(1) || keysDown.contains(125) { rm.moveForward -= 1 }   // S or Down
        if keysDown.contains(0) || keysDown.contains(123) { rm.moveRight -= 1 }     // A or Left
        if keysDown.contains(2) || keysDown.contains(124) { rm.moveRight += 1 }     // D or Right
        if keysDown.contains(49) { rm.moveUp += 1 }                                  // Space
        if keysDown.contains(56) { rm.moveUp -= 1 }                                  // Shift (crouch)
    }

    // Accept first responder for key events
    override var acceptsFirstResponder: Bool { true }

    // Handle key events here (not calling super prevents beep)
    override func keyDown(with event: NSEvent) {
        handleEvent(event)
    }
    override func keyUp(with event: NSEvent) {
        handleEvent(event)
    }

    // Mouse movement handled by local event monitor (setupInput) — no overrides needed

    override func mouseDown(with event: NSEvent) {
        if uiActive {
            ClientUI.shared.keyEvent(178, down: true)  // K_MOUSE1 down
        } else {
            if !mouseCaptured { captureMouse() }
            ClientMain.shared.keyEvent(178, down: true)  // K_MOUSE1 → binding → +attack
        }
    }

    override func mouseUp(with event: NSEvent) {
        if uiActive {
            ClientUI.shared.keyEvent(178, down: false)  // K_MOUSE1 up
        } else {
            ClientMain.shared.keyEvent(178, down: false)  // K_MOUSE1 → binding → -attack
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if uiActive {
            ClientUI.shared.keyEvent(179, down: true)  // K_MOUSE2 down
        } else {
            if !mouseCaptured { captureMouse() }
            ClientMain.shared.keyEvent(179, down: true)  // K_MOUSE2
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if uiActive {
            ClientUI.shared.keyEvent(179, down: false)  // K_MOUSE2 up
        } else {
            ClientMain.shared.keyEvent(179, down: false)  // K_MOUSE2
        }
    }

    // MARK: - macOS Key Code → Q3 Key Number Mapping

    private func macKeyToQ3(_ keyCode: UInt16) -> Int32 {
        switch keyCode {
        case 53: return 27     // Escape → K_ESCAPE
        case 36: return 13     // Return → K_ENTER
        case 48: return 9      // Tab → K_TAB
        case 51: return 127    // Delete → K_BACKSPACE
        case 49: return 32     // Space
        case 126: return 132   // Up → K_UPARROW
        case 125: return 133   // Down → K_DOWNARROW
        case 123: return 134   // Left → K_LEFTARROW
        case 124: return 135   // Right → K_RIGHTARROW
        case 56: return 138    // Left Shift → K_SHIFT
        case 59: return 137    // Left Control → K_CTRL
        case 58: return 136    // Left Alt → K_ALT
        case 50: return 96     // Backtick → `
        // Letter keys (a-z)
        case 0: return 97      // A
        case 11: return 98     // B
        case 8: return 99      // C
        case 2: return 100     // D
        case 14: return 101    // E
        case 3: return 102     // F
        case 5: return 103     // G
        case 4: return 104     // H
        case 34: return 105    // I
        case 38: return 106    // J
        case 40: return 107    // K
        case 37: return 108    // L
        case 46: return 109    // M
        case 45: return 110    // N
        case 31: return 111    // O
        case 35: return 112    // P
        case 12: return 113    // Q
        case 15: return 114    // R
        case 1: return 115     // S
        case 17: return 116    // T
        case 32: return 117    // U
        case 9: return 118     // V
        case 13: return 119    // W
        case 7: return 120     // X
        case 16: return 121    // Y
        case 6: return 122     // Z
        // Number keys
        case 29: return 48     // 0
        case 18: return 49     // 1
        case 19: return 50     // 2
        case 20: return 51     // 3
        case 21: return 52     // 4
        case 23: return 53     // 5
        case 22: return 54     // 6
        case 26: return 55     // 7
        case 28: return 56     // 8
        case 25: return 57     // 9
        // F keys
        case 122: return 145   // F1 → K_F1
        case 120: return 146   // F2
        case 99: return 147    // F3
        case 118: return 148   // F4
        case 96: return 149    // F5
        case 97: return 150    // F6
        case 98: return 151    // F7
        case 100: return 152   // F8
        case 101: return 153   // F9
        case 109: return 154   // F10
        case 103: return 155   // F11
        case 111: return 156   // F12
        default:
            // Try to map from character
            return Int32(keyCode) + 200
        }
    }
}
