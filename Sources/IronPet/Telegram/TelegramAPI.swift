import Foundation
import Security

struct TelegramUser: Codable, Equatable {
    let id: Int64
    let isBot: Bool?
    let firstName: String?
    let lastName: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
    }

    var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? (username ?? String(id)) : full
    }
}

/// A file Telegram stores for a message: a photo size, document, voice message, audio, video or video note.
struct TelegramAttachment: Codable, Equatable {
    let fileId: String
    var fileSize: Int?
    var fileName: String?
    var mimeType: String?

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileSize = "file_size"
        case fileName = "file_name"
        case mimeType = "mime_type"
    }
}

struct TelegramMessage: Codable, Equatable {
    /// The message this one replies to. Telegram nests it one level only, so the original has no reply of its own here.
    struct Original: Codable, Equatable {
        let from: TelegramUser?
        let text: String?
        var caption: String? = nil
        /// Lets a reply be matched to the bot message it answers.
        var messageId: Int64? = nil

        enum CodingKeys: String, CodingKey {
            case from, text, caption
            case messageId = "message_id"
        }
    }

    struct Chat: Codable, Equatable {
        let id: Int64
        let type: String
    }

    let messageId: Int64
    let from: TelegramUser?
    let chat: Chat
    let text: String?
    var caption: String? = nil
    /// The same photo in several sizes, smallest first.
    var photo: [TelegramAttachment]? = nil
    var document: TelegramAttachment? = nil
    var voice: TelegramAttachment? = nil
    var audio: TelegramAttachment? = nil
    var video: TelegramAttachment? = nil
    var videoNote: TelegramAttachment? = nil
    /// Photos or documents sent together as an album share this id.
    var mediaGroupId: String? = nil
    /// Set when the user used Telegram's own Reply.
    var replyToMessage: Original? = nil

    enum CodingKeys: String, CodingKey {
        case from, chat, text, caption, photo, document, voice, audio, video
        case replyToMessage = "reply_to_message"
        case messageId = "message_id"
        case videoNote = "video_note"
        case mediaGroupId = "media_group_id"
    }
}

/// A tap on an inline keyboard button.
struct TelegramCallback: Codable, Equatable {
    let id: String
    let from: TelegramUser
    var message: TelegramMessage?
    var data: String?
}

struct TelegramUpdate: Codable, Equatable {
    let updateId: Int
    var message: TelegramMessage?
    var callbackQuery: TelegramCallback? = nil

    enum CodingKeys: String, CodingKey {
        case message
        case updateId = "update_id"
        case callbackQuery = "callback_query"
    }
}

/// Where Telegram keeps a file for download. `getFile` returns it.
struct TelegramFilePath: Codable, Equatable {
    let filePath: String?
    var fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileSize = "file_size"
    }
}

struct TelegramButton: Equatable {
    let text: String
    let data: String
}

enum TelegramError: LocalizedError, Equatable {
    case noToken
    /// The Bot API answered `ok: false`.
    case api(code: Int, description: String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No bot token saved."
        case .api(401, _): return "Telegram rejected the bot token."
        case .api(409, _): return "Another program is polling this bot (409). Stop it, or use a different bot."
        case .api(let code, let description): return "Telegram error \(code): \(description)"
        case .network(let message): return "Network error: \(message)"
        }
    }
}

/// The part of the Bot API ironpet uses. The real one talks HTTPS; tests use a fake.
protocol TelegramClient: Sendable {
    func getMe() async throws -> TelegramUser
    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate]
    /// `html` true sends `text` with parse mode HTML. `keyboard` is the inline keyboard, one array per row. Returns the
    /// new message's id.
    @discardableResult
    func sendMessage(chat: Int64, text: String, html: Bool, keyboard: [[TelegramButton]]) async throws -> Int64
    /// Replaces a message's text and its inline keyboard. An empty keyboard removes it.
    func editMessage(chat: Int64, messageID: Int64, text: String, keyboard: [[TelegramButton]]) async throws
    func answerCallback(id: String, text: String?, alert: Bool) async throws
    func sendChatAction(chat: Int64) async throws
    func getFile(id: String) async throws -> TelegramFilePath
    func download(path: String) async throws -> Data
}

extension TelegramClient {
    func sendMessage(chat: Int64, text: String, html: Bool) async throws {
        try await sendMessage(chat: chat, text: text, html: html, keyboard: [])
    }

    /// `buttons` become one row.
    @discardableResult
    func sendMessage(chat: Int64, text: String, html: Bool, buttons: [TelegramButton]) async throws -> Int64 {
        try await sendMessage(chat: chat, text: text, html: html, keyboard: buttons.isEmpty ? [] : [buttons])
    }

    /// Replaces a message's text and removes its inline keyboard.
    func editMessage(chat: Int64, messageID: Int64, text: String) async throws {
        try await editMessage(chat: chat, messageID: messageID, text: text, keyboard: [])
    }
}

/// Sends one request and returns the status code and body. Swapped out in tests.
protocol TelegramTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionTransport: TelegramTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TelegramError.network(error.localizedDescription)
        }
    }
}

