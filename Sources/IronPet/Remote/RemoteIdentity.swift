import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509

/// Where the Mac's certificate and its private key live between launches: two base64 lines, the P-256 key and the DER certificate.
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
        try? Data(contentsOf: file)
    }

    func save(_ key: Data) {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with the final mode, so the key is never readable by others even for an instant.
        FileManager.default.createFile(atPath: file.path, contents: key, attributes: [.posixPermissions: 0o600])
    }

    func erase() { try? FileManager.default.removeItem(at: file) }
}

final class MemoryKeyStorage: RemoteKeyStorage {
    private var key: Data?
    func load() -> Data? { key }
    func save(_ key: Data) { self.key = key }
    func erase() { key = nil }
}

/// The Mac's identity for pairing: a P-256 key and a self-signed certificate, made the first time the remote API is turned on. The server
/// presents this certificate on the network address. The QR code carries the SHA-256 of its DER encoding, and the phone accepts only a
/// server whose certificate has that hash, so a stranger on the same Wi-Fi cannot stand in for the Mac.
final class RemoteIdentity: @unchecked Sendable {
    struct Material {
        var key: P256.Signing.PrivateKey
        var der: Data
    }

    private let storage: RemoteKeyStorage
    private let lock = NSLock()
    private var material: Material?

    init(storage: RemoteKeyStorage) { self.storage = storage }

    private func current() -> Material {
        lock.lock()
        defer { lock.unlock() }
        if let material { return material }
        if let loaded = Self.decode(storage.load()) {
            material = loaded
            return loaded
        }
        return replace()
    }

    /// Caller holds the lock.
    private func replace() -> Material {
        let made = Self.make()
        storage.save(Self.encode(made))
        material = made
        return made
    }

    /// Makes the certificate now if there is none, so the first pairing code already has a fingerprint.
    func ensure() { _ = current() }

    /// The certificate, DER encoded.
    var certificateDER: Data { current().der }

    /// Lowercase hex SHA-256 of the DER certificate. This is the `f` value of the pairing link.
    var fingerprint: String { RemoteHash.hex(current().der) }

    /// What the HTTPS listener serves.
    func tlsConfiguration() throws -> TLSConfiguration {
        let current = current()
        let certificate = try NIOSSLCertificate(bytes: Array(current.der), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(current.key.derRepresentation), format: .der)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv12
        return configuration
    }

    /// Replaces the key and the certificate. Every fingerprint handed out before stops matching.
    func rotate() {
        lock.lock()
        defer { lock.unlock() }
        _ = replace()
    }

    private static func encode(_ material: Material) -> Data {
        Data("\(material.key.rawRepresentation.base64EncodedString())\n\(material.der.base64EncodedString())\n".utf8)
    }

    /// Nil for a missing file, a file of the older Ed25519 format (one line) or damaged content, so a new identity is made.
    private static func decode(_ data: Data?) -> Material? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 2, let raw = Data(base64Encoded: lines[0]), let der = Data(base64Encoded: lines[1]),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        return Material(key: key, der: der)
    }

    /// A self-signed certificate for a fresh key, valid ten years. Phones pin its hash, so the name and the dates are not checked.
    private static func make() -> Material {
        let key = P256.Signing.PrivateKey()
        let name = try! DistinguishedName { CommonName("ironpet") }
        let now = Date()
        let certificate = try! Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400), notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try! Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try! ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: .init(key))
        var serializer = DER.Serializer()
        try! serializer.serialize(certificate)
        return Material(key: key, der: Data(serializer.serializedBytes))
    }
}
