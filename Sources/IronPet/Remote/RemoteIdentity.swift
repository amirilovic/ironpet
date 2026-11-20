import CryptoKit
import Foundation
import Security

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
    private var loaded: Material?

    init(storage: RemoteKeyStorage) { self.storage = storage }

    private func current() -> Material {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        if let decoded = Self.decode(storage.load()) {
            loaded = decoded
            return decoded
        }
        return replace()
    }

    /// Caller holds the lock.
    private func replace() -> Material {
        let made = Self.make()
        storage.save(Self.encode(made))
        loaded = made
        return made
    }

    /// Makes the certificate now if there is none, so the first pairing code already has a fingerprint.
    func ensure() { _ = current() }

    /// The certificate, DER encoded.
    var certificateDER: Data { current().der }

    /// Lowercase hex SHA-256 of the DER certificate. This is the `f` value of the pairing link.
    var fingerprint: String { RemoteHash.hex(current().der) }

    /// The key and the certificate, for the HTTPS listener.
    var material: Material { current() }

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
        return Material(key: key, der: SelfSignedCertificate.der(key: key, commonName: "ironpet", now: Date()))
    }
}

/// A minimal X.509 v3 certificate in DER, signed with its own P-256 key (ECDSA with SHA-256). Written by hand so the app needs no
/// certificate library: the fields are version 3, a random serial, the signature algorithm, issuer and subject `CN=<name>`, a validity of
/// ten years from a day ago, the public key, and two extensions (not a CA, and server authentication).
enum SelfSignedCertificate {
    static func der(key: P256.Signing.PrivateKey, commonName: String, now: Date) -> Data {
        let ecdsaWithSHA256 = sequence(oid([1, 2, 840, 10045, 4, 3, 2]))
        let name = sequence(set(sequence(oid([2, 5, 4, 3]) + tlv(0x0C, Data(commonName.utf8)))))
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let validity = sequence(time(now.addingTimeInterval(-86_400)) + time(now.addingTimeInterval(10 * 365 * 86_400)))
        let notCA = sequence(oid([2, 5, 29, 19]) + tlv(0x01, Data([0xFF])) + tlv(0x04, sequence(Data())))
        let serverAuth = sequence(oid([2, 5, 29, 37]) + tlv(0x04, sequence(oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))))
        let tbs = sequence(
            tlv(0xA0, tlv(0x02, Data([0x02])))
                + tlv(0x02, serial)
                + ecdsaWithSHA256
                + name
                + validity
                + name
                + key.publicKey.derRepresentation
                + tlv(0xA3, sequence(notCA + serverAuth)))
        // `signature(for:)` hashes with SHA-256, which is what ecdsa-with-SHA256 names.
        let signature = (try? key.signature(for: tbs).derRepresentation) ?? Data()
        return sequence(tbs + ecdsaWithSHA256 + tlv(0x03, Data([0x00]) + signature))
    }

    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        let count = value.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var rest = count
            while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + value
    }

    static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    static func set(_ content: Data) -> Data { tlv(0x31, content) }

    static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 { chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime up to 2049, GeneralizedTime after, as RFC 5280 asks.
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(formatter.string(from: date).utf8))
    }
}

/// Network.framework takes the server's certificate and key only as a `SecIdentity`, and macOS makes one only from items in a keychain.
/// This keychain lives in the temporary folder while the HTTPS listener runs: the running binary imports the key and the certificate into it,
/// so the items belong to this build and macOS shows no Keychain prompt, even after an update with a new ad-hoc signature. Nothing is added
/// to the login keychain or the keychain search list. The key file in `~/.ironpet/remote/` stays the only lasting copy.
final class RemoteTLSKeychain {
    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)
        case certificate
        case identity(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status): return "could not create the TLS keychain (\(status))"
            case .certificate: return "the remote API certificate is damaged"
            case .identity(let status): return "could not make the TLS identity (\(status))"
            }
        }
    }

    let identity: SecIdentity
    private let keychain: SecKeychain
    private let file: URL

    init(_ material: RemoteIdentity.Material, folder: URL = FileManager.default.temporaryDirectory) throws {
        let path = folder.appendingPathComponent("ironpet-remote-\(UUID().uuidString).keychain-db")
        file = path
        // A random password nobody needs again: the keychain is deleted when the listener stops.
        let password = RemoteHash.random(32)
        var made: SecKeychain?
        let status = password.withCString { pointer in
            SecKeychainCreate(path.path, UInt32(strlen(pointer)), pointer, false, nil, &made)
        }
        guard status == errSecSuccess, let made else { throw Failure.keychain(status) }
        keychain = made
        do {
            identity = try Self.importIdentity(material, into: made)
        } catch {
            SecKeychainDelete(made)
            try? FileManager.default.removeItem(at: path)
            throw error
        }
    }

    private static func importIdentity(_ material: RemoteIdentity.Material, into keychain: SecKeychain) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, material.der as CFData) else { throw Failure.certificate }
        // SecItemAdd refuses a SecKey made from raw bytes for a file keychain (errSecParam), and SecItemImport does not read PKCS#8 for EC
        // keys. It does read the SEC1 form (RFC 5915, "EC PRIVATE KEY"), which is built here from the raw key.
        let sec1 = SelfSignedCertificate.sequence(
            SelfSignedCertificate.tlv(0x02, Data([0x01]))
                + SelfSignedCertificate.tlv(0x04, material.key.rawRepresentation)
                + SelfSignedCertificate.tlv(0xA0, SelfSignedCertificate.oid([1, 2, 840, 10045, 3, 1, 7]))
                + SelfSignedCertificate.tlv(0xA1, SelfSignedCertificate.tlv(0x03, Data([0x00]) + material.key.publicKey.x963Representation)))
        var format = SecExternalFormat.formatOpenSSL
        var type = SecExternalItemType.itemTypePrivateKey
        var parameters = SecItemImportExportKeyParameters()
        let keyStatus = SecItemImport(sec1 as CFData, nil, &format, &type, [], &parameters, keychain, nil)
        guard keyStatus == errSecSuccess else { throw Failure.identity(keyStatus) }
        let addCertificate: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate, kSecUseKeychain as String: keychain]
        let certificateStatus = SecItemAdd(addCertificate as CFDictionary, nil)
        guard certificateStatus == errSecSuccess else { throw Failure.identity(certificateStatus) }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw Failure.identity(status) }
        return identity
    }

    /// Deletes the keychain file. Call once the listener that uses the identity has stopped.
    func close() {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: file)
    }
}
