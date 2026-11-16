import SwiftUI

/// What the user sees when `ironpet.db` could not be opened and ironpet runs on an in-memory stand-in.
enum DatabaseNotice {
    static let alertID = "database-unavailable"
    static let bannerText = "Not saved: the database is unavailable"

    /// The alert for an unavailable database, or nil for a normal one.
    static func signal(for database: Database) -> Signal? {
        guard let reason = database.unavailableReason else { return nil }
        let path = database.unavailablePath?.path ?? "ironpet.db"
        return Signal(id: alertID, title: "\(reason)\nFile: \(path)", subtitle: path, url: nil,
                      label: "ironpet can't open its database", symbol: "exclamationmark.triangle.fill", mood: .failed, ask: nil)
    }

    /// The error that tasks tools and the CLI return instead of an empty list.
    static func toolError(_ reason: String) -> String { "\(bannerText). \(reason)" }
}

/// A one-line banner for sections that read the database.
struct DatabaseBanner: View {
    let reason: String

    var body: some View {
        Label(DatabaseNotice.bannerText, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.orange.opacity(0.12))
            .help(reason)
            .accessibilityLabel("\(DatabaseNotice.bannerText). \(reason)")
    }
}

extension SignalStore {
    /// Adds the unavailable-database alert, with a bubble, when the database is the in-memory stand-in.
    func reportIfUnavailable(_ database: Database) {
        if let signal = DatabaseNotice.signal(for: database) { add(signal, notify: true) }
    }
}
