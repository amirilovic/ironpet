import Foundation
import QuickJS

/// Runs a script automation: a small JavaScript function `poll(state)` that gets the state it returned last time,
/// may run commands through `sh`, and returns the new state plus what to do next.
///
/// ```js
/// function poll(state) {
///   const out = sh("gh pr list --json number,title,url");
///   const items = JSON.parse(out.stdout);
///   return { state: { seen: items.map(i => i.number) }, actions: [{ type: "alert", id: "1", title: "..." }] };
/// }
/// ```
///
/// The script is not trusted, so everything around it is a limit:
/// - QuickJS runs it in memory. A fresh runtime has no `fetch`, `require`, files, processes, timers or modules.
///   The `std` and `os` modules stay off. The only functions the script gets are `sh` and `console.log`. A script that needs the network runs `curl` through `sh`.
/// - A memory limit and an interrupt handler stop a script that allocates too much or loops forever.
/// - `sh` is synchronous, counts against a call limit, and run with a timeout that cannot pass the time
///   the script has left. Its output is capped. It runs through `HostIO`, so tests replace it.
/// - The script cannot cause a side effect by itself. It returns `actions` (`bubble`, `alert`, `prompt` or `suggest_task`),
///   and the engine carries them out. A `suggest_task` only ever becomes a suggestion the user adds or skips. A script an agent wrote needs approval like a shell command, and that covers what it can return.
/// - State and results are size limited.
enum AutomationScript {
    static let memoryLimit = 32 * 1024 * 1024
    static let defaultDeadline: TimeInterval = 60
    static let maxHostCalls = 8
    static let maxStateBytes = 256 * 1024
    static let maxActions = 20
    static let maxScriptBytes = 64 * 1024
    static let maxLogBytes = 4 * 1024

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    struct Output: Equatable {
        /// The state to pass in next time, as JSON text.
        var state: String
        /// What to do now: `bubble`, `alert`, `prompt` and `suggest_task` actions, in order.
        var actions: [[String: JSONBox]]
        var logs: [String]
    }

    static let actionTypes = ["bubble", "alert", "prompt", "suggest_task"]

    /// A JSON object the script returned, compared by its text so `Output` stays `Equatable`.
    struct JSONBox: Equatable {
        var value: Any
        static func == (a: JSONBox, b: JSONBox) -> Bool { "\(a.value)" == "\(b.value)" }
    }

    /// What `sh` does. Replaced in tests.
    struct HostIO {
        var sh: (_ command: String, _ timeout: TimeInterval) -> CommandResult

        static let system = HostIO(sh: { command, timeout in
            CommandRunner.runBlocking(executable: "/bin/sh", arguments: ["-c", command], timeout: timeout,
                                      environment: CommandRunner.defaultEnvironment(), stdin: nil, maxBytes: CommandRunner.maxOutput)
        })
    }

    /// Runs `poll(state)` off the main thread. `state` is the JSON text the last run returned, or nil on the first run.
    static func run(script: String, state: String?, deadline: TimeInterval = defaultDeadline, host: HostIO = .system) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do { continuation.resume(returning: try runBlocking(script: script, state: state, deadline: deadline, host: host)) } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = stackBytes
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// Checks that the script parses, runs its top level, and defines `poll`. Nothing else runs.
    static func check(_ script: String) -> String? {
        onScriptStack { checkOnThisThread(script) }
    }

    /// QuickJS limits recursion to 1 MiB below the stack pointer of the thread that created the runtime. Dispatch
    /// and Swift concurrency threads have 512 KiB, so a recursive script overflowed the real stack and crashed the
    /// process. Every runtime is created and used on a thread with a stack larger than that limit.
    private static let stackBytes = 8 * 1024 * 1024

