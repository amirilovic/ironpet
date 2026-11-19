import XCTest
@testable import IronPet

@MainActor
final class MemoryReflectorTests: XCTestCase {
    private var dir: URL!
    private var store: FileMemoryStore!
    private var index: MemoryIndex!
    private var reflector: MemoryReflector!
    private var threads: [String: ChatThread] = [:]
    private var prompts: [String] = []
    /// Who read each prompt.
    private var readers: [MemoryReflector.Reader] = []
    /// Answers the fake agent gives, in order. Out of answers, it says there is nothing to keep.
    private var answers: [Result<String, MemoryReflector.RunError>] = []
    private var config = Config.Memory()
    private var clock = Date(timeIntervalSince1970: 1_795_000_000)
    private var workspace: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-reflector-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        index = MemoryIndex(database: try Database(path: nil, migrations: AppMigrations.all))
        store = FileMemoryStore(directory: dir.appendingPathComponent("memory"), index: index)
        store.now = { [unowned self] in clock }
        reflector = MemoryReflector(store: store, index: index) { [unowned self] prompt, reader in
            prompts.append(prompt)
            readers.append(reader)
            return answers.isEmpty ? .success(#"{"notes":[]}"#) : answers.removeFirst()
        }
        reflector.config = { [unowned self] in config }
        reflector.now = { [unowned self] in clock }
        reflector.threads = { [unowned self] in threads[$0] }
        reflector.recentThreads = { [unowned self] in threads.values.sorted { $0.updatedAt > $1.updatedAt } }
        reflector.petName = { "Ghost" }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func chat(_ id: String, _ items: [ChatSession.Item], updated: Date? = nil, automation: String? = nil) -> ChatThread {
        let thread = ChatThread(id: id, title: "t", workspace: workspace.path, updatedAt: updated ?? clock, items: items, agent: "claude",
                                automation: automation)
        threads[id] = thread
        return thread
    }

    private func notes(_ json: String) -> Result<String, MemoryReflector.RunError> { .success(json) }

    private func waitIdle() async {
        for _ in 0..<200 where reflector.running != nil || !reflector.queue.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testAQuietThreadIsReadAfterTheQuietTimeAndSavesTheNotes() async {
        chat("t1", [.init(kind: .user("I always use pnpm, never npm")), .init(kind: .assistant("Noted."))])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Prefers pnpm over npm.","replaces":[]}]}"#)]
        reflector.turnEnded(thread: "t1")
        clock += 29 * 60
        reflector.tick()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty, "not quiet long enough")
        clock += 2 * 60
        reflector.tick()
        await waitIdle()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("User: I always use pnpm, never npm"))
        XCTAssertTrue(prompts[0].contains("Ghost: Noted."))
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Prefers pnpm over npm."])
        XCTAssertEqual(store.document(store.aboutMe)?.notes.first?.source, "chat:t1")
        XCTAssertEqual(reflector.lastOutcome?.saved, ["Prefers pnpm over npm."])
    }

