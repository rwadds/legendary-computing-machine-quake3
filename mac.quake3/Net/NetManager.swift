// NetManager.swift — Loopback network driver for single-player

import Foundation

class NetManager {
    static let shared = NetManager()

    // Loopback buffers
    private var clientToServer: [Data] = []
    private var serverToClient: [Data] = []
    private let maxLoopbackMessages = 64

    // Connection state
    var connected = false

    private init() {}

    // MARK: - Client → Server

    func sendClientMessage(_ data: Data) {
        guard connected else { return }
        if clientToServer.count < maxLoopbackMessages {
            clientToServer.append(data)
        }
    }

    func receiveServerSideMessages() -> [Data] {
        let messages = clientToServer
        clientToServer.removeAll(keepingCapacity: true)
        return messages
    }

    // MARK: - Server → Client

    func sendServerMessage(_ data: Data) {
        guard connected else { return }
        if serverToClient.count < maxLoopbackMessages {
            serverToClient.append(data)
        }
    }

    func receiveClientSideMessages() -> [Data] {
        let messages = serverToClient
        serverToClient.removeAll(keepingCapacity: true)
        return messages
    }

    // MARK: - Connection

    func connect() {
        connected = true
        clientToServer.removeAll()
        serverToClient.removeAll()
    }

    func disconnect() {
        connected = false
        clientToServer.removeAll()
        serverToClient.removeAll()
    }
}
