import XCTest
@testable import IronPet

/// A Bot API stand-in that records what the bridge sends and returns scripted updates.
final class FakeTelegram: TelegramClient, @unchecked Sendable {
    struct Sent: Equatable {
        let chat: Int64
        let text: String
        let html: Bool
        var buttons: [TelegramButton] = []
    }

    struct Edit: Equatable {
        let chat: Int64
        let messageID: Int64
        let text: String
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var _typing = 0
    private var _calls: [String] = []
    private var _edits: [Edit] = []
    private var _answers: [String] = []
    private var _nextID: Int64 = 500
    /// file_id to (path, bytes). A file whose bytes are missing answers getFile with `fileSize` only.
    var files: [String: (path: String, data: Data)] = [:]
    var reportedSizes: [String: Int] = [:]
    /// Called for each getUpdates; the default blocks until cancelled, like a long poll with nothing new.
    var updates: @Sendable (Int) async throws -> [TelegramUpdate] = { _ in
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return []
    }
    var me: @Sendable () async throws -> TelegramUser = { TelegramUser(id: 1, isBot: true, firstName: "Ghost bot", lastName: nil, username: "ghost_bot") }
    var sendFailure: @Sendable (Sent) -> TelegramError? = { _ in nil }

    var sent: [Sent] { lock.withLock { _sent } }
    var typing: Int { lock.withLock { _typing } }
    var calls: [String] { lock.withLock { _calls } }
    var edits: [Edit] { lock.withLock { _edits } }
    var answers: [String] { lock.withLock { _answers } }

    func getMe() async throws -> TelegramUser {
        lock.withLock { _calls.append("getMe") }
        return try await me()
    }

    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] {
        lock.withLock { _calls.append("getUpdates(\(offset))") }
        return try await updates(offset)
    }

    func sendMessage(chat: Int64, text: String, html: Bool, buttons: [TelegramButton]) async throws -> Int64 {
        let message = Sent(chat: chat, text: text, html: html, buttons: buttons)
        if let failure = sendFailure(message) { throw failure }
        return lock.withLock {
            _sent.append(message)
            _nextID += 1
            return _nextID
        }
    }

    func editMessage(chat: Int64, messageID: Int64, text: String) async throws {
        lock.withLock { _edits.append(Edit(chat: chat, messageID: messageID, text: text)) }
    }

    func answerCallback(id: String, text: String?, alert: Bool) async throws {
        lock.withLock { _answers.append(text ?? "") }
    }

    func getFile(id: String) async throws -> TelegramFilePath {
        lock.withLock { _calls.append("getFile(\(id))") }
        if let size = reportedSizes[id] { return TelegramFilePath(filePath: "big/\(id)", fileSize: size) }
        guard let file = files[id] else { throw TelegramError.api(code: 400, description: "Bad Request: wrong file_id") }
        return TelegramFilePath(filePath: file.path, fileSize: file.data.count)
    }

    func download(path: String) async throws -> Data {
        guard let file = files.values.first(where: { $0.path == path }) else { throw TelegramError.api(code: 404, description: "Not Found") }
        return file.data
    }

    func sendChatAction(chat: Int64) async throws {
        lock.withLock { _typing += 1 }
    }
}

/// Transport that answers from a closure.
struct StubTransport: TelegramTransport {
    let respond: @Sendable (URLRequest) -> (String, Int)
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (body, status) = respond(request)
        return (Data(body.utf8), status)
    }
}

final class UserStore: @unchecked Sendable {
    var users: [Config.Telegram.User] = []
    var offset = 0
}

func telegramMessage(_ text: String?, from id: Int64, name: String = "Ann", username: String? = "ann", chat: Int64? = nil,
                     type: String = "private", isBot: Bool = false, update: Int = 1) -> TelegramUpdate {
    TelegramUpdate(updateId: update, message: TelegramMessage(
        messageId: 1, from: TelegramUser(id: id, isBot: isBot, firstName: name, lastName: nil, username: username),
        chat: .init(id: chat ?? id, type: type), text: text))
}

