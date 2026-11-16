import XCTest
@testable import IronPet

/// Secrets are redacted first, for every item. The sample secrets are built from pieces so this file holds no real-looking key.
final class CaptureRedactorTests: XCTestCase {
    private let aws = "AKIA" + "IOSFODNN7EXAMPLE"
    private let github = "ghp_" + String(repeating: "a1B2", count: 9)
    private let anthropic = "sk-ant-" + "api03-" + String(repeating: "xY7_", count: 8)
    private let openAI = "sk-" + "proj-" + String(repeating: "Ab3d", count: 8)
    private let stripe = "sk_" + "live_" + "4eC39HqLyjWDarjtT1zdp7dc"
    private let slack = "xoxb-" + "123456789012-1234567890123-abcdefghijklmnopqrstuvwx"
    private let jwt = "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dBjftJeZ4CVPmB92K27uhbUJU1p1r"
    private let google = "AIza" + "SyA-" + String(String(repeating: "q1w2e3r4", count: 4).prefix(31))
    private let npm = "npm_" + String(repeating: "a9Z8", count: 9)
    private let gitlab = "glpat-" + "abcdefghij1234567890"
    private let sendgrid = "SG." + "abcdefghijklmnop1234" + "." + "qrstuvwxyz0123456789"
    private let pem = "-----BEGIN RSA PRIVATE" + " KEY-----\nMIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo\n4lgOEePzNm0tRgeLezV6ffAt0gun\n-----END RSA PRIVATE" + " KEY-----"

    private func redact(_ text: String) -> (text: String, report: CaptureRedactor.Report) { CaptureRedactor.redact(text) }

    private func assertRedacted(_ text: String, kind: String, secret: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = redact(text)
        XCTAssertFalse(result.text.contains(secret), "\(kind): the secret is still there in \(result.text)", file: file, line: line)
        XCTAssertTrue(result.text.contains("[redacted:\(kind)]"), "\(kind): no marker in \(result.text)", file: file, line: line)
        XCTAssertEqual(result.report.kinds[kind], 1, "\(kind)", file: file, line: line)
    }

    // MARK: Each detector

    func testProviderKeys() {
        assertRedacted("use \(aws) for the deploy", kind: "aws-key", secret: aws)
        assertRedacted("ASIA" + "IOSFODNN7EXAMPLE temp key", kind: "aws-key", secret: "ASIA" + "IOSFODNN7EXAMPLE")
        assertRedacted("token \(github) pushed", kind: "github-token", secret: github)
        assertRedacted("token gho_" + String(repeating: "q9Z8", count: 9) + " pushed", kind: "github-token", secret: "gho_" + String(repeating: "q9Z8", count: 9))
        assertRedacted("github_pat_" + String(repeating: "A1b2C3", count: 8), kind: "github-token", secret: "github_pat_" + String(repeating: "A1b2C3", count: 8))
        assertRedacted("gitlab \(gitlab)", kind: "gitlab-token", secret: gitlab)
        assertRedacted("ANTHROPIC \(anthropic)", kind: "anthropic-key", secret: anthropic)
        assertRedacted("OPENAI \(openAI)", kind: "api-key", secret: openAI)
        assertRedacted("stripe \(stripe)", kind: "stripe-key", secret: stripe)
        assertRedacted("whsec_" + String(repeating: "q9W8", count: 6), kind: "stripe-key", secret: "whsec_" + String(repeating: "q9W8", count: 6))
        assertRedacted("slack \(slack)", kind: "slack-token", secret: slack)
        assertRedacted("hooks " + "https://hooks.slack.com/services/" + "T0123ABCD/B0123ABCD/abcdefghijklmnopqrstuvwx", kind: "slack-webhook",
                       secret: "T0123ABCD/B0123ABCD")
        assertRedacted("maps \(google)", kind: "google-key", secret: google)
        assertRedacted("npm \(npm)", kind: "npm-token", secret: npm)
        assertRedacted("mail \(sendgrid)", kind: "sendgrid-key", secret: sendgrid)
    }

    func testJWTAndPrivateKeys() {
        assertRedacted("Authorization header was \(jwt) ok", kind: "jwt", secret: jwt)
        let result = redact("before\n\(pem)\nafter")
        XCTAssertEqual(result.text, "before\n[redacted:private-key]\nafter")
        XCTAssertEqual(result.report.kinds, ["private-key": 1], "a block that spans lines is one span")
        let cut = redact("-----BEGIN OPENSSH PRIVATE" + " KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU")
        XCTAssertTrue(cut.text.contains("[redacted:private-key]"), "a block cut off by the screen is redacted too")
        XCTAssertFalse(cut.text.contains("b3BlbnNz"))
    }

