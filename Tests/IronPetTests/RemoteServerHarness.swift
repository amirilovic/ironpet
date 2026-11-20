import CryptoKit
import Darwin
import Security
import XCTest
@testable import IronPet

final class RemoteTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

struct RemoteReply {
    var status: Int
    var data: Data
    var headers: [String: String]
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
}

/// Accepts a server only when the SHA-256 of its leaf certificate (DER) is `fingerprint`, the way the phone treats the `f` of the QR code.
/// Host name, dates and the chain are not checked, so a self-signed certificate passes with the right hash and nothing passes with another.
final class PinningDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              RemoteHash.hex(SecCertificateCopyData(leaf) as Data) == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// The remote API over in-memory stores on an ephemeral port, with a fake clock and a real Announcer, so a test pairs the way a phone does.
@MainActor
final class RemoteServerHarness {
    let clock = RemoteTestClock()
    let events: APIEventBus
    let bubbles = BubbleStore()
    let api: IronPetAPI
    let controller: RemoteController
    let database: Database
    let session: URLSession

    /// `interfaces` is what the controller sees as the Mac's addresses. Empty by default, so a controller test binds loopback only.
    init(eventCapacity: Int = 500, interfaces: [InterfaceAddress] = []) {
        events = APIEventBus(capacity: eventCapacity)
        database = APITestSupport.memoryDatabase()
        api = APITestSupport.makeAPI(events: events, bubbles: bubbles)
        let clock = clock
        controller = RemoteController(api: api, settings: api.settings, database: database, bubbles: bubbles, activity: nil,
                                      storage: MemoryKeyStorage(), now: { clock.now },
                                      interfaces: { interfaces }, magicDNS: { nil })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    var service: RemoteService { controller.service }
    var port: Int { controller.server!.port ?? 0 }

    func start() async throws { try await controller.server!.start(port: 0) }
    func stop() async { await controller.server!.stop() }

    /// Loopback plain HTTP and HTTPS on `address`, on one free port.
    func startSecure(_ address: String) async throws { try await controller.server!.start(port: 0, secureAddress: address) }

    /// The test Mac as the controller sees it: one address, 127.0.0.1, which gets the HTTPS listener alone. Sandboxes and VMs often cannot
    /// connect to the machine's own LAN address, so the TLS tests use the loopback address and a test of the bind checks the real one.
    static let loopbackInterface = InterfaceAddress(name: "lo0", ip: "127.0.0.1")

    /// An address of this Mac that is not loopback. Nil on a machine with no network.
    static func localAddress() -> InterfaceAddress? {
        let all = RemoteNetwork.interfaces()
        return all.first { $0.name.hasPrefix("en") } ?? all.first
    }

    /// When set, `request` goes over HTTPS to 127.0.0.1 and accepts only this certificate hash.
    var pinned: String?

    /// A request over HTTPS that accepts only the certificate with `fingerprint`.
    func secureRequest(_ method: String, address: String, port: Int, _ path: String, fingerprint: String, token: String? = nil,
                       body: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> RemoteReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        let pinned = URLSession(configuration: configuration, delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
        defer { pinned.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://\(address):\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await pinned.data(for: request)
        let http = response as! HTTPURLResponse
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields { fields["\(key)".lowercased()] = "\(value)" }
        return RemoteReply(status: http.statusCode, data: data, headers: fields)
    }

    func request(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> RemoteReply {
        if let pinned {
            return try await secureRequest(method, address: "127.0.0.1", port: port, path, fingerprint: pinned, token: token, body: body, headers: headers)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields { fields["\(key)".lowercased()] = "\(value)" }
        return RemoteReply(status: http.statusCode, data: data, headers: fields)
    }

    struct Paired {
        var token: String
        var deviceID: String
        var response: RemoteReply
        var code: String
    }

    /// Runs the whole pairing: a code, `POST /v1/pair`, the bubble's Allow and the poll that hands out the token.
    func pairDevice(name: String = "Test phone") async throws -> Paired {
        let code = service.newPairingCode().code
        let reply = try await request("POST", "/v1/pair", body: ["code": code, "device_name": name])
        XCTAssertEqual(reply.status, 202)
        let id = reply.json["pairing_id"] as! String, secret = reply.json["secret"] as! String
        try pressBubble(id, "Allow")
        let poll = try await request("GET", "/v1/pair/\(id)", headers: ["X-Pairing-Secret": secret])
        XCTAssertEqual(poll.json["status"] as? String, "allowed", String(decoding: poll.data, as: UTF8.self) + " \(poll.status)")
        return Paired(token: poll.json["token"] as! String, deviceID: poll.json["device_id"] as! String, response: reply, code: code)
    }

    func pressBubble(_ pairingID: String, _ title: String) throws {
        let bubble = try XCTUnwrap(api.bubbles.list().first { $0.id == Announcer.remotePairingID(pairingID) }, "no pairing bubble")
        let action = try XCTUnwrap(bubble.actions.first { $0.title == title })
        try api.bubbles.press(PressBubbleRequest(bubble: bubble.id, action: action.id))
    }

    /// A TCP port nothing listens on, for the settings-driven start.
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
