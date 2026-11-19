import Foundation

/// The saved voice-mode conversations for the Voice page. The page is a Mac-only client of the chat, so this stays a plain
/// read here and is not part of the API.
enum VoiceHistory {
    static func threads(limit: Int = 20) -> [ChatThread] { ThreadStore.voice(limit: limit) }
}
