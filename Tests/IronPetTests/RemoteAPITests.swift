import CryptoKit
import XCTest
@testable import IronPet

@MainActor
final class RemoteAPITests: XCTestCase {
    private var h: RemoteServerHarness!

    override func setUp() async throws {
        h = RemoteServerHarness()
        try await h.start()
    }

    override func tearDown() async throws { await h.stop() }

    private func connects(_ port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/tasks")!)
        request.timeoutInterval = 2
        return (try? await h.session.data(for: request)) != nil
    }

    // S1
    func testPortFollowsTheSetting() async throws {
        await h.stop()
        let port = RemoteServerHarness.freePort()
        let ok = await connects(port)
        XCTAssertFalse(ok)
        h.api.settings.update { $0.remote.enabled = true; $0.remote.port = port }
        await h.controller.settled()
        var answered = await connects(port)
        XCTAssertTrue(answered, "the port answers once the setting is on")
        XCTAssertEqual(h.controller.status, .listening(port: port))
        let device = try await pairForSocket()
        let socket = h.session.webSocketTask(with: socketRequest(port: port, token: device))
        socket.resume()
        _ = try await socket.receive()
        h.api.settings.update { $0.remote.enabled = false }
        await h.controller.settled()
        answered = await connects(port)
        XCTAssertFalse(answered, "refused after turning it off")
        do {
            // The settings change itself arrives as an event first.
            for _ in 0..<5 { _ = try await socket.receive() }
            XCTFail("the socket should be closed")
        } catch {}
    }

    private func pairForSocket() async throws -> String {
        let code = h.service.newPairingCode().code
        let port = h.controller.server!.port!
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pair")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "device_name": "Socket phone"])
        let (data, _) = try await h.session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let id = json["pairing_id"] as! String, secret = json["secret"] as! String
        try h.pressBubble(id, "Allow")
        var poll = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pair/\(id)")!)
        poll.setValue(secret, forHTTPHeaderField: "X-Pairing-Secret")
        let (pollData, _) = try await h.session.data(for: poll)
        return (try JSONSerialization.jsonObject(with: pollData) as! [String: Any])["token"] as! String
    }

