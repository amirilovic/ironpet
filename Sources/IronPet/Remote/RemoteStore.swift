import CryptoKit
import Foundation

/// A paired device. The token is never stored, only its SHA-256.
struct RemoteDevice: Equatable, Identifiable {
    let id: String
    var name: String
    var created: Date
    var lastSeen: Date?
    /// The `X-Forwarded-For` value of the last request, as the client sent it. Shown to the user, never trusted.
    var origin: String?
    /// The device's own public key (base64), when it sent one at pairing. Kept for a later push step; nothing uses it yet.
    var publicKey: String?
}

/// One row of the access log.
struct RemoteAccessRow: Equatable {
    var at: Date
    var deviceID: String?
    var method: String
    /// The route template (`/v1/tasks/:id`), never the concrete path or the query.
    var route: String
    var status: Int
    var bytes: Int
    var durationMs: Int
}

enum RemoteHash {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hex(_ text: String) -> String { hex(Data(text.utf8)) }

    /// Compares without stopping at the first difference.
    static func equal(_ a: String, _ b: String) -> Bool {
        let (x, y) = (Array(a.utf8), Array(b.utf8))
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    /// `count` random bytes as unpadded base64url.
    static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no random bytes")
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The remote API's tables in `ironpet.db`: devices, pairing codes and the access log. Thread safe through `Database`.
final class RemoteStore: @unchecked Sendable {
    /// The access log is kept this long.
    static let logRetention: TimeInterval = 30 * 86_400

    static let migrations: [Database.Migration] = [
        .init(540, "remote: devices", sql: """
            CREATE TABLE remote_devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL, created REAL NOT NULL,
                                        last_seen REAL, origin TEXT, public_key TEXT) WITHOUT ROWID;
            """),
        .init(541, "remote: pairing codes", sql: """
            CREATE TABLE remote_pairing(id TEXT PRIMARY KEY, code_hash TEXT NOT NULL, created REAL NOT NULL, expires REAL NOT NULL, used REAL) WITHOUT ROWID;
            CREATE INDEX remote_pairing_by_hash ON remote_pairing(code_hash);
            """),
        .init(542, "remote: access log", sql: """
            CREATE TABLE remote_access_log(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, device_id TEXT, method TEXT NOT NULL,
                                           route TEXT NOT NULL, status INTEGER NOT NULL, bytes INTEGER NOT NULL, duration_ms INTEGER NOT NULL);
            CREATE INDEX remote_access_log_by_time ON remote_access_log(at);
            """),
    ]

    private let database: Database

    init(database: Database) { self.database = database }

    // MARK: Devices

    func devices() -> [RemoteDevice] {
        let rows = (try? database.read { try $0.rows("SELECT id, name, created, last_seen, origin, public_key FROM remote_devices ORDER BY created, id") }) ?? []
        return rows.compactMap(Self.device)
    }

    /// The device whose token hashes to `hash`. Every row is compared, so the time does not tell how much of a hash matched.
    func device(tokenHash hash: String) -> RemoteDevice? {
        let rows = (try? database.read { try $0.rows("SELECT id, name, created, last_seen, origin, public_key, token_hash FROM remote_devices") }) ?? []
        var found: RemoteDevice?
        for row in rows {
            if let stored = row[6] as? String, RemoteHash.equal(stored, hash) { found = Self.device(row) }
        }
        return found
    }

    func add(_ device: RemoteDevice, tokenHash: String) throws {
        try database.write {
            try $0.execute("INSERT INTO remote_devices(id, name, token_hash, created, last_seen, origin, public_key) VALUES(?, ?, ?, ?, NULL, ?, ?)",
                           [device.id, device.name, tokenHash, device.created.timeIntervalSince1970, device.origin, device.publicKey])
        }
    }

    func touch(_ id: String, at: Date, origin: String?) {
        try? database.write { try $0.execute("UPDATE remote_devices SET last_seen = ?, origin = ? WHERE id = ?", [at.timeIntervalSince1970, origin, id]) }
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        let before = devices().count
        try? database.write { try $0.execute("DELETE FROM remote_devices WHERE id = ?", [id]) }
        return devices().count < before
    }

    func removeAll() { try? database.write { try $0.execute("DELETE FROM remote_devices") } }

    private static func device(_ row: [Database.Value]) -> RemoteDevice? {
        guard let id = row[0] as? String, let name = row[1] as? String, let created = row[2] as? Double else { return nil }
        return RemoteDevice(id: id, name: name, created: Date(timeIntervalSince1970: created),
                            lastSeen: (row[3] as? Double).map { Date(timeIntervalSince1970: $0) }, origin: row[4] as? String, publicKey: row[5] as? String)
    }

    // MARK: Pairing codes

    func addCode(hash: String, now: Date, ttl: TimeInterval) {
        try? database.write {
            try $0.execute("INSERT INTO remote_pairing(id, code_hash, created, expires, used) VALUES(?, ?, ?, ?, NULL)",
                           [UUID().uuidString, hash, now.timeIntervalSince1970, now.addingTimeInterval(ttl).timeIntervalSince1970])
        }
    }

    /// Marks the code used when it is known, unused and not expired. A code works once.
    func consumeCode(hash: String, now: Date) -> Bool {
        let at = now.timeIntervalSince1970
        var consumed = false
        try? database.write { db in
            let rows = try db.rows("SELECT id FROM remote_pairing WHERE code_hash = ? AND used IS NULL AND expires > ?", [hash, at])
            guard let id = rows.first?[0] as? String else { return }
            try db.execute("UPDATE remote_pairing SET used = ? WHERE id = ?", [at, id])
            consumed = true
        }
        return consumed
    }

    /// Drops every code that is still unused, so a QR code on screen stops working.
    func closeCodes() { try? database.write { try $0.execute("DELETE FROM remote_pairing WHERE used IS NULL") } }

    func pruneCodes(now: Date) {
        try? database.write { try $0.execute("DELETE FROM remote_pairing WHERE expires < ?", [now.addingTimeInterval(-86_400).timeIntervalSince1970]) }
    }

    // MARK: Access log

    func log(_ row: RemoteAccessRow) {
        do {
            try database.write {
                try $0.execute("INSERT INTO remote_access_log(at, device_id, method, route, status, bytes, duration_ms) VALUES(?, ?, ?, ?, ?, ?, ?)",
                               [row.at.timeIntervalSince1970, row.deviceID, row.method, row.route, row.status, row.bytes, row.durationMs])
            }
        } catch { NSLog("ironpet: remote access log write failed: \(error.localizedDescription)") }
    }

    func accessLog(limit: Int = 200) -> [RemoteAccessRow] {
        let rows = (try? database.read {
            try $0.rows("SELECT at, device_id, method, route, status, bytes, duration_ms FROM remote_access_log ORDER BY id DESC LIMIT ?", [limit])
        }) ?? []
        return rows.compactMap { row in
            guard let at = row[0] as? Double, let method = row[2] as? String, let route = row[3] as? String, let status = row[4] as? Int64,
                  let bytes = row[5] as? Int64, let ms = row[6] as? Int64 else { return nil }
            return RemoteAccessRow(at: Date(timeIntervalSince1970: at), deviceID: row[1] as? String, method: method, route: route,
                                   status: Int(status), bytes: Int(bytes), durationMs: Int(ms))
        }
    }

    func pruneLog(now: Date) {
        try? database.write { try $0.execute("DELETE FROM remote_access_log WHERE at < ?", [now.addingTimeInterval(-Self.logRetention).timeIntervalSince1970]) }
    }
}
