import Foundation

/// A pairing code on screen: what goes into the QR code.
struct RemotePairingCode: Equatable {
    var code: String
    /// SHA-256 of the Mac's TLS certificate, in hex.
    var fingerprint: String
    var expires: Date
}

/// A phone that sent a valid code and waits for the user to press Allow or Deny.
struct RemotePairingRequest: Equatable, Identifiable {
    var id: String
    var deviceName: String
    var created: Date
}

/// What `POST /v1/pair` answers with when the code was good.
struct RemotePairAccepted: Equatable {
    var pairingID: String
    var secret: String
    var expiresIn: Int
}

enum RemotePairResult: Equatable {
    case accepted(RemotePairAccepted)
    case invalid(String)
    case unauthorized
    case limited(retryAfter: Int)
}

enum RemotePollResult: Equatable {
    case pending
    case allowed(token: String, deviceID: String)
    case denied
    case expired
    /// The token was already handed out once.
    case gone
    case unauthorized
    case limited(retryAfter: Int)
}

enum RemoteAuthResult: Equatable {
    case device(RemoteDevice)
    case unauthorized
    case limited(retryAfter: Int)
}

/// The rules of the remote API that do not depend on HTTP: pairing, device tokens, rate limits and open sockets. The server calls it from
/// its own threads, so all state sits behind one lock. Nothing here reads a store of the app: the Mac side sets the closures below.
final class RemoteService: @unchecked Sendable {
    static let codeLifetime: TimeInterval = 300
    static let maxWrongCodes = 5
    static let pairAttemptsPerMinute = 5
    static let unauthenticatedPerMinute = 10
    static let lockout: TimeInterval = 300
    static let socketsPerDevice = 3
    static let burst = 20.0
    static let sustained = 5.0
    /// Written to `last_seen` at most this often per device, so a chatty client does not write on every request.
    static let touchInterval: TimeInterval = 30

    let store: RemoteStore
    let identity: RemoteIdentity
    private let now: () -> Date
    private let lock = NSLock()

    /// A valid code arrived. The Mac shows Allow and Deny and calls `decide`.
    var onPairingRequest: (@Sendable (RemotePairingRequest) -> Void)?
    /// A request was decided or expired, so its bubble can go.
    var onPairingResolved: (@Sendable (String) -> Void)?
    /// Five wrong codes closed the pairing screen.
    var onPairingClosed: (@Sendable () -> Void)?
    /// Too many unauthenticated requests: shown once per lockout.
    var onAuthBurst: (@Sendable () -> Void)?
    /// The device list changed.
    var onDevicesChanged: (@Sendable () -> Void)?
    var activity: (@Sendable (ActivityEvent) -> Void)?

    private struct Pending {
        enum State { case waiting, allowed(token: String, deviceID: String), denied, delivered }
        var id: String
        var name: String
        var secretHash: String
        var publicKey: String?
        var created: Date
        var state: State
    }

    private struct Window {
        var hits: [Date] = []
        /// Records a hit and says whether it is within `limit` for the last `span` seconds.
        mutating func hit(at now: Date, limit: Int, span: TimeInterval) -> Bool {
            hits.removeAll { now.timeIntervalSince($0) >= span }
            guard hits.count < limit else { return false }
            hits.append(now)
            return true
        }
    }

    private struct Bucket {
        var tokens: Double
        var updated: Date
    }

    private var pending: [String: Pending] = [:]
    private var wrongCodes = 0
    private var pairWindow = Window()
    private var unauthWindow = Window()
    private var lockedUntil: Date?
    private var buckets: [String: Bucket] = [:]
    private var touched: [String: Date] = [:]
    private var sockets: [UUID: (device: String, close: @Sendable () -> Void)] = [:]
    private var lastPrune = Date.distantPast

    init(store: RemoteStore, identity: RemoteIdentity, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.identity = identity
        self.now = now
    }

    // MARK: Pairing codes

    /// Makes a code that works once for five minutes. Only its hash is stored.
    func newPairingCode() -> RemotePairingCode {
        identity.ensure()
        let code = RemoteHash.random(16)
        let at = now()
        store.addCode(hash: RemoteHash.hex(code), now: at, ttl: Self.codeLifetime)
        lock.lock()
        wrongCodes = 0
        lock.unlock()
        prune(at)
        return RemotePairingCode(code: code, fingerprint: identity.fingerprint, expires: at.addingTimeInterval(Self.codeLifetime))
    }

