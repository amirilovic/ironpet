import XCTest
@testable import IronPet

@MainActor
final class OpenSessionTests: XCTestCase {
    private final class Recorder {
        var urls: [String] = []
        var commands: [[String]] = []
        var activated: [String] = []
        var handled = true
        var executable: String? = "/opt/bin/herdr-app"

        var effects: SourceJumper.Effects {
            .init(openURL: { [self] in urls.append($0.absoluteString); return handled },
                  run: { [self] exe, args in commands.append([exe] + args) },
                  activate: { [self] id, _ in activated.append(id) },
                  findExecutable: { [self] _, _ in executable })
        }
    }

    private func session(_ source: AgentSource = .claude, id: String = "c1", owner: String? = nil,
                         _ edit: (inout SessionOrigin) -> Void = { _ in }) -> AgentSession {
        var s = AgentSession(id: "\(source.rawValue):\(id)", source: source)
        s.origin.workspace = "/Users/me/code"
        s.origin.ownerBundleID = owner
        edit(&s.origin)
        return s
    }

    private func target(_ bundleID: String) -> OpenTarget {
        Editors.builtIn.first { $0.bundleID == bundleID }!
    }

    private func open(_ bundleID: String, _ s: AgentSession, t3: String? = nil, _ r: Recorder) {
        SourceJumper.open(target(bundleID), folder: s.origin.workspace, session: s, t3EnvironmentID: { t3 }, effects: r.effects)
    }

    // S1
    func testCmuxOpensTheSurface() {
        let r = Recorder()
        open(Editors.cmuxID, session { $0.cmuxWorkspaceID = "w1"; $0.cmuxSurfaceID = "s1" }, r)
        XCTAssertEqual(r.urls, ["cmux://workspace/w1/surface/s1"])
        XCTAssertTrue(r.activated.isEmpty)
    }

    func testCmuxWithoutIdsOnlyActivates() {
        let r = Recorder()
        open(Editors.cmuxID, session { $0.cmuxWorkspaceID = "w1" }, r)
        XCTAssertTrue(r.urls.isEmpty)
        XCTAssertEqual(r.activated, [Editors.cmuxID])
    }

