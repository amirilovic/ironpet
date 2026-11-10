import Foundation
import ServiceManagement

/// Starts ironpet when the user logs in. Chosen in the welcome window; Settings and the pet's menu toggle it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ironpet: could not \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }
}
