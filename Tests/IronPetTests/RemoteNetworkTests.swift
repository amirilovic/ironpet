import CryptoKit
import Security
import XCTest
@testable import IronPet

final class RemoteNetworkTests: XCTestCase {
    private let sample: [InterfaceAddress] = [
        .init(name: "en0", ip: "192.168.68.51"), .init(name: "utun0", ip: "10.33.33.1"), .init(name: "bridge100", ip: "192.168.64.1"),
        .init(name: "utun5", ip: "100.96.0.2"), .init(name: "utun15", ip: "100.73.7.100"),
    ]

    // S1
    func testTailscaleComesFirstThenWifiThenTheRest() {
        let list = RemoteNetwork.addresses(from: sample)
        XCTAssertEqual(list.map(\.label), ["100.96.0.2 (utun5)", "100.73.7.100 (utun15)", "192.168.68.51 (en0)", "10.33.33.1 (utun0)", "192.168.64.1 (bridge100)"])
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "", addresses: list), .direct(bindIP: "100.96.0.2", host: "100.96.0.2"), "the first line is the default")
    }

    func testTailscaleRangeIs100_64_0_0_10() {
        XCTAssertTrue(RemoteNetwork.isTailscale("100.64.0.1"))
        XCTAssertTrue(RemoteNetwork.isTailscale("100.127.255.255"))
        XCTAssertFalse(RemoteNetwork.isTailscale("100.63.0.1"))
        XCTAssertFalse(RemoteNetwork.isTailscale("100.128.0.1"))
        XCTAssertFalse(RemoteNetwork.isTailscale("10.0.0.1"))
    }

    func testMagicDNSNameFollowsTheTailscaleAddresses() {
        let list = RemoteNetwork.addresses(from: sample, magicDNS: "mac.tail1234.ts.net")
        XCTAssertEqual(list.map(\.value), ["100.96.0.2", "100.73.7.100", "mac.tail1234.ts.net", "192.168.68.51", "10.33.33.1", "192.168.64.1"])
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "mac.tail1234.ts.net", addresses: list), .direct(bindIP: "100.96.0.2", host: "mac.tail1234.ts.net"))
        XCTAssertEqual(RemoteNetwork.addresses(from: [.init(name: "en0", ip: "192.168.1.5")], magicDNS: "x.ts.net").count, 1, "no Tailscale address to bind, no name")
    }

    func testMagicDNSNameIsReadFromTailscaleStatus() {
        let json = Data(#"{"Self":{"DNSName":"mac.tail1234.ts.net.","TailscaleIPs":["100.96.0.2"]}}"#.utf8)
        XCTAssertEqual(RemoteNetwork.magicDNSName(statusJSON: json), "mac.tail1234.ts.net")
        XCTAssertNil(RemoteNetwork.magicDNSName(statusJSON: Data("{}".utf8)))
        XCTAssertNil(RemoteNetwork.magicDNSName(statusJSON: Data("not json".utf8)))
    }

    func testTheSameAddressOnTwoInterfacesIsListedOnce() {
        let list = RemoteNetwork.addresses(from: [.init(name: "en0", ip: "10.0.0.2"), .init(name: "en1", ip: "10.0.0.2")])
        XCTAssertEqual(list.count, 1)
    }

    // S6
    func testCustomAddressesBecomeAnEndpoint() {
        let list = RemoteNetwork.addresses(from: sample)
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "https://mac.tailnet.ts.net/", addresses: list), .front(url: "https://mac.tailnet.ts.net"))
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "mac.example.com", addresses: list), .front(url: "https://mac.example.com"))
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "192.168.1.9", addresses: list), .direct(bindIP: "192.168.1.9", host: "192.168.1.9"))
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "", addresses: []), .none)
        let front = RemoteEndpoint.front(url: "https://mac.tailnet.ts.net")
        XCTAssertFalse(front.pinsCertificate)
        XCTAssertNil(front.bindIP, "a front reaches the loopback listener, so nothing else is bound")
        XCTAssertEqual(front.baseURL(port: 47380), "https://mac.tailnet.ts.net")
    }

    func testNothingEverBindsEveryInterfaceOrLoopbackTwice() {
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "0.0.0.0", addresses: []), .none)
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "127.0.0.1", addresses: []), .none)
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "127.0.0.2", addresses: []), .none)
    }

    func testTheRealInterfaceListHasNoLoopbackOrLinkLocal() {
        for item in RemoteNetwork.interfaces() {
            XCTAssertFalse(item.ip.hasPrefix("127."), item.ip)
            XCTAssertFalse(item.ip.hasPrefix("169.254."), item.ip)
            XCTAssertTrue(RemoteNetwork.isIPv4(item.ip), item.ip)
        }
    }

    // S2
    func testPairingLinkPayload() {
        let code = RemotePairingCode(code: "abc123", fingerprint: "f00d", expires: Date())
        XCTAssertEqual(RemoteController.pairingLink(baseURL: "https://100.96.0.2:47380", code: code), "ironpet://pair?u=https://100.96.0.2:47380&c=abc123&f=f00d")
        XCTAssertEqual(RemoteController.pairingLink(baseURL: "https://mac.ts.net", code: code, pin: false), "ironpet://pair?u=https://mac.ts.net&c=abc123")
        XCTAssertNil(RemoteController.pairingLink(baseURL: " ", code: code))
    }

    func testMachineNameDefaultsToTheMacsName() {
        XCTAssertEqual(RemoteController.machineName("  Studio Mac "), "Studio Mac")
        XCTAssertFalse(RemoteController.machineName("").isEmpty)
    }

    func testTheCertificateIsStableUntilRotated() throws {
        let storage = MemoryKeyStorage()
        let first = RemoteIdentity(storage: storage)
        let hash = first.fingerprint
        XCTAssertEqual(RemoteIdentity(storage: storage).fingerprint, hash, "a second launch loads the saved certificate")
        first.rotate()
        XCTAssertNotEqual(first.fingerprint, hash)
        XCTAssertEqual(RemoteIdentity(storage: storage).fingerprint, first.fingerprint)
    }

    func testTheHandWrittenCertificateParsesAndCarriesTheKey() throws {
        let key = P256.Signing.PrivateKey()
        let der = SelfSignedCertificate.der(key: key, commonName: "ironpet", now: Date())
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData), "Security parses the DER")
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "ironpet")
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let raw = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        XCTAssertEqual(raw, key.publicKey.x963Representation, "the certificate holds the key it is signed with")
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        XCTAssertNotNil(trust)
    }

    func testTheTLSKeychainMakesAnIdentityAndCleansUp() throws {
        let identity = RemoteIdentity(storage: MemoryKeyStorage())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-kc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keychain = try RemoteTLSKeychain(identity.material, folder: folder)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(keychain.identity, &certificate), errSecSuccess)
        XCTAssertEqual(RemoteHash.hex(SecCertificateCopyData(try XCTUnwrap(certificate)) as Data), identity.fingerprint)
        keychain.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "the keychain file is gone after close")
    }

    func testAnOlderEd25519KeyFileIsReplaced() {
        let storage = MemoryKeyStorage()
        storage.save(Data(repeating: 7, count: 32).base64EncodedData())
        XCTAssertEqual(RemoteIdentity(storage: storage).fingerprint.count, 64)
    }

    func testTheKeyFileIsPrivate() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-\(UUID().uuidString)/remote/identity.key")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let identity = RemoteIdentity(storage: FileKeyStorage(file: file))
        identity.ensure()
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

