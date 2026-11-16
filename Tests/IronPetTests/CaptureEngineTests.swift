import XCTest
@testable import IronPet

final class CaptureEngineTests: XCTestCase {
    private func text(_ value: String, y: Double = 100) -> CaptureNode {
        CaptureNode(role: "StaticText", value: value, frame: CaptureRect(x: 20, y: y, width: 400, height: 18))
    }

    /// A native window with a few lines of text, read by the generic rule.
    private func window(app: String = "com.example.notepad", title: String = "Plan", url: String? = nil, lines: [String] = ["Call the plumber on Friday", "Buy milk"],
                        extra: [CaptureNode] = []) -> CaptureSnapshot {
        let children = lines.enumerated().map { text($1, y: 100 + Double($0) * 20) } + extra
        return CaptureSnapshot(app: CaptureApp(bundleId: app, name: "Notepad", pid: 7), windowTitle: title, url: url,
                               root: CaptureNode(role: "Window", frame: CaptureRect(x: 0, y: 0, width: 800, height: 600), children: children), capturedAt: 1)
    }

    private func pipeline(rules: CaptureRules = CaptureRules(), privacy: CapturePrivacy = CapturePrivacy()) -> (CapturePipeline, CaptureStore) {
        let store = CaptureStore.inMemory()
        return (CapturePipeline(privacy: privacy, rules: rules, store: store), store)
    }

    private func isStored(_ outcome: CapturePipeline.Outcome) -> Bool {
        if case .stored = outcome { return true }
        return false
    }

    private func allText(_ store: CaptureStore) -> String {
        store.recent(limit: 100).map(\.body).joined(separator: "\n") + ((try? store.database.read { try $0.rows("SELECT url, key, title, last_text FROM capture_threads") }) ?? [])
            .map { "\($0)" }.joined()
    }

    // MARK: S3, the hard floor

    func testASavedWindowIsStored() {
        let (pipeline, store) = pipeline()
        XCTAssertTrue(isStored(pipeline.process(window())), "\(pipeline.process(window()))")
        XCTAssertEqual(store.itemCount, 1)
    }

    func testSecureFieldValueIsNeverStored() {
        let (pipeline, store) = pipeline()
        let secure = CaptureNode(role: "SecureTextField", value: "hunter2-secret", attrs: ["placeholder": "Password"], focused: true)
        let subrole = CaptureNode(role: "TextField", value: "tok-123-secret", attrs: ["subrole": "AXSecureTextField"])
        _ = pipeline.process(window(extra: [secure, subrole]))
        let stored = allText(store)
        XCTAssertFalse(stored.contains("hunter2"), "secure role")
        XCTAssertFalse(stored.contains("tok-123"), "secure subrole")
        XCTAssertTrue(stored.contains("plumber"))
    }

    func testDenylistedAppsStoreNothing() {
        for bundle in ["com.agilebits.onepassword7", "com.1password.1password", "com.lastpass.lastpass-electron", "com.apple.loginwindow", "com.bitwarden.desktop",
                       "com.xk72.Charles", "com.okta.mobile"] {
            let (pipeline, store) = pipeline()
            let outcome = pipeline.process(window(app: bundle))
            XCTAssertEqual(outcome, .skipped(.deniedApp(bundle)), bundle)
            XCTAssertEqual(store.itemCount, 0, bundle)
            XCTAssertFalse(pipeline.mayRead(CaptureApp(bundleId: bundle, name: "x")), "\(bundle) is not read at all")
        }
    }

    func testPrivateBrowserWindowStoresNothing() {
        for title in ["Bank - Private Browsing", "New Tab - Google Chrome (Incognito)", "Mail — InPrivate"] {
            let (pipeline, store) = pipeline()
            let outcome = pipeline.process(window(app: "com.google.Chrome", title: title, url: "https://example.com/inbox"))
            XCTAssertEqual(outcome, .skipped(.privateWindow), title)
            XCTAssertEqual(store.itemCount, 0)
        }
    }

