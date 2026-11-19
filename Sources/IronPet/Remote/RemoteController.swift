import Foundation
import SwiftUI

/// Runs the remote API for the Mac app: starts and stops the server when the settings change, shows the pairing bubble, and holds what the
/// Devices page shows. The server and service know nothing about the app, and this class is the only place that connects them.
@MainActor
final class RemoteController: ObservableObject {
    enum Status: Equatable {
        case off
        case listening(port: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var devices: [RemoteDevice] = []
    /// The code on screen. It goes away when it is used, expires or five wrong codes close the pairing screen.
    @Published private(set) var pairing: RemotePairingCode?
    @Published private(set) var pairingNote: String?

    let service: RemoteService
    /// Nil for the screenshot renderer, which shows the page without a server.
    let server: RemoteServer?
    private let settings: SettingsAPI
    private let bubbles: BubbleStore
    private let chime: () -> Void
    private var running: Task<Void, Never>?
    private var again = false
    private var settingsWatch: APIEventBus.Subscription?
    private var expiry: Task<Void, Never>?

    /// A controller for `--render-previews`: a page over sample devices, with no server and no app.
    init(preview service: RemoteService, settings: SettingsAPI, bubbles: BubbleStore, status: Status) {
        self.settings = settings
        self.bubbles = bubbles
        chime = {}
        self.service = service
        server = nil
        devices = service.devices
        self.status = status
    }

    init(api: IronPetAPI, settings: SettingsAPI, database: Database, bubbles: BubbleStore, chime: @escaping () -> Void = {}, activity: ActivityLog?,
         storage: RemoteKeyStorage = FileKeyStorage(), now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.bubbles = bubbles
        self.chime = chime
        service = RemoteService(store: RemoteStore(database: database), identity: RemoteIdentity(storage: storage), now: now)
        server = RemoteServer(api: api, service: service)
        devices = service.devices
        service.activity = { event in activity?.record(event) }
        service.onPairingRequest = { [weak self] request in
            Task { @MainActor in self?.showPairing(request) }
        }
        service.onPairingResolved = { [weak self] id in
            Task { @MainActor in self?.bubbles.dismiss(Announcer.remotePairingID(id)) }
        }
        service.onPairingClosed = { [weak self] in
            Task { @MainActor in
                self?.pairing = nil
                self?.pairingNote = "Five wrong codes were sent, so the pairing code is closed. Make a new one."
            }
        }
        service.onAuthBurst = { [weak self] in
            Task { @MainActor in if let self { self.bubbles.show(Announcer.remoteBlockedBubble()) } }
        }
        service.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        // A change of `remote.enabled` or `remote.port`, from the Devices page, a hand edit of config.json or the settings API.
        settingsWatch = api.events.subscribe { [weak self] event in
            if event.kind == .settingsChanged { self?.reconcile() }
        }
    }

    // MARK: Server

    /// Makes the server match the settings: listening on the port when the API is on, closed when it is off. Safe to call often.
    func reconcile() {
        if running != nil {
            again = true
            return
        }
        running = Task {
            repeat {
                again = false
                await match()
            } while again
            running = nil
        }
    }

    /// Returns when the server matches the settings. Tests wait on it after changing a setting.
    func settled() async {
        while let running { await running.value }
    }

    private func match() async {
        guard let server else { return }
        while true {
            let want = settings.config.remote
            if server.isRunning, !want.enabled || server.port != want.port {
                await server.stop()
                status = .off
                pairing = nil
            } else if want.enabled, !server.isRunning {
                service.identity.ensure()
                do {
                    try await server.start(port: want.port)
                    status = .listening(port: server.port ?? want.port)
                } catch {
                    status = .failed("Could not listen on 127.0.0.1:\(want.port): \(error.localizedDescription)")
                    return
                }
            } else {
                // Switching off after a failed start must not leave the failure on the page.
                if !want.enabled { status = .off }
                return
            }
        }
    }

    // MARK: Pairing

    func startPairing() {
        pairingNote = nil
        let code = service.newPairingCode()
        pairing = code
        expiry?.cancel()
        let wait = max(1, code.expires.timeIntervalSinceNow)
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pairing = nil
        }
    }

    func stopPairing() {
        expiry?.cancel()
        pairing = nil
        service.closePairing()
    }

    /// `ironpet://pair?u=<base URL>&c=<code>&f=<fingerprint>`. Nil without a base URL, which the phone could not reach anyway.
    static func pairingLink(baseURL: String, code: RemotePairingCode) -> String? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "ironpet"
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "u", value: base), URLQueryItem(name: "c", value: code.code), URLQueryItem(name: "f", value: code.fingerprint)]
        // Reserved characters inside a value, such as the ':' and '/' of a URL, stay as they are. Only '&', '=', '+' and '#' would break the link.
        return parts.string
    }

    private func showPairing(_ request: RemotePairingRequest) {
        // A used code is gone, so the QR code on screen would only fail.
        pairing = nil
        let service = service
        bubbles.show(Announcer.remotePairingBubble(request, allow: { service.decide(request.id, allow: true) },
                                                   deny: { service.decide(request.id, allow: false) }))
        chime()
    }

    // MARK: Devices

    func refreshDevices() { devices = service.devices }

    func revoke(_ id: String) {
        service.revoke(id)
        refreshDevices()
    }

    func revokeAllAndRotate() {
        service.revokeAllAndRotate()
        pairing = nil
        refreshDevices()
    }

    /// The command that points Tailscale at the loopback port. Unverified against the installed `tailscale`: see the Devices page.
    static func serveCommand(port: Int) -> String { "tailscale serve --bg --https=443 http://127.0.0.1:\(port)" }
}