    private func socketRequest(port: Int, token: String?, since: Int? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/events" + (since.map { "?since=\($0)" } ?? ""))!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    // S2
    func testAllowHandsOutTheTokenOnceAndStoresOnlyItsHash() async throws {
        let paired = try await h.pairDevice()
        XCTAssertTrue(paired.token.hasPrefix("ipt_"))
        let device = try XCTUnwrap(h.service.devices.first)
        XCTAssertEqual(device.id, paired.deviceID)
        let rows = try h.database.read { try $0.rows("SELECT token_hash FROM remote_devices") }
        XCTAssertEqual(rows.compactMap { $0[0] as? String }, [RemoteHash.hex(paired.token)])
        let dump = try h.database.read { try $0.rows("SELECT * FROM remote_devices") }.flatMap { $0 }.compactMap { $0 as? String }
        XCTAssertFalse(dump.contains(paired.token))
        let id = paired.response.json["pairing_id"] as! String, secret = paired.response.json["secret"] as! String
        let again = try await h.request("GET", "/v1/pair/\(id)", headers: ["X-Pairing-Secret": secret])
        XCTAssertEqual(again.status, 410, "the token comes out once")
    }

    func testDenyGivesNoDevice() async throws {
        let code = h.service.newPairingCode().code
        let reply = try await h.request("POST", "/v1/pair", body: ["code": code, "device_name": "Stranger"])
        let id = reply.json["pairing_id"] as! String, secret = reply.json["secret"] as! String
        let bubble = try XCTUnwrap(h.api.bubbles.list().first { $0.id == Announcer.remotePairingID(id) })
        XCTAssertTrue(bubble.title.contains("Stranger"))
        try h.pressBubble(id, "Deny")
        let poll = try await h.request("GET", "/v1/pair/\(id)", headers: ["X-Pairing-Secret": secret])
        XCTAssertEqual(poll.json["status"] as? String, "denied")
        XCTAssertTrue(h.service.devices.isEmpty)
    }

    // S3
    func testUsedAndExpiredCodesAreRefusedWithoutABubble() async throws {
        let used = try await h.pairDevice()
        h.api.bubbles.list().forEach { try? h.api.bubbles.dismiss($0.id) }
        var reply = try await h.request("POST", "/v1/pair", body: ["code": used.code, "device_name": "Again"])
        XCTAssertEqual(reply.status, 401)
        let old = h.service.newPairingCode().code
        h.clock.advance(RemoteService.codeLifetime + 1)
        reply = try await h.request("POST", "/v1/pair", body: ["code": old, "device_name": "Late"])
        XCTAssertEqual(reply.status, 401)
        XCTAssertTrue(h.api.bubbles.list().isEmpty)
    }

    // S4
    func testPairingAttemptsAndUnauthenticatedRequestsAreLimited() async throws {
        for _ in 0..<5 {
            let reply = try await h.request("POST", "/v1/pair", body: ["code": "wrong", "device_name": "x"])
            XCTAssertEqual(reply.status, 401)
        }
        let sixth = try await h.request("POST", "/v1/pair", body: ["code": "wrong", "device_name": "x"])
        XCTAssertEqual(sixth.status, 429)
        h.clock.advance(61)
        for index in 0..<10 {
            let reply = try await h.request("GET", "/v1/tasks")
            XCTAssertEqual(reply.status, 401, "request \(index + 1)")
        }
        let eleventh = try await h.request("GET", "/v1/tasks")
        XCTAssertEqual(eleventh.status, 429)
        XCTAssertNotNil(eleventh.headers["retry-after"])
        XCTAssertEqual(h.api.bubbles.list().filter { $0.id == "remote:blocked" }.count, 1)
        let during = try await h.request("GET", "/v1/tasks", token: "nope")
        XCTAssertEqual(during.status, 429)
        h.clock.advance(RemoteService.lockout + 1)
        let after = try await h.request("GET", "/v1/tasks")
        XCTAssertEqual(after.status, 401)
    }

    func testFiveWrongCodesClosePairing() async throws {
        let good = h.service.newPairingCode().code
        h.clock.advance(0)
        for _ in 0..<5 { _ = try await h.request("POST", "/v1/pair", body: ["code": "wrong", "device_name": "x"]) }
        h.clock.advance(61)
        let reply = try await h.request("POST", "/v1/pair", body: ["code": good, "device_name": "x"])
        XCTAssertEqual(reply.status, 401, "the open code was closed")
    }

    // S5
    func testTasksNeedTheDevicesToken() async throws {
        let paired = try await h.pairDevice()
        _ = try h.api.tasks.create(CreateTaskRequest(title: "Write docs", source: .user))
        let none = try await h.request("GET", "/v1/tasks")
        XCTAssertEqual(none.status, 401)
        let wrong = try await h.request("GET", "/v1/tasks", token: "ipt_wrong")
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(wrong.json["error"] as? [String: String], ["code": "unauthorized", "message": "unauthorized"])
        let ok = try await h.request("GET", "/v1/tasks", token: paired.token)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(ok.headers["cache-control"], "no-store")
        let list = try XCTUnwrap(ok.json["tasks"] as? [[String: Any]])
        XCTAssertEqual(list.compactMap { $0["id"] as? String }, h.api.tasks.list().map(\.id))
        XCTAssertNotNil(list.first?["created"] as? String, "ISO 8601 date")
        h.clock.advance(61)
        let revoke = try await h.request("DELETE", "/v1/devices/me", token: paired.token)
        XCTAssertEqual(revoke.status, 200)
        let revoked = try await h.request("GET", "/v1/tasks", token: paired.token)
        XCTAssertEqual(revoked.status, 401)
    }

    // S6
    func testAcceptingASuggestionRecordsTheDevice() async throws {
        let paired = try await h.pairDevice()
        h.api.tasks.suggest(SuggestTaskRequest(draft: .init(key: "k", title: "Review PR", due: nil), kind: .pr, sourceRef: "pr:1"))
        let suggestion = try XCTUnwrap(h.api.tasks.suggestions.first)
        let list = try await h.request("GET", "/v1/suggestions", token: paired.token)
        XCTAssertEqual((list.json["suggestions"] as? [[String: Any]])?.count, 1)
        let accepted = try await h.request("POST", "/v1/suggestions/\(suggestion.id)/accept", token: paired.token, body: [:])
        XCTAssertEqual(accepted.status, 200)
        let task = try XCTUnwrap(h.api.tasks.items.first { $0.title == "Review PR" })
        XCTAssertTrue(h.api.tasks.history(task.id).contains { $0.by == "remote:\(paired.deviceID)" })
    }

    // S7
    func testClosingNeedsANote() async throws {
        let paired = try await h.pairDevice()
        let task = try h.api.tasks.create(CreateTaskRequest(title: "Ship", source: .user))
        let bad = try await h.request("POST", "/v1/tasks/\(task.id)/close", token: paired.token, body: [:])
        XCTAssertEqual(bad.status, 400)
        let message = (bad.json["error"] as? [String: Any])?["message"] as? String
        XCTAssertEqual(message, "note is required and must not be empty: say what shows the task is done")
        let good = try await h.request("POST", "/v1/tasks/\(task.id)/close", token: paired.token, body: ["note": "merged"])
        XCTAssertEqual(good.status, 200)
        XCTAssertEqual(h.api.tasks.task(task.id)?.status, .done)
        let missing = try await h.request("GET", "/v1/tasks/nope", token: paired.token)
        XCTAssertEqual(missing.status, 404)
    }

    // S8
    private func read(_ socket: URLSessionWebSocketTask, until kind: String, limit: Int = 10) async throws -> [[String: Any]] {
        var seen: [[String: Any]] = []
        for _ in 0..<limit {
            guard case .string(let text) = try await socket.receive() else { continue }
            let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            seen.append(frame)
            if frame["kind"] as? String == kind { break }
        }
        return seen
    }

    func testEventSocketStreamsReplaysAndClosesOnRevoke() async throws {
        let paired = try await h.pairDevice()
        let socket = h.session.webSocketTask(with: socketRequest(port: h.port, token: paired.token))
        socket.resume()
        let hello = try await read(socket, until: "hello")
        XCTAssertEqual(hello.last?["kind"] as? String, "hello")
        let started = Date()
        _ = try h.api.tasks.create(CreateTaskRequest(title: "Live", source: .user))
        let frames = try await read(socket, until: "tasks.changed")
        XCTAssertEqual(frames.last?["kind"] as? String, "tasks.changed")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let seen = try XCTUnwrap(frames.last?["seq"] as? Int)
        socket.cancel(with: .normalClosure, reason: nil)

        _ = try h.api.tasks.create(CreateTaskRequest(title: "Missed", source: .user))
        let again = h.session.webSocketTask(with: socketRequest(port: h.port, token: paired.token, since: seen))
        again.resume()
        let replay = try await read(again, until: "tasks.changed")
        XCTAssertTrue(replay.contains { ($0["seq"] as? Int ?? 0) > seen && $0["kind"] as? String == "tasks.changed" })
        XCTAssertFalse(replay.contains { $0["kind"] as? String == "resync" })

        h.service.revoke(paired.deviceID)
        do {
            for _ in 0..<5 { _ = try await again.receive() }
            XCTFail("the socket should be closed")
        } catch {}
    }

    func testOldSeqGetsResyncAndAnUnauthenticatedSocketIsRefused() async throws {
        let paired = try await h.pairDevice()
        // A seq above the bus's own comes from an earlier launch.
        let socket = h.session.webSocketTask(with: socketRequest(port: h.port, token: paired.token, since: 9_999))
        socket.resume()
        let frames = try await read(socket, until: "resync")
        XCTAssertEqual(frames.last?["kind"] as? String, "resync")
        socket.cancel(with: .normalClosure, reason: nil)
        let refused = h.session.webSocketTask(with: socketRequest(port: h.port, token: nil))
        refused.resume()
        do {
            _ = try await refused.receive()
            XCTFail("no token, no socket")
        } catch {}
    }

    // S9
    func testPairingCodeCarriesTheCertificateHash() async throws {
        let code = h.service.newPairingCode()
        XCTAssertEqual(code.fingerprint, RemoteHash.hex(h.service.identity.certificateDER))
        let reply = try await h.request("POST", "/v1/pair", body: ["code": code.code, "device_name": "Phone"])
        XCTAssertEqual(reply.status, 202)
        XCTAssertNil(reply.json["signature"], "the pinned certificate replaced the Ed25519 signature")
    }

    func testRevokeAllRotatesTheKeyAndKillsTokens() async throws {
        let paired = try await h.pairDevice()
        let before = h.service.identity.fingerprint
        h.service.revokeAllAndRotate()
        XCTAssertNotEqual(h.service.identity.fingerprint, before)
        h.clock.advance(61)
        let reply = try await h.request("GET", "/v1/tasks", token: paired.token)
        XCTAssertEqual(reply.status, 401)
        XCTAssertTrue(h.service.devices.isEmpty)
    }

    // S10
    func testAccessLogHoldsTemplatesOnly() async throws {
        let paired = try await h.pairDevice()
        let task = try h.api.tasks.create(CreateTaskRequest(title: "Secret title", source: .user))
        _ = try await h.request("GET", "/v1/tasks?label=secret:value", token: paired.token)
        _ = try await h.request("GET", "/v1/tasks/\(task.id)", token: paired.token)
        _ = try await h.request("POST", "/v1/tasks/\(task.id)/close", token: paired.token, body: ["note": "hush-note"])
        _ = try await h.request("GET", "/v1/unknown/path?x=1", token: paired.token)
        let rows = h.service.store.accessLog()
        XCTAssertTrue(rows.contains { $0.route == "/v1/tasks/:id" && $0.deviceID == paired.deviceID })
        XCTAssertTrue(rows.contains { $0.route == "/v1/tasks/:id/close" })
        let dump = try h.database.read { try $0.rows("SELECT * FROM remote_access_log") }.flatMap { $0 }.map { "\($0 ?? "")" }.joined(separator: "\n")
        for secret in [paired.token, paired.code, task.id, "secret:value", "hush-note", "unknown", "x=1"] {
            XCTAssertFalse(dump.contains(secret), "\(secret) is in the access log")
        }
    }
}


final class RemoteConfigTests: XCTestCase {
    func testPortStaysOutOfTheHookServersRange() {
        var config = Config()
        XCTAssertFalse(config.remote.enabled)
        XCTAssertEqual(config.remote.port, 47380)
        for bad in [0, 80, 47321, 47340, 70_000] {
            config.remote.port = bad
            XCTAssertEqual(config.sanitized().remote.port, 47380, "\(bad)")
        }
        config.remote.port = 47500
        config.remote.address = " https://mac.ts.net/ "
        XCTAssertEqual(config.sanitized().remote.port, 47500)
        XCTAssertEqual(config.sanitized().remote.address, "https://mac.ts.net")
    }