@MainActor
final class RemoteSecureListenerTests: XCTestCase {
    private let loopback = RemoteServerHarness.loopbackInterface

    // S3
    func testAPinnedClientPairsAndListsTasksOverHTTPS() async throws {
        let h = RemoteServerHarness()
        try await h.startSecure(loopback.ip)
        h.pinned = h.service.newPairingCode().fingerprint
        let paired = try await h.pairDevice()
        let tasks = try await h.request("GET", "/v1/tasks", token: paired.token)
        XCTAssertEqual(tasks.status, 200)
        await h.stop()
    }

    func testAnotherPinnedFingerprintIsRejectedByTheClient() async throws {
        let h = RemoteServerHarness()
        try await h.startSecure(loopback.ip)
        do {
            _ = try await h.secureRequest("GET", address: loopback.ip, port: h.port, "/v1/tasks", fingerprint: String(repeating: "0", count: 64))
            XCTFail("the handshake should fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled, "the client's delegate cancelled the handshake: \(error)")
        }
        await h.stop()
    }

    func testPlainHTTPOnTheSecureAddressIsRefused() async throws {
        let h = RemoteServerHarness()
        try await h.startSecure(loopback.ip)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/v1/tasks")!)
        request.timeoutInterval = 3
        let reply = try? await h.session.data(for: request)
        XCTAssertNil(reply, "the listener does not answer a plain request")
        await h.stop()
    }

    // S4
    func testNothingListensOnEveryInterface() async throws {
        let address = try XCTUnwrap(RemoteServerHarness.localAddress(), "this Mac has no network address").ip
        let h = RemoteServerHarness()
        try await h.startSecure(address)
        let listening = try listeners(port: h.port)
        XCTAssertEqual(Set(listening), Set(["127.0.0.1", address]), "\(listening)")
        await h.stop()
    }

    func testTheSecureListenerNeverTakesTheWildcardAddress() {
        XCTAssertEqual(RemoteNetwork.endpoint(setting: "0.0.0.0", addresses: []).bindIP, nil)
    }

    /// The addresses `lsof` shows for the listening sockets of `port` in this process.
    private func listeners(port: Int) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }
            .map { String($0.dropFirst().split(separator: ":").first ?? "") }
    }

    // S2
    func testTheControllerBindsTheChosenAddressAndShowsTheLinkAtOnce() async throws {
        let h = RemoteServerHarness(interfaces: [loopback])
        let port = RemoteServerHarness.freePort()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port }
        await h.controller.settled()
        XCTAssertNil(h.controller.pairing, "no code is made while the Devices page is closed")
        h.controller.pageAppeared()
        XCTAssertEqual(h.controller.status, .listening(port: port))
        XCTAssertEqual(h.controller.server?.secureAddress, loopback.ip, "the default is the first address of the list")
        let link = try XCTUnwrap(h.controller.pairingLink, "a code is shown without a button press")
        let code = try XCTUnwrap(h.controller.pairing)
        XCTAssertEqual(link, "ironpet://pair?u=https://\(loopback.ip):\(port)&c=\(code.code)&f=\(code.fingerprint)")
        await h.controller.server?.stop()
    }

    // S5
    func testRevokeAllAndRotateMakesANewCertificate() async throws {
        let h = RemoteServerHarness(interfaces: [loopback])
        let port = RemoteServerHarness.freePort()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port }
        await h.controller.settled()
        let old = h.service.identity.fingerprint
        h.pinned = old
        let paired = try await h.pairDevice()
        let before = try await h.request("GET", "/v1/tasks", token: paired.token)
        XCTAssertEqual(before.status, 200)

        h.controller.revokeAllAndRotate()
        await h.controller.settled()
        let new = h.service.identity.fingerprint
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(h.controller.server?.servedFingerprint, new, "the listener restarted with the new certificate")
        do {
            _ = try await h.request("GET", "/v1/tasks", token: paired.token)
            XCTFail("the old pin must fail")
        } catch {}
        h.pinned = new
        h.clock.advance(61)
        let after = try await h.request("GET", "/v1/tasks", token: paired.token)
        XCTAssertEqual(after.status, 401)
        await h.controller.server?.stop()
    }

    // S6
    func testACustomFrontKeepsTheLoopbackListenerAndPinsNothing() async throws {
        let h = RemoteServerHarness(interfaces: [loopback])
        let port = RemoteServerHarness.freePort()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port; $0.remote.address = "https://mac.tailnet.ts.net" }
        await h.controller.settled()
        h.controller.pageAppeared()
        XCTAssertEqual(h.controller.status, .listening(port: port))
        XCTAssertNil(h.controller.server?.secureAddress)
        let link = try XCTUnwrap(h.controller.pairingLink)
        let code = try XCTUnwrap(h.controller.pairing)
        XCTAssertEqual(link, "ironpet://pair?u=https://mac.tailnet.ts.net&c=\(code.code)")
        let reply = try await h.request("GET", "/v1/tasks")
        XCTAssertEqual(reply.status, 401, "the front reaches the plain loopback listener")
        await h.controller.server?.stop()
    }

    func testChangingTheAddressMovesTheListener() async throws {
        let h = RemoteServerHarness(interfaces: [loopback])
        let port = RemoteServerHarness.freePort()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port }
        await h.controller.settled()
        XCTAssertEqual(h.controller.server?.secureAddress, loopback.ip)
        h.api.settings.update { $0.remote.address = "https://front.example.com" }
        await h.controller.settled()
        XCTAssertNil(h.controller.server?.secureAddress)
        XCTAssertEqual(h.controller.status, .listening(port: port))
        await h.controller.server?.stop()
    }

    func testTheListenerMovesWhileAConnectionIsStillOpen() async throws {
        let h = RemoteServerHarness(interfaces: [loopback])
        let port = RemoteServerHarness.freePort()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port; $0.remote.address = "https://front.example.com" }
        await h.controller.settled()
        // A client that keeps its connection open, as a phone's event socket or a front does.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(connected, 0)
        let request = "GET /v1/tasks HTTP/1.1\r\nHost: x\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 512)
        XCTAssertGreaterThan(recv(fd, &buffer, buffer.count, 0), 0)

        h.api.settings.update { $0.remote.address = "" }
        await h.controller.settled()
        XCTAssertEqual(h.controller.status, .listening(port: port), "a closing connection does not block the new listener")
        XCTAssertEqual(h.controller.server?.secureAddress, loopback.ip)
        await h.controller.server?.stop()
    }

    func testAMissingAddressIsReportedNotSwallowed() async throws {
        let h = RemoteServerHarness(interfaces: [])
        let port = RemoteServerHarness.freePort()
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port; $0.remote.address = "10.255.255.254" }
        await h.controller.settled()
        guard case .failed(let message) = h.controller.status else { return XCTFail("\(h.controller.status)") }
        XCTAssertTrue(message.contains("10.255.255.254"), message)
        XCTAssertFalse(h.controller.server?.isRunning ?? true, "the loopback listener does not keep running after a failed start")
    }
}