@MainActor
final class TelegramTests: XCTestCase {
    private var client: FakeTelegram!
    private var session: ChatSession!
    private var bridge: TelegramBridge!
    private var store: UserStore!
    private var tokens: MemoryTokenStore!
    private var runs: [String] = []
    private var turns: [ACPTurn] = []
    private var filesDirectory: URL!
    private var voiceOn = true
    private var transcribeStub: @Sendable (Data, String) async throws -> String = { _, _ in "transcript" }

    override func setUp() async throws {
        TestMemory.isolate()
        client = FakeTelegram()
        session = ChatSession(restore: false)
        store = UserStore()
        tokens = MemoryTokenStore()
        runs = []
        turns = []
        voiceOn = true
        filesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tg-files-\(UUID().uuidString)")
        session.use(URL(fileURLWithPath: "/tmp/telegram-test-project"))
        bridge = makeBridge()
    }

    private func makeBridge(sleep: @escaping (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }) -> TelegramBridge {
        let store = store!
        return TelegramBridge(
            client: client, host: session, tokens: tokens,
            storage: .init(users: { store.users }, add: { store.users.append($0) },
                           remove: { id in store.users.removeAll { $0.id == id } },
                           offset: { store.offset }, setOffset: { store.offset = $0 }),
            filesDirectory: filesDirectory, voiceEnabled: { [unowned self] in voiceOn },
            transcribe: { [unowned self] data, name in try await transcribeStub(data, name) },
            sleep: sleep)
    }

    private func allow(_ id: Int64) {
        store.users.append(.init(id: id, name: "Ann", username: "ann"))
    }

    /// An agent that answers with `text` once told to continue.
    private func answering(_ text: String) {
        session.turnRunner = { turn, emit in
            await MainActor.run {
                self.turns.append(turn)
                self.runs.append(turn.prompt)
                emit(.assistant(text))
                emit(.finished(error: nil))
            }
        }
    }

    // MARK: S1

