import XCTest
@testable import IronPet

private final class VoiceServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [(contentType: String, body: Data)] = []
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.requests.append((request.value(forHTTPHeaderField: "Content-Type") ?? "", body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((Self.status == 200 ? #"{"text":"turn the lights on"}"# : #"{"error":{"message":"no model"}}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class TelegramMediaTests: XCTestCase {
    private var client: FakeTelegram!
    private var session: ChatSession!
    private var bridge: TelegramBridge!
    private var directory: URL!
    private var turns: [ACPTurn] = []
    private var voiceOn = true
    private var transcribe: @Sendable (Data, String) async throws -> String = { _, _ in "turn the lights on" }
    private var users = UserStore()

    override func setUp() async throws {
        client = FakeTelegram()
        session = ChatSession(restore: false)
        session.use(URL(fileURLWithPath: "/tmp/telegram-media-project"))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tg-media-\(UUID().uuidString)")
        users = UserStore()
        users.users = [.init(id: 10, name: "Ann", username: "ann")]
        turns = []
        voiceOn = true
        transcribe = { _, _ in "turn the lights on" }
        let store = users
        bridge = TelegramBridge(
            client: client, host: session, tokens: MemoryTokenStore(),
            storage: .init(users: { store.users }, add: { store.users.append($0) },
                           remove: { id in store.users.removeAll { $0.id == id } },
                           offset: { 0 }, setOffset: { _ in }),
            filesDirectory: directory, voiceEnabled: { [unowned self] in voiceOn },
            transcribe: { [unowned self] data, name in try await transcribe(data, name) })
        session.turnRunner = { turn, emit in
            await MainActor.run {
                self.turns.append(turn)
                emit(.assistant("done"))
                emit(.finished(error: nil))
            }
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func message(from id: Int64 = 10, caption: String? = nil, photo: [TelegramAttachment]? = nil,
                         document: TelegramAttachment? = nil, voice: TelegramAttachment? = nil, group: String? = nil,
                         update: Int = 1) -> TelegramUpdate {
        TelegramUpdate(updateId: update, message: TelegramMessage(
            messageId: Int64(update), from: TelegramUser(id: id, isBot: false, firstName: "Ann", lastName: nil, username: "ann"),
            chat: .init(id: id, type: "private"), text: nil, caption: caption, photo: photo, document: document, voice: voice,
            mediaGroupId: group))
    }

    private func settle() async {
        await bridge.flush()
        for _ in 0..<50 where session.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        await bridge.flush()
    }

    // MARK: S9

    func testPhotoWithCaptionAndPdfAreAttachedToOneMessage() async throws {
        client.files["p-small"] = ("photos/file_1.jpg", Data([1]))
        client.files["p-big"] = ("photos/file_2.jpg", Data([0xFF, 0xD8, 0xFF, 2]))
        client.files["d1"] = ("documents/file_3.pdf", Data("%PDF-1.4".utf8))
        bridge.handle([
            message(caption: "what is in these?", photo: [.init(fileId: "p-small", fileSize: 1), .init(fileId: "p-big", fileSize: 4)],
                    group: "album", update: 1),
            message(document: .init(fileId: "d1", fileSize: 8, fileName: "report.pdf", mimeType: "application/pdf"), group: "album", update: 2),
        ])
        await settle()
        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.prompt, "what is in these?")
        XCTAssertEqual(turn.images.map(\.lastPathComponent), ["photo.jpg"])
        XCTAssertEqual(turn.files.map(\.lastPathComponent), ["report.pdf"])
        for file in turn.images + turn.files {
            XCTAssertTrue(file.path.hasPrefix(directory.appendingPathComponent("10").path), file.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertEqual(try Data(contentsOf: turn.images[0]), Data([0xFF, 0xD8, 0xFF, 2]))
        let attached = session.items.compactMap { item -> String? in
            if case .screenshot(let path) = item.kind, item.origin == ChatSession.telegramOrigin { return path }
            return nil
        }
        XCTAssertEqual(Set(attached), Set((turn.images + turn.files).map(\.path)))
        guard case .user("what is in these?") = session.items.last(where: { if case .user = $0.kind { return true } else { return false } })?.kind else {
            return XCTFail("caption is not the message text")
        }
        XCTAssertTrue(session.attachments.isEmpty, "the Mac draft must stay untouched")
    }

    func testSeparatePhotoMessagesStayTwoMessages() async {
        client.files["a"] = ("photos/a.jpg", Data([1]))
        client.files["b"] = ("photos/b.jpg", Data([2]))
        bridge.handle(message(photo: [.init(fileId: "a", fileSize: 1)], update: 1))
        bridge.handle(message(photo: [.init(fileId: "b", fileSize: 1)], update: 2))
        for _ in 0..<100 where turns.count < 2 { try? await Task.sleep(nanoseconds: 30_000_000) }
        await settle()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.first?.prompt, "Help me with the attached file.")
    }

    func testFileNamesCannotEscapeTheFolder() throws {
        let url = try TelegramMediaStore.save(Data([1]), name: "../../evil.sh", chat: 10, root: directory)
        XCTAssertEqual(url.lastPathComponent, "evil.sh")
        XCTAssertTrue(url.path.hasPrefix(directory.path))
        XCTAssertEqual(TelegramMediaStore.safeName(".."), "file")
    }

    // MARK: S10

    func testFilesOverTwentyMegabytesGetASizeReplyAndNothingReachesGhost() async {
        let doc = TelegramAttachment(fileId: "big1", fileSize: 25 * 1_048_576, fileName: "huge.zip")
        bridge.handle(message(caption: "read this", document: doc))
        await settle()
        XCTAssertTrue(client.sent.last?.text.contains("20 MB") == true, client.sent.map(\.text).description)
        XCTAssertTrue(client.sent.last?.text.contains("huge.zip") == true)
        XCTAssertTrue(turns.isEmpty)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("getFile") }, "no download for a size already known to be too big")
    }

    func testSizeReportedOnlyByGetFileAlsoStops() async {
        client.reportedSizes["big2"] = 30 * 1_048_576
        bridge.handle(message(document: .init(fileId: "big2", fileSize: nil, fileName: "movie.mov")))
        await settle()
        XCTAssertTrue(client.sent.last?.text.contains("20 MB") == true)
        XCTAssertTrue(turns.isEmpty)
    }

    func testTelegramTooBigErrorBecomesASizeReply() async {
        // Telegram answers getFile with a 400 "file is too big" for anything over the limit.
        client.files = [:]
        let failing = FailingFile()
        let bridge = TelegramBridge(
            client: failing, host: session, tokens: MemoryTokenStore(),
            storage: .init(users: { [.init(id: 10, name: "Ann", username: nil)] }, add: { _ in }, remove: { _ in },
                           offset: { 0 }, setOffset: { _ in }),
            filesDirectory: directory, voiceEnabled: { true }, transcribe: { _, _ in "" })
        bridge.handle(message(document: .init(fileId: "x", fileSize: nil, fileName: "a.bin")))
        await bridge.flush()
        XCTAssertTrue(failing.sent.last?.contains("20 MB") == true)
        XCTAssertTrue(turns.isEmpty)
    }

    // MARK: S11

    func testVoiceMessageIsTranscribedEchoedAndSentAsText() async throws {
        client.files["v1"] = ("voice/file_0.oga", Data("OggS".utf8))
        let received = Received()
        transcribe = { data, name in
            await received.set(data, name)
            return "turn the lights on"
        }
        bridge.handle(message(voice: .init(fileId: "v1", fileSize: 4, mimeType: "audio/ogg")))
        await settle()
        let got = await received.value
        XCTAssertEqual(got?.0, Data("OggS".utf8))
        XCTAssertEqual(got?.1, "voice.ogg")
        XCTAssertEqual(client.sent.first?.text, "🎙 turn the lights on")
        XCTAssertEqual(turns.map(\.prompt), ["turn the lights on"])
        XCTAssertEqual(client.sent.map(\.text).last, "done")
    }

    func testVoiceOffRepliesAndSendsNothing() async {
        voiceOn = false
        client.files["v1"] = ("voice/file_0.oga", Data([1]))
        bridge.handle(message(voice: .init(fileId: "v1", fileSize: 1)))
        await settle()
        XCTAssertTrue(client.sent.last?.text.contains("Settings → Voice") == true)
        XCTAssertTrue(turns.isEmpty)
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("getFile") })
    }

    func testTranscriptionFailureRepliesAndSendsNothing() async {
        client.files["v1"] = ("voice/file_0.oga", Data([1]))
        transcribe = { _, _ in throw TranscriptionError.http(status: 500, detail: "model missing") }
        bridge.handle(message(voice: .init(fileId: "v1", fileSize: 1)))
        await settle()
        XCTAssertTrue(client.sent.last?.text.contains("model missing") == true, client.sent.map(\.text).description)
        XCTAssertTrue(turns.isEmpty)
        XCTAssertTrue(session.items.isEmpty)
    }

    func testSilentVoiceMessageSendsNothing() async {
        client.files["v1"] = ("voice/file_0.oga", Data([1]))
        transcribe = { _, _ in "" }
        bridge.handle(message(voice: .init(fileId: "v1", fileSize: 1)))
        await settle()
        XCTAssertTrue(client.sent.last?.text.contains("could not hear") == true)
        XCTAssertTrue(turns.isEmpty)
    }

    func testVoiceGoesToTheConfiguredServerAsOgg() async throws {
        VoiceServer.requests = []
        VoiceServer.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceServer.self]
        let transcriber = Transcriber(baseURL: "http://voice.test/v1", model: "m", apiKey: "k", session: URLSession(configuration: configuration))
        let text = try await TelegramVoice.transcribe(Data("OggS-not-decodable".utf8), name: "voice.oga", with: transcriber)
        XCTAssertEqual(text, "turn the lights on")
        let request = try XCTUnwrap(VoiceServer.requests.first)
        XCTAssertTrue(request.contentType.hasPrefix("multipart/form-data"))
        let body = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(body.contains("filename=\"voice.oga\""))
        XCTAssertTrue(body.contains("Content-Type: audio/ogg"))

        VoiceServer.status = 500
        do {
            _ = try await TelegramVoice.transcribe(Data("OggS".utf8), name: "voice.oga", with: transcriber)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testDecodableAudioIsConvertedToWav() throws {
        let samples = (0..<16_000).map { Int16(truncatingIfNeeded: Int(sin(Double($0) / 20) * 8000)) }
        let source = directory.appendingPathComponent("tone.wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try WAV.encode(samples).write(to: source)
        let wav = try XCTUnwrap(TelegramVoice.wav(from: source))
        XCTAssertEqual(WAV.duration(of: wav) ?? 0, 1, accuracy: 0.05)
        XCTAssertNil(TelegramVoice.wav(from: directory.appendingPathComponent("missing.ogg")))
    }

    // MARK: S12

    private final class Decisions: @unchecked Sendable {
        var values: [Bool] = []
    }

    private func awaitingApproval() -> Decisions {
        let decisions = Decisions()
        session.turnRunner = { turn, emit in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task { @MainActor in
                    self.session.handlePermission(ACPToolCall(id: "t", title: "Run ls", kind: "execute", rawInput: ["command": "ls -la"])) { decision in
                        decisions.values.append(decision.allow)
                        continuation.resume()
                    }
                }
            }
            await MainActor.run {
                emit(.assistant(decisions.values.last == true ? "ran it" : "skipped"))
                emit(.finished(error: nil))
            }
        }
        return decisions
    }

    private func callback(_ data: String, from id: Int64 = 10, chat: Int64? = nil) -> TelegramUpdate {
        TelegramUpdate(updateId: 9, message: nil, callbackQuery: TelegramCallback(
            id: "cb-\(UUID().uuidString.prefix(4))",
            from: TelegramUser(id: id, isBot: false, firstName: "X", lastName: nil, username: nil),
            message: TelegramMessage(messageId: 501, from: nil, chat: .init(id: chat ?? id, type: "private"), text: "x"), data: data))
    }

    private func startApprovalTurn() async -> (Decisions, UUID) {
        let decisions = awaitingApproval()
        bridge.handle(TelegramUpdate(updateId: 1, message: TelegramMessage(
            messageId: 1, from: TelegramUser(id: 10, isBot: false, firstName: "Ann", lastName: nil, username: nil),
            chat: .init(id: 10, type: "private"), text: "list files")))
        for _ in 0..<100 where session.approvals.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        await bridge.flush()
        return (decisions, session.approvals[0].id)
    }

    func testApproveFromTelegramRunsTheToolAndEditsTheMessage() async throws {
        let (decisions, id) = await startApprovalTurn()
        let sent = try XCTUnwrap(client.sent.first { !$0.buttons.isEmpty })
        XCTAssertEqual(sent.buttons.map(\.text), ["Approve", "Reject"])
        XCTAssertTrue(sent.text.contains(session.approvals[0].title) && sent.text.contains("ls -la"), sent.text)
        XCTAssertEqual(sent.buttons[0].data, "a:\(id.uuidString):1")
        bridge.handle(callback(sent.buttons[0].data))
        await settle()
        XCTAssertEqual(decisions.values, [true])
        XCTAssertEqual(client.answers, ["Approved."])
        let edit = try XCTUnwrap(client.edits.first)
        XCTAssertEqual(edit.chat, 10)
        XCTAssertEqual(edit.messageID, 501)
        XCTAssertTrue(edit.text.hasSuffix("✅ Approved from Telegram."), edit.text)
        XCTAssertTrue(session.approvals.isEmpty)
        XCTAssertEqual(client.sent.last?.text, "ran it")
    }

    func testRejectFromTelegramDeniesTheTool() async throws {
        let (decisions, _) = await startApprovalTurn()
        let sent = try XCTUnwrap(client.sent.first { !$0.buttons.isEmpty })
        bridge.handle(callback(sent.buttons[1].data))
        await settle()
        XCTAssertEqual(decisions.values, [false])
        XCTAssertEqual(client.answers, ["Rejected."])
        XCTAssertTrue(client.edits.first?.text.hasSuffix("❌ Rejected from Telegram.") == true)
        XCTAssertEqual(client.sent.last?.text, "skipped")
    }

    func testApprovingOnTheMacFirstEditsTelegramAndIgnoresLateTaps() async throws {
        let (decisions, id) = await startApprovalTurn()
        let sent = try XCTUnwrap(client.sent.first { !$0.buttons.isEmpty })
        session.decide(id: id, allow: true)
        await settle()
        XCTAssertEqual(decisions.values, [true])
        XCTAssertTrue(client.edits.first?.text.hasSuffix("Answered on the Mac: allowed.") == true, client.edits.description)
        bridge.handle(callback(sent.buttons[1].data))
        await settle()
        XCTAssertEqual(decisions.values, [true], "a late tap must not decide again")
        XCTAssertEqual(client.answers.last, "That button is no longer active.")
        XCTAssertEqual(client.edits.count, 1)
    }

    func testNonAllowedUserCannotPressTheButtons() async throws {
        let (decisions, _) = await startApprovalTurn()
        let sent = try XCTUnwrap(client.sent.first { !$0.buttons.isEmpty })
        bridge.handle(callback(sent.buttons[0].data, from: 99))
        await bridge.flush()
        XCTAssertEqual(client.answers, ["Not authorised."])
        XCTAssertEqual(session.approvals.count, 1)
        XCTAssertTrue(decisions.values.isEmpty)
        // An allowed user tapping from another chat is refused too.
        bridge.handle(callback(sent.buttons[0].data, from: 10, chat: 77))
        await bridge.flush()
        XCTAssertEqual(session.approvals.count, 1)
        bridge.handle(callback(sent.buttons[1].data))
        await settle()
        XCTAssertEqual(decisions.values, [false])
    }

    func testStoppingTheTurnEndsTheTelegramApproval() async throws {
        let (_, _) = await startApprovalTurn()
        session.stop()
        await bridge.flush()
        XCTAssertTrue(client.edits.first?.text.hasSuffix("No longer needed: the turn ended.") == true, client.edits.description)
    }
}

private actor Received {
    var value: (Data, String)?
    func set(_ data: Data, _ name: String) { value = (data, name) }
}

private final class FailingFile: TelegramClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.withLock { _sent } }
    func getMe() async throws -> TelegramUser { throw TelegramError.noToken }
    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] { [] }
    func sendMessage(chat: Int64, text: String, html: Bool, buttons: [TelegramButton]) async throws -> Int64 {
        lock.withLock { _sent.append(text) }
        return 1
    }
    func editMessage(chat: Int64, messageID: Int64, text: String) async throws {}
    func answerCallback(id: String, text: String?, alert: Bool) async throws {}
    func sendChatAction(chat: Int64) async throws {}
    func getFile(id: String) async throws -> TelegramFilePath { throw TelegramError.api(code: 400, description: "Bad Request: file is too big") }
    func download(path: String) async throws -> Data { Data() }
}
