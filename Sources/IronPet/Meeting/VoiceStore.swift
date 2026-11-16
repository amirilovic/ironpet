import CryptoKit
import Foundation
import Security

/// One person ironpet can recognise by voice. Biometric data: it stays in the encrypted store on this Mac.
struct StoredVoice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Unit length, 256 floats.
    var centroid: [Float]
    var seconds: Double
    var confirmedMeetings: Int
    var created: Date
    var updated: Date
    var modelId: String
}

/// The voices ironpet has been taught, in its own file in Application Support. The file is AES-GCM encrypted with a key
/// in the Keychain, so it is useless when copied off the Mac, and it holds no audio and no transcript text.
final class VoiceStore {
    /// The embedding model the centroids belong to. A different id makes every stored centroid meaningless.
    static let currentModelId = "fluidaudio-offline-wespeaker-256-v1"

    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent(Paths.isIsolated ? "IronPet-test" : "IronPet", isDirectory: true)
        return folder.appendingPathComponent("voices.enc")
    }()

    static let shared = VoiceStore(url: defaultURL, key: { VoiceStoreKey.load() })

    private let url: URL
    private let key: () -> SymmetricKey?
    private let lock = NSLock()
    let modelId: String

    init(url: URL, key: @escaping () -> SymmetricKey?, modelId: String = VoiceStore.currentModelId) {
        self.url = url
        self.key = key
        self.modelId = modelId
    }

    /// Voices from the current embedding model. A store written by another model is ignored, and removed on the next write.
    func voices() -> [StoredVoice] {
        lock.lock()
        defer { lock.unlock() }
        return (read() ?? []).filter { $0.modelId == modelId }
    }

    /// True when a store file exists, readable or not. Settings uses it to keep "Forget all voices" available for a file that cannot be read.
    var hasFile: Bool { FileManager.default.fileExists(atPath: url.path) }

    var candidates: [VoiceCandidate] {
        voices().map { VoiceCandidate(id: $0.id, name: $0.name, centroid: $0.centroid) }
    }

    /// Adds `embedding` to the person called `name`, or creates them. Clusters with less than the minimum speech do nothing.
    /// `meetingConfirmed` counts the meeting once for this person. Returns the voice, or nil when nothing was stored.
    @discardableResult
    func enroll(name: String, embedding: [Float], seconds: Double, meetingConfirmed: Bool = true, now: Date = Date()) -> StoredVoice? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, seconds >= SpeakerThresholds.minEnrollSeconds, !embedding.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let stored = read() else {
            NSLog("ironpet: the voice store cannot be read, so it is left as it is. Forget all voices to start again.")
            return nil
        }
        var all = stored.filter { $0.modelId == modelId }
        let unit = SpeakerMatcher.normalized(embedding)
        var voice: StoredVoice
        if let index = all.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            voice = all[index]
            voice.centroid = SpeakerMatcher.merge(voice.centroid, oldSeconds: voice.seconds, unit, newSeconds: seconds)
            voice.seconds += seconds
            if meetingConfirmed { voice.confirmedMeetings += 1 }
            voice.updated = now
            all[index] = voice
        } else {
            voice = StoredVoice(id: UUID().uuidString, name: name, centroid: unit, seconds: seconds,
                                confirmedMeetings: meetingConfirmed ? 1 : 0, created: now, updated: now, modelId: modelId)
            all.append(voice)
        }
        write(all)
        return voice
    }

    func forget(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = read() else {
            NSLog("ironpet: the voice store cannot be read, so no voice was forgotten. Forget all voices deletes the file.")
            return
        }
        write(stored.filter { $0.id != id && $0.modelId == modelId })
    }

    /// Deletes the file, so nothing is left to recover.
    func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: File

    /// Nil when a file exists but cannot be decrypted or decoded, so a caller never overwrites it with a shorter list.
    private func read() -> [StoredVoice]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let key = key(), let data = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder.iso.decode([StoredVoice].self, from: plain)
    }

    private func write(_ voices: [StoredVoice]) {
        if voices.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let key = key(), let plain = try? JSONEncoder.iso.encode(voices),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else {
            NSLog("ironpet: could not encrypt the voice store")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("ironpet: could not write the voice store: \(error)")
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// The store's AES key, created on first use and kept in the Keychain (service `ironpet.voiceprints`).
enum VoiceStoreKey {
    static let service = "ironpet.voiceprints"
    static let account = "store-key"
    /// An automated run must never wait on a Keychain dialog, so `--test-mode` keeps a key for the process only.
    nonisolated(unsafe) private static var processKey: SymmetricKey?

    static func load() -> SymmetricKey? {
        if CommandLine.arguments.contains("--test-mode") {
            if processKey == nil { processKey = SymmetricKey(size: .bits256) }
            return processKey
        }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        var query = match
        query[kSecReturnData as String] = true
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        var item = match
        item[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return nil }
        return fresh
    }
}