    func testCredentialsInURLs() {
        let result = redact("clone https://deploy:" + "s3cr3tPass" + "@git.example.com/org/repo.git now")
        XCTAssertEqual(result.text, "clone https://[redacted:url-credentials]@git.example.com/org/repo.git now")
        XCTAssertEqual(result.report.kinds, ["url-credentials": 1])
        let params = redact("open https://app.example.com/cb?code=abc123&state=xyz789&view=inbox#access_token=tok456")
        XCTAssertFalse(params.text.contains("abc123") || params.text.contains("xyz789") || params.text.contains("tok456"))
        XCTAssertTrue(params.text.contains("view=inbox"), "other parameters stay")
        XCTAssertEqual(params.report.kinds, ["url-param": 3])
    }

    func testAssignmentsAndEnvLines() {
        for (text, secret) in [
            ("password = hunter2", "hunter2"), ("the wifi password is hunter2", "hunter2"), ("PASSWORD: S3cretValue", "S3cretValue"),
            ("API_KEY=abcd1234efgh", "abcd1234efgh"), ("export CLIENT_SECRET=\"Zx9-Qq7-Lm2\"", "Zx9-Qq7-Lm2"), ("\"token\": \"a1b2c3d4e5\"", "a1b2c3d4e5"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"), ("DB_PASSWD=hunter2hunter", "hunter2hunter"),
            ("secret is Tr0ub4dor", "Tr0ub4dor"),
        ] {
            let result = redact(text)
            XCTAssertFalse(result.text.contains(secret), "\(text) -> \(result.text)")
            XCTAssertTrue(result.text.contains("[redacted:secret-assignment]"), text)
        }
        XCTAssertEqual(redact("password = hunter2").text, "password = [redacted:secret-assignment]", "the name stays, so the line still reads")
    }

    func testCardAndBankNumbers() {
        assertRedacted("card 4242 4242 4242 4242 expires 12/29", kind: "card-number", secret: "4242 4242 4242 4242")
        assertRedacted("pay to DE89 3704 0044 0532 0130 00 please", kind: "iban", secret: "0532 0130 00")
        XCTAssertTrue(redact("order 4242 4242 4242 4243 shipped").report.isEmpty, "a number that fails the Luhn check is not a card")
        XCTAssertEqual(redact("card 5555 5555 5555 4444 ok").text, "card [redacted:card-number] ok", "the space after the number stays")
    }

    func testLongHighEntropyStrings() {
        let random = "Zk3QmP9xLw2VnB7cT4yRfH8sJd6GaE1uXo5NiK0b"
        assertRedacted("signing key \(random) rotated", kind: "high-entropy", secret: random)
    }

    // MARK: What stays

    func testOrdinaryTextIsLeftAlone() {
        for text in [
            "Please send the report to Dana by Friday.", "commit 3f786850e387550fdab836ed7e6dc881de23001b fixed it", "id 550e8400-e29b-41d4-a716-446655440000",
            "the token: expired message came back", "password reset email sent", "let tokenCount = 5", "version 3.5.1 of the build", "see /Users/ana/Projects/ironpet/Sources/IronPet/Capture",
            "token_url = https://example.com/path", "password=<your password>", "API_KEY=${API_KEY}", "SECRET=changeme", "Retry last message", "internationalization_and_localization_settings_page",
            "https://example.com/a/b?page=2&view=list", "auth: true",
        ] {
            let result = redact(text)
            XCTAssertEqual(result.text, text, text)
            XCTAssertTrue(result.report.isEmpty, text)
        }
    }

    func testBearerHeadersAndNamesThatMerelyContainAKeyword() {
        let bearer = redact("Authorization: Bearer " + "abcDEF123456.ghi789_jkl-mno")
        XCTAssertFalse(bearer.text.contains("abcDEF123456"), bearer.text)
        XCTAssertEqual(bearer.report.count, 1)
        let short = redact("authorization: Bearer abc12345")
        XCTAssertFalse(short.text.contains("abc12345"), short.text)
        for text in ["Author: John Smith", "Secretary: Alice Johnson", "tokenizer: GPT2Tokenizer", "max_tokens: 4096", "token: 5", "authority: Dana"] {
            XCTAssertEqual(redact(text).text, text, text)
        }
        XCTAssertFalse(redact("password=hunter").text.contains("hunter"), "an = assignment to a password name counts whatever the value looks like")
    }

    func testAKeyNextToACombiningMarkIsStillRedacted() {
        let result = redact("key \(aws)\u{0301} and password = hunter2\u{200D}")
        XCTAssertFalse(result.text.contains(aws))
        XCTAssertFalse(result.text.contains("hunter2"))
    }

    func testRedactedTextPassesThroughAgainUnchangedAndUncounted() {
        let text = "open https://deploy:" + "s3cr3tPass" + "@host.example.com/cb?token=abc123&code=zzz999 and Authorization: Bearer " + "abcDEF123456.ghi789_jkl-mno"
        let once = redact(text)
        XCTAssertGreaterThan(once.report.count, 2)
        let twice = redact(once.text)
        XCTAssertEqual(twice.text, once.text)
        XCTAssertTrue(twice.report.isEmpty, "the send-time pass must not report spans the first pass already replaced: \(twice.report.summary)")
    }

    func testLargeBodiesAreRedactedInBoundedTime() {
        // Shapes that make a naive pattern quadratic: one long run of name characters, a long dotted run, long digit and base64 runs.
        let shapes = [
            String(repeating: "a.", count: 12_000), String(repeating: "a-b_", count: 6_000), String(repeating: "1234 ", count: 5_000),
            String(repeating: "Zk3QmP9xLw2VnB7cT4yRfH8sJd6GaE1u", count: 750), String(repeating: "token ", count: 4_000),
            String(repeating: "password ", count: 2_700) + String(repeating: "x", count: 100), String(repeating: "-----BEGIN PRIVATE KEY-----\n", count: 800),
            String(repeating: "see https://a.example.com/path?x=1 and email me\n", count: 500),
        ]
        for shape in shapes {
            let started = Date()
            _ = redact(shape)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5.0, "\(shape.prefix(20)) took too long")
        }
    }

