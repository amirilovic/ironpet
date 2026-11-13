import Foundation
import Security

/// The transcription server's API key, kept in the Keychain (service `ironpet.voice`) and never written to
/// `~/.ironpet`. Same approach as the Sentry token.
enum VoiceKey {
    static let service = "ironpet.voice"
    static let account = "api-key"

    private static var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = match
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static var isSet: Bool { load() != nil }

    /// Stores `key`, replacing any earlier one. An empty key removes it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(match as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var item = match
        item[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(match as CFDictionary)
    }
}