    private static func onScriptStack<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = body()
            done.signal()
        }
        thread.stackSize = stackBytes
        thread.start()
        done.wait()
        return result!
    }

    private static func checkOnThisThread(_ script: String) -> String? {
        if script.utf8.count > maxScriptBytes { return "the script is longer than \(maxScriptBytes / 1024) KiB" }
        do {
            let sandbox = try Sandbox(deadline: 2, host: .init(sh: { _, _ in CommandResult(spawnError: "not available while checking") }))
            try sandbox.load(script)
            let kind = try sandbox.evaluate("typeof poll")
            return kind == "function" ? nil : "the script must define a function named poll"
        } catch {
            return error.localizedDescription
        }
    }

    static func runBlocking(script: String, state: String?, deadline: TimeInterval, host: HostIO) throws -> Output {
        guard script.utf8.count <= maxScriptBytes else { throw Failure(message: "the script is longer than \(maxScriptBytes / 1024) KiB") }
        if let state, state.utf8.count > maxStateBytes { throw Failure(message: "the saved state is larger than \(maxStateBytes / 1024) KiB") }
        let sandbox = try Sandbox(deadline: deadline, host: host)
        try sandbox.load(script)
        let input = jsonStringLiteral(state ?? "null")
        let text = try sandbox.evaluate("""
            (() => {
              const result = poll(JSON.parse(\(input)));
              if (result && typeof result.then === 'function') throw new Error('poll must be a plain function, not async');
              return JSON.stringify(result === undefined ? null : result);
            })()
            """)
        guard text.utf8.count <= maxStateBytes * 2 else { throw Failure(message: "poll returned more than \(maxStateBytes * 2 / 1024) KiB") }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) else {
            throw Failure(message: "poll returned something that is not JSON")
        }
        guard let dict = object as? [String: Any] else {
            if object is NSNull { return Output(state: state ?? "null", actions: [], logs: sandbox.logs) }
            throw Failure(message: "poll must return an object like {state, actions}")
        }
        let newState: String
        if let value = dict["state"] {
            newState = String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8), as: UTF8.self)
        } else {
            newState = state ?? "null"
        }
        guard newState.utf8.count <= maxStateBytes else { throw Failure(message: "the new state is larger than \(maxStateBytes / 1024) KiB") }
        var actions: [[String: JSONBox]] = []
        for (index, entry) in ((dict["actions"] as? [Any]) ?? []).prefix(maxActions).enumerated() {
            guard let action = entry as? [String: Any], let type = action["type"] as? String, actionTypes.contains(type) else {
                throw Failure(message: "action \(index + 1) needs a type of \(actionTypes.joined(separator: ", "))")
            }
            actions.append(action.mapValues(JSONBox.init(value:)))
        }
        return Output(state: newState, actions: actions, logs: sandbox.logs)
    }

    /// `text` as a JavaScript string literal.
    private static func jsonStringLiteral(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"null\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// One QuickJS runtime and context for one run, with the limits and the host functions.
    private final class Sandbox {
        private let runtime: JSRuntime
        private let context: JSContext
        private let started = Date()
        private let limit: TimeInterval
        private var calls = 0
        private(set) var logs: [String] = []

        init(deadline: TimeInterval, host: HostIO) throws {
            limit = deadline
            let started = self.started
            var options = JSRuntimeOptions(memoryLimit: AutomationScript.memoryLimit, enableStdModules: false, enableHelpers: false,
                                           interruptHandler: { Date().timeIntervalSince(started) > deadline }, flushJobsAfterEval: true)
            options.enableStdModules = false
            guard let runtime = JSRuntime(options: options), let context = runtime.createContext() else {
                throw Failure(message: "could not start the script engine")
            }
            self.runtime = runtime
            self.context = context
            installHost(host)
        }

        private var remaining: TimeInterval { max(1, limit - Date().timeIntervalSince(started)) }

        private func installHost(_ host: HostIO) {
            func arg(_ context: JSContext, _ argc: Int, _ argv: UnsafeMutablePointer<JSCValue>?, _ index: Int) -> String? {
                guard let argv, index < argc else { return nil }
                return String(context, value: argv[index])
            }
            func reply(_ result: CommandResult) -> String {
                let object: [String: Any] = ["code": result.code.map { Int($0) } as Any? ?? NSNull(), "stdout": result.stdout, "stderr": result.stderr,
                                             "timedOut": result.timedOut, "truncated": result.truncated, "error": result.spawnError as Any? ?? NSNull()]
                return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
            }
            context.module("host") {
                JSModuleFunction("sh", argc: 2) { [unowned self] context, _, argc, argv in
                    guard let command = arg(context, argc, argv, 0) else { return JSError.exception("sh needs a command string") }
                    guard self.calls < AutomationScript.maxHostCalls else { return JSError.exception("too many sh calls in one run (\(AutomationScript.maxHostCalls))") }
                    self.calls += 1
                    let options = (arg(context, argc, argv, 1)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    let timeout = min(max(1, (options["timeoutSeconds"] as? Double) ?? 30), self.remaining)
                    return reply(host.sh(command, timeout))
                }
                JSModuleFunction("log", argc: 1) { [unowned self] context, _, argc, argv in
                    if self.logs.joined().utf8.count < AutomationScript.maxLogBytes, let line = arg(context, argc, argv, 0) { self.logs.append(String(line.prefix(500))) }
                    return nil
                }
            }
        }

        /// Defines `sh` and `console.log`, then the user's script, as a global script.
        func load(_ script: String) throws {
            try evaluateSource("""
                import { sh as __sh, log as __log } from "host";
                const parse = (text) => JSON.parse(text);
                globalThis.sh = (command, options) => parse(__sh(String(command), JSON.stringify(options || {})));
                globalThis.console = { log: (...args) => __log(args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ')) };
                """, type: .module)
            try evaluateSource(script, type: .global)
        }

        private func evaluateSource(_ source: String, type: JSContext.EvalType) throws {
            do { _ = try context.evaluate(source, options: EvalOptions(type: type, filename: type == .global ? "automation.js" : "prelude.js", strict: true)) }
            catch { throw Failure(message: Self.describe(error)) }
        }

        /// Evaluates an expression that gives a string.
        func evaluate(_ expression: String) throws -> String {
            do {
                let value = try context.evaluate(expression, options: EvalOptions(type: .global, filename: "automation.js", strict: true))
                guard let text = value.string else { throw Failure(message: "the script returned no text") }
                return text
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(message: Self.describe(error))
            }
        }

        private static func describe(_ error: Error) -> String {
            switch error as? JSError {
            case .interrupted?: return "the script ran too long and was stopped"
            case .exception(let message)?: return message.contains("interrupted") ? "the script ran too long and was stopped" : message
            case .conversionFailed?: return "the script returned a value that cannot be read"
            case nil: return error.localizedDescription
            }
        }
    }
}