/// The Telegram Bot API over HTTPS, with the bot token read from `token` for every call so a changed token takes
/// effect at once. The token is part of the URL path, so it never goes into a log line or an error message here.
struct TelegramAPI: TelegramClient {
    var token: @Sendable () -> String?
    var transport: TelegramTransport = URLSessionTransport()
    var baseURL: String = TelegramAPI.defaultBase

    static let testMode = CommandLine.arguments.contains("--test-mode")

    static var defaultBase: String {
        // A local fake Bot API for automated runs. Ignored outside test mode.
        if TelegramAPI.testMode, let override = ProcessInfo.processInfo.environment["IRONPET_TELEGRAM_API"] {
            return override
        }
        return "https://api.telegram.org"
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let result: T?
        let errorCode: Int?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case ok, result, description
            case errorCode = "error_code"
        }
    }

    private struct Empty: Decodable {}

    private func call<T: Decodable>(_ method: String, _ body: [String: Any], timeout: TimeInterval = 20, as: T.Type) async throws -> T {
        guard let token = token(), !token.isEmpty, let url = URL(string: "\(baseURL)/bot\(token)/\(method)") else {
            throw TelegramError.noToken
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await transport.send(request)
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw TelegramError.api(code: status, description: "Unexpected response")
        }
        guard envelope.ok, let result = envelope.result else {
            throw TelegramError.api(code: envelope.errorCode ?? status, description: envelope.description ?? "Unknown error")
        }
        return result
    }

    func getMe() async throws -> TelegramUser {
        try await call("getMe", [:], as: TelegramUser.self)
    }

    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] {
        // The HTTP timeout has to outlast the long poll.
        try await call("getUpdates", ["offset": offset, "timeout": timeout, "allowed_updates": ["message", "callback_query"]],
                       timeout: TimeInterval(timeout + 15), as: [TelegramUpdate].self)
    }

    private static func markup(_ keyboard: [[TelegramButton]]) -> [String: Any] {
        ["inline_keyboard": keyboard.map { row in row.map { ["text": $0.text, "callback_data": $0.data] } }]
    }

    func sendMessage(chat: Int64, text: String, html: Bool, keyboard: [[TelegramButton]]) async throws -> Int64 {
        var body: [String: Any] = ["chat_id": chat, "text": text, "disable_web_page_preview": true]
        if html { body["parse_mode"] = "HTML" }
        if !keyboard.isEmpty { body["reply_markup"] = Self.markup(keyboard) }
        return try await call("sendMessage", body, as: TelegramMessage.self).messageId
    }

    func editMessage(chat: Int64, messageID: Int64, text: String, keyboard: [[TelegramButton]]) async throws {
        var body: [String: Any] = ["chat_id": chat, "message_id": messageID, "text": text, "disable_web_page_preview": true]
        if !keyboard.isEmpty { body["reply_markup"] = Self.markup(keyboard) }
        _ = try await call("editMessageText", body, as: TelegramMessage.self)
    }

    func answerCallback(id: String, text: String?, alert: Bool) async throws {
        var body: [String: Any] = ["callback_query_id": id, "show_alert": alert]
        if let text { body["text"] = text }
        _ = try await call("answerCallbackQuery", body, as: Bool.self)
    }

    func sendChatAction(chat: Int64) async throws {
        _ = try await call("sendChatAction", ["chat_id": chat, "action": "typing"], as: Bool.self)
    }

    func getFile(id: String) async throws -> TelegramFilePath {
        try await call("getFile", ["file_id": id], as: TelegramFilePath.self)
    }

    /// The file's bytes. The path comes from `getFile`; downloads are capped by Telegram at 20 MB for bots.
    func download(path: String) async throws -> Data {
        guard let token = token(), !token.isEmpty,
              let url = URL(string: "\(baseURL)/file/bot\(token)/\(path)") else { throw TelegramError.noToken }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw TelegramError.api(code: status, description: "Download failed") }
        return data
    }
}

/// Where the bot token lives. The Keychain in the app; memory in tests and in `--test-mode`, where a Keychain
/// approval dialog would block an automated run.
protocol TelegramTokenStore: AnyObject, Sendable {
    func load() -> String?
    @discardableResult func save(_ token: String) -> Bool
}

extension TelegramTokenStore {
    var isSet: Bool { load() != nil }
}

final class MemoryTokenStore: TelegramTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func load() -> String? { lock.withLock { value } }

    func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { value = trimmed.isEmpty ? nil : trimmed }
        return true
    }
}

/// The bot token, kept in the Keychain (service `ironpet.telegram`) and never written to `~/.ironpet`.
final class TelegramToken: TelegramTokenStore, @unchecked Sendable {
    static let shared: TelegramTokenStore = TelegramAPI.testMode ? MemoryTokenStore() : TelegramToken()

    private let service = "ironpet.telegram"
    private let account = "bot-token"

    private var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> String? {
        var query = match
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Stores `token`, replacing any earlier one. An empty token removes it.
    func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(match as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var item = match
        item[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
