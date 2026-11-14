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
        XCTAssertEqual(transport.sent.map { $0["method"] as? String }, ["a", "b"])
        let ids = transport.sent.map { $0["id"] as! Int }
        // Answer out of order.
        transport.feed(#"{"jsonrpc":"2.0","id":\#(ids[1]),"result":{"who":"b"}}"# + "\n")
        transport.feed(#"{"jsonrpc":"2.0","id":\#(ids[0]),"result":{"who":"a"}}"# + "\n")
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
