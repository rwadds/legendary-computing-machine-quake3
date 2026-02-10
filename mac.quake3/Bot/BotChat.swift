// BotChat.swift — Bot chat/personality system

import Foundation

class BotChat {
    static let shared = BotChat()

    // Chat message queue
    private var chatQueue: [(clientNum: Int, text: String, teamOnly: Bool)] = []

    private init() {}

    // MARK: - Chat

    func say(clientNum: Int, text: String, teamOnly: Bool) {
        chatQueue.append((clientNum: clientNum, text: text, teamOnly: teamOnly))
        Q3Console.shared.print("Bot \(clientNum): \(text)")
    }

    func getNextMessage() -> (clientNum: Int, text: String, teamOnly: Bool)? {
        guard !chatQueue.isEmpty else { return nil }
        return chatQueue.removeFirst()
    }

    func clearMessages() {
        chatQueue.removeAll()
    }

    // MARK: - Chat Generation (simplified)

    /// Generate a chat string for a specific situation
    func generateChat(clientNum: Int, situation: ChatSituation) -> String {
        switch situation {
        case .death:
            return deathChats.randomElement() ?? "Good fight!"
        case .kill:
            return killChats.randomElement() ?? "Got you!"
        case .greeting:
            return greetingChats.randomElement() ?? "Hi!"
        case .taunt:
            return tauntChats.randomElement() ?? "Come get some!"
        case .teamOrder:
            return "On it!"
        }
    }

    // MARK: - Chat Templates

    enum ChatSituation {
        case death
        case kill
        case greeting
        case taunt
        case teamOrder
    }

    private let deathChats = [
        "Nice shot!",
        "I'll be back!",
        "Lucky shot...",
        "You won't get me next time!",
        "Good one!"
    ]

    private let killChats = [
        "Too easy!",
        "You need more practice!",
        "Got you!",
        "Don't feel bad about it.",
        "That was fun!"
    ]

    private let greetingChats = [
        "Hello!",
        "Hi there!",
        "Let's do this!",
        "Ready to play!",
        "Hey!"
    ]

    private let tauntChats = [
        "Come get some!",
        "Is that all you got?",
        "Try harder!",
        "Over here!",
        "Catch me if you can!"
    ]
}
