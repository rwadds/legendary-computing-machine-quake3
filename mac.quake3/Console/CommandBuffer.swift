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
