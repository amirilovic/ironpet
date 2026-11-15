import XCTest
@testable import IronPet

/// A transport that records what the client writes and lets a test feed it agent output.
final class FakeTransport: ACPTransport {
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var sent: [JSON] = []

    func start(onData: @escaping (Data) -> Void, onClose: @escaping (String?) -> Void) throws {
        self.onData = onData
        self.onClose = onClose
    }

    func send(_ data: Data) {
        for line in data.split(separator: 0x0A) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSON { sent.append(object) }
        }
    }

    func close() {}

    func feed(_ text: String) { onData?(Data(text.utf8)) }
}

@MainActor
final class ACPClientTests: XCTestCase {
    private var transport: FakeTransport!
    private var client: ACPClient!

    override func setUp() async throws {
        transport = FakeTransport()
        client = ACPClient(transport: transport)
        try client.start()
    }

    /// Lets the request's task run far enough to write its line.
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testResponsesMatchRequestsByID() async throws {
        async let first = client.request("a")
        async let second = client.request("b")
        await settle()
        // `async let` children start in no fixed order, so look the ids up by method.
        XCTAssertEqual(Set(transport.sent.compactMap { $0["method"] as? String }), ["a", "b"])
        let ids = Dictionary(uniqueKeysWithValues: transport.sent.map { ($0["method"] as! String, $0["id"] as! Int) })
        XCTAssertNotEqual(ids["a"], ids["b"])
        // Answer in the opposite order to the one they were sent in.
        for method in transport.sent.compactMap({ $0["method"] as? String }).reversed() {
            transport.feed(#"{"jsonrpc":"2.0","id":\#(ids[method]!),"result":{"who":"\#(method)"}}"# + "\n")
        }
        let (a, b) = try await (first, second)
        XCTAssertEqual(a["who"] as? String, "a")
        XCTAssertEqual(b["who"] as? String, "b")
    }

    func testNotificationsArriveInOrder() {
        var seen: [String] = []
        client.onNotification = { method, params in seen.append("\(method):\(params["n"] ?? "")") }
        transport.feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"n":1}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"session/update","params":{"n":2}}"# + "\n")
        XCTAssertEqual(seen, ["session/update:1", "session/update:2"])
    }

    func testLinesSplitAcrossReadsAreJoined() {
        var count = 0
        client.onNotification = { _, _ in count += 1 }
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"text":"héllo"}}"# + "\n"
        let bytes = Array(line.utf8)
        // Split inside the multi-byte character as well.
        for chunk in [bytes[0..<20], bytes[20..<60], bytes[60..<bytes.count]] { client.receive(Data(chunk)) }
        XCTAssertEqual(count, 1)
        client.receive(Data("\n\n".utf8))
        XCTAssertEqual(count, 1, "blank lines are ignored")
    }

    func testAgentRequestIsAnsweredWithTheSameID() {
        client.onRequest = { method, params, respond in
            XCTAssertEqual(method, "session/request_permission")
            XCTAssertEqual(params["sessionId"] as? String, "s1")
            respond(.success(["outcome": ["outcome": "selected", "optionId": "allow-once"]]))
        }
        transport.feed(#"{"jsonrpc":"2.0","id":"perm-7","method":"session/request_permission","params":{"sessionId":"s1"}}"# + "\n")
        let reply = transport.sent.last
        XCTAssertEqual(reply?["id"] as? String, "perm-7")
        XCTAssertEqual(((reply?["result"] as? JSON)?["outcome"] as? JSON)?["optionId"] as? String, "allow-once")
    }

    func testUnknownAgentRequestGetsMethodNotFound() {
        transport.feed(#"{"jsonrpc":"2.0","id":3,"method":"fs/read_text_file","params":{}}"# + "\n")
        XCTAssertEqual((transport.sent.last?["error"] as? JSON)?["code"] as? Int, -32601)
    }

    func testErrorResponseThrows() async {
        async let result = client.request("session/new")
        await settle()
        let id = transport.sent[0]["id"] as! Int
        transport.feed(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"Authentication required"}}"# + "\n")
        do {
            _ = try await result
            XCTFail("expected an error")
        } catch let error as ACPError {
            XCTAssertEqual(error.code, -32000)
            XCTAssertTrue(error.isAuthRequired)
            XCTAssertEqual(error.message, "Authentication required")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testOnlySignInErrorsCountAsAuthRequired() {
        XCTAssertTrue(ACPError(code: -32000, message: "Authentication required").isAuthRequired)
        XCTAssertTrue(ACPError(code: -32000, message: "Authentication required: provider authentication required").isAuthRequired)
        XCTAssertTrue(ACPError(code: -32000, message: "Please log in first").isAuthRequired)
        XCTAssertFalse(ACPError(code: -32000, message: "This client is no longer supported for Gemini Code Assist for individuals.").isAuthRequired)
        XCTAssertFalse(ACPError(code: -32603, message: "Authentication failed in a tool").isAuthRequired)
    }

    func testClosingFailsPendingRequests() async {
        async let result = client.request("session/prompt")
        await settle()
        transport.onClose?("boom: stderr text")
        do {
            _ = try await result
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ACPError)?.message, "boom: stderr text")
        }
        do {
            _ = try await client.request("again")
            XCTFail("a closed client must refuse requests")
        } catch {}
    }
}

/// A resumed session replays its whole history as notifications. Measures what that costs the main thread.
@MainActor
final class ACPReplayCostTests: XCTestCase {
    static func replayData(lines: Int, megabytes: Int) -> [Data] {
        let filler = String(repeating: "x", count: megabytes * 1_048_576 / lines)
        var chunks: [Data] = []
        var all = Data()
        for i in 0..<lines {
            let update: JSON = i % 3 == 0
                ? ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": filler]]
                : ["sessionUpdate": "tool_call", "toolCallId": "t\(i)", "title": "Ran", "rawInput": ["command": filler]]
            let msg: JSON = ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "s", "update": update]]
            all.append(try! JSONSerialization.data(withJSONObject: msg))
            all.append(0x0A)
        }
        var offset = 0
        while offset < all.count { chunks.append(all.subdata(in: offset..<min(all.count, offset + 65_536))); offset += 65_536 }
        return chunks
    }

    func testReplayOfLargeSessionOnMainThread() throws {
        let transport = FakeTransport()
        let client = ACPClient(transport: transport)
        try client.start()
        var seen = 0
        client.onNotification = { _, _ in seen += 1 }
        let chunks = Self.replayData(lines: 4604, megabytes: 16)
        let cpu0 = HugeTranscriptTests.threadCPU()
        let wall0 = Date()
        var worstChunk = 0.0
        for chunk in chunks {
            let t = Date()
            transport.onData?(chunk)
            worstChunk = max(worstChunk, Date().timeIntervalSince(t))
        }
        XCTAssertLessThan(HugeTranscriptTests.threadCPU() - cpu0, 1.0, "replaying a 16 MB session blocked the main thread")
        print("REPLAY \(seen) notifications: main-thread cpu \(HugeTranscriptTests.threadCPU() - cpu0)s, wall \(Date().timeIntervalSince(wall0))s, worst chunk \(worstChunk)s, footprint \(HugeTranscriptTests.footprintMB()) MB")
    }
}