    // MARK: Report

    func testRedactionIsIdempotentAndCountsEverySpan() {
        let text = "keys \(aws) and \(github) and password = hunter2 and again \(aws)"
        let once = redact(text)
        XCTAssertEqual(once.report.kinds, ["aws-key": 2, "github-token": 1, "secret-assignment": 1])
        XCTAssertEqual(once.report.count, 4)
        let twice = redact(once.text)
        XCTAssertEqual(twice.text, once.text)
        XCTAssertTrue(twice.report.isEmpty)
        XCTAssertEqual(once.report.summary, "redacted 4 spans (aws-key 2, github-token 1, secret-assignment 1)")
        XCTAssertEqual(redact("hello").report.summary, "nothing redacted")
        XCTAssertEqual(redact("key \(aws)").report.summary, "redacted 1 span (aws-key 1)")
    }

    func testReportRoundTripsThroughJSONAndTheStoredMarkers() {
        let report = redact("a \(aws) b password = hunter2").report
        XCTAssertEqual(CaptureRedactor.Report(json: report.json), report)
        XCTAssertNil(CaptureRedactor.Report().json)
        XCTAssertEqual(CaptureStore.report(of: redact("a \(aws) b password = hunter2").text), report)
    }
}

final class CaptureRedactionStoreTests: XCTestCase {
    private let key = "AKIA" + "IOSFODNN7EXAMPLE"

