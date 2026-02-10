// ServerClient.swift — Client connection, userinfo, command handling

import Foundation

extension ServerMain {

    // MARK: - Local Client Connection

    /// Connect a local client (for single-player/loopback)
    @discardableResult
    func connectLocalClient() -> Bool {
        let clientNum = 0  // Local client is always client 0

        guard clientNum < maxClients else {
            Q3Console.shared.error("No client slots available")
            return false
        }

        // Set default userinfo (ip=localhost signals local client to game VM, skipping password check)
        let userinfo = "\\name\\Player\\ip\\localhost\\rate\\25000\\snaps\\20\\model\\sarge\\headmodel\\sarge\\handicap\\100\\color1\\4\\color2\\5"
        clients[clientNum].userinfo = userinfo
        clients[clientNum].name = "Player"
        clients[clientNum].rate = 25000
        clients[clientNum].snapshotMsec = 50

        // Connect through game VM
        if let errorMsg = clientConnect(clientNum: clientNum, firstTime: true) {
            Q3Console.shared.error("Client connect failed: \(errorMsg)")
            return false
        }

        Q3Console.shared.print("Local client connected")

        // Begin
        clientBegin(clientNum: clientNum)
        Q3Console.shared.print("Local client entered game")

        // Build initial snapshot so cgame has valid data during CG_INIT
        ServerSnapshot.shared.buildClientSnapshot(clientNum: clientNum)

        return true
    }

    // MARK: - Userinfo

    func userinfoChanged(clientNum: Int) {
        guard clientNum >= 0 && clientNum < maxClients else { return }

        // Extract name from userinfo
        let info = clients[clientNum].userinfo
        if let name = infoValueForKey(info, key: "name") {
            clients[clientNum].name = name
        }

        // Extract rate
        if let rateStr = infoValueForKey(info, key: "rate"), let rate = Int32(rateStr) {
            clients[clientNum].rate = max(1000, min(90000, rate))
        }

        // Extract snaps
        if let snapsStr = infoValueForKey(info, key: "snaps"), let snaps = Int32(snapsStr) {
            clients[clientNum].snapshotMsec = max(50, 1000 / max(1, snaps))
        }

        // Notify game
        if let gvm = gameVM {
            _ = QVMInterpreter.call(gvm, command: GameExport.gameClientUserinfoChanged.rawValue,
                                    args: [Int32(clientNum)])
        }
    }

    // MARK: - Client Commands

    func executeClientCommand(clientNum: Int, command: String) {
        guard clientNum >= 0 && clientNum < maxClients else { return }
        guard clients[clientNum].state >= .connected else { return }

        // Tokenize the command
        Q3CommandBuffer.shared.tokenize(command)

        let cmd = Q3CommandBuffer.shared.commandArgv(0).lowercased()

        switch cmd {
        case "userinfo":
            let info = Q3CommandBuffer.shared.commandArgs()
            clients[clientNum].userinfo = info
            userinfoChanged(clientNum: clientNum)

        case "disconnect":
            clientDisconnect(clientNum: clientNum)

        default:
            // Forward to game VM
            if gameVM != nil {
                self.clientCommand(clientNum: clientNum)
            }
        }
    }

    // MARK: - Process Usercmd

    func clientThink(clientNum: Int, cmd: UserCmd) {
        guard clientNum >= 0 && clientNum < maxClients else { return }
        guard clients[clientNum].state == .active else { return }

        clients[clientNum].lastUsercmd = cmd
    }

    // MARK: - Info String Parsing

    private func infoValueForKey(_ info: String, key: String) -> String? {
        var remaining = info[info.startIndex...]
        while !remaining.isEmpty {
            // Skip leading backslash
            if remaining.first == "\\" {
                remaining = remaining.dropFirst()
            }

            // Read key
            var k = ""
            while let c = remaining.first, c != "\\" {
                k.append(c)
                remaining = remaining.dropFirst()
            }

            // Skip separator
            if remaining.first == "\\" {
                remaining = remaining.dropFirst()
            }

            // Read value
            var v = ""
            while let c = remaining.first, c != "\\" {
                v.append(c)
                remaining = remaining.dropFirst()
            }

            if k == key { return v }
        }
        return nil
    }

    // MARK: - Send Gamestate

    func sendGamestate(clientNum: Int) {
        guard clientNum >= 0 && clientNum < maxClients else { return }

        let client = clients[clientNum]
        _ = client  // Used for tracking state

        // In a full implementation, this would send all config strings
        // and entity baselines to the client. For loopback, we handle
        // this more directly.

        clients[clientNum].state = .primed
        clients[clientNum].gamestateMessageNum = snapshotCounter
    }
}