    /// Stops every code that is still unused.
    func closePairing() { store.closeCodes() }

    func pair(code: String, deviceName: String, publicKey: String?) -> RemotePairResult {
        let at = now()
        lock.lock()
        let allowed = pairWindow.hit(at: at, limit: Self.pairAttemptsPerMinute, span: 60)
        lock.unlock()
        guard allowed else { return .limited(retryAfter: 60) }
        let name = Self.cleanName(deviceName)
        guard !code.isEmpty, code.count <= 128 else { return .unauthorized }
        guard !name.isEmpty else { return .invalid("device_name is required") }
        guard store.consumeCode(hash: RemoteHash.hex(code), now: at) else {
            lock.lock()
            wrongCodes += 1
            let close = wrongCodes >= Self.maxWrongCodes
            if close { wrongCodes = 0 }
            lock.unlock()
            if close {
                store.closeCodes()
                onPairingClosed?()
            }
            return .unauthorized
        }
        let id = UUID().uuidString.lowercased()
        let secret = RemoteHash.random(32)
        let request = Pending(id: id, name: name, secretHash: RemoteHash.hex(secret), publicKey: publicKey.map { String($0.prefix(256)) }, created: at, state: .waiting)
        lock.lock()
        pending[id] = request
        lock.unlock()
        onPairingRequest?(RemotePairingRequest(id: id, deviceName: name, created: at))
        return .accepted(RemotePairAccepted(pairingID: id, secret: secret, expiresIn: Int(Self.codeLifetime)))
    }