    private func conversation(_ lines: [String], thread: String = "slack:ops") -> CaptureItem {
        CaptureItem(app: CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), threadKey: thread, threadTitle: "Ops",
                    content: .conversation(title: "Ops", isGroup: true, messages: lines.map { CaptureMessage(author: "Bo", text: $0) }), parser: "test")
    }

    /// Everything the capture tables hold as text, joined.
    private func everything(_ store: CaptureStore, includingOriginals: Bool = false) -> String {
        var tables = ["SELECT body FROM capture_items", "SELECT body FROM capture_messages", "SELECT last_text || title FROM capture_threads"]
        if includingOriginals { tables.append("SELECT body FROM capture_originals") }
        return tables.flatMap { sql in ((try? store.database.read { try $0.rows(sql) }) ?? []).compactMap { $0.first as? String } }.joined(separator: "\n")
    }

    func testASecretIsRedactedBeforeItIsStoredAndTheOriginalIsKeptApart() throws {
        let store = CaptureStore.inMemory()
        let now = Date()
        let id = try XCTUnwrap(store.ingest(conversation(["deploy with \(key) and tell Dana", "see you at 3"]), now: now).itemId)
        let item = try XCTUnwrap(store.item(id: id))
        XCTAssertEqual(item.body, "Bo: deploy with [redacted:aws-key] and tell Dana\nBo: see you at 3")
        XCTAssertEqual(item.redactions.kinds, ["aws-key": 1])
        XCTAssertFalse(everything(store).contains(key), "no table but the originals holds the key")
        let original = try XCTUnwrap(store.original(of: id, now: now))
        XCTAssertTrue(original.text.contains(key))
        XCTAssertEqual(original.expires.timeIntervalSince(now), 24 * 3600, accuracy: 1)
    }

    func testTheSameContentReadAgainStoresNothingAndANewMessageStoresOnlyItself() throws {
        let store = CaptureStore.inMemory()
        _ = try store.ingest(conversation(["deploy with \(key)"]))
        XCTAssertFalse(try store.ingest(conversation(["deploy with \(key)"])).changed, "redaction is stable, so change detection still sees the same content")
        let second = try store.ingest(conversation(["deploy with \(key)", "done"]))
        XCTAssertEqual(second.newMessages, 1)
        XCTAssertEqual(store.recent(limit: 1).first?.body, "Bo: done")
        XCTAssertNil(store.recent(limit: 1).first.flatMap { store.original(of: $0.id) }, "an item without a secret has no original")
    }

    func testADocumentWithAKeyIsRedactedToo() throws {
        let store = CaptureStore.inMemory()
        let page = CaptureItem(app: CaptureApp(bundleId: "com.apple.Notes", name: "Notes"), threadKey: "notes:env", threadTitle: "env file token=abcd1234efgh",
                               content: .document(title: "env", text: "first line\nAPI_KEY=abcd1234efgh\nlast line"), parser: "test")
        let id = try XCTUnwrap(store.ingest(page).itemId)
        XCTAssertEqual(store.item(id: id)?.body, "first line\nAPI_KEY=[redacted:secret-assignment]\nlast line")
        XCTAssertFalse(everything(store).contains("abcd1234efgh"), "the body, the change-detection text and the title are redacted")
        XCTAssertEqual(store.original(of: id)?.text, "first line\nAPI_KEY=abcd1234efgh\nlast line")
    }

    func testTheOriginalIsGoneAfter24HoursAndOnlyTheRedactedTextRemains() throws {
        let store = CaptureStore.inMemory()
        let now = Date()
        let id = try XCTUnwrap(store.ingest(conversation(["deploy with \(key)"]), now: now).itemId)
        XCTAssertNotNil(store.original(of: id, now: now.addingTimeInterval(23 * 3600)))
        XCTAssertNotNil(store.inspect(now: now.addingTimeInterval(23 * 3600)).first?.originalUntil)
        XCTAssertNil(store.original(of: id, now: now.addingTimeInterval(24 * 3600 + 1)), "even before the purge runs, it cannot be read")
        XCTAssertEqual(store.purgeOriginals(now: now.addingTimeInterval(24 * 3600 + 1)), 1)
        XCTAssertFalse(everything(store, includingOriginals: true).contains(key), "nothing holds the key any more")
        XCTAssertNil(store.inspect(now: now.addingTimeInterval(25 * 3600)).first?.originalUntil)
        XCTAssertEqual(store.item(id: id)?.body, "Bo: deploy with [redacted:aws-key]")
    }

    func testAnItemStillFlaggedKeepsItsTextAsAnOriginalFor24HoursAndThenOnlyTheRow() throws {
        let store = CaptureStore.inMemory()
        let now = Date()
        let id = try XCTUnwrap(store.ingest(conversation(["the vault phrase is rosebud"]), now: now).itemId)
        store.setState(id, "local", reason: CaptureDecisionFilter.flaggedReason, secret: 0.9)
        store.dropText(id)
        XCTAssertEqual(store.item(id: id)?.body, "")
        XCTAssertEqual(store.original(of: id, now: now)?.text, "Bo: the vault phrase is rosebud")
        XCTAssertEqual(store.purgeOriginals(now: now.addingTimeInterval(25 * 3600)), 1)
        XCTAssertFalse(everything(store, includingOriginals: true).contains("rosebud"))
    }

    func testTheOutcomeSaysWhatHappened() throws {
        let store = CaptureStore.inMemory()
        let id = try XCTUnwrap(store.ingest(conversation(["deploy with \(key)"])).itemId)
        func outcome() -> String { store.outcome(of: store.inspect().first { $0.id == id }!) }
        XCTAssertEqual(outcome(), "redacted 1 span (aws-key 1), waiting for the filter")
        store.setState(id, "sent")
        XCTAssertEqual(outcome(), "redacted 1 span (aws-key 1), sent")
        store.setState(id, "local", reason: CaptureDecisionFilter.flaggedReason)
        XCTAssertEqual(outcome(), "redacted 1 span (aws-key 1), still flagged after redaction, kept local")
        let plain = try XCTUnwrap(store.ingest(conversation(["hello"], thread: "slack:other")).itemId)
        store.setState(plain, "sent")
        XCTAssertEqual(store.outcome(of: store.inspect().first { $0.id == plain }!), "nothing redacted, sent")
    }

    func testMigrationRedactsTextThatEarlierBuildsStored() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("capture-migrate-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        let early = Array(CaptureStore.migrations.prefix(2))
        let old = try Database(path: file, migrations: early)
        try old.write { db in
            try db.execute("INSERT INTO capture_threads(id, key, app, app_name, title, kind, first_seen, last_seen, last_text) VALUES(1, 'k', 'a', 'A', 'T', 'conversation', 1, 1, 'Bo: password = hunter2')")
            let message = CaptureMessage(author: "Bo", text: "password = hunter2")
            try db.execute("INSERT INTO capture_messages(thread_id, fingerprint, author, body, first_seen) VALUES(1, ?, 'Bo', ?, 1)", [message.id + "#0", message.text])
            try db.execute("INSERT INTO capture_items(id, thread_id, at, hash, version, new_messages, body) VALUES(7, 1, 1, 'h', 1, 1, 'Bo: password = hunter2')")
        }
        let migrated = try Database(path: file, migrations: CaptureStore.migrations)
        let store = CaptureStore(database: migrated)
        XCTAssertEqual(store.item(id: 7)?.body, "Bo: password = [redacted:secret-assignment]")
        XCTAssertEqual(store.item(id: 7)?.redactions.kinds, ["secret-assignment": 1])
        XCTAssertFalse(everything(store).contains("hunter2"))
        XCTAssertEqual(store.original(of: 7)?.text, "Bo: password = hunter2", "kept for the usual 24 hours from the migration")
        // A message read again after the migration is the same message, not a new one.
        let again = try store.ingest(conversation(["password = hunter2"], thread: "k").withApp("a"))
        XCTAssertEqual(again.newMessages, 0)
    }
}

