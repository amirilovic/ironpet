import Foundation

/// One agent from the ACP registry that ironpet can start.
struct ACPAgent: Identifiable, Hashable {
    /// Claude Code, Codex and Pi have no ACP mode of their own. A bundled adapter speaks ACP and drives the user's CLI,
    /// which it finds through the environment variable `pathVariable`.
    struct Helper: Hashable {
        let adapter: String
        let pathVariable: String
    }

    let id: String
    let name: String
    /// The executable the user installed, looked up on the login-shell PATH.
    let command: String
    let args: [String]
    let helper: Helper?

    var viaHelper: Bool { helper != nil }
}

enum AgentCatalog {
    static let all: [ACPAgent] = snapshot

    static func agent(id: String?) -> ACPAgent? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Agents whose executable exists. Native agents are not yet checked against `initialize`; see `ACPProbe`.
    static func present(path: String = LoginShell.path) -> [ACPAgent] {
        all.filter { LoginShell.find($0.command, path: path) != nil }
    }
}

/// The PATH of the user's login shell. A Finder-launched app has a minimal PATH that misses Homebrew and nvm.
enum LoginShell {
    static let path: String = resolve()

    static func resolve() -> String {
        if let forced = ProcessInfo.processInfo.environment["IRONPET_LOGIN_PATH"] { return forced }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "/usr/bin", "/bin"]
        var parts: [String] = []
        if let output = run(shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
            parts = parse(output)
        }
        parts += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        parts += fallback
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The shell prints rc-file noise before and after; the markers pick out the PATH.
    static func parse(_ output: String) -> [String] {
        guard let start = output.range(of: "__IRONPET_PATH_BEGIN__"), let end = output.range(of: "__IRONPET_PATH_END__"),
              start.upperBound <= end.lowerBound else { return [] }
        return output[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
    }

    private static func run(shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", #"printf '__IRONPET_PATH_BEGIN__%s__IRONPET_PATH_END__' "$PATH""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A slow rc file must not stall the app: give the shell five seconds.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    static func find(_ name: String, path: String = LoginShell.path) -> URL? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The environment for agent processes: the user's own, with the login-shell PATH.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }
}
