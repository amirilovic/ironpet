import Foundation
import os

/// One line per event that clears the chat, opens a thread, changes the folder or agent, or restarts the agent process.
/// Read it with `log show --predicate 'subsystem == "com.ironpet" AND category == "chat"'`.
enum ChatLog {
    private static let logger = Logger(subsystem: "com.ironpet", category: "chat")
    /// Receives every message. Tests set it to check what was logged.
    nonisolated(unsafe) static var sink: ((String) -> Void)?

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        sink?(message)
    }
}
