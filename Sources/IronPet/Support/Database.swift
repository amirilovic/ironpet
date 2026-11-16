import Foundation
import SQLite3

/// ironpet's common app database, `~/.ironpet/ironpet.db`, on the system SQLite in WAL mode. It is opened once and shared.
/// This layer knows nothing about the features that use it: each feature contributes ordered `Migration`s that create its own
/// prefixed tables, and runs its own queries through `read` and `write`.
///
/// All writes go through one serial queue, each in its own transaction. Reads use a second, read-only connection on a
/// concurrent queue, so they do not wait for a write (WAL lets readers and the writer work at once). An in-memory
/// database has one connection, and reads share the write queue.
final class Database {
    /// A column value: `Int64`, `Double`, `String` or nil.
    typealias Value = Any?

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// One step of the schema. `version` numbers all migrations of the app in order, with no gaps in meaning but gaps allowed in
    /// number, so features can leave room. The runner applies the ones above `PRAGMA user_version`, each in its own
    /// transaction, and stores the new version in the same transaction.
    struct Migration {
        let version: Int
        let name: String
        let apply: (Connection) throws -> Void

        init(_ version: Int, _ name: String, apply: @escaping (Connection) throws -> Void) {
            self.version = version
            self.name = name
            self.apply = apply
        }

        /// A migration that is a script of SQL statements.
        init(_ version: Int, _ name: String, sql: String) {
            self.init(version, name) { try $0.script(sql) }
        }
    }

    /// One SQLite connection. Only used inside `read` and `write` closures.
    final class Connection {
        fileprivate var handle: OpaquePointer?

        fileprivate init(path: String, readOnly: Bool) throws {
            let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
                sqlite3_close(handle)
                throw Failure(message: "cannot open \(path): \(message)")
            }
            sqlite3_busy_timeout(handle, 3000)
        }

        deinit { sqlite3_close(handle) }

        private var message: String { String(cString: sqlite3_errmsg(handle)) }

        /// Runs several statements without parameters.
        func script(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: message) }
        }

        /// Runs one statement with `?` parameters.
        func execute(_ sql: String, _ args: [Value] = []) throws {
            _ = try rows(sql, args)
        }

        /// Runs one statement and returns its rows.
        @discardableResult
        func rows(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure(message: "\(message) in \(sql)") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in args.enumerated() {
                let position = Int32(index + 1)
                switch value {
                case let v as String: sqlite3_bind_text(statement, position, v, -1, transient)
                case let v as Int64: sqlite3_bind_int64(statement, position, v)
                case let v as Int: sqlite3_bind_int64(statement, position, Int64(v))
                case let v as Double: sqlite3_bind_double(statement, position, v)
                default: sqlite3_bind_null(statement, position)
                }
            }
            var result: [[Value]] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw Failure(message: "\(message) in \(sql)") }
                result.append((0..<sqlite3_column_count(statement)).map { column -> Value in
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
                    case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
                    case SQLITE_TEXT: return String(cString: sqlite3_column_text(statement, column))
                    default: return nil
                    }
                })
            }
            return result
        }
    }

    /// `nil` for an in-memory database.
    let path: URL?
    /// Set when this is the in-memory stand-in for a file that could not be opened. Nothing in it reaches the disk.
    private(set) var unavailableReason: String?
    /// The file that could not be opened, when `unavailableReason` is set.
    private(set) var unavailablePath: URL?
    private let writer: Connection
    private let reader: Connection?
    private let writeQueue = DispatchQueue(label: "ironpet.database.write")
    private let readQueue = DispatchQueue(label: "ironpet.database.read", attributes: .concurrent)

    /// Opens (creating it if needed), switches to WAL and applies the migrations that are due.
    /// Throws, leaving the file as it was before the failing migration, when one fails or the file is from a newer ironpet.
    init(path: URL?, migrations: [Migration]) throws {
        self.path = path
        if let path { try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true) }
        writer = try Connection(path: path?.path ?? ":memory:", readOnly: false)
        // Check the version before switching to WAL, because that switch rewrites the header of a file that is not in WAL mode.
        try Self.refuseNewer(writer, migrations)
        if path != nil {
            try writer.script("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        }
        try Self.migrate(writer, migrations)
        reader = try path.map { try Connection(path: $0.path, readOnly: true) }
    }

    /// Opens the database. When it cannot be opened or migrated, logs why and uses an in-memory one, so the app still runs.
    static func open(path: URL?, migrations: [Migration]) -> (database: Database, error: String?) {
        do { return (try Database(path: path, migrations: migrations), nil) } catch {
            NSLog("ironpet: database \(path?.path ?? ":memory:") unavailable, using memory only: \(error.localizedDescription)")
            // An in-memory database with the same migrations cannot fail the way a damaged file can.
            let fallback = try! Database(path: nil, migrations: migrations)
            fallback.unavailableReason = error.localizedDescription
            fallback.unavailablePath = path
            return (fallback, error.localizedDescription)
        }
    }

    /// The version the schema is at.
    var schemaVersion: Int { (try? read { Self.version($0) }) ?? 0 }

    /// Runs `body` on the write queue inside one transaction. A throw rolls the transaction back and rethrows.
    @discardableResult
    func write<T>(_ body: (Connection) throws -> T) throws -> T {
        try writeQueue.sync {
            try writer.script("BEGIN IMMEDIATE")
            do {
                let value = try body(writer)
                try writer.script("COMMIT")
                return value
            } catch {
                try? writer.script("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs `body` on the read connection. Several reads can run at once.
    func read<T>(_ body: (Connection) throws -> T) throws -> T {
        guard let reader else { return try writeQueue.sync { try body(writer) } }
        return try readQueue.sync { try body(reader) }
    }

    // MARK: Migrations

    private static func version(_ connection: Connection) -> Int {
        ((try? connection.rows("PRAGMA user_version"))?.first?.first as? Int64).map(Int.init) ?? 0
    }

    private static func refuseNewer(_ connection: Connection, _ migrations: [Migration]) throws {
        let current = version(connection)
        if let latest = migrations.map(\.version).max(), current > latest {
            throw Failure(message: "the database is at version \(current), newer than this ironpet knows (\(latest)). "
                + "A newer ironpet build created it. Install that build or a newer one again; your data is untouched.")
        }
    }

    private static func migrate(_ connection: Connection, _ migrations: [Migration]) throws {
        let ordered = migrations.sorted { $0.version < $1.version }
        for (a, b) in zip(ordered, ordered.dropFirst()) where a.version == b.version {
            throw Failure(message: "two migrations have version \(a.version): \(a.name) and \(b.name)")
        }
        try refuseNewer(connection, migrations)
        let current = version(connection)
        for migration in ordered where migration.version > current {
            try connection.script("BEGIN IMMEDIATE")
            do {
                try migration.apply(connection)
                try connection.script("PRAGMA user_version = \(migration.version)")
                try connection.script("COMMIT")
            } catch {
                try? connection.script("ROLLBACK")
                throw Failure(message: "migration \(migration.version) (\(migration.name)) failed: \(error.localizedDescription)")
            }
        }
    }
}
