import Foundation

/// Decides when Ghost offers to record a call. It never records: the user's click does.
@MainActor
final class CallPrompt {
    enum Action: Equatable {
        case offerRecord(String)
        case offerStop(String)
    }

    /// Meetings are on and "Offer to record calls" is on.
    var isEnabled: () -> Bool
    /// A meeting is already being set up, recorded or wrapped up.
    var isBusy: () -> Bool

    /// Apps whose current call the user declined. Cleared when the app releases the mic.
    private(set) var snoozed: Set<String> = []
    /// The app whose call the user chose to record.
    private(set) var recording: String?

    init(isEnabled: @escaping () -> Bool, isBusy: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        self.isBusy = isBusy
    }

    func callStarted(_ app: String) -> Action? {
        guard isEnabled(), !isBusy(), !snoozed.contains(app) else { return nil }
        return .offerRecord(app)
    }

    func callEnded(_ app: String) -> Action? {
        snoozed.remove(app)
        guard recording == app else { return nil }
        recording = nil
        return isBusy() ? .offerStop(app) : nil
    }

    func notNow(_ app: String) { snoozed.insert(app) }

    func accepted(_ app: String) { recording = app }
}