    func testAnOlderBaseUrlMovesToTheAddress() {
        var config = Config()
        config.remote.baseUrl = " https://mac.ts.net/ "
        let moved = config.sanitized().remote
        XCTAssertEqual(moved.address, "https://mac.ts.net")
        XCTAssertEqual(moved.baseUrl, "")
        config.remote.address = "100.96.0.2"
        XCTAssertEqual(config.sanitized().remote.address, "100.96.0.2", "an address already chosen wins")
    }
}

@MainActor
final class RemoteEvictionTests: XCTestCase {
    func testASeqPushedOutOfTheBufferGetsResync() async throws {
        let h = RemoteServerHarness(eventCapacity: 3)
        try await h.start()
        defer { Task { await h.stop() } }
        let paired = try await h.pairDevice()
        for index in 0..<6 { _ = try h.api.tasks.create(CreateTaskRequest(title: "T\(index)", source: .user)) }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(h.port)/v1/events?since=1")!)
        request.setValue("Bearer \(paired.token)", forHTTPHeaderField: "Authorization")
        let socket = h.session.webSocketTask(with: request)
        socket.resume()
        var kinds: [String] = []
        for _ in 0..<4 {
            guard case .string(let text) = try await socket.receive() else { continue }
            kinds.append((try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])["kind"] as! String)
            if kinds.last == "resync" { break }
        }
        XCTAssertTrue(kinds.contains("resync"), "\(kinds)")
        socket.cancel(with: .normalClosure, reason: nil)
    }
}
