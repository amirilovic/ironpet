import XCTest
@testable import IronPet

final class ThreadRestoreTests: XCTestCase {
    private func thread(_ kinds: [ChatSession.Item.Kind]) -> ChatThread {
        ChatThread(id: "t1", title: "Chat", workspace: "/tmp", updatedAt: Date(),
                   items: kinds.map { ChatSession.Item(kind: $0) }, agent: "claude")
    }

    func testRunningStepsShowAsFailedAfterQuit() {
        let restored = thread([.user("hi"), .tool("Ran `npm test`", ok: nil), .tool("Read a.ts", ok: true)]).restoredAfterQuit()
        guard case .tool(_, let running) = restored.items[1].kind, case .tool(_, let finished) = restored.items[2].kind else {
            return XCTFail("tool items expected")
        }
        XCTAssertEqual(running, false)
        XCTAssertEqual(finished, true)
    }

    func testOtherItemsAndMetadataAreKept() {
        let original = thread([.user("hi"), .assistant("hello"), .tool("Edited b.ts", ok: false)])
        let restored = original.restoredAfterQuit()
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.agent, "claude")
        XCTAssertEqual(restored.items.map(\.id), original.items.map(\.id))
        guard case .assistant(let text) = restored.items[1].kind else { return XCTFail("assistant item expected") }
        XCTAssertEqual(text, "hello")
    }

    func testTaskLinkRoundTripsAndOldThreadsStillDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var linked = thread([.user("hi")])
        linked.task = "fix-login"
        XCTAssertEqual(try decoder.decode(ChatThread.self, from: encoder.encode(linked)).task, "fix-login")
        let old = #"{"id":"t1","title":"Chat","workspace":"/tmp","updatedAt":"2026-11-01T10:00:00Z","items":[],"agent":"claude"}"#
        XCTAssertNil(try decoder.decode(ChatThread.self, from: Data(old.utf8)).task)
    }

    // MARK: Transcript

    private func describe(_ items: [ChatSession.Item]) -> [String] {
        items.map {
            switch $0.kind {
            case .assistant(let text): "a:\(text)"
            case .tool(let summary, let ok): "t:\(summary):\(ok.map(String.init) ?? "nil")"
            default: "other"
            }
        }
    }

    func testTranscriptFoldsTextToolsAndSubagents() {
        var transcript = ChatTranscript()
        var items: [ChatSession.Item] = []
        XCTAssertEqual(transcript.apply(.assistant("Hel"), to: &items, running: true).activity, "Writing")
        _ = transcript.apply(.assistant("lo"), to: &items, running: true)
        XCTAssertEqual(transcript.apply(.toolStarted(id: "1", summary: "Ran `npm test`"), to: &items, running: true).activity,
                       "Running `npm test`")
        _ = transcript.apply(.subagentTool(parent: "1", id: "s1", summary: "Read a.ts", ok: nil), to: &items, running: true)
        _ = transcript.apply(.subagentTool(parent: "1", id: "s1", summary: "Read a.ts", ok: true), to: &items, running: true)
        XCTAssertEqual(transcript.apply(.toolFinished(id: "1", ok: true), to: &items, running: true), .init(activity: "Thinking"))
        XCTAssertEqual(describe(items), ["a:Hello", "t:Ran `npm test` · 1 tool call:true"])
    }

    func testTranscriptOutsideATurnOpensANewReplyAndAsksToSave() {
        var transcript = ChatTranscript()
        var items = [ChatSession.Item(kind: .assistant("Done"))]
        XCTAssertEqual(transcript.apply(.assistant("Late"), to: &items, running: false), .init())
        _ = transcript.apply(.assistant(" result"), to: &items, running: false)
        _ = transcript.apply(.toolStarted(id: "2", summary: "Edited a.ts"), to: &items, running: false)
        XCTAssertEqual(transcript.apply(.toolFinished(id: "2", ok: false), to: &items, running: false), .init(save: true))
        XCTAssertEqual(describe(items), ["a:Done", "a:Late result", "t:Edited a.ts:false"])
    }
}
