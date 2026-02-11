// CommandBuffer.swift — Command registration, tokenization, and execution

import Foundation
import Cocoa

class Q3CommandBuffer {
    static let shared = Q3CommandBuffer()

    private static let MAX_CMD_BUFFER = 16384
    private static let MAX_CMD_LINE = 1024

    // Registered commands
    private var commands: [String: CommandEntry] = [:]

    struct CommandEntry {
        let name: String
        let handler: () -> Void
        let description: String
    }

    // Command buffer (queued commands)
    private var commandText: String = ""

    // Current tokenized command
    private(set) var argc: Int = 0
    private var argv: [String] = []

    private init() {
        registerBuiltinCommands()
    }

    // MARK: - Command Registration

    func addCommand(_ name: String, description: String = "", handler: @escaping () -> Void) {
        commands[name.lowercased()] = CommandEntry(name: name, handler: handler, description: description)
    }

    func removeCommand(_ name: String) {
        commands.removeValue(forKey: name.lowercased())
    }

    // MARK: - Tokenization

    func tokenize(_ text: String) {
        argc = 0
        argv.removeAll()

        var i = text.startIndex

        while i < text.endIndex {
            // Skip whitespace
            while i < text.endIndex && (text[i] == " " || text[i] == "\t") {
                i = text.index(after: i)
            }
            if i >= text.endIndex { break }

            // Skip // comments
            if i < text.endIndex {
                let nextIdx = text.index(after: i)
                if nextIdx < text.endIndex && text[i] == "/" && text[nextIdx] == "/" {
                    return // rest of line is comment
                }
            }

            var token = ""

            if text[i] == "\"" {
                // Quoted string
                i = text.index(after: i) // skip opening quote
                while i < text.endIndex && text[i] != "\"" {
                    token.append(text[i])
                    i = text.index(after: i)
                }
                if i < text.endIndex {
                    i = text.index(after: i) // skip closing quote
                }
            } else {
                // Unquoted token
                while i < text.endIndex && text[i] != " " && text[i] != "\t" && text[i] != "\n" {
                    token.append(text[i])
                    i = text.index(after: i)
                }
            }

            if !token.isEmpty {
                argv.append(token)
                argc += 1
            }
        }
    }

    func commandArgv(_ index: Int) -> String {
        guard index >= 0 && index < argc else { return "" }
        return argv[index]
    }

    func commandArgs() -> String {
        guard argc > 1 else { return "" }
        return argv[1...].joined(separator: " ")
    }

    func commandArgsFrom(_ index: Int) -> String {
        guard index < argc else { return "" }
        return argv[index...].joined(separator: " ")
    }

    // MARK: - Buffer Operations

    func addText(_ text: String) {
        if commandText.count + text.count > Q3CommandBuffer.MAX_CMD_BUFFER {
            Q3Console.shared.warning("Command buffer overflow")
            return
        }
        commandText += text
    }

    func insertText(_ text: String) {
        commandText = text + "\n" + commandText
    }

