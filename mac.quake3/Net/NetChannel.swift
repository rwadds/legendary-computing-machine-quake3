// NetChannel.swift — Simplified reliable/unreliable message channel for loopback

import Foundation

class NetChannel {
    var outgoingSequence: Int32 = 1
    var incomingSequence: Int32 = 0
    var dropped: Int32 = 0

    // Reliable command queue
    var reliableCommands: [String] = Array(repeating: "", count: 128)
    var reliableSequence: Int32 = 0
    var reliableAcknowledge: Int32 = 0

    // Server commands received
    var serverCommands: [String] = Array(repeating: "", count: 128)
    var serverCommandSequence: Int32 = 0
    var lastExecutedServerCommand: Int32 = 0

    // MARK: - Reliable Commands

    func addReliableCommand(_ cmd: String) {
        reliableSequence += 1
        let idx = Int(reliableSequence) & 127
        reliableCommands[idx] = cmd
    }

    func getReliableCommand(sequence: Int32) -> String? {
        guard sequence > 0 && sequence <= reliableSequence else { return nil }
        let idx = Int(sequence) & 127
        return reliableCommands[idx]
    }

    // MARK: - Server Commands

    func addServerCommand(_ cmd: String) {
        serverCommandSequence += 1
        let idx = Int(serverCommandSequence) & 127
        serverCommands[idx] = cmd
    }

    func getServerCommand(sequence: Int32) -> String? {
        guard sequence > 0 && sequence <= serverCommandSequence else { return nil }
        let idx = Int(sequence) & 127
        return serverCommands[idx]
    }

    // MARK: - Send/Receive for Loopback

    func transmit(_ msg: MessageBuffer) {
        let data = Data(msg.data[0..<msg.curSize])
        outgoingSequence += 1

        // For loopback, just push to NetManager
        NetManager.shared.sendClientMessage(data)
    }

    func transmitFromServer(_ msg: MessageBuffer) {
        let data = Data(msg.data[0..<msg.curSize])
        NetManager.shared.sendServerMessage(data)
    }

    func reset() {
        outgoingSequence = 1
        incomingSequence = 0
        dropped = 0
        reliableSequence = 0
        reliableAcknowledge = 0
        serverCommandSequence = 0
        lastExecutedServerCommand = 0
    }
}
