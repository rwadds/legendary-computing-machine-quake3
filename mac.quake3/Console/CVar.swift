// CVar.swift — Console Variable system

import Foundation

class Q3CVar {
    static let shared = Q3CVar()

    private var cvars: [String: CVar] = [:]
    private var cvarList: [CVar] = []

    struct CVar {
        let name: String
        var string: String
        var resetString: String
        var latchedString: String?
        var flags: CVarFlags
        var modified: Bool
        var modificationCount: Int
        var value: Float
        var integer: Int32
    }

    private init() {}

    // MARK: - Get/Register

    @discardableResult
    func get(_ name: String, defaultValue: String, flags: CVarFlags = []) -> CVar {
        let key = name.lowercased()
        if var existing = cvars[key] {
            // Add any new flags
            existing.flags.formUnion(flags)
            cvars[key] = existing
            return existing
        }

        let cvar = CVar(
            name: name,
            string: defaultValue,
            resetString: defaultValue,
            latchedString: nil,
            flags: flags,
            modified: true,
            modificationCount: 1,
            value: Float(defaultValue) ?? 0,
            integer: Int32(defaultValue) ?? 0
        )
        cvars[key] = cvar
        cvarList.append(cvar)
        return cvar
    }

    func register(_ vmCvar: inout VMCVar, name: String, defaultValue: String, flags: CVarFlags = []) {
        let cvar = get(name, defaultValue: defaultValue, flags: flags)
        vmCvar.handle = Int32(cvarList.count) // handle is index+1
        vmCvar.modificationCount = Int32(cvar.modificationCount)
        vmCvar.value = cvar.value
        vmCvar.integer = cvar.integer
        vmCvar.string = cvar.string
    }

    func update(_ vmCvar: inout VMCVar, name: String) {
        guard let cvar = find(name) else { return }
        vmCvar.modificationCount = Int32(cvar.modificationCount)
        vmCvar.value = cvar.value
        vmCvar.integer = cvar.integer
        vmCvar.string = cvar.string
    }

    // MARK: - Find

    func find(_ name: String) -> CVar? {
        return cvars[name.lowercased()]
    }

    // MARK: - Set

    @discardableResult
    func set(_ name: String, value: String, flags: CVarFlags = [], force: Bool = false) -> CVar {
        let key = name.lowercased()

        if var existing = cvars[key] {
            if !force {
                // Check for read-only (VM-initiated sets bypass this with force:true)
                if existing.flags.contains(.rom) {
                    Q3Console.shared.print("\"\(name)\" is read only")
                    return existing
                }

                // Check for init-only
                if existing.flags.contains(.initOnly) {
                    Q3Console.shared.print("\(name) can only be set at initialization")
                    return existing
                }
            }

            // Check for latched (VM force-sets bypass this)
            if !force && existing.flags.contains(.latch) {
                if existing.string != value {
                    existing.latchedString = value
                    Q3Console.shared.print("\(name) will be changed upon restart")
                    cvars[key] = existing
                }
                return existing
            }

            existing.string = value
            existing.value = Float(value) ?? 0
            existing.integer = Int32(value) ?? 0
            existing.modified = true
            existing.modificationCount += 1
            existing.flags.formUnion(flags)
            cvars[key] = existing

            // Update in cvarList too
            if let idx = cvarList.firstIndex(where: { $0.name.lowercased() == key }) {
                cvarList[idx] = existing
            }

            return existing
        }

        // Create new cvar
        return get(name, defaultValue: value, flags: flags)
    }

    func setFloat(_ name: String, value: Float) {
        set(name, value: String(value))
    }

    func setInt(_ name: String, value: Int32) {
        set(name, value: String(value))
    }

    // MARK: - Convenience Getters

    func variableValue(_ name: String) -> Float {
        return find(name)?.value ?? 0
    }

    func variableIntegerValue(_ name: String) -> Int32 {
        return find(name)?.integer ?? 0
    }

    func variableString(_ name: String) -> String {
        return find(name)?.string ?? ""
    }

    // MARK: - Command Interface

    func handleCommand(_ name: String, args: String?) -> Bool {
        guard let cvar = find(name) else { return false }

        if let args = args, !args.isEmpty {
            set(name, value: args)
        } else {
            Q3Console.shared.print("\"\(cvar.name)\" is: \"\(cvar.string)\" default: \"\(cvar.resetString)\"")
        }
        return true
    }

    // MARK: - List

    func listCVars() {
        let sorted = cvarList.sorted { $0.name < $1.name }
        for cvar in sorted {
            var flagStr = ""
            if cvar.flags.contains(.archive) { flagStr += "A" }
            if cvar.flags.contains(.userInfo) { flagStr += "U" }
            if cvar.flags.contains(.serverInfo) { flagStr += "S" }
            if cvar.flags.contains(.rom) { flagStr += "R" }
            if cvar.flags.contains(.initOnly) { flagStr += "I" }
            if cvar.flags.contains(.latch) { flagStr += "L" }
            if cvar.flags.contains(.cheat) { flagStr += "C" }

            let padded = flagStr.padding(toLength: 7, withPad: " ", startingAt: 0)
            Q3Console.shared.print(" \(padded) \(cvar.name) = \"\(cvar.string)\"")
        }
        Q3Console.shared.print("\(sorted.count) total cvars")
    }

    // MARK: - Completion

    func completeName(_ partial: String) -> [String] {
        let lower = partial.lowercased()
        return cvars.keys.filter { $0.hasPrefix(lower) }.sorted()
    }

    // MARK: - Info String

    func infoString(bit: CVarFlags) -> String {
        var info = ""
        for cvar in cvarList {
            if cvar.flags.contains(bit) {
                info += "\\\(cvar.name)\\\(cvar.string)"
            }
        }
        return info
    }

    // MARK: - Reset

    func reset(_ name: String) {
        let key = name.lowercased()
        guard var cvar = cvars[key] else { return }
        cvar.string = cvar.resetString
        cvar.value = Float(cvar.resetString) ?? 0
        cvar.integer = Int32(cvar.resetString) ?? 0
        cvar.modified = true
        cvar.modificationCount += 1
        cvars[key] = cvar
    }

    func setCheatState() {
        for key in cvars.keys {
            guard var cvar = cvars[key] else { continue }
            if cvar.flags.contains(.cheat) {
                cvar.string = cvar.resetString
                cvar.value = Float(cvar.resetString) ?? 0
                cvar.integer = Int32(cvar.resetString) ?? 0
                cvar.modified = true
                cvar.modificationCount += 1
                cvars[key] = cvar
            }
        }
    }

    // MARK: - Latched Values

    func applyLatchedValues() {
        for key in cvars.keys {
            guard var cvar = cvars[key] else { continue }
            if let latched = cvar.latchedString {
                cvar.string = latched
                cvar.value = Float(latched) ?? 0
                cvar.integer = Int32(latched) ?? 0
                cvar.latchedString = nil
                cvar.modified = true
                cvar.modificationCount += 1
                cvars[key] = cvar
            }
        }
    }
}
