import CryptoKit
import Foundation

/// What runs the bundled adapter `.mjs` files: the user's Node, or a Bun that ironpet downloaded on request.
struct ACPRuntime {
    enum Kind: Equatable { case node, bun }
    let kind: Kind
    let executable: URL

    /// The adapters' `engines` field: the Claude adapter needs Node 22, pi-acp needs 20.
    static func minimumNodeMajor(adapter: String) -> Int { adapter == "pi" ? 20 : 22 }

    static func nodeMajor(fromVersionOutput output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("v") else { return nil }
        return Int(text.dropFirst().prefix { $0.isNumber })
    }

    /// The user's `node` if it is new enough, else a Bun downloaded earlier, else nil.
    static func resolve(adapter: String, path: String = LoginShell.path, bun: URL = BunRuntime.executable) -> ACPRuntime? {
        if let node = LoginShell.find("node", path: path), let major = major(of: node), major >= minimumNodeMajor(adapter: adapter) {
            return ACPRuntime(kind: .node, executable: node)
        }
        if FileManager.default.isExecutableFile(atPath: bun.path) { return ACPRuntime(kind: .bun, executable: bun) }
        return nil
    }

    private static func major(of node: URL) -> Int? {
        let process = Process()
        process.executableURL = node
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return nodeMajor(fromVersionOutput: String(decoding: data, as: UTF8.self))
    }

    /// Where the bundled adapters live: `IronPet.app/Contents/Resources/acp`, or `sidecar/out` when run from a checkout.
    static func adapterFile(_ adapter: String) -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["IRONPET_ACP_DIR"] { candidates.append(URL(fileURLWithPath: override)) }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("acp")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("sidecar/out"))
        return candidates.map { $0.appendingPathComponent("\(adapter).mjs") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Bun, downloaded once into `~/.ironpet/runtime` after the user allows it.
enum BunRuntime {
    static let version = "1.4.4"
    static let sizeDescription = "about 40 MB"

    enum Failure: LocalizedError {
        case checksumMissing(String)
        case checksumMismatch
        case unpackFailed(String)

        var errorDescription: String? {
            switch self {
            case .checksumMissing(let file): return "The Bun release has no checksum for \(file), so ironpet did not use it."
            case .checksumMismatch: return "The Bun download did not match its published checksum, so ironpet did not use it."
            case .unpackFailed(let why): return "Could not unpack Bun: \(why)"
            }
        }
    }

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["IRONPET_RUNTIME_DIR"] { return URL(fileURLWithPath: override) }
        return Paths.root.appendingPathComponent("runtime")
    }

    static var executable: URL { directory.appendingPathComponent("bun") }

    static var assetName: String {
        #if arch(arm64)
        return "bun-darwin-aarch64.zip"
        #else
        return "bun-darwin-x64.zip"
        #endif
    }

    static func releaseURL(_ file: String) -> URL {
        URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v\(version)/\(file)")!
    }

    /// `SHASUMS256.txt` lines look like `<64 hex digits>  <file>`.
    static func expectedChecksum(in shasums: String, file: String) -> String? {
        for line in shasums.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == file { return String(fields[0]).lowercased() }
        }
        return nil
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads Bun, checks it against the release's `SHASUMS256.txt`, then unpacks it. Nothing is written to `directory`
    /// unless the checksum matches.
    static func install(directory: URL = BunRuntime.directory, asset: String = BunRuntime.assetName,
                        fetch: (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }) async throws {
        let shasums = String(decoding: try await fetch(releaseURL("SHASUMS256.txt")), as: UTF8.self)
        guard let expected = expectedChecksum(in: shasums, file: asset) else { throw Failure.checksumMissing(asset) }
        let archive = try await fetch(releaseURL(asset))
        guard sha256(archive) == expected else { throw Failure.checksumMismatch }
        try unpack(archive, asset: asset, into: directory)
    }

    private static func unpack(_ archive: Data, asset: String, into directory: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ironpet-bun-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent(asset)
        try archive.write(to: zip)
        let unpacked = work.appendingPathComponent("out")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let folder = asset.replacingOccurrences(of: ".zip", with: "")
        let bun = unpacked.appendingPathComponent(folder).appendingPathComponent("bun")
        guard fm.isExecutableFile(atPath: bun.path) else { throw Failure.unpackFailed("the archive has no bun executable") }
        // The checksum has passed, so the download is the release Oven published. Clear the quarantine flag.
        _ = try? run("/usr/bin/xattr", ["-d", "com.apple.quarantine", bun.path])
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("bun")
        try? fm.removeItem(at: target)
        try fm.moveItem(at: bun, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Failure.unpackFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }
}