    func testGetMeParsesTheBotAndTokenStaysOutOfConfig() async throws {
        let api = TelegramAPI(token: { "123:SECRET" }, transport: StubTransport { request in
            XCTAssertEqual(request.url?.path, "/bot123:SECRET/getMe")
            return (#"{"ok":true,"result":{"id":7,"is_bot":true,"first_name":"Ghost","username":"ghost_bot"}}"#, 200)
        }, baseURL: "https://example.test")
        let bot = try await api.getMe()
        XCTAssertEqual(bot.username, "ghost_bot")

        XCTAssertTrue(bridge.saveToken("  123:SECRET \n"))
        XCTAssertEqual(tokens.load(), "123:SECRET")
        XCTAssertTrue(bridge.hasToken)
        var config = Config()
        config.telegram.enabled = true
        config.telegram.allowedUsers = [.init(id: 5, name: "Ann", username: nil)]
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertTrue(json.contains("\"telegram\""))
    }

    func testTestButtonShowsUsername() async {
        tokens.save("abc")
        let result = await bridge.test()
        XCTAssertEqual(try? result.get(), "@ghost_bot")
    }

    func testInvalidTokenAndConflictHaveReadableErrors() async {
        let api = TelegramAPI(token: { "bad" }, transport: StubTransport { _ in
            (#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#, 401)
        }, baseURL: "https://example.test")
        do {
            _ = try await api.getMe()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TelegramError, .api(code: 401, description: "Unauthorized"))
            XCTAssertEqual(error.localizedDescription, "Telegram rejected the bot token.")
            XCTAssertFalse(error.localizedDescription.contains("bad"))
        }
        XCTAssertTrue(TelegramError.api(code: 409, description: "x").localizedDescription.contains("409"))
        let missing = TelegramAPI(token: { nil }, transport: StubTransport { _ in ("", 0) }, baseURL: "https://example.test")
        do { _ = try await missing.getMe() } catch { XCTAssertEqual(error as? TelegramError, .noToken) }
    }

    // MARK: S2

    func testPairingAllowsFirstStartAndIgnoresLaterStrangers() async {
        var requests: [Int64] = []
        var resolved: [Int64] = []
        bridge.onPairingRequest = { requests.append($0.id) }
        bridge.onPairingResolved = { resolved.append($0) }
        bridge.handle(telegramMessage("hello", from: 10)) // not /start: ignored
        XCTAssertTrue(bridge.pending.isEmpty)
        bridge.handle(telegramMessage("/start", from: 10))
        bridge.handle(telegramMessage("/start", from: 10)) // repeat does not add a second bubble
        XCTAssertEqual(requests, [10])
        XCTAssertEqual(bridge.pending.map(\.id), [10])
        bridge.allow(10)
        XCTAssertEqual(store.users.map(\.id), [10])
        XCTAssertEqual(resolved, [10])
        XCTAssertTrue(bridge.pending.isEmpty)

        bridge.handle(telegramMessage("/start", from: 11, name: "Bob"))
        XCTAssertEqual(requests, [10])
        XCTAssertTrue(bridge.pending.isEmpty)
        await bridge.flush()
        XCTAssertEqual(client.sent.filter { $0.chat == 11 }, [])
    }

    func testDeniedUserCannotAskAgain() {
        var requests = 0
        bridge.onPairingRequest = { _ in requests += 1 }
        bridge.handle(telegramMessage("/start", from: 10))
        bridge.deny(10)
        bridge.handle(telegramMessage("/start", from: 10))
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(store.users.isEmpty)
    }

    func testPendingRequestsAreCapped() {
        for id in 1...10 { bridge.handle(telegramMessage("/start", from: Int64(id))) }
        XCTAssertEqual(bridge.pending.count, TelegramBridge.maxPending)
    }

    // MARK: S3, S4, S7

    func testAllowedMessageReachesTheOpenChatAndTheAnswerGoesBack() async {
        allow(10)
        answering("Hi **there**")
        let folder = session.workspace
        bridge.handle(telegramMessage("hello", from: 10))
        for _ in 0..<50 where session.state != .done { try? await Task.sleep(nanoseconds: 20_000_000) }
        await bridge.flush()
        XCTAssertEqual(runs, ["hello"])
        XCTAssertEqual(session.workspace, folder)
        XCTAssertNil(session.sessionID)
        guard case .user("hello") = session.items.first?.kind else { return XCTFail("no user item") }
        XCTAssertEqual(session.items.first?.origin, ChatSession.telegramOrigin)
        XCTAssertEqual(client.sent, [.init(chat: 10, text: "Hi <b>there</b>", html: true)])
        XCTAssertGreaterThanOrEqual(client.typing, 0)
    }

    func testTelegramReplyGivesTheAgentTheOriginalText() async {
        allow(10)
        answering("ok")
        var update = telegramMessage("what about this?", from: 10)
        update.message?.replyToMessage = .init(from: TelegramUser(id: 1, isBot: true, firstName: "Ghost", lastName: nil, username: nil),
                                               text: "the earlier answer")
        bridge.handle(update)
        for _ in 0..<50 where session.state != .done { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].contains("> the earlier answer"), runs[0])
        XCTAssertTrue(runs[0].hasSuffix("\n\nwhat about this?"), runs[0])
    }

