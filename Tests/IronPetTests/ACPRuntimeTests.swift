import XCTest
@testable import IronPet

final class ACPRuntimeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ironpet-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Bun download

    /// A zip like Bun's release: `bun-darwin-aarch64/bun`.
    private func makeArchive(asset: String, script: String = "#!/bin/sh\necho 1.4.4\n") throws -> Data {
        let folder = asset.replacingOccurrences(of: ".zip", with: "")
        let source = dir.appendingPathComponent("src/\(folder)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try script.write(to: source.appendingPathComponent("bun"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("bun").path)
        let zip = dir.appendingPathComponent(asset)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func fetcher(archive: Data, shasums: String) -> (URL) async throws -> Data {
        { url in url.lastPathComponent == "SHASUMS256.txt" ? Data(shasums.utf8) : archive }
    }

    func testInstallsWhenTheChecksumMatches() async throws {
        let asset = "bun-darwin-aarch64.zip"
        let archive = try makeArchive(asset: asset)
        let shasums = "\(String(repeating: "0", count: 64))  other.zip\n\(BunRuntime.sha256(archive))  \(asset)\n"
        let target = dir.appendingPathComponent("runtime")
        try await BunRuntime.install(directory: target, asset: asset, fetch: fetcher(archive: archive, shasums: shasums))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("bun").path))
    }

    func testATamperedDownloadIsRejectedAndNothingIsWritten() async throws {
        let asset = "bun-darwin-aarch64.zip"
        let archive = try makeArchive(asset: asset)
        let shasums = "\(BunRuntime.sha256(archive))  \(asset)\n"
        var tampered = archive
        tampered.append(0x00)
        let target = dir.appendingPathComponent("runtime")
        do {
            try await BunRuntime.install(directory: target, asset: asset, fetch: fetcher(archive: tampered, shasums: shasums))
            XCTFail("a tampered archive must not install")
        } catch BunRuntime.Failure.checksumMismatch {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing is written before the checksum passes")
    }

    func testAMissingChecksumLineIsRejected() async throws {
        let asset = "bun-darwin-aarch64.zip"
        let archive = try makeArchive(asset: asset)
        do {
            try await BunRuntime.install(directory: dir.appendingPathComponent("runtime"), asset: asset,
                                         fetch: fetcher(archive: archive, shasums: "\(BunRuntime.sha256(archive))  something-else.zip\n"))
            XCTFail("an unlisted file must not install")
        } catch BunRuntime.Failure.checksumMissing {
        }
    }

    func testAFailedDownloadInstallsNothing() async {
        struct Offline: Error {}
        let target = dir.appendingPathComponent("runtime")
        do {
            try await BunRuntime.install(directory: target, asset: "bun-darwin-aarch64.zip", fetch: { _ in throw Offline() })
            XCTFail("expected a failure")
        } catch is Offline {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testChecksumLineParsing() {
        let text = "aaa  bun-darwin-aarch64-profile.zip\nBBB  bun-darwin-aarch64.zip\nccc *bun-linux-x64.zip\n"
        XCTAssertEqual(BunRuntime.expectedChecksum(in: text, file: "bun-darwin-aarch64.zip"), "bbb")
        XCTAssertEqual(BunRuntime.expectedChecksum(in: text, file: "bun-linux-x64.zip"), "ccc")
        XCTAssertNil(BunRuntime.expectedChecksum(in: text, file: "bun-darwin-x64.zip"))
    }

    func testReleaseURLsPointAtOvensGitHubRelease() {
        XCTAssertEqual(BunRuntime.releaseURL("SHASUMS256.txt").absoluteString,
                       "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/SHASUMS256.txt")
    }

    // MARK: Runtime choice

    private func fakeNode(version: String, in folder: String) throws -> String {
        let bin = dir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try "#!/bin/sh\necho \(version)\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return bin.path
    }

    func testUsesTheUsersNodeWhenItIsNewEnough() throws {
        let path = try fakeNode(version: "v22.21.1", in: "n22")
        let runtime = ACPRuntime.resolve(adapter: "claude", path: path, bun: dir.appendingPathComponent("no-bun"))
        XCTAssertEqual(runtime?.kind, .node)
    }

    func testOldNodeFallsBackToDownloadedBunThenToNothing() throws {
        let path = try fakeNode(version: "v20.11.0", in: "n20")
        let bun = dir.appendingPathComponent("bun")
        XCTAssertNil(ACPRuntime.resolve(adapter: "claude", path: path, bun: bun), "Node 20 is too old for the Claude adapter")
        XCTAssertEqual(ACPRuntime.resolve(adapter: "pi", path: path, bun: bun)?.kind, .node, "pi-acp accepts Node 20")
        try "#!/bin/sh\n".write(to: bun, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bun.path)
        XCTAssertEqual(ACPRuntime.resolve(adapter: "claude", path: path, bun: bun)?.kind, .bun)
    }

    func testNodeVersionParsing() {
        XCTAssertEqual(ACPRuntime.nodeMajor(fromVersionOutput: "v26.10.0\n"), 26)
        XCTAssertNil(ACPRuntime.nodeMajor(fromVersionOutput: "not node"))
    }

    // MARK: Catalog and PATH

    func testLoginShellPathParsingIgnoresRcFileNoise() {
        let output = "Welcome back!\n__IRONPET_PATH_BEGIN__/Users/a/.nvm/versions/node/v22/bin:/opt/homebrew/bin__IRONPET_PATH_END__\nbye"
        XCTAssertEqual(LoginShell.parse(output), ["/Users/a/.nvm/versions/node/v22/bin", "/opt/homebrew/bin"])
        XCTAssertEqual(LoginShell.parse("no markers"), [])
    }

    func testExecutablesAreFoundOnTheGivenPath() throws {
        let bin = try fakeNode(version: "v1", in: "nvm/bin")
        XCTAssertEqual(LoginShell.find("node", path: "/nowhere:\(bin)")?.path, "\(bin)/node")
        XCTAssertNil(LoginShell.find("codex", path: "/nowhere:\(bin)"))
    }

    func testCatalogHasTheAgentsTheBriefNames() {
        let byID = Dictionary(uniqueKeysWithValues: AgentCatalog.all.map { ($0.id, $0) })
        XCTAssertEqual(byID["cursor"]?.command, "cursor-agent")
        XCTAssertEqual(byID["cursor"]?.args, ["acp"])
        XCTAssertEqual(byID["gemini"]?.args, ["--acp"])
        XCTAssertEqual(byID["opencode"]?.args, ["acp"])
        XCTAssertEqual(byID["claude"]?.helper, ACPAgent.Helper(adapter: "claude", pathVariable: "CLAUDE_CODE_EXECUTABLE"))
        XCTAssertEqual(byID["codex"]?.helper, ACPAgent.Helper(adapter: "codex", pathVariable: "CODEX_PATH"))
        XCTAssertEqual(byID["pi"]?.helper, ACPAgent.Helper(adapter: "pi", pathVariable: "PI_ACP_PI_COMMAND"))
        XCTAssertEqual(Set(AgentCatalog.all.map(\.id)).count, AgentCatalog.all.count, "ids are unique")
    }
}