    func testLocalAndInternalURLsStoreNothing() {
        for url in ["file:///Users/me/secret.txt", "data:text/html,hello", "javascript:alert(1)", "blob:https://x.com/abc", "about:blank", "chrome://settings"] {
            let (pipeline, store) = pipeline()
            XCTAssertEqual(pipeline.process(window(app: "com.google.Chrome", url: url)), .skipped(.unsafeURL), url)
            XCTAssertEqual(store.itemCount, 0)
        }
        let (pipeline, _) = pipeline()
        XCTAssertEqual(pipeline.process(window(app: "com.google.Chrome", url: "app://notes/1")), .skipped(.unsafeURL), "a browser stores only http(s)")
        XCTAssertEqual(pipeline.process(window(app: "com.example.electron", url: "file:///x")), .skipped(.unsafeURL))
        XCTAssertEqual(pipeline.process(window(app: "com.example.electron", url: "https:///nohost")), .skipped(.unsafeURL))
    }

    func testURLSecretsAreStrippedBeforeStorage() {
        let (pipeline, store) = pipeline()
        let url = "https://user:pw@app.example.com/callback?code=abc123&state=xyz789&view=inbox#access_token=tok456&tab=2"
        XCTAssertTrue(isStored(pipeline.process(window(app: "com.google.Chrome", title: "Callback", url: url))))
        let stored = allText(store)
        for secret in ["abc123", "xyz789", "tok456", "pw@", "user:"] { XCTAssertFalse(stored.contains(secret), "\(secret) in \(stored)") }
        XCTAssertTrue(stored.contains("view=inbox"))
    }