    // S2
    func testT3CodeUsesEnvironmentFileAndThread() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".t3/userdata")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "e1\n".write(to: dir.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Editors.t3EnvironmentID(home: home.path), "e1")

        let r = Recorder()
        open(Editors.t3CodeID, session { $0.t3ThreadID = "t1" }, t3: Editors.t3EnvironmentID(home: home.path), r)
        XCTAssertEqual(r.urls, ["t3code://threads/e1/t1"])
    }

    func testT3CodeWithoutThreadOrEnvironmentOnlyActivates() {
        let r = Recorder()
        open(Editors.t3CodeID, session(), t3: "e1", r)
        open(Editors.t3CodeID, session { $0.t3ThreadID = "t1" }, t3: nil, r)
        XCTAssertTrue(r.urls.isEmpty)
        XCTAssertEqual(r.activated, [Editors.t3CodeID, Editors.t3CodeID])
    }

    // S3
    func testHerdrRunsFocusAsArgvAndActivates() {
        let r = Recorder()
        open(Editors.herdrID, session { $0.herdrTerminalID = "h1" }, r)
        XCTAssertEqual(r.commands, [["/opt/bin/herdr-app", "do", "agent.focus", "--terminal", "h1"]])
        XCTAssertEqual(r.activated, [Editors.herdrID])
    }

    func testHerdrIdWithShellCharactersStaysOneArgument() {
        let r = Recorder()
        open(Editors.herdrID, session { $0.herdrTerminalID = "a b; rm -rf ~ $(x)" }, r)
        XCTAssertEqual(r.commands, [["/opt/bin/herdr-app", "do", "agent.focus", "--terminal", "a b; rm -rf ~ $(x)"]])
    }

    func testHerdrWithoutIdOrProgramOnlyActivates() {
        let r = Recorder()
        open(Editors.herdrID, session(), r)
        r.executable = nil
        open(Editors.herdrID, session { $0.herdrTerminalID = "h1" }, r)
        XCTAssertTrue(r.commands.isEmpty)
        XCTAssertEqual(r.activated, [Editors.herdrID, Editors.herdrID])
    }

    func testHerdrCoreOwnerResolvesToTheApp() {
        let t = Editors.resolve(session: session(owner: Editors.herdrCoreID), openIn: "auto", custom: [],
                                isInstalled: { _ in true }, appName: { _ in nil })
        XCTAssertEqual(t.bundleID, Editors.herdrID)
        XCTAssertNotNil(t.command)
    }

    func testExecutableNameWithSlashIsNeverUsed() {
        // The live finder rejects anything but a bare name, so a session cannot choose the program.
        XCTAssertTrue(Editors.builtIn.compactMap(\.command).allSatisfy { !$0.executable.contains("/") })
    }

    // S4
    func testClaudeDesktopOpensTheSession() {
        let r = Recorder()
        open(Editors.claudeDesktopID, session(.claude, id: "c1"), r)
        XCTAssertEqual(r.urls, ["claude://code/needs-input?session=c1"])
    }

    func testCodexOpensTheThread() {
        let r = Recorder()
        open(Editors.codexID, session(.codex, id: "x1"), r)
        XCTAssertEqual(r.urls, ["codex://threads/x1"])
    }

    func testSessionIdIsEncodedAndAgentSpecific() {
        let r = Recorder()
        open(Editors.codexID, session(.codex, id: "a/b c"), r)
        XCTAssertEqual(r.urls, ["codex://threads/a%2Fb%20c"])
        // A Claude session cannot fill the Codex template.
        open(Editors.codexID, session(.claude, id: "c1"), r)
        XCTAssertEqual(r.urls.count, 1)
        XCTAssertEqual(r.activated, [Editors.codexID])
    }

    func testUnhandledSchemeFallsBackToActivating() {
        let r = Recorder()
        r.handled = false
        open(Editors.cmuxID, session { $0.cmuxWorkspaceID = "w1"; $0.cmuxSurfaceID = "s1" }, r)
        XCTAssertEqual(r.activated, [Editors.cmuxID])
    }

    func testCodexOwnerResolvesToTheCodexTarget() {
        let t = Editors.resolve(session: session(.codex, owner: Editors.codexID), openIn: "auto", custom: [],
                                isInstalled: { _ in true }, appName: { _ in "ChatGPT" })
        XCTAssertEqual(t.name, "Codex")
        XCTAssertEqual(t.bundleID, Editors.codexID)
    }

    func testBuiltInsAreOnlyOfferedWhenInstalled() {
        let names = Editors.available(custom: [], isInstalled: { $0 == Editors.cmuxID }).map(\.name)
        XCTAssertEqual(names, ["cmux"])
    }

    func testCustomTemplateCanUseSessionPlaceholder() {
        let custom = [Config.Editor(name: "X", bundleId: "com.x", urlTemplate: "x://s/{session}?d={cwd}")]
        let r = Recorder()
        SourceJumper.open(Editors.custom(custom)[0], folder: "/a b", session: session(.gemini, id: "g1"), effects: r.effects)
        XCTAssertEqual(r.urls, ["x://s/g1?d=/a%20b"])
    }

    // S5
    func testCaptureKeepsOnlyTheNamedVariables() {
        let origin = AppIDs.capture(env: ["CMUX_WORKSPACE_ID": "w1", "CMUX_SURFACE_ID": "s1", "T3CODE_THREAD_ID": "t1",
                                          "HC_TERMINAL_ID": "h1", "HOME": "/Users/me", "OPENAI_API_KEY": "secret"])
        XCTAssertEqual([origin.cmuxWorkspaceID, origin.cmuxSurfaceID, origin.t3ThreadID, origin.herdrTerminalID],
                       ["w1", "s1", "t1", "h1"])
        let json = String(data: try! JSONEncoder().encode(origin), encoding: .utf8)!
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("/Users/me"))
    }

    func testCaptureRejectsEmptyLongAndControlCharacterValues() {
        XCTAssertNil(AppIDs.clean(""))
        XCTAssertNil(AppIDs.clean(String(repeating: "a", count: 201)))
        XCTAssertNil(AppIDs.clean("a\r\nX-Evil: 1"))
        XCTAssertEqual(AppIDs.clean("a b;c"), "a b;c")
    }

    func testHookScriptForwardsTheFourVariablesAndNotTheEnvironment() {
        let script = HookScript.contents
        for (env, header) in AppIDs.headers {
            XCTAssertTrue(script.contains("${\(env):-}"), env)
            XCTAssertTrue(script.lowercased().contains(header), header)
        }
        XCTAssertFalse(script.contains("printenv"))
        XCTAssertFalse(script.contains("env |"))
    }

    func testStoreKeepsIdsAcrossEventsAndEncodingRoundTrip() throws {
        let store = SessionStore()
        var origin = AppIDs.capture(env: ["CMUX_WORKSPACE_ID": "w1", "CMUX_SURFACE_ID": "s1", "HC_TERMINAL_ID": "h1"])
        origin.workspace = "/Users/me/code"
        store.apply(HookEvent(source: .claude, name: "UserPromptSubmit", payload: ["session_id": "c1"], origin: origin))
        // A later event without the variables does not erase them.
        store.apply(HookEvent(source: .claude, name: "Stop", payload: ["session_id": "c1"], origin: SessionOrigin()))
        let stored = try XCTUnwrap(store.sessions["claude:c1"])
        XCTAssertEqual(stored.origin.cmuxSurfaceID, "s1")
        XCTAssertEqual(stored.origin.herdrTerminalID, "h1")

        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded.origin.cmuxWorkspaceID, "w1")
        XCTAssertEqual(decoded.agentSessionID, "c1")
    }

    func testOldSavedOriginWithoutNewKeysDecodes() throws {
        let json = #"{"workspace":"/x","termProgram":"iTerm.app"}"#
        let origin = try JSONDecoder().decode(SessionOrigin.self, from: Data(json.utf8))
        XCTAssertNil(origin.cmuxWorkspaceID)
    }

    // S6
    func testSessionButtonsAllGoThroughSourceJumper() throws {
        // The row button, the done bubble and the notification call PetController.jump, which calls
        // SourceJumper.jump. This guards against a second opener appearing.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IronPet")
        let pet = try String(contentsOf: root.appendingPathComponent("Pet/PetController.swift"), encoding: .utf8)
        XCTAssertTrue(pet.contains("SourceJumper.jump(to: session)"))
        XCTAssertFalse(pet.contains("NSWorkspace.shared.openApplication"))
    }
}