    func testMacTurnsAreNotMirroredAndTelegramMessageWaitsForABusyAgent() async {
        allow(10)
        var release: CheckedContinuation<Void, Never>?
        session.turnRunner = { turn, emit in
            if turn.prompt == "from the mac" { await withCheckedContinuation { release = $0 } }
            await MainActor.run {
                self.runs.append(turn.prompt)
                emit(.assistant("answer to \(turn.prompt)"))
                emit(.finished(error: nil))
            }
        }
        session.input = "from the mac"
        session.send()
        XCTAssertTrue(session.isRunning)
        bridge.handle(telegramMessage("from telegram", from: 10))
        XCTAssertEqual(session.telegramQueueCount, 1)
        XCTAssertEqual(runs, [])
        for _ in 0..<50 where release == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        release?.resume()
        for _ in 0..<100 where runs.count < 2 || session.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        await bridge.flush()
        XCTAssertEqual(runs, ["from the mac", "from telegram"])
        let texts = client.sent.map(\.text)
        XCTAssertTrue(texts.contains { $0.contains("queued") })
        XCTAssertTrue(texts.contains("answer to from telegram"))
        XCTAssertFalse(texts.contains("answer to from the mac"))
    }

    func testTelegramMessageWhileBusyNeverClearsTheChatOrAuto() async {
        allow(10)
        var log: [String] = []
        ChatLog.sink = { log.append($0) }
        defer { ChatLog.sink = nil }
        var release: CheckedContinuation<Void, Never>?
        session.turnRunner = { turn, emit in
            await MainActor.run { emit(.session("thread-1")) }
            if turn.prompt == "busy" { await withCheckedContinuation { release = $0 } }
            await MainActor.run { emit(.finished(error: nil)) }
        }
        session.autoMode = true
        session.input = "busy"
        session.send()
        for _ in 0..<50 where release == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        session.isVisible = false
        let before = session.items.map(\.id)
        bridge.handle(telegramMessage("while busy", from: 10))
        bridge.handle(telegramMessage("/status", from: 10, update: 2))
        XCTAssertEqual(session.telegramQueueCount, 1)
        XCTAssertEqual(session.items.map(\.id), before)
        session.cancelTelegram(chat: 10)
        XCTAssertEqual(session.items.map(\.id), before)
        XCTAssertEqual(session.threadID, "thread-1")
        XCTAssertTrue(session.autoMode)
        XCTAssertFalse(log.contains { $0.hasPrefix("chat cleared") || $0.hasPrefix("thread ") })
        release?.resume()
    }