    func testAUserRuleCannotAllowWhatTheFloorDenies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "export const meta = { api: 1, kind: 'denylist' };\nexport function check(target, ctx) { return null; }"
            .write(to: folder.appendingPathComponent("denylist.js"), atomically: true, encoding: .utf8)
        // A transform that puts a secret URL back into the item, and a parser-level allow of everything.
        try "export const meta = { api: 1, kind: 'transform' };\nexport function transform(item, ctx) { item.url = 'https://x.example.com/p?token=LEAK1'; item.thread_key = 'k:https://x.example.com/p?token=LEAK2'; item.app = { bundle_id: 'com.example.fake', name: 'Fake', pid: 0 }; return item; }"
            .write(to: folder.appendingPathComponent("zz-evil.js"), atomically: true, encoding: .utf8)
        let rules = CaptureRules(set: CaptureRuleSet(folder: folder))
        let (pipeline, store) = pipeline(rules: rules)
        XCTAssertEqual(pipeline.process(window(app: "com.lastpass.lastpass-electron")), .skipped(.deniedApp("com.lastpass.lastpass-electron")))
        XCTAssertEqual(pipeline.process(window(app: "com.google.Chrome", url: "https://vault.1password.com/x")), .skipped(.deniedHost("vault.1password.com")))
        XCTAssertTrue(isStored(pipeline.process(window(app: "com.example.notepad"))))
        let stored = allText(store)
        XCTAssertFalse(stored.contains("LEAK"), stored)
        XCTAssertFalse(stored.contains("com.example.fake"), "the app is the one that was read")
    }

    func testAFailingDenylistRuleDeniesEverything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "export const meta = { api: 1, kind: 'denylist' };\nexport function check(target, ctx) { throw new Error('boom'); }"
            .write(to: folder.appendingPathComponent("zz-broken-denylist.js"), atomically: true, encoding: .utf8)
        let (pipeline, store) = pipeline(rules: CaptureRules(set: CaptureRuleSet(folder: folder)))
        if case .skipped(.ruleFailed) = pipeline.process(window()) {} else { XCTFail("a denylist that fails must deny") }
        XCTAssertEqual(store.itemCount, 0)
    }

    func testPauseLockAndExclusionStopCapture() {
        let privacy = CapturePrivacy()
        let (pipeline, store) = pipeline(privacy: privacy)
        privacy.pause(for: 600)
        XCTAssertEqual(pipeline.process(window()), .skipped(.paused))
        privacy.resume()
        privacy.setScreenLocked(true)
        XCTAssertEqual(pipeline.process(window()), .skipped(.locked))
        privacy.setScreenLocked(false)
        privacy.setExcluded(["Notepad"])
        XCTAssertEqual(pipeline.process(window()), .skipped(.deniedApp("com.example.notepad")), "excluded by name, ignoring case")
        XCTAssertEqual(store.itemCount, 0)
    }

    // MARK: S4, change detection

    func testTheSameContentReadTwiceStoresOneVersion() {
        let (pipeline, store) = pipeline()
        guard case .stored(_, let first) = pipeline.process(window()), case .stored(_, let second) = pipeline.process(window()) else { return XCTFail() }
        XCTAssertTrue(first.changed)
        XCTAssertNotNil(first.itemId)
        XCTAssertFalse(second.changed)
        XCTAssertNil(second.itemId)
        XCTAssertEqual(store.itemCount, 1)
    }

    func testChangedContentStoresANewVersionWithOnlyWhatIsNew() {
        let (pipeline, store) = pipeline()
        _ = pipeline.process(window())
        _ = pipeline.process(window(lines: ["Call the plumber on Friday", "Buy milk", "Send the invoice to Dana"]))
        let items = store.recent(limit: 10).reversed().map { $0 }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.version), [1, 2])
        XCTAssertEqual(items[1].body, "Send the invoice to Dana")
        XCTAssertEqual(items[0].threadId, items[1].threadId)
    }

    func testDifferentWindowsAreDifferentThreads() {
        let (pipeline, store) = pipeline()
        _ = pipeline.process(window(title: "Plan"))
        _ = pipeline.process(window(title: "Other"))
        XCTAssertEqual(Set(store.recent(limit: 10).map(\.threadId)).count, 2)
    }

    func testTheSameKeyInTwoAppsIsTwoThreads() {
        let (pipeline, store) = pipeline()
        _ = pipeline.process(window(app: "com.example.notepad", title: "Plan"))
        _ = pipeline.process(window(app: "com.example.other", title: "Plan"))
        XCTAssertEqual(Set(store.recent(limit: 10).map(\.app)).count, 2)
    }

    func testRedactingAnItemClearsTheThreadsCopyOfTheText() throws {
        let (pipeline, store) = pipeline()
        _ = pipeline.process(window())
        let id = try XCTUnwrap(store.recent(limit: 1).first).id
        store.dropText(id)
        XCTAssertFalse(allText(store).contains("plumber"))
    }

    func testAMismatchedConfirmationReadStoresNothing() {
        let (pipeline, store) = pipeline()
        XCTAssertEqual(pipeline.process(window(title: "Plan"), confirmedBy: window(title: "Other")), .skipped(.unsettled))
        XCTAssertEqual(store.itemCount, 0)
        XCTAssertTrue(isStored(pipeline.process(window(title: "Plan"), confirmedBy: window(title: "Plan"))))
        XCTAssertEqual(store.itemCount, 1)
    }

    func testConversationsKeepMessageLevelDiffs() throws {
        let store = CaptureStore.inMemory()
        func item(_ messages: [CaptureMessage]) -> CaptureItem {
            CaptureItem(app: CaptureApp(bundleId: "com.example.chat", name: "Chat"), threadKey: "chat:ana", threadTitle: "Ana",
                        content: .conversation(title: "Ana", isGroup: false, messages: messages), parser: "test")
        }
        let a = CaptureMessage(author: "Ana", text: "Can you send the contract?")
        let b = CaptureMessage(author: "Me", text: "Yes, tomorrow")
        _ = try store.ingest(item([a]))
        let second = try store.ingest(item([a, b, CaptureMessage(text: "typing a draft", draft: true)]))
        XCTAssertEqual(second.newMessages, 1)
        let third = try store.ingest(item([a, b, CaptureMessage(text: "a different draft", draft: true)]))
        XCTAssertFalse(third.changed, "a draft is not a change")
        let repeated = try store.ingest(item([a, b, CaptureMessage(author: "Me", text: "Yes, tomorrow")]))
        XCTAssertEqual(repeated.newMessages, 1, "an exact repeat in the same capture is a second message")
        XCTAssertEqual(store.recent(limit: 10).reversed().map(\.body), ["Ana: Can you send the contract?", "Me: Yes, tomorrow", "Me: Yes, tomorrow"])
    }

    func testInspectShowsWhatWasKeptAndWhatTheFilterDecided() throws {
        let store = CaptureStore.inMemory()
        func item(_ thread: String, _ text: String) -> CaptureItem {
            CaptureItem(app: CaptureApp(bundleId: "com.example.chat", name: "Chat"), url: "https://example.com/x", threadKey: thread, threadTitle: thread,
                        content: .conversation(title: thread, isGroup: false, messages: [CaptureMessage(author: "Ana", text: text)]), parser: "test")
        }
        let a = try XCTUnwrap(store.ingest(item("a", "send the invoice")).itemId)
        let b = try XCTUnwrap(store.ingest(item("b", "the password is hunter2")).itemId)
        store.setState(a, "ready", secret: 0.01, related: ["t1"], calendar: 0.1, task: 0.7)
        store.setState(b, "local", reason: "secret", secret: 0.9)
        store.dropText(b)
        let rows = store.inspect()
        XCTAssertEqual(rows.map(\.id), [b, a], "newest first")
        XCTAssertEqual(rows[1].body, "Ana: send the invoice")
        XCTAssertEqual(rows[1].related, #"["t1"]"#)
        XCTAssertEqual(rows[1].task, 0.7)
        XCTAssertEqual(rows[0].reason, "secret")
        XCTAssertEqual(rows[0].body, "")
        XCTAssertEqual(rows[1].url, "https://example.com/x")
        XCTAssertEqual(store.inspect(state: "local").map(\.id), [b])
    }

    func testCaptureMigrationsFitTheAppsSharedSchema() {
        let versions = AppMigrations.all.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count, "every feature's migration has its own version")
        XCTAssertEqual(CaptureStore.migrations.map(\.version), [300, 301, 302])
    }

    func testRetentionPrunesOldItems() throws {
        let (pipeline, store) = pipeline()
        _ = pipeline.process(window(), confirmedBy: nil, now: Date().addingTimeInterval(-40 * 86400))
        _ = pipeline.process(window(title: "Fresh"), confirmedBy: nil, now: Date())
        XCTAssertEqual(store.itemCount, 2)
        XCTAssertEqual(store.prune(olderThanDays: 30), 1)
        XCTAssertEqual(store.itemCount, 1)
    }
}

final class CapturePerformanceTests: XCTestCase {
    /// S8's proxy: the cost of one full read through the rules, the floor and the store, on the recorded fixtures. The app reads a window at
    /// most once per 800 ms of quiet or 5 s of activity, twice for an identity change (the confirmation), so CPU is this cost over that period.
    func testOneReadCostsMillisecondsNotSeconds() throws {
        let rules = CaptureRules()
        let store = CaptureStore.inMemory()
        let pipeline = CapturePipeline(privacy: CapturePrivacy(), rules: rules, store: store)
        let snapshots = CaptureFixtures.names.compactMap(CaptureFixtures.snapshot)
        _ = snapshots.map { pipeline.process($0) } // the first pass compiles the rules
        let rounds = 5
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<rounds { for snapshot in snapshots { _ = pipeline.process(snapshot) } }
        let perRead = (ProcessInfo.processInfo.systemUptime - start) / Double(rounds * snapshots.count)
        print("capture cost per read (debug build): \(Int(perRead * 1000)) ms over \(snapshots.count) fixtures")
        XCTAssertLessThan(perRead, 0.25, "a read through the rules must stay far below the 5 s refresh period")
    }
}
