import Foundation

/// One send to the larger model, as shown in Settings.
struct CaptureSendRecord: Equatable {
    var id: Int64
    var at: Date
    var harness: String
    var model: String
    var items: [Int64]
    var bytes: Int
    var outcome: String
}

/// Ignored suggestions and the log of sends to the larger model, both in the `capture_*` tables.
extension CaptureStore {
    // MARK: Ignored proposals

    /// A stable id for a proposal, so the same suggestion is not made twice after the user ignored it.
    static func fingerprint(kind: String, title: String, taskId: String? = nil) -> String {
        let normalized = title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        let basis = "\(kind)|\(taskId ?? "")|\(normalized)"
        return CaptureHash.hex(basis, length: 24)
    }

    func ignore(fingerprint: String, kind: String, now: Date = Date()) {
        try? database.write { try $0.execute("INSERT OR REPLACE INTO capture_ignored(fingerprint, kind, at) VALUES(?, ?, ?)", [fingerprint, kind, now.timeIntervalSince1970]) }
    }

    func clearIgnored() {
        try? database.write { try $0.execute("DELETE FROM capture_ignored") }
    }

    func isIgnored(_ fingerprint: String) -> Bool {
        !(((try? database.read { try $0.rows("SELECT 1 FROM capture_ignored WHERE fingerprint = ?", [fingerprint]) }) ?? []).isEmpty)
    }

    // MARK: Send log

    func logSend(harness: String, model: String, items: [Int64], bytes: Int, outcome: String, now: Date = Date()) {
        try? database.write { db in
            try db.execute("INSERT INTO capture_send_log(at, harness, model, items, bytes, outcome) VALUES(?, ?, ?, ?, ?, ?)",
                           [now.timeIntervalSince1970, harness, model, items.map(String.init).joined(separator: ","), bytes, outcome])
        }
    }

    func updateSendOutcome(id: Int64, outcome: String) {
        try? database.write { try $0.execute("UPDATE capture_send_log SET outcome = ? WHERE id = ?", [outcome, id]) }
    }

    var lastSendLogId: Int64? { (try? database.read { try $0.rows("SELECT MAX(id) FROM capture_send_log") })?.first?.first as? Int64 }

    func sendLog(limit: Int = 50) -> [CaptureSendRecord] {
        ((try? database.read { try $0.rows("SELECT id, at, harness, model, items, bytes, outcome FROM capture_send_log ORDER BY id DESC LIMIT ?", [limit]) }) ?? []).map {
            CaptureSendRecord(id: $0[0] as! Int64, at: Date(timeIntervalSince1970: $0[1] as! Double), harness: $0[2] as! String, model: $0[3] as! String,
                              items: ($0[4] as! String).split(separator: ",").compactMap { Int64($0) }, bytes: Int($0[5] as! Int64), outcome: $0[6] as! String)
        }
    }
}