    func testStrangerNeverReachesTheChat() async {
        answering("should not run")
        bridge.handle(telegramMessage("run rm -rf", from: 99))
        bridge.handle(telegramMessage("/start", from: 99))
        bridge.handle(telegramMessage("again", from: 99))
        allow(10)
        bridge.handle(telegramMessage("group text", from: 10, chat: -100, type: "group"))
        bridge.handle(telegramMessage("bot text", from: 10, isBot: true))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runs, [])
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertEqual(session.telegramQueueCount, 0)
    }

    func testStatusCommandReportsBusyOrIdle() async {
        allow(10)
        bridge.handle(telegramMessage("/status", from: 10))
        await bridge.flush()
        XCTAssertTrue(client.sent.last?.text.contains("idle") == true)
        XCTAssertTrue(client.sent.last?.text.contains("New chat") == true)
        XCTAssertTrue(session.items.isEmpty)
    }

    func testApprovalAndFailureAreReported() async {
        allow(10)
        session.turnRunner = { _, emit in
            await MainActor.run {
                self.session.handlePermission(ACPToolCall(id: "t", title: "Run ls", kind: "execute", rawInput: ["command": "ls"])) { _ in }
                emit(.finished(error: "boom"))
            }
        }
        bridge.handle(telegramMessage("go", from: 10))
        for _ in 0..<50 where session.state != .failed { try? await Task.sleep(nanoseconds: 20_000_000) }
        await bridge.flush()
        let texts = client.sent.map(\.text)
        XCTAssertFalse(texts.contains("Waiting for approval on the Mac."))
        XCTAssertTrue(client.sent.contains { $0.text.contains("wants to:") && $0.buttons.count == 2 })
        XCTAssertTrue(texts.contains { $0.contains("boom") })
    }

    // MARK: S6

    func testPollingBacksOffAndShowsTheError() async {
        let sleeps = SleepLog()
        client.me = { throw TelegramError.api(code: 401, description: "Unauthorized") }
        let fixed = Date(timeIntervalSince1970: 1_000)
        let bridge = TelegramBridge(
            client: client, host: session, tokens: tokens,
            storage: .init(users: { [] }, add: { _ in }, remove: { _ in }, offset: { 0 }, setOffset: { _ in }),
            sleep: { try await sleeps.sleep($0) }, now: { fixed })
        bridge.start()
        for _ in 0..<100 where await sleeps.values.count < 4 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let values = await sleeps.values
        XCTAssertEqual(Array(values.prefix(4)), [2, 4, 8, 16])
        XCTAssertEqual(bridge.status, .error("Telegram rejected the bot token.", fixed))
        XCTAssertTrue(bridge.pending.isEmpty)
        XCTAssertEqual(client.sent, [])
        bridge.stop()
        XCTAssertEqual(bridge.status, .off)
    }

    func testHeaderStatusIsConnectedFailedOrOff() {
        let when = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TelegramIntegration.status(.off, enabled: false, hasToken: true).label, "Off")
        XCTAssertNil(TelegramIntegration.status(.off, enabled: false, hasToken: true).detail)
        XCTAssertEqual(TelegramIntegration.status(.polling(bot: "@b"), enabled: true, hasToken: true).label, "Connected")
        let failed = TelegramIntegration.status(.error("Telegram rejected the bot token.", when), enabled: true, hasToken: true)
        XCTAssertEqual(failed.label, "Failed")
        XCTAssertTrue(failed.detail?.contains("Telegram rejected the bot token.") == true)
        let noToken = TelegramIntegration.status(.off, enabled: true, hasToken: false)
        XCTAssertEqual(noToken.label, "Failed")
        XCTAssertTrue(noToken.detail?.contains("No bot token") == true)
    }

    func testBackoffCapsAtFiveMinutes() {
        XCTAssertEqual(TelegramBridge.backoff(failures: 1), 2)
        XCTAssertEqual(TelegramBridge.backoff(failures: 20), 300)
    }

    func testPollingSkipsOldBacklogAndPersistsTheOffset() async {
        allow(10)
        answering("ok")
        let script = Script()
        client.updates = { offset in
            let step = await script.next()
            switch step {
            case 0: return [telegramMessage("old message", from: 10, update: 41)] // answer to offset -1
            case 1:
                XCTAssertEqual(offset, 42)
                return [telegramMessage("new message", from: 10, update: 42)]
            default:
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        }
        bridge.start()
        for _ in 0..<100 where runs.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        bridge.stop()
        XCTAssertEqual(runs, ["new message"])
        XCTAssertEqual(store.offset, 43)
    }

    func testTypingIsSentWhileTheTurnRuns() async {
        allow(10)
        let ticks = SleepLog()
        let bridge = makeBridge(sleep: { try await ticks.sleep($0) })
        var release: CheckedContinuation<Void, Never>?
        session.turnRunner = { _, emit in
            await withCheckedContinuation { release = $0 }
            await MainActor.run {
                emit(.assistant("done"))
                emit(.finished(error: nil))
            }
        }
        bridge.handle(telegramMessage("work", from: 10))
        for _ in 0..<100 where await ticks.values.count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(client.typing, 2)
        let firstTick = await ticks.values.first
        XCTAssertEqual(firstTick, TelegramBridge.typingInterval)
        for _ in 0..<50 where release == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        release?.resume()
        for _ in 0..<50 where session.state != .done { try? await Task.sleep(nanoseconds: 20_000_000) }
        let before = client.typing
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThanOrEqual(client.typing - before, 1)
        _ = bridge
    }

    func testHtmlRejectionFallsBackToPlainText() async {
        allow(10)
        client.sendFailure = { $0.html ? .api(code: 400, description: "can't parse entities") : nil }
        answering("hello")
        bridge.handle(telegramMessage("hi", from: 10))
        for _ in 0..<50 where session.state != .done { try? await Task.sleep(nanoseconds: 20_000_000) }
        await bridge.flush()
        XCTAssertEqual(client.sent, [.init(chat: 10, text: "hello", html: false)])
    }

    // MARK: S5

    func testLongMarkdownSplitsIntoValidMessages() {
        var markdown = "# Title\n\nSome **bold** text with `code` and a [link](https://example.com).\n\n```swift\n"
        for i in 0..<400 { markdown += "let value\(i) = \"a < b && c > d\" // line \(i)\n" }
        markdown += "```\n\nAfter the block: *italic* and more text.\n"
        for i in 0..<200 { markdown += "- item \(i) with **bold \(i)**\n" }
        let parts = TelegramFormat.parts(markdown)
        XCTAssertGreaterThan(parts.count, 2)
        for part in parts {
            XCTAssertLessThanOrEqual(part.html.count, TelegramFormat.limit)
            XCTAssertTrue(TelegramFormat.isBalanced(part.html), part.html.prefix(200).description)
            XCTAssertFalse(part.html.contains("```"))
        }
        // Code split across messages is reopened, so each half is a complete block.
        let codeParts = parts.filter { $0.html.contains("<pre>") }
        XCTAssertGreaterThan(codeParts.count, 1)
        XCTAssertEqual(parts.map(\.html).joined().components(separatedBy: "<pre>").count,
                       parts.map(\.html).joined().components(separatedBy: "</pre>").count)
        XCTAssertTrue(parts.map(\.html).joined().contains("a &lt; b &amp;&amp; c &gt; d"))
    }

    func testHandAddedUserEndsPairing() {
        bridge.handle(telegramMessage("/start", from: 1))
        bridge.handle(telegramMessage("/start", from: 2))
        bridge.addUser(id: 1)
        XCTAssertTrue(bridge.pending.isEmpty)
        bridge.allow(2)
        XCTAssertEqual(store.users.map(\.id), [1])
    }

    func testRemovedUserLosesQueuedMessagesAndAnswers() async {
        allow(10)
        session.turnRunner = { _, _ in await withCheckedContinuation { _ in } }
        session.input = "from the mac"
        session.send()
        bridge.handle(telegramMessage("queued", from: 10))
        XCTAssertEqual(session.telegramQueueCount, 1)
        bridge.removeUser(id: 10)
        XCTAssertEqual(session.telegramQueueCount, 0)
        XCTAssertTrue(store.users.isEmpty)
    }

    func testUnknownSlashTextIsAPrompt() async {
        allow(10)
        answering("ok")
        bridge.handle(telegramMessage("/review the last commit", from: 10))
        for _ in 0..<50 where session.state != .done { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(runs, ["/review the last commit"])
    }

    func testShortLongLineIsNotBroken() {
        let line = String(repeating: "word ", count: 300)
        XCTAssertEqual(TelegramFormat.parts(line).count, 1)
    }

    func testOneHugeLineIsSplit() {
        let parts = TelegramFormat.parts(String(repeating: "&", count: 20_000))
        XCTAssertGreaterThan(parts.count, 4)
        XCTAssertTrue(parts.allSatisfy { $0.html.count <= TelegramFormat.limit })
    }

    func testMarkdownConversion() {
        XCTAssertEqual(TelegramFormat.html("**a** and *b* and `c<d>`"), "<b>a</b> and <i>b</i> and <code>c&lt;d&gt;</code>")
        XCTAssertEqual(TelegramFormat.html("## Head"), "<b>Head</b>")
        XCTAssertEqual(TelegramFormat.html("- one\n  - two"), "• one\n  • two")
        XCTAssertEqual(TelegramFormat.html("[x](https://a.b/c?d=1&e=2)"), "<a href=\"https://a.b/c?d=1&amp;e=2\">x</a>")
        XCTAssertEqual(TelegramFormat.html("[x](javascript:alert(1))"), "[x](javascript:alert(1))")
        XCTAssertEqual(TelegramFormat.html("```py\nprint(1)\n```"), "<pre><code class=\"language-py\">print(1)</code></pre>")
        XCTAssertEqual(TelegramFormat.html("```\nunclosed"), "<pre><code>unclosed</code></pre>")
        // Crossed emphasis falls back to escaped text for that line instead of producing broken tags.
        XCTAssertTrue(TelegramFormat.isBalanced(TelegramFormat.html("**bold *it** x*")))
        XCTAssertEqual(TelegramFormat.html("a_b_c and 2*3*4"), "a_b_c and 2*3*4")
    }
}

actor SleepLog {
    private(set) var values: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws {
        values.append(seconds)
        // Yield so loops that sleep do not starve the test, but never block forever.
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

actor Script {
    private var step = -1
    func next() -> Int {
        step += 1
        return step
    }
}

@MainActor
final class TelegramAutoApprovalTests: XCTestCase {
    private func session(auto: Bool, telegram: Bool) -> ChatSession {
        let session = ChatSession(restore: false)
        session.use(URL(fileURLWithPath: "/tmp/telegram-test-project"))
        session.autoMode = auto
        session.turnRunner = { _, _ in }
        if telegram { session.submitFromTelegram("hi", chat: 5) } else { session.input = "hi"; session.send() }
        return session
    }

    private func decision(_ session: ChatSession, _ call: ACPToolCall) -> ApprovalDecision? {
        var result: ApprovalDecision?
        session.handlePermission(call) { result = $0 }
        return result
    }

    private let ps = ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": "ps -axo lstart,command"])
    private let rm = ACPToolCall(id: "2", title: "Run", kind: "execute", rawInput: ["command": "rm -rf build"])

    func testAutoAllowsSafeCommandOnTelegramTurn() {
        let s = session(auto: true, telegram: true)
        var events: [ChatSession.TelegramEvent] = []
        s.onTelegram = { _, e in events.append(e) }
        XCTAssertNotNil(decision(s, ps))
        XCTAssertTrue(s.approvals.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testAutoStillAsksForDestructiveCommandOnTelegramTurn() {
        let s = session(auto: true, telegram: true)
        var asked = false
        s.onTelegram = { _, e in if case .approval = e { asked = true } }
        XCTAssertNil(decision(s, rm))
        XCTAssertEqual(s.approvals.count, 1)
        XCTAssertTrue(asked)
    }

    func testAutoOffAsksOnTelegramTurn() {
        let s = session(auto: false, telegram: true)
        var asked = false
        s.onTelegram = { _, e in if case .approval = e { asked = true } }
        XCTAssertNil(decision(s, ps))
        XCTAssertEqual(s.approvals.count, 1)
        XCTAssertTrue(asked)
    }

    func testMacAndTelegramTurnsGetTheSamePolicy() {
        let calls = [
            ACPToolCall(id: "a", title: "Read", kind: "read"),
            ps, rm,
            ACPToolCall(id: "b", title: "Edit", kind: "edit", rawInput: ["file_path": "/work/app.swift", "new_string": "x"]),
            ACPToolCall(id: "c", title: "mcp__sentry__search_issues", kind: "other"),
            ACPToolCall(id: "d", title: "mcp__db__run_query", kind: "other", rawInput: ["sql": "DROP TABLE users"]),
        ]
        for call in calls {
            let mac = session(auto: true, telegram: false)
            let tg = session(auto: true, telegram: true)
            XCTAssertEqual(decision(mac, call) == nil, decision(tg, call) == nil, call.title)
        }
    }
}