    /// The name goes into a bubble, so it is one line of printable text and at most 60 characters.
    static func cleanName(_ raw: String) -> String {
        let printable = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        return String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces).prefix(60).description
    }

    /// The user pressed Allow or Deny. A request that is not waiting any more is ignored.
    func decide(_ id: String, allow: Bool) {
        let at = now()
        lock.lock()
        guard var request = pending[id], case .waiting = request.state, at.timeIntervalSince(request.created) < Self.codeLifetime else {
            lock.unlock()
            return
        }
        if allow {
            let token = "ipt_" + RemoteHash.random(32)
            let device = RemoteDevice(id: UUID().uuidString.lowercased(), name: request.name, created: at, lastSeen: nil, origin: nil, publicKey: request.publicKey)
            do {
                try store.add(device, tokenHash: RemoteHash.hex(token))
                request.state = .allowed(token: token, deviceID: device.id)
            } catch {
                NSLog("ironpet: remote device could not be saved: \(error.localizedDescription)")
                request.state = .denied
            }
        } else {
            request.state = .denied
        }
        pending[id] = request
        let allowed: Bool = { if case .allowed = request.state { return true } else { return false } }()
        lock.unlock()
        activity?(ActivityEvent(at: at, kind: ActivityEvent.Kind(allowed ? "remote.paired" : "remote.denied"), ref: id,
                                title: allowed ? "Paired \(request.name)" : "Refused pairing with \(request.name)"))
        onPairingResolved?(id)
        onDevicesChanged?()
    }

    func poll(id: String, secret: String) -> RemotePollResult {
        let at = now()
        lock.lock()
        guard var request = pending[id], RemoteHash.equal(request.secretHash, RemoteHash.hex(secret)) else {
            lock.unlock()
            return failedAuthentication()
        }
        defer { lock.unlock() }
        switch request.state {
        case .waiting:
            if at.timeIntervalSince(request.created) >= Self.codeLifetime { return .expired }
            return .pending
        case .allowed(let token, let deviceID):
            request.state = .delivered
            pending[id] = request
            return .allowed(token: token, deviceID: deviceID)
        case .denied: return .denied
        case .delivered: return .gone
        }
    }

    // MARK: Authentication

    /// Reads a bearer token and finds its device. With `count` false nothing is recorded, for a check that another request repeats.
    func authenticate(authorization: String?, origin: String?, count: Bool = true) -> RemoteAuthResult {
        let at = now()
        if let token = Self.bearer(authorization), let device = store.device(tokenHash: RemoteHash.hex(token)) {
            guard count else { return .device(device) }
            lock.lock()
            var bucket = buckets[device.id] ?? Bucket(tokens: Self.burst, updated: at)
            bucket.tokens = min(Self.burst, bucket.tokens + max(0, at.timeIntervalSince(bucket.updated)) * Self.sustained)
            bucket.updated = at
            let ok = bucket.tokens >= 1
            if ok { bucket.tokens -= 1 }
            buckets[device.id] = bucket
            let due = touched[device.id].map { at.timeIntervalSince($0) >= Self.touchInterval } ?? true
            if ok, due { touched[device.id] = at }
            lock.unlock()
            guard ok else { return .limited(retryAfter: 1) }
            if due { store.touch(device.id, at: at, origin: origin.map { String($0.prefix(200)) }) }
            return .device(device)
        }
        guard count else { return .unauthorized }
        switch failedAuthentication() {
        case .limited(let seconds): return .limited(retryAfter: seconds)
        default: return .unauthorized
        }
    }

    /// Counts one request that carried no valid token. The eleventh in a minute starts a lockout of five minutes.
    private func failedAuthentication() -> RemotePollResult {
        let at = now()
        lock.lock()
        if let until = lockedUntil, until > at {
            lock.unlock()
            return .limited(retryAfter: max(1, Int(until.timeIntervalSince(at).rounded(.up))))
        }
        lockedUntil = nil
        let within = unauthWindow.hit(at: at, limit: Self.unauthenticatedPerMinute, span: 60)
        if !within { lockedUntil = at.addingTimeInterval(Self.lockout) }
        lock.unlock()
        guard !within else { return .unauthorized }
        onAuthBurst?()
        activity?(ActivityEvent(at: at, kind: ActivityEvent.Kind("remote.blocked"), ref: "auth", title: "Blocked requests to the remote API without a valid token"))
        return .limited(retryAfter: Int(Self.lockout))
    }

    static func bearer(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty || token.count > 256 ? nil : token
    }

    // MARK: Devices

    var devices: [RemoteDevice] { store.devices() }

    @discardableResult
    func revoke(_ id: String) -> Bool {
        let name = store.devices().first { $0.id == id }?.name
        guard store.remove(id) else { return false }
        closeSockets(device: id)
        lock.lock()
        buckets[id] = nil
        touched[id] = nil
        lock.unlock()
        activity?(ActivityEvent(at: now(), kind: ActivityEvent.Kind("remote.revoked"), ref: id, title: "Revoked \(name ?? "a device")"))
        onDevicesChanged?()
        return true
    }

    /// Removes every device and makes a new certificate, so tokens and fingerprints handed out so far stop working.
    func revokeAllAndRotate() {
        let count = store.devices().count
        store.removeAll()
        store.closeCodes()
        identity.rotate()
        closeAllSockets()
        lock.lock()
        pending = [:]
        buckets = [:]
        touched = [:]
        lock.unlock()
        activity?(ActivityEvent(at: now(), kind: ActivityEvent.Kind("remote.revoked_all"), ref: "all", title: "Revoked \(count) device\(count == 1 ? "" : "s") and made a new certificate"))
        onDevicesChanged?()
    }

    // MARK: Sockets

    /// Registers an open event socket, or returns nil when the device already has three. `close` ends the socket.
    func openSocket(device: String, close: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard sockets.values.filter({ $0.device == device }).count < Self.socketsPerDevice else { return nil }
        let id = UUID()
        sockets[id] = (device, close)
        return id
    }

    func socketClosed(_ id: UUID) {
        lock.lock()
        sockets[id] = nil
        lock.unlock()
    }

    func socketCount(device: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.values.filter { $0.device == device }.count
    }

    func closeSockets(device: String) {
        lock.lock()
        let victims = sockets.filter { $0.value.device == device }.map(\.value.close)
        lock.unlock()
        victims.forEach { $0() }
    }

    func closeAllSockets() {
        lock.lock()
        let victims = sockets.map(\.value.close)
        lock.unlock()
        victims.forEach { $0() }
    }

    // MARK: Log

    func log(_ row: RemoteAccessRow) {
        store.log(row)
        prune(row.at)
    }

    private func prune(_ at: Date) {
        lock.lock()
        let due = at.timeIntervalSince(lastPrune) > 86_400
        if due { lastPrune = at }
        lock.unlock()
        if due {
            store.pruneLog(now: at)
            store.pruneCodes(now: at)
        }
    }
}
