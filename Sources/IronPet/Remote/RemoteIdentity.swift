import CryptoKit
import Foundation

/// Where the Mac's Ed25519 private key lives between launches.
protocol RemoteKeyStorage: AnyObject {
    func load() -> Data?
    func save(_ key: Data)
    func erase()
}

/// A file in `~/.ironpet/remote/` readable by the user only, like the hook server's token.
final class FileKeyStorage: RemoteKeyStorage {
    private let file: URL

    init(file: URL = Paths.root.appendingPathComponent("remote/identity.key")) { self.file = file }

    func load() -> Data? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func save(_ key: Data) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with the final mode, so the key is never readable by others even for an instant.
        FileManager.default.createFile(atPath: file.path, contents: Data(key.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
    }

    func erase() { try? FileManager.default.removeItem(at: file) }
}

final class MemoryKeyStorage: RemoteKeyStorage {
    private var key: Data?
    func load() -> Data? { key }
    func save(_ key: Data) { self.key = key }
    func erase() { key = nil }
}

/// The Mac's identity for pairing: an Ed25519 key made the first time the remote API is turned on. The QR code carries the SHA-256 of the
/// public key, and the Mac signs each pairing answer with the private key, so a phone can tell the Mac it scanned from a stranger
/// on the same address.
final class RemoteIdentity: @unchecked Sendable {
    private let storage: RemoteKeyStorage
    private let lock = NSLock()
    private var key: Curve25519.Signing.PrivateKey?

    init(storage: RemoteKeyStorage) { self.storage = storage }

    /// Loads the key, or makes one when there is none.
    private func current() -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        if let data = storage.load(), let loaded = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            key = loaded
            return loaded
        }
        let made = Curve25519.Signing.PrivateKey()
        storage.save(made.rawRepresentation)
        key = made
        return made
    }

    /// Makes the key now if there is none, so the first pairing code already has a fingerprint.
    func ensure() { _ = current() }

    var publicKey: Data { current().publicKey.rawRepresentation }

    /// Lowercase hex SHA-256 of the raw public key. This is the `f` value of the pairing link.
    var fingerprint: String { RemoteHash.hex(publicKey) }

    func sign(_ message: Data) -> Data { (try? current().signature(for: message)) ?? Data() }

    /// Replaces the key. Every fingerprint handed out before stops matching.
    func rotate() {
        lock.lock()
        defer { lock.unlock() }
        let made = Curve25519.Signing.PrivateKey()
        storage.save(made.rawRepresentation)
        key = made
    }
}