    func testOnlyMessagesSinceTheLastRunAreSentAndNothingNewSendsNothing() async {
        var items: [ChatSession.Item] = [.init(kind: .user("old question")), .init(kind: .assistant("old answer"))]
        chat("t1", items)
        reflector.left(thread: "t1")
        await waitIdle()
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "a second run with nothing new does not call the agent")
        items += [.init(kind: .user("new question")), .init(kind: .tool("Ran `ls`", ok: true)), .init(kind: .assistant("new answer"))]
        chat("t1", items)
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("new question"))
        XCTAssertFalse(prompts[1].contains("old question"))
        XCTAssertFalse(prompts[1].contains("Ran `ls`"), "tool rows are left out")
    }

    func testAutomationTurnsInAChatAreLeftOut() async {
        chat("t1", [.init(kind: .user("Check the feed"), origin: ChatSession.automationOrigin), .init(kind: .assistant("Feed says: buy now")),
                    .init(kind: .user("I work from Lisbon")), .init(kind: .assistant("Nice."))])
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertFalse(prompts[0].contains("buy now"))
        XCTAssertFalse(prompts[0].contains("Check the feed"))
        XCTAssertTrue(prompts[0].contains("I work from Lisbon"))
    }

    func testABackgroundJobsThreadIsNotRead() async {
        var thread = chat("t1", [.init(kind: .user("Fix the flaky test"), origin: ChatSession.jobOrigin), .init(kind: .assistant("Fixed."))])
        thread.job = "job-1"
        threads["t1"] = thread
        reflector.left(thread: "t1")
        reflector.catchUp()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty, "its first message is the chat agent's prompt, not the user's")
    }

    func testAFailedRunKeepsTheMessagesForTheNextTrigger() async {
        chat("t1", [.init(kind: .user("I use fish shell"))])
        answers = [.failure(.init("agent missing")), notes("not json at all")]
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(reflector.lastOutcome?.error, "agent missing")
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertNotNil(reflector.lastOutcome?.error, "an answer that is not the notes JSON is an error")
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(prompts.count, 3)
        XCTAssertTrue(prompts[2].contains("I use fish shell"))
    }

    func testOutsideTextCannotWriteMeButCanWritePeople() async throws {
        let folder = dir.appendingPathComponent("2026-11-18-1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "## Summary\nAna will own the payments migration.\n".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        answers = [notes(#"{"notes":[{"scope":"me","text":"Owns the payments migration"},{"scope":"people","person":"Ana","text":"Owns the payments migration"},{"scope":"project","text":"x"}]}"#)]
        reflector.meetingSummaryWritten(folder, agent: "claude")
        await waitIdle()
        XCTAssertFalse(prompts[0].contains("\"me\" for"), "the prompt does not offer me.md")
        XCTAssertTrue(prompts[0].contains("never use scope \"me\""))
        XCTAssertNil(store.document(store.aboutMe))
        XCTAssertEqual(store.document(store.people)?.entries.map(\.section), ["Ana"])
        XCTAssertEqual(store.document(store.people)?.notes.first?.source, "meeting:2026-11-18-1000")
        XCTAssertEqual(reflector.lastOutcome?.dropped.count, 2)
        reflector.meetingSummaryWritten(folder, agent: "claude")
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "the same summary is read once")
    }

    func testOutsideTextIsSentWithoutTheNotes() async throws {
        _ = try store.remember("Works from Lisbon", scope: .me, source: "chat:a").get()
        _ = try store.remember("Leads payments", scope: .people, person: "Ana", source: "chat:a").get()
        reflector.automationFinished(id: "prs", name: "PR watcher", answer: "Ana merged PR 12.", agent: "claude")
        await waitIdle()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(prompts[0].contains("Works from Lisbon"), "the agent that ran the automation never had the notes")
        XCTAssertFalse(prompts[0].contains("Leads payments"))
        chat("t1", [.init(kind: .user("hi")), .init(kind: .assistant("hello"))])
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertTrue(prompts[1].contains("Works from Lisbon"), "a chat's agent had them in its preamble")
    }

    func testAnAutomationAnswerIsOutsideText() async {
        answers = [notes(#"{"notes":[{"scope":"me","text":"Likes red"},{"scope":"people","person":"Bo","text":"Reviews PRs on Mondays"}]}"#)]
        reflector.automationFinished(id: "prs", name: "PR watcher", answer: "Bo reviewed PR 12, as he does on Mondays.", agent: "claude")
        await waitIdle()
        XCTAssertTrue(prompts[0].contains("the automation \"PR watcher\""))
        XCTAssertNil(store.document(store.aboutMe))
        XCTAssertEqual(store.document(store.people)?.notes.first?.source, "automation:prs")
    }

    func testEachTextIsReadByTheAgentThatAlreadyHadIt() async throws {
        threads["c1"] = ChatThread(id: "c1", title: "t", workspace: workspace.path, updatedAt: clock, items: [.init(kind: .user("I use zsh"))],
                                   agent: "cursor")
        chat("c2", [.init(kind: .user("I use fish"))])
        let folder = dir.appendingPathComponent("2026-11-18-1100")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Ana decided".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        reflector.left(thread: "c1")
        reflector.left(thread: "c2")
        reflector.automationFinished(id: "a", name: "A", answer: "Ana is out", agent: "codex")
        reflector.meetingSummaryWritten(folder, agent: "gemini")
        await waitIdle()
        XCTAssertEqual(readers, [.init(agent: "cursor", model: nil), .init(agent: "claude", model: "haiku"),
                                 .init(agent: "codex", model: nil), .init(agent: "gemini", model: nil)],
                       "each chat, answer and summary goes to its own agent, with Claude Code's cheap model")
    }

    func testAPickedAgentOnlyReadsItsOwnText() async throws {
        config.reflectAgent = "claude"
        index.setCursor(MemoryReflector.seededKey, item: "1", at: clock)
        threads["c1"] = ChatThread(id: "c1", title: "t", workspace: workspace.path, updatedAt: clock, items: [.init(kind: .user("I use zsh"))],
                                   agent: "cursor")
        reflector.left(thread: "c1")
        reflector.automationFinished(id: "a", name: "A", answer: "Ana is out", agent: "codex")
        let folder = dir.appendingPathComponent("2026-11-18-1100")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Ana decided".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        reflector.meetingSummaryWritten(folder, agent: "cursor")
        reflector.catchUp()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty, "the chat used Cursor, the automation Codex and the summary Cursor; the picked agent is Claude Code")
        XCTAssertEqual(reflector.lastOutcome?.skipped, true)
        config.reflectAgent = "cursor"
        reflector.left(thread: "c1")
        await waitIdle()
        XCTAssertEqual(readers, [.init(agent: "cursor", model: nil)], "with Cursor picked, its chats are read")
    }

    func testAFailedTidyIsNotRetriedUntilTheFileChanges() async throws {
        config.tidy = true
        for n in 0..<200 { _ = try store.remember("Note \(n) that repeats itself a little", scope: .me, source: "chat:old").get() }
        chat("t1", [.init(kind: .user("I like tea"))])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Likes tea"}]}"#), notes("no")]
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(prompts.count, 2, "one reflection and one tidy")
        let url = store.aboutMe
        let skipped = await MemoryTidier.tidy(url, limit: 8_000, store: store, reader: .init(agent: "claude", model: "haiku"), runner: { _, _ in .success("{}") })
        XCTAssertFalse(skipped)
        XCTAssertEqual(prompts.count, 2, "the same file is not sent again")
    }

    func testOutsideTextCannotReplaceNotesAndNoProposalReplacesMoreThanFive() async throws {
        for name in ["a", "b", "c", "d", "e", "f"] { _ = try store.remember("Ana fact \(name)", scope: .people, person: "Ana", source: "chat:x").get() }
        answers = [notes(#"{"notes":[{"scope":"people","person":"Ana","text":"Ana left","replaces":["Ana fact a"]}]}"#)]
        reflector.automationFinished(id: "mail", name: "Mail", answer: "Ana left the company", agent: "claude")
        await waitIdle()
        XCTAssertEqual(store.document(store.people)?.notes.count, 6)
        XCTAssertTrue(reflector.lastOutcome?.dropped.first?.contains("may not replace") == true)
        chat("t1", [.init(kind: .user("Ana changed teams"))])
        let all = ["a", "b", "c", "d", "e", "f"].map { "\"Ana fact \($0)\"" }.joined(separator: ",")
        answers = [notes(#"{"notes":[{"scope":"people","person":"Ana","text":"Ana is on growth","replaces":["# + all + "]}]}")]
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(store.document(store.people)?.notes.count, 6, "a proposal may not wipe a section")
    }

    func testAutomationQuietRepliesAndRepeatsAreNotRead() async {
        reflector.automationFinished(id: "w", name: "W", answer: "No changes.", agent: "claude", quiet: "No changes.")
        reflector.automationFinished(id: "w", name: "W", answer: "PR 12 merged", agent: "claude")
        await waitIdle()
        reflector.automationFinished(id: "w", name: "W", answer: "PR 12 merged ", agent: "claude")
        await waitIdle()
        XCTAssertEqual(prompts.count, 1)
    }

    func testInTestModeOnlyReflectNowRuns() async {
        reflector.automatic = false
        chat("t1", [.init(kind: .user("I use vim"))])
        reflector.turnEnded(thread: "t1")
        reflector.left(thread: "t1")
        reflector.automationFinished(id: "w", name: "W", answer: "x", agent: "claude")
        reflector.catchUp()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty)
        _ = await reflector.reflectNow(.thread("t1"))
        XCTAssertEqual(prompts.count, 1)
    }

    func testReplacesAndTheNoteLimit() async throws {
        _ = try store.remember("Uses npm", scope: .me, source: "chat:old").get()
        chat("t1", [.init(kind: .user("switching to pnpm for good"))])
        let many = (0..<12).map { #"{"scope":"project","text":"Fact \#($0)"}"# }.joined(separator: ",")
        answers = [notes(#"{"notes":[{"scope":"me","text":"Uses pnpm","replaces":["Uses npm"]},"# + many + "]}")]
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(store.document(store.aboutMe)?.notes.map(\.text), ["Uses pnpm"])
        XCTAssertEqual(store.document(store.projectFile(ProjectKey.of(workspace)))?.notes.count, MemoryReflector.maxNotes - 1)
    }

    func testAFileOverItsLimitIsLeftAloneWhileTidyingIsOff() async throws {
        for n in 0..<200 { _ = try store.remember("Note \(n) that repeats itself a little", scope: .me, source: "chat:old").get() }
        chat("t1", [.init(kind: .user("I like tea"))])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Likes tea"}]}"#)]
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(prompts.count, 1, "no tidy pass, which would send the whole file")
        XCTAssertFalse(prompts[0].contains("Note 0 that"), "the reflection prompt holds only the preamble's share of the notes")
    }

    func testAFileOverItsLimitIsTidiedWhenTheResultChecksOut() async throws {
        config.tidy = true
        for n in 0..<200 { _ = try store.remember("Note \(n) that repeats itself a little", scope: .me, source: "chat:old").get() }
        let before = store.text(store.aboutMe)
        let kept = MemoryDocument(before).notes.prefix(70).map(\.line).joined(separator: "\n")
        chat("t1", [.init(kind: .user("I like tea"))])
        let tidied = try JSONSerialization.data(withJSONObject: ["file": "# About me\n\n" + kept + "\n"])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Likes tea"}]}"#), notes(String(decoding: tidied, as: UTF8.self))]
        reflector.left(thread: "t1")
        await waitIdle()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("over its size limit"))
        XCTAssertEqual(store.document(store.aboutMe)?.notes.count, 70)
        let change = try XCTUnwrap(store.recentChanges().first)
        XCTAssertEqual(change.action, .tidied)
        try store.undo(change).get()
        XCTAssertGreaterThan(store.document(store.aboutMe)?.notes.count ?? 0, 200, "undo goes back to the version before the tidy")
    }

    func testTidyRejectsAnswersThatAddOrChangeNotes() {
        let original = "# About me\n\n- One <!-- 2026-11-01 chat:a -->\n- Two <!-- 2026-11-02 chat:b -->\n- Hand written\n"
        func answer(_ file: String) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: ["file": file]), as: UTF8.self) }
        XCTAssertEqual(try MemoryTidier.validate(original: original, answer: answer("# About me\n\n- One and two <!-- 2026-11-02 chat:b -->\n- Hand written\n")).get(),
                       "# About me\n\n- One and two <!-- 2026-11-02 chat:b -->\n- Hand written\n")
        XCTAssertEqual(MemoryTidier.validate(original: original, answer: answer("# About me\n\n- New <!-- 2026-11-18 chat:z -->\n")),
                       .failure(.unknownTrailer("- New <!-- 2026-11-18 chat:z -->")))
        XCTAssertEqual(MemoryTidier.validate(original: original, answer: answer("# Me\n\n- One <!-- 2026-11-01 chat:a -->\n")), .failure(.headingsChanged))
        XCTAssertEqual(MemoryTidier.validate(original: original, answer: answer("# About me\n\n- Invented by hand\n")), .failure(.unknownLine("- Invented by hand")))
        XCTAssertEqual(MemoryTidier.validate(original: original, answer: answer(original + "- Two <!-- 2026-11-02 chat:b -->\n")), .failure(.notSmaller))
        XCTAssertEqual(MemoryTidier.validate(original: original, answer: "sure, here you go"), .failure(.notJSON))
        let many = "# About me\n\n" + (0..<9).map { "- Note \($0) <!-- 2026-11-0\($0 + 1) chat:a -->" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(MemoryTidier.validate(original: many, answer: answer("# About me\n\n- Note 8 <!-- 2026-11-09 chat:a -->\n")), .failure(.tooFew),
                       "a tidy may not drop most of the notes")
    }

    func testWithReflectionOffNothingIsScheduledOrRun() async {
        config.reflect = false
        chat("t1", [.init(kind: .user("I use vim"))])
        reflector.turnEnded(thread: "t1")
        reflector.left(thread: "t1")
        reflector.catchUp()
        await waitIdle()
        XCTAssertTrue(reflector.due.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testTheFirstCatchUpMarksEarlierChatsAsReadAndSendsNothing() async {
        chat("before", [.init(kind: .user("I use tabs")), .init(kind: .assistant("OK"))])
        reflector.catchUp()
        await waitIdle()
        XCTAssertTrue(prompts.isEmpty, "the update does not send chats from before it")
        var thread = threads["before"]!
        thread.items += [.init(kind: .user("I moved to Lisbon"))]
        threads["before"] = thread
        reflector.catchUp()
        await waitIdle()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("I moved to Lisbon"))
        XCTAssertFalse(prompts[0].contains("I use tabs"))
    }

    func testCatchUpReadsAtMostFiveRecentUnreadThreads() async {
        for n in 0..<7 { chat("recent\(n)", [.init(kind: .user("message \(n)"))], updated: clock.addingTimeInterval(-Double(n) * 3600)) }
        chat("old", [.init(kind: .user("old message"))], updated: clock.addingTimeInterval(-8 * 86_400))
        chat("run", [.init(kind: .user("automation"))], automation: "watcher")
        index.setCursor("recent0", item: threads["recent0"]!.items.last!.id.uuidString, at: clock)
        index.setCursor(MemoryReflector.seededKey, item: "1", at: clock)
        reflector.catchUp()
        await waitIdle()
        XCTAssertEqual(prompts.count, 5)
        XCTAssertFalse(prompts.contains { $0.contains("message 0") }, "a thread already read is skipped")
        XCTAssertFalse(prompts.contains { $0.contains("old message") || $0.contains("User: automation") })
    }

    func testRunsOneAtATimeInOrder() async {
        chat("a", [.init(kind: .user("first"))])
        chat("b", [.init(kind: .user("second"))])
        reflector.left(thread: "a")
        reflector.left(thread: "b")
        reflector.left(thread: "b")
        XCTAssertNotNil(reflector.running)
        XCTAssertEqual(reflector.queue, [.thread("b")], "a job already waiting is not queued twice")
        await waitIdle()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("first") && prompts[1].contains("second"))
    }

    func testForgetEverythingDropsWaitingAndRunningPasses() async {
        chat("a", [.init(kind: .user("I use emacs"))])
        chat("b", [.init(kind: .user("I use nano"))])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Uses emacs"}]}"#)]
        reflector.turnEnded(thread: "b")
        reflector.left(thread: "a")
        reflector.left(thread: "b")
        XCTAssertNotNil(reflector.running)
        reflector.cancelAll()
        await waitIdle()
        XCTAssertTrue(reflector.due.isEmpty)
        XCTAssertEqual(prompts.count, 1, "the queued thread never ran")
        XCTAssertNil(store.document(store.aboutMe), "the run in flight saved nothing")
    }

    func testReflectNowWaitsForItsOutcome() async {
        chat("t1", [.init(kind: .user("I prefer dark mode"))])
        answers = [notes(#"{"notes":[{"scope":"me","text":"Prefers dark mode"}]}"#)]
        let outcome = await reflector.reflectNow(.thread("t1"))
        XCTAssertEqual(outcome.saved, ["Prefers dark mode"])
    }

    func testForgetEverythingAnswersAQueuedReflectNow() async {
        chat("t1", [.init(kind: .user("a"))])
        chat("t2", [.init(kind: .user("b"))])
        var release: CheckedContinuation<Void, Never>?
        reflector.runner = { _, _ in
            await withCheckedContinuation { release = $0 }
            return .success(#"{"notes":[]}"#)
        }
        let first = Task { await self.reflector.reflectNow(.thread("t1")) }
        for _ in 0..<200 where release == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let second = Task { await self.reflector.reflectNow(.thread("t2")) }
        for _ in 0..<200 where reflector.queue.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        reflector.cancelAll()
        let dropped = await second.value
        XCTAssertTrue(dropped.skipped)
        release?.resume()
        let finished = await first.value
        XCTAssertTrue(finished.skipped, "the run in flight saves nothing")
    }

    func testTranscriptKeepsTheNewestMessagesWithinTheLimit() {
        let long = String(repeating: "x", count: 10_000)
        let messages = (0..<5).map { (id: "\($0)", user: true, text: "m\($0) " + long) }
        let text = reflector.transcript(messages)
        XCTAssertLessThanOrEqual(text.count, MemoryReflector.maxInput + 10)
        XCTAssertTrue(text.contains("m4 "))
        XCTAssertFalse(text.contains("m0 "))
    }

    func testParseReadsFencedJSONAndSkipsBadEntries() {
        let answer = "Here:\n```json\n{\"notes\":[{\"scope\":\"ME\",\"text\":\"a\"},{\"scope\":\"world\",\"text\":\"b\"},{\"text\":\"c\"}]}\n```"
        XCTAssertEqual(MemoryReflector.parse(answer), [.init(scope: .me, text: "a", person: nil, replaces: [])])
        XCTAssertNil(MemoryReflector.parse("no notes today"))
    }
}
