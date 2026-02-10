// Console.swift — Quake III console system

import Foundation

class Q3Console {
    static let shared = Q3Console()

    private static let MAX_CONSOLE_LINES = 1024
    private static let MAX_NOTIFY_LINES = 4
    private static let NOTIFY_TIME: Double = 3.0

    // Print buffer
    private(set) var text: String = ""
    private(set) var lines: [ConsoleLine] = []

    // Notification lines (temporary on-screen messages)
    private(set) var notifyLines: [NotifyLine] = []

    // Scroll position
    var scrollOffset: Int = 0
    var isOpen: Bool = false

    struct ConsoleLine {
        let text: String
        let time: Double
    }

    struct NotifyLine {
        let text: String
        let time: Double
    }

    private init() {}

    // MARK: - Print

    func print(_ message: String) {
        // Also print to stdout for debugging
        Swift.print("[Q3] \(message)")

        text += message
        if !message.hasSuffix("\n") {
            text += "\n"
        }

        let time = ProcessInfo.processInfo.systemUptime
        let msgLines = message.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in msgLines {
            lines.append(ConsoleLine(text: line, time: time))
            notifyLines.append(NotifyLine(text: line, time: time))
        }

        // Trim old lines
        if lines.count > Q3Console.MAX_CONSOLE_LINES {
            lines.removeFirst(lines.count - Q3Console.MAX_CONSOLE_LINES)
        }
    }

    func warning(_ message: String) {
        print("WARNING: \(message)")
    }

    func error(_ message: String) {
        print("ERROR: \(message)")
    }

    // MARK: - Notifications

    func getActiveNotifications() -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        let cutoff = now - Q3Console.NOTIFY_TIME

        // Remove expired
        notifyLines.removeAll { $0.time < cutoff }

        // Return last N
        let count = min(notifyLines.count, Q3Console.MAX_NOTIFY_LINES)
        if count == 0 { return [] }
        return notifyLines.suffix(count).map { $0.text }
    }

    func clearNotifications() {
        notifyLines.removeAll()
    }

    // MARK: - Scroll

    func scrollUp(_ lines: Int = 1) {
        scrollOffset = min(scrollOffset + lines, max(0, self.lines.count - 10))
    }

    func scrollDown(_ lines: Int = 1) {
        scrollOffset = max(0, scrollOffset - lines)
    }

    func scrollToBottom() {
        scrollOffset = 0
    }

    func clear() {
        text = ""
        lines.removeAll()
        scrollOffset = 0
    }

    // MARK: - Visible Lines

    func getVisibleLines(maxLines: Int) -> [String] {
        if lines.isEmpty { return [] }
        let endIndex = lines.count - scrollOffset
        let startIndex = max(0, endIndex - maxLines)
        guard startIndex < endIndex else { return [] }
        return lines[startIndex..<endIndex].map { $0.text }
    }
}