    func executeBuffer() {
        while !commandText.isEmpty {
            // Find next command (delimited by \n or ;)
            var cmdEnd = commandText.startIndex
            var inQuotes = false

            for idx in commandText.indices {
                if commandText[idx] == "\"" {
                    inQuotes = !inQuotes
                }
                if !inQuotes && (commandText[idx] == "\n" || commandText[idx] == ";") {
                    cmdEnd = idx
                    break
                }
                cmdEnd = commandText.index(after: idx)
            }

            let cmd = String(commandText[commandText.startIndex..<cmdEnd])
            if cmdEnd < commandText.endIndex {
                commandText = String(commandText[commandText.index(after: cmdEnd)...])
            } else {
                commandText = ""
            }

            let trimmed = cmd.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                executeString(trimmed)
            }
        }
    }

    // MARK: - Execution

    func executeString(_ text: String) {
        tokenize(text)
        guard argc > 0 else { return }

        let cmdName = commandArgv(0).lowercased()

        // Check registered commands
        if let entry = commands[cmdName] {
            entry.handler()
            return
        }

        // Check cvars
        if Q3CVar.shared.handleCommand(cmdName, args: argc > 1 ? commandArgv(1) : nil) {
            return
        }

        // Forward to game VM as server console command (handles addbot, etc.)
        if let gvm = ServerMain.shared.gameVM, ServerMain.shared.state == .game {
            let result = QVMInterpreter.call(gvm, command: GameExport.gameConsoleCommand.rawValue)
            if result != 0 {
                return  // Game VM handled the command
            }
        }

        Q3Console.shared.print("Unknown command: \(cmdName)")
    }

    // MARK: - Built-in Commands

    private func registerBuiltinCommands() {
        addCommand("echo", description: "Print text to console") {
            Q3Console.shared.print(Q3CommandBuffer.shared.commandArgs())
        }

        addCommand("cmdlist", description: "List all commands") {
            let sorted = Q3CommandBuffer.shared.commands.keys.sorted()
            for name in sorted {
                Q3Console.shared.print("  \(name)")
            }
            Q3Console.shared.print("\(sorted.count) commands")
        }

        addCommand("cvarlist", description: "List all cvars") {
            Q3CVar.shared.listCVars()
        }

        addCommand("exec", description: "Execute a config file") {
            let file = Q3CommandBuffer.shared.commandArgv(1)
            guard !file.isEmpty else {
                Q3Console.shared.print("exec <filename>: execute a config file")
                return
            }
            if let data = Q3FileSystem.shared.loadFile(file),
               let text = String(data: data, encoding: .utf8) {
                Q3Console.shared.print("execing \(file)")
                Q3CommandBuffer.shared.insertText(text)
            } else {
                Q3Console.shared.print("Couldn't exec \(file)")
            }
        }

        addCommand("clear", description: "Clear console") {
            Q3Console.shared.clear()
        }

        addCommand("set", description: "Set a cvar value") {
            guard Q3CommandBuffer.shared.argc >= 3 else {
                Q3Console.shared.print("set <variable> <value>")
                return
            }
            let name = Q3CommandBuffer.shared.commandArgv(1)
            let value = Q3CommandBuffer.shared.commandArgsFrom(2)
            Q3CVar.shared.set(name, value: value, flags: .userCreated)
        }

        addCommand("seta", description: "Set and archive a cvar") {
            guard Q3CommandBuffer.shared.argc >= 3 else {
                Q3Console.shared.print("seta <variable> <value>")
                return
            }
            let name = Q3CommandBuffer.shared.commandArgv(1)
            let value = Q3CommandBuffer.shared.commandArgsFrom(2)
            Q3CVar.shared.set(name, value: value, flags: [.userCreated, .archive])
        }

        addCommand("toggle", description: "Toggle a cvar between 0 and 1") {
            guard Q3CommandBuffer.shared.argc >= 2 else {
                Q3Console.shared.print("toggle <variable>")
                return
            }
            let name = Q3CommandBuffer.shared.commandArgv(1)
            if let cvar = Q3CVar.shared.find(name) {
                let newValue = cvar.integer == 0 ? "1" : "0"
                Q3CVar.shared.set(name, value: newValue)
            }
        }

        addCommand("quit", description: "Quit the application") {
            Q3Console.shared.print("QUIT COMMAND RECEIVED (frame \(Q3Engine.shared.frameCount))")
            let symbols = Thread.callStackSymbols
            for (i, sym) in symbols.prefix(10).enumerated() {
                Q3Console.shared.print("  quit[\(i)]: \(sym)")
            }
            NSApplication.shared.terminate(nil)
        }

        addCommand("vstr", description: "Execute a variable's string value") {
            guard Q3CommandBuffer.shared.argc >= 2 else {
                Q3Console.shared.print("vstr <variable>")
                return
            }
            let name = Q3CommandBuffer.shared.commandArgv(1)
            if let cvar = Q3CVar.shared.find(name) {
                Q3CommandBuffer.shared.insertText(cvar.string + "\n")
            }
        }

        addCommand("bind", description: "Bind a key to a command") {
            let cb = Q3CommandBuffer.shared
            guard cb.argc >= 2 else {
                Q3Console.shared.print("bind <key> [command]")
                return
            }
            let keyName = cb.commandArgv(1)
            guard let keyNum = Q3CommandBuffer.keyNumFromString(keyName) else {
                Q3Console.shared.print("Unknown key: \(keyName)")
                return
            }
            if cb.argc == 2 {
                let binding = ClientUI.shared.keyBindings[keyNum] ?? ""
                Q3Console.shared.print("\"\(keyName)\" = \"\(binding)\"")
            } else {
                let command = cb.commandArgsFrom(2)
                ClientUI.shared.keyBindings[keyNum] = command
            }
        }

        addCommand("unbind", description: "Unbind a key") {
            let keyName = Q3CommandBuffer.shared.commandArgv(1)
            if let keyNum = Q3CommandBuffer.keyNumFromString(keyName) {
                ClientUI.shared.keyBindings.removeValue(forKey: keyNum)
            }
        }

        addCommand("unbindall", description: "Remove all key bindings") {
            ClientUI.shared.keyBindings.removeAll()
        }

        addCommand("bindlist", description: "List all key bindings") {
            for (key, binding) in ClientUI.shared.keyBindings.sorted(by: { $0.key < $1.key }) {
                let keyName = Q3CommandBuffer.keyNumToString(key)
                Q3Console.shared.print("\(keyName) = \"\(binding)\"")
            }
        }
    }

    // MARK: - Key Name ↔ Key Number (matches Q3 keycodes.h)

    static func keyNumFromString(_ name: String) -> Int? {
        // Single printable ASCII char
        if name.count == 1, let ch = name.lowercased().first, ch.isASCII, let ascii = ch.asciiValue {
            return Int(ascii)
        }

        switch name.uppercased() {
        case "TAB":         return 9
        case "ENTER", "RETURN", "KP_ENTER": return 13
        case "ESCAPE", "ESC": return 27
        case "SPACE":       return 32
        case "BACKSPACE":   return 127
        case "UPARROW":     return 132
        case "DOWNARROW":   return 133
        case "LEFTARROW":   return 134
        case "RIGHTARROW":  return 135
        case "ALT":         return 136
        case "CTRL":        return 137
        case "SHIFT":       return 138
        case "INS":         return 139
        case "DEL":         return 140
        case "PGDN":        return 141
        case "PGUP":        return 142
        case "HOME":        return 143
        case "END":         return 144
        case "F1":  return 145;  case "F2":  return 146;  case "F3":  return 147
        case "F4":  return 148;  case "F5":  return 149;  case "F6":  return 150
        case "F7":  return 151;  case "F8":  return 152;  case "F9":  return 153
        case "F10": return 154;  case "F11": return 155;  case "F12": return 156
        case "COMMAND":     return 128
        case "CAPSLOCK":    return 129
        case "PAUSE":       return 131
        case "MOUSE1":      return 178
        case "MOUSE2":      return 179
        case "MOUSE3":      return 180
        case "MOUSE4":      return 181
        case "MOUSE5":      return 182
        case "MWHEELDOWN":  return 183
        case "MWHEELUP":    return 184
        case "SEMICOLON":   return 59
        case "KP_HOME":     return 160;  case "KP_UPARROW":  return 161
        case "KP_PGUP":     return 162;  case "KP_LEFTARROW": return 163
        case "KP_5":        return 164;  case "KP_RIGHTARROW": return 165
        case "KP_END":      return 166;  case "KP_DOWNARROW":  return 167
        case "KP_PGDN":     return 168;  case "KP_INS":        return 170
        case "KP_DEL":      return 171;  case "KP_SLASH":      return 172
        case "KP_MINUS":    return 173;  case "KP_PLUS":       return 174
        case "KP_STAR":     return 176;  case "KP_EQUALS":     return 177
        default: return nil
        }
    }

    static func keyNumToString(_ keynum: Int) -> String {
        switch keynum {
        case 9: return "TAB";  case 13: return "ENTER";  case 27: return "ESCAPE"
        case 32: return "SPACE";  case 127: return "BACKSPACE"
        case 128: return "COMMAND";  case 131: return "PAUSE"
        case 132: return "UPARROW";  case 133: return "DOWNARROW"
        case 134: return "LEFTARROW";  case 135: return "RIGHTARROW"
        case 136: return "ALT";  case 137: return "CTRL";  case 138: return "SHIFT"
        case 139: return "INS";  case 140: return "DEL"
        case 141: return "PGDN";  case 142: return "PGUP"
        case 143: return "HOME";  case 144: return "END"
        case 145...156: return "F\(keynum - 144)"
        case 178: return "MOUSE1";  case 179: return "MOUSE2"
        case 180: return "MOUSE3";  case 183: return "MWHEELDOWN"
        case 184: return "MWHEELUP"
        default:
            if keynum >= 32 && keynum < 127 {
                return String(Character(UnicodeScalar(keynum)!))
            }
            return "KEY\(keynum)"
        }
    }

    /// Set up default key bindings (if not already set by config files)
    func setupDefaultBindings() {
        let bindings = ClientUI.shared.keyBindings
        // Only set defaults if bindings are mostly empty (configs didn't load them)
        if bindings.count < 5 {
            let defaults: [(Int, String)] = [
                (49, "weapon 1"),   // 1
                (50, "weapon 2"),   // 2
                (51, "weapon 3"),   // 3
                (52, "weapon 4"),   // 4
                (53, "weapon 5"),   // 5
                (54, "weapon 6"),   // 6
                (55, "weapon 7"),   // 7
                (56, "weapon 8"),   // 8
                (57, "weapon 9"),   // 9
                (178, "+attack"),   // MOUSE1
                (179, "+attack"),   // MOUSE2 (also attack for now)
                (184, "weapnext"), // MWHEELUP
                (183, "weapprev"), // MWHEELDOWN
                (27, "togglemenu"), // ESCAPE
                (9, "+scores"),    // TAB
            ]
            for (key, cmd) in defaults {
                if bindings[key] == nil {
                    ClientUI.shared.keyBindings[key] = cmd
                }
            }
            Q3Console.shared.print("Default key bindings applied")
        }
    }

    // MARK: - Command Completion

    func completeCommand(_ partial: String) -> [String] {
        let lower = partial.lowercased()
        var matches: [String] = []

        for name in commands.keys where name.hasPrefix(lower) {
            matches.append(name)
        }

        // Also check cvars
        matches.append(contentsOf: Q3CVar.shared.completeName(lower))

        return matches.sorted()
    }
}
