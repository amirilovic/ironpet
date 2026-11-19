import XCTest
@testable import IronPet

/// Drives the shared chat only through `IronPetAPI`: Codable requests, Codable answers and bus events. The agent is a scripted
/// `turnRunner`; the helper receives the engine only so the test can set that runner, the way it would set a fake agent process.
@MainActor
final class ChatAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var session: ChatSession!
    private var api: IronPetAPI!
    private var turns: [ACPTurn] = []
    private var deliver: [(AgentEvent) -> Void] = []
    private var heard: [(ChatOrigin, ChatTurnEvent)] = []
    private var previousThreads: URL!
    private var threads: URL!

    override func setUp() async throws {
        TestMemory.isolate()
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        session = ChatSession(restore: false)
        session.workspace = FileManager.default.temporaryDirectory
        turns = []
        deliver = []
        heard = []
        session.turnRunner = { [unowned self] turn, onEvent in
            turns.append(turn)
            deliver.append(onEvent)
        }
        api = APITestSupport.makeAPI(events: events, chat: session)
        api.chat.onTurn { [unowned self] origin, event in heard.append((origin, event)) }
        previousThreads = ThreadStore.directory
        threads = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-api-threads-\(UUID().uuidString)")
        ThreadStore.directory = threads
    }

    override func tearDown() async throws {
        ThreadStore.directory = previousThreads
        try? FileManager.default.removeItem(at: threads)
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private let phone = ChatOrigin(client: "ios", ref: "device-1")

    private func send(_ text: String, from origin: ChatOrigin? = nil, files: [URL] = []) async throws -> ChatSendResult {
        try await api.chat.send(SendChatRequest(text: text, origin: origin, files: files))
    }

    func testASentMessageRunsATurnAndTheSenderHearsTheAnswer() async throws {
        let result = try await send("  What changed today?  ", from: phone)
        XCTAssertEqual(result.outcome, .sent)
        await settle()
        XCTAssertEqual(turns.map(\.prompt), ["What changed today?"])
        var status = await api.chat.status()
        XCTAssertTrue(status.running)
        deliver[0](.assistant("Two files."))
        deliver[0](.finished(error: nil))
        await settle()
        status = await api.chat.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.state, "done")
        XCTAssertEqual(heard.map(\.0), [phone, phone])
        XCTAssertEqual(heard.last?.1, .finished("Two files."))
        let messages = await api.chat.messages()
        XCTAssertEqual(messages.first?.origin, "ios", "the transcript marks where the message came from")
        XCTAssertEqual(status.title, "What changed today?")
    }

    func testAMacMessageNeedsAFolderAndSaysSo() async throws {
        session.workspace = nil
        session.prepareForShow()
        let result = try await send("hello")
        XCTAssertEqual(result.outcome, .needsFolder)
        let options = await api.chat.options()
        XCTAssertTrue(options.needsFolder)
        try await api.chat.useFolder(FileManager.default.temporaryDirectory.path)
        let after = try await send("hello")
        XCTAssertEqual(after.outcome, .sent)
        let empty = try await send("   ")
        XCTAssertEqual(empty.outcome, .ignored)
    }

    func testEventIdsNameTheMessageThatChanged() async throws {
        _ = try await send("hello", from: phone)
        await settle()
        let user = try XCTUnwrap(session.items.first)
        XCTAssertTrue(seen.contains { $0.kind == .chatItem && $0.id == user.id.uuidString })
        seen = []
        deliver[0](.assistant("Hi"))
        let reply = try XCTUnwrap(session.items.last)
        XCTAssertEqual(seen.filter { $0.kind == .chatItem }.map(\.id), [reply.id.uuidString], "a new reply is announced by its own id")
        seen = []
        deliver[0](.assistant(" there"))
        XCTAssertEqual(seen.filter { $0.kind == .chatItem }.map(\.id), [reply.id.uuidString], "streamed text names the reply it extends, not the last message")
        let message = try await api.chat.message(reply.id)
        if case .assistant(let text) = message.kind { XCTAssertEqual(text, "Hi there") } else { XCTFail("not a reply") }
    }

    func testAnEditToAnEarlierMessageNamesThatMessage() async throws {
        _ = try await send("run it", from: phone)
        await settle()
        deliver[0](.toolStarted(id: "t1", summary: "Reading"))
        deliver[0](.assistant("Working on it."))
        let tool = try XCTUnwrap(session.items.first { if case .tool = $0.kind { return true } else { return false } })
        seen = []
        deliver[0](.toolFinished(id: "t1", ok: true))
        XCTAssertEqual(seen.filter { $0.kind == .chatItem }.map(\.id), [tool.id.uuidString], "the finished tool is named, though a reply comes after it")
    }

    func testAResetOrRemovalAsksClientsToReadEverythingAgain() async throws {
        _ = try await send("hello", from: phone)
        await settle()
        seen = []
        await api.chat.newChat()
        XCTAssertTrue(seen.contains { $0.kind == .chatItem && $0.id == nil })
        let messages = await api.chat.messages()
        XCTAssertTrue(messages.isEmpty)
    }

    func testStreamingDoesNotPushOtherEventsOutOfTheReplayBuffer() async throws {
        let bus = APIEventBus(capacity: 20)
        let streaming = APITestSupport.makeAPI(events: bus, chat: session)
        _ = streaming
        _ = try await send("hello", from: phone)
        await settle()
        bus.publish(.tasksChanged, id: "keep-me")
        let before = bus.lastSeq
        for _ in 0..<500 { deliver[0](.assistant("word ")) }
        XCTAssertGreaterThan(bus.lastSeq - before, 400, "every delta still reaches live subscribers")
        let replay = bus.replay(after: before - 1)
        XCTAssertTrue(replay.events.contains { $0.kind == .tasksChanged && $0.id == "keep-me" }, "the buffer still holds the earlier event")
        XCTAssertLessThanOrEqual(replay.events.filter { $0.kind == .chatItem }.count, 2, "one buffered event per streamed message")
        XCTAssertFalse(replay.gap)
    }

    func testABusyAgentQueuesTheNextMessageAndCancelDropsIt() async throws {
        _ = try await send("first", from: phone)
        let second = try await send("second", from: phone)
        XCTAssertEqual(second.outcome, .queued)
        await settle()
        var status = await api.chat.status()
        XCTAssertEqual(status.queued, 1)
        XCTAssertTrue(heard.contains { $0.1 == .queued })
        let queue = await api.chat.queue()
        XCTAssertEqual(queue.map(\.text), ["second"])
        XCTAssertFalse(queue[0].fromMac)
        await api.chat.cancel(from: phone)
        status = await api.chat.status()
        XCTAssertEqual(status.queued, 0)
    }

    func testStopGivesQueuedMacMessagesBackAsADraft() async throws {
        _ = try await send("first")
        await settle()
        let queued = try await send("second", files: [URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertEqual(queued.outcome, .queued)
        let result = await api.chat.stop()
        XCTAssertEqual(result.restored?.text, "second")
        XCTAssertEqual(result.restored?.files, [URL(fileURLWithPath: "/tmp/a.png")])
        let again = await api.chat.takeRestoredDraft()
        XCTAssertNil(again, "a draft is handed back once")
    }

    func testApprovalsAreListedAndDecidedThroughTheAPI() async throws {
        _ = try await send("delete the build folder", from: phone)
        await settle()
        var decision: ApprovalDecision?
        session.handlePermission(ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])) { decision = $0 }
        let approvals = await api.chat.approvals()
        let pending = try XCTUnwrap(approvals.first)
        XCTAssertTrue(heard.contains { if case .approval(let id, _, _) = $0.1 { return id == pending.id } else { return false } })
        try await api.chat.decide(DecideApprovalRequest(id: pending.id, allow: false))
        XCTAssertEqual(decision?.allow, false)
        let left = await api.chat.approvals()
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(heard.contains { $0.1 == .approvalDecided(id: pending.id, outcome: .denied) })
        do { try await api.chat.decide(DecideApprovalRequest(id: pending.id, allow: true)); XCTFail("decided twice") } catch {
            XCTAssertEqual((error as? APIError)?.code, .notFound)
        }
    }

    func testAQuestionIsAnsweredThroughTheAPI() async throws {
        _ = try await send("ask me", from: phone)
        await settle()
        let form = ElicitationForm(message: "Which one?", fields: [
            ElicitationField(id: "pick", title: "Pick", detail: "", required: true, kind: .single([ElicitationOption(value: "a", title: "A", detail: "")]))])
        var reply: ElicitationReply?
        session.handleElicitation(form) { reply = $0 }
        let forms = await api.chat.forms()
        let shown = try XCTUnwrap(forms.first)
        XCTAssertEqual(shown.form.message, "Which one?")
        do { try await api.chat.submitForm(shown.id); XCTFail("submitted without the required answer") } catch {
            XCTAssertEqual((error as? APIError)?.code, .invalid)
        }
        try await api.chat.answerForm(AnswerFormRequest(id: shown.id, field: "pick", value: .one("a")))
        try await api.chat.submitForm(shown.id)
        XCTAssertEqual(reply, .accept(["pick": "a"]))
        let left = await api.chat.forms()
        XCTAssertTrue(left.isEmpty)
    }

    func testStopEndsTheTurnAndTellsTheSender() async throws {
        _ = try await send("long job", from: phone)
        await settle()
        _ = await api.chat.stop()
        let status = await api.chat.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(heard.last?.1, .failed("Stopped on the Mac."))
    }

    func testAnEmptyMessageFromAnotherClientIsRejected() async {
        do { _ = try await send("   ", from: phone); XCTFail("sent nothing") } catch { XCTAssertEqual((error as? APIError)?.code, .invalid) }
    }

    func testUploadsAreSavedByNameOnlyAndHandedToTheAgent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-uploads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatAPI(session: session, uploads: dir)
        _ = try await chat.send(SendChatRequest(text: "see file", origin: phone, uploads: [ChatUpload(fileName: "../../evil.txt", data: Data("hi".utf8))]))
        await settle()
        let saved = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasSuffix("-evil.txt"), "the sender's path is dropped: \(saved[0])")
        XCTAssertEqual(turns.first?.files.count, 1)
    }

    func testThreadsListOpenAndNewChat() async throws {
        _ = try await send("remember the milk", from: phone)
        await settle()
        deliver[0](.session("thread-1"))
        deliver[0](.assistant("Noted."))
        deliver[0](.finished(error: nil))
        await settle()
        let all = await api.chat.threads()
        let saved = try XCTUnwrap(all.first)
        XCTAssertEqual(saved.title, "remember the milk")
        await api.chat.newChat()
        var status = await api.chat.status()
        XCTAssertEqual(status.title, "New chat")
        try await api.chat.openThread(saved.id)
        status = await api.chat.status()
        XCTAssertEqual(status.title, "remember the milk")
        do { try await api.chat.openThread("nope"); XCTFail("opened a missing thread") } catch { XCTAssertEqual((error as? APIError)?.code, .notFound) }
    }

    func testOptionsCarryTheAgentFolderAndModelsAndAreChangedByCalls() async throws {
        var options = await api.chat.options()
        XCTAssertFalse(options.agent.id.isEmpty)
        XCTAssertEqual(options.folder, FileManager.default.temporaryDirectory.path)
        await api.chat.setModel("fast")
        await api.chat.setAutoMode(true)
        options = await api.chat.options()
        XCTAssertEqual(options.model, "fast")
        XCTAssertTrue(options.autoMode)
        XCTAssertTrue(seen.contains { $0.kind == .chatState && $0.id == "options" })
        do { try await api.chat.setAgent("no-such-agent"); XCTFail("picked a missing agent") } catch { XCTAssertEqual((error as? APIError)?.code, .notFound) }
        do { try await api.chat.useFolder("/definitely/not/here"); XCTFail("picked a missing folder") } catch { XCTAssertEqual((error as? APIError)?.code, .invalid) }
    }

    func testEverythingARemoteClientReadsRoundTripsAsJSON() async throws {
        _ = try await send("hi", from: phone)
        await settle()
        deliver[0](.assistant("Hello"))
        let snapshot = api.chat.snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(ChatSnapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(back.messages.map(\.id), snapshot.messages.map(\.id))
        XCTAssertEqual(back.options, snapshot.options)
        XCTAssertEqual(back.status.title, "hi")
        let request = SendChatRequest(text: "hi", origin: phone, files: [URL(fileURLWithPath: "/tmp/a.png")], uploads: [ChatUpload(fileName: "a", data: Data([1]))])
        XCTAssertEqual(try decoder.decode(SendChatRequest.self, from: encoder.encode(request)), request)
    }
}