extension CaptureRedactionStoreTests {
    func testMigrationKeepsTwoMessagesThatOnlyDifferedInTheSecret() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("capture-migrate-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        let old = try Database(path: file, migrations: Array(CaptureStore.migrations.prefix(2)))
        try old.write { db in
            try db.execute("INSERT INTO capture_threads(id, key, app, app_name, title, kind, first_seen, last_seen) VALUES(1, 'k', 'a', 'A', 'T', 'conversation', 1, 1)")
            for (n, text) in ["password = hunter2", "password = correcthorse9"].enumerated() {
                let message = CaptureMessage(author: "Bo", text: text)
                try db.execute("INSERT INTO capture_messages(thread_id, fingerprint, author, body, first_seen) VALUES(1, ?, 'Bo', ?, ?)", [message.id + "#0", message.text, n])
            }
        }
        let migrated = try Database(path: file, migrations: CaptureStore.migrations)
        let count = try migrated.read { try $0.rows("SELECT COUNT(*) FROM capture_messages").first?.first as? Int64 }
        XCTAssertEqual(count, 2, "the second message is renumbered, not replaced")
    }
}

private extension CaptureItem {
    func withApp(_ bundleId: String) -> CaptureItem {
        var copy = self
        copy.app = CaptureApp(bundleId: bundleId, name: "A")
        return copy
    }
}

final class CaptureOriginalsOnDiskTests: XCTestCase {
    func testTheDatabaseFilesAreOwnerOnlyAndAPurgeEmptiesTheLog() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("capture-disk-\(UUID().uuidString).db")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let database = try Database(path: file, migrations: CaptureStore.migrations)
        let store = CaptureStore(database: database)
        CaptureStore.restrictPermissions(of: database)
        let key = "AKIA" + "IOSFODNN7EXAMPLE"
        let item = CaptureItem(app: CaptureApp(bundleId: "a", name: "A"), threadKey: "k", threadTitle: "t",
                               content: .conversation(title: "t", isGroup: false, messages: [CaptureMessage(author: "Bo", text: "deploy with \(key)")]), parser: "test")
        let now = Date()
        let id = try XCTUnwrap(store.ingest(item, now: now).itemId)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: file.path + suffix) {
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path + suffix)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, 0o600, "\(file.lastPathComponent)\(suffix)")
        }
        XCTAssertEqual(store.purgeOriginals(now: now.addingTimeInterval(25 * 3600)), 1)
        XCTAssertNil(store.original(of: id, now: now))
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: file.path + suffix) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: file.path + suffix))
            XCTAssertNil(bytes.range(of: Data(key.utf8)), "the key is not in \(file.lastPathComponent)\(suffix) after the purge")
        }
    }
}
