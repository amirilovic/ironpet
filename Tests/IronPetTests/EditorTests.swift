import XCTest
@testable import IronPet

final class EditorTests: XCTestCase {
    private func session(owner: String? = nil, iterm: String? = nil) -> AgentSession {
        var s = AgentSession(id: "claude:1", source: .claude)
        s.origin.workspace = "/Users/me/code"
        s.origin.ownerBundleID = owner
        s.origin.itermSessionID = iterm
        return s
    }

    private func resolve(_ s: AgentSession, openIn: String = "auto", custom: [Config.Editor] = [],
                         installed: Set<String> = [Editors.cursorID, Editors.finderID]) -> OpenTarget {
        Editors.resolve(session: s, openIn: openIn, custom: custom, isInstalled: { installed.contains($0) },
                        appName: { $0 == "com.apple.Terminal" ? "Terminal" : nil })
    }

    func testProcessWalkFindsBandThroughNode() {
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        let paths: [Int32: String] = [300: "/usr/local/bin/claude", 200: "/usr/local/bin/node",
                                      100: "/Applications/Band.app/Contents/MacOS/Band"]
        let id = ProcessTree.owningBundleID(pid: 300, parent: { parents[$0] }, executablePath: { paths[$0] },
                                            bundleID: { $0 == "/Applications/Band.app" ? "app.getband.agent" : nil })
        XCTAssertEqual(id, "app.getband.agent")
    }

    func testProcessWalkUsesOutermostApp() {
        XCTAssertEqual(ProcessTree.appBundlePath(in: "/Applications/Band.app/Contents/Frameworks/Band Helper.app/Contents/MacOS/x"),
                       "/Applications/Band.app")
    }

    func testProcessWalkWithoutAppIsNil() {
        let parents: [Int32: Int32] = [30: 20, 20: 1]
        XCTAssertNil(ProcessTree.owningBundleID(pid: 30, parent: { parents[$0] }, executablePath: { _ in "/bin/zsh" },
                                                bundleID: { _ in "x" }))
    }

    func testProcessWalkForExitedProcessIsNil() {
        XCTAssertNil(ProcessTree.owningBundleID(pid: 999999, parent: { _ in nil }, executablePath: { _ in nil }))
    }

    func testAutoUsesOwningAppFromTable() {
        let t = resolve(session(owner: "app.getband.agent"))
        XCTAssertEqual(t.name, "Band")
    }

    func testAutoWithUnknownOwnerUsesItsName() {
        let t = resolve(session(owner: "com.apple.Terminal"))
        XCTAssertEqual(t.name, "Terminal")
        XCTAssertNil(t.urlTemplate)
    }

    func testAutoKeepsItermWhenSessionKnown() {
        XCTAssertEqual(resolve(session(owner: "app.getband.agent", iterm: "w0t0p0:abc")).name, "iTerm")
    }

    func testAutoWithoutOwnerFallsBackToCursor() {
        XCTAssertEqual(resolve(session()).name, "Cursor")
    }

    func testFallbackIsFinderWhenCursorMissing() {
        XCTAssertEqual(resolve(session(), installed: [Editors.finderID]).name, "Finder")
    }

    func testFixedChoiceOverridesAuto() {
        let t = resolve(session(owner: "app.getband.agent", iterm: "x"), openIn: "dev.zed.Zed",
                        installed: ["dev.zed.Zed", Editors.cursorID])
        XCTAssertEqual(t.name, "Zed")
    }

    func testFixedChoiceThatIsNotInstalledFallsBackToAuto() {
        XCTAssertEqual(resolve(session(owner: "app.getband.agent"), openIn: "dev.zed.Zed").name, "Band")
    }

    func testPickerListsOnlyInstalledBuiltInsPlusCustom() {
        let custom = [Config.Editor(name: "My IDE", bundleId: "com.x.ide", urlTemplate: "myide://open?path={cwd}")]
        let installed: Set<String> = [Editors.cursorID, "dev.zed.Zed", Editors.finderID]
        let names = Editors.available(custom: custom, isInstalled: { installed.contains($0) }).map(\.name)
        XCTAssertEqual(names, ["Cursor", "Zed", "Finder", "My IDE"])
    }

    func testCustomEntryNeedsNoInstallCheckAndWinsOverBuiltIn() {
        let custom = [Config.Editor(name: "Zed Preview", bundleId: "dev.zed.Zed", urlTemplate: nil)]
        let list = Editors.available(custom: custom, isInstalled: { _ in true })
        XCTAssertEqual(list.filter { $0.bundleID == "dev.zed.Zed" }.map(\.name), ["Zed Preview"])
    }

    func testTemplateEncodesSpacesUnicodeAndHash() {
        XCTAssertEqual(Editors.expand("myide://open?path={cwd}", cwd: "/Users/me/my proj/café #1"),
                       "myide://open?path=/Users/me/my%20proj/caf%C3%A9%20%231")
    }

    func testTemplateAfterSlashDropsDoubleSlash() {
        XCTAssertEqual(Editors.expand("zed://file/{cwd}", cwd: "/Users/me/x"), "zed://file/Users/me/x")
    }

    func testConfigWithoutNewKeysStillLoads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"pet":{"name":"Rex"}}"#.write(to: file, atomically: true, encoding: .utf8)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertEqual(config.openIn, "auto")
        XCTAssertEqual(config.editors, [])
    }

    func testConfigReadsCustomEditors() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{"openIn":"com.x.ide","editors":[{"name":"My IDE","bundleId":"com.x.ide"}]}"#.write(to: file, atomically: true, encoding: .utf8)
        let (config, error) = Config.load(from: file)
        XCTAssertNil(error)
        XCTAssertEqual(config.editors, [Config.Editor(name: "My IDE", bundleId: "com.x.ide", urlTemplate: nil)])
        XCTAssertEqual(config.openIn, "com.x.ide")
    }
}
