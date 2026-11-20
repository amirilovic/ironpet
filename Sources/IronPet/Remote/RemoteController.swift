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
    /// The lines of the Network picker. `refreshAddresses` re-reads them.
    @Published private(set) var addresses: [NetworkAddress] = []

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
    /// True while the Devices page is open. A code is only made, and made again after it expires, while someone can see it.
    private var pageOpen = false
    private let interfaces: () -> [InterfaceAddress]
    private let magicDNS: () async -> String?
    private var magicDNSName: String?

    /// A controller for `--render-previews`: a page over sample devices and sample addresses, with no server and no app.
    init(preview service: RemoteService, settings: SettingsAPI, bubbles: BubbleStore, status: Status, interfaces sample: [InterfaceAddress]) {
        self.settings = settings
        self.bubbles = bubbles
        chime = {}
        self.service = service
        server = nil
        devices = service.devices
        self.status = status
        interfaces = { sample }
        magicDNS = { nil }
        addresses = RemoteNetwork.addresses(from: sample)
    }

    init(api: IronPetAPI, settings: SettingsAPI, database: Database, bubbles: BubbleStore, chime: @escaping () -> Void = {}, activity: ActivityLog?,
         storage: RemoteKeyStorage = FileKeyStorage(), now: @escaping () -> Date = Date.init,
         interfaces: @escaping () -> [InterfaceAddress] = RemoteNetwork.interfaces, magicDNS: @escaping () async -> String? = RemoteNetwork.readMagicDNS) {
        self.settings = settings
        self.interfaces = interfaces
        self.magicDNS = magicDNS
        self.bubbles = bubbles
        self.chime = chime
        service = RemoteService(store: RemoteStore(database: database), identity: RemoteIdentity(storage: storage), now: now)
        server = RemoteServer(api: api, service: service)
        devices = service.devices
        addresses = RemoteNetwork.addresses(from: interfaces())
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
            let bind = want.enabled ? endpoint.bindIP : nil
            if want.enabled { service.identity.ensure() }
            let served = bind == nil ? nil : service.identity.fingerprint
            if server.isRunning, !want.enabled || server.port != want.port || server.secureAddress != bind || server.servedFingerprint != served {
                await server.stop()
                status = .off
                pairing = nil
            } else if want.enabled, !server.isRunning {
                do {
                    try await server.start(port: want.port, secureAddress: bind)
                    status = .listening(port: server.port ?? want.port)
                    ensurePairing()
                } catch {
                    let place = bind.map { "\($0):\(want.port)" } ?? "127.0.0.1:\(want.port)"
                    status = .failed("Could not listen on \(place): \(error.localizedDescription)")
                    return
                }
            } else {
                // Switching off after a failed start must not leave the failure on the page.
                if !want.enabled { status = .off }
                return
            }
        }
    }

    // MARK: Network

    /// Where the phone connects, from the saved address and the interfaces read last.
    var endpoint: RemoteEndpoint { RemoteNetwork.endpoint(setting: settings.config.remote.address, addresses: addresses) }

    /// Re-reads the Mac's interfaces and the Tailscale name, then moves the listener if the chosen address changed.
    func refreshAddresses() {
        addresses = RemoteNetwork.addresses(from: interfaces(), magicDNS: magicDNSName)
        reconcile()
        Task { [weak self] in
            guard let self else { return }
            let name = await magicDNS()
            guard name != magicDNSName else { return }
            magicDNSName = name
            addresses = RemoteNetwork.addresses(from: interfaces(), magicDNS: name)
            reconcile()
        }
    }

    /// The Mac's name for the Allow bubble and the device list.
    var machineName: String { Self.machineName(settings.config.remote.machineName) }

    nonisolated static func machineName(_ saved: String) -> String {
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (Host.current().localizedName ?? ProcessInfo.processInfo.hostName) : trimmed
    }

    /// The link on screen: `ironpet://pair?u=<base URL>&c=<code>&f=<certificate hash>`, built from the current endpoint. Nil without a code or an address.
    var pairingLink: String? {
        guard let code = pairing, let base = endpoint.baseURL(port: settings.config.remote.port) else { return nil }
        return Self.pairingLink(baseURL: base, code: code, pin: endpoint.pinsCertificate)
    }

    // MARK: Pairing

    /// Makes a code when the page needs one: the page is open, the server is up, nothing is on screen and five wrong codes did not just close the pairing.
    func ensurePairing() {
        guard pageOpen, case .listening = status, pairing == nil, pairingNote == nil else { return }
        startPairing()
    }

    /// Regenerate code: the old code stops working.
    func startPairing() {
        pairingNote = nil
        service.closePairing()
        let code = service.newPairingCode()
        pairing = code
        expiry?.cancel()
        let wait = max(1, code.expires.timeIntervalSinceNow)
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pairing = nil
            self?.ensurePairing()
        }
    }

    /// The Devices page appeared: show a code as soon as the server is up.
    func pageAppeared() {
        pageOpen = true
        ensurePairing()
    }

    func stopPairing() {
        pageOpen = false
        expiry?.cancel()
        pairing = nil
        service.closePairing()
    }

    /// `ironpet://pair?u=<base URL>&c=<code>&f=<fingerprint>`. `f` is left out when `pin` is false, because a custom front has its own certificate.
    nonisolated static func pairingLink(baseURL: String, code: RemotePairingCode, pin: Bool = true) -> String? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "ironpet"
        parts.host = "pair"
        var items = [URLQueryItem(name: "u", value: base), URLQueryItem(name: "c", value: code.code)]
        if pin { items.append(URLQueryItem(name: "f", value: code.fingerprint)) }
        parts.queryItems = items
        // Reserved characters inside a value, such as the ':' and '/' of a URL, stay as they are. Only '&', '=', '+' and '#' would break the link.
        return parts.string
    }

    private func showPairing(_ request: RemotePairingRequest) {
        // A used code is gone, so the QR code on screen would only fail.
        pairing = nil
        let service = service
        bubbles.show(Announcer.remotePairingBubble(request, machine: machineName, allow: { service.decide(request.id, allow: true) },
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
        // The listener still presents the old certificate. `match` sees the new hash and restarts it.
        reconcile()
    }

    /// The command that points Tailscale at the loopback port, shown under Add custom address. Checked against `tailscale serve --help`
    /// of Tailscale 1.102, not run against a tailnet.
    static func serveCommand(port: Int) -> String { "tailscale serve --bg --https=443 http://127.0.0.1:\(port)" }
}
