import Foundation
import SQLite3

/// Wispr Flow cannot find ironpet's text field through Accessibility, so it shows
/// "Select a textbox first" instead of typing. It still records every dictation in its local
/// history with the target app's bundle id, so while the chat is open we read new entries
/// addressed to ironpet and insert them ourselves.
@MainActor
final class WisprBridge {
    static let database = Paths.home.appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")

    var onDictation: ((String) -> Void)?
    private var timer: Timer?
    private var lastRowID: Int64 = 0

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: database.path) }

    func start() {
        guard Self.isAvailable, timer == nil else { return }
        lastRowID = Self.query("SELECT IFNULL(MAX(rowid), 0) FROM History", bind: nil).first.map { $0.0 } ?? 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.ironpet.app"
        let rows = Self.query("""
            SELECT rowid, COALESCE(NULLIF(pastedText, ''), NULLIF(formattedText, ''), asrText)
            FROM History WHERE rowid > ? AND app = ? ORDER BY rowid
            """, bind: (lastRowID, bundleID))
        for (rowID, text) in rows {
            lastRowID = max(lastRowID, rowID)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onDictation?(trimmed) }
        }
    }

    private static func query(_ sql: String, bind: (Int64, String)?) -> [(Int64, String)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(database.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let (rowID, app) = bind {
            sqlite3_bind_int64(statement, 1, rowID)
            sqlite3_bind_text(statement, 2, app, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var rows: [(Int64, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let text = sqlite3_column_count(statement) > 1 ? sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "" : ""
            rows.append((id, text))
        }
        return rows
    }
}
