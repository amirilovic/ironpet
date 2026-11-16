import Foundation
import QuickJS

/// A thread that runs QuickJS for one rule set. QuickJS measures its C stack against the thread that created the runtime, and
/// Grand Central Dispatch moves a serial queue between worker threads. A runtime used from a different thread than it was built on
/// can see its stack as overflowed, which showed up as a rule failing with no message. Building and calling a runtime only on this one
/// thread avoids that.
final class CaptureRuleThread {
    private final class State {
        let condition = NSCondition()
        var jobs: [() -> Void] = []
        var stopped = false
    }

    private let state = State()

    init() {
        let state = self.state
        let thread = Thread {
            while true {
                state.condition.lock()
                while state.jobs.isEmpty && !state.stopped { state.condition.wait() }
                if state.stopped && state.jobs.isEmpty {
                    state.condition.unlock()
                    return
                }
                let job = state.jobs.removeFirst()
                state.condition.unlock()
                job()
            }
        }
        thread.name = "ironpet.capture.rules"
        thread.qualityOfService = .utility
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
    }

    deinit {
        state.condition.lock()
        state.stopped = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    /// Runs `body` on the thread and returns its result. Must not be called from the thread itself.
    func run<T>(_ body: @escaping () throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        state.condition.lock()
        state.jobs.append {
            result = Result { try body() }
            done.signal()
        }
        state.condition.signal()
        state.condition.unlock()
        done.wait()
        return try result!.get()
    }
}

/// What a rule file declared.
struct CaptureRuleMeta: Equatable {
    var kind = "parser"
    var bundleIds: [String] = []
    var hosts: [String] = []
    var fallback = false
    /// The parser exports `ocrRegions`: it needs text the app draws without exposing it.
    var readsScreen = false
}

/// One QuickJS runtime with the active rules loaded, in the sandbox pattern of `AutomationScript`: a memory limit, an interrupt
/// deadline per call, and no `std`/`os` modules, so a rule has no files, processes or network. The only host functions are the
/// four URL helpers lookback's `_ctx.js` expects (`redact`, `host`, `hostMatches`, `normalize`).
///
/// Rule files are lookback's ES modules. QuickJS-Swift has no module loader for them, so each is loaded as a function body:
/// the leading `export` of a declaration is dropped and the exported names are collected.
final class CaptureVM {
    struct Limits: Equatable {
        /// Wall-clock time for one rule call.
        var timeSeconds: TimeInterval
        var memoryBytes: Int

        static var standard: Limits {
            // Debug builds compile every rule unoptimised, which can pass 100 ms when tests run in parallel.
            #if DEBUG
            return Limits(timeSeconds: 1.0, memoryBytes: 64 * 1024 * 1024)
            #else
            return Limits(timeSeconds: 0.1, memoryBytes: 64 * 1024 * 1024)
            #endif
        }
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The call deadline, shared with the interrupt handler.
    private final class Clock {
        var until: TimeInterval = .infinity
        static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    }

    private let runtime: JSRuntime
    private let context: JSContext
    private let clock = Clock()
    private let limits: Limits

    init(limits: Limits = .standard) throws {
        self.limits = limits
        let clock = self.clock
        let options = JSRuntimeOptions(memoryLimit: limits.memoryBytes, enableStdModules: false, enableHelpers: false,
                                       interruptHandler: { Clock.now > clock.until }, flushJobsAfterEval: true)
        guard let runtime = JSRuntime(options: options), let context = runtime.createContext() else {
            throw Failure(message: "could not start the script engine")
        }
        self.runtime = runtime
        self.context = context
        arm()
        defer { disarm() }
        installHost()
        try run("globalThis.__rules = {};", module: false, filename: "rules.js")
        try run("globalThis.__ctx = (\(BundledCaptureRules.context))(globalThis.__native);", module: false, filename: "_ctx.js")
        try run(Self.invoker, module: false, filename: "invoke.js")
    }

    /// Calls `rules[name][func](JSON.parse(input), ctx)` and returns the JSON of the result. A transform that returns nothing keeps its
    /// possibly mutated argument.
    private static let invoker = """
        globalThis.__invoke = function (name, func, input) {
          const rule = globalThis.__rules[name];
          if (rule === undefined || typeof rule[func] !== "function") throw new Error("rule " + name + " has no function " + func);
          const arg = JSON.parse(input);
          const result = rule[func](arg, globalThis.__ctx);
          if (func === "transform" && result === undefined) return JSON.stringify(arg);
          return result === undefined ? "null" : JSON.stringify(result);
        };
        globalThis.__describe = function (name) {
          const rule = globalThis.__rules[name];
          const fns = {};
          for (const f of ["parse", "check", "transform", "ocrRegions"]) if (typeof rule[f] === "function") fns[f] = true;
          return JSON.stringify({ meta: rule.meta === undefined ? null : rule.meta, fns: fns });
        };
        """

    private func arm() { clock.until = Clock.now + limits.timeSeconds }
    private func disarm() { clock.until = .infinity }

    private func installHost() {
        func text(_ context: JSContext, _ argc: Int, _ argv: UnsafeMutablePointer<JSCValue>?, _ index: Int) -> String {
            guard let argv, index < argc else { return "" }
            return String(context, value: argv[index]) ?? ""
        }
        context.module("host") {
            JSModuleFunction("redact", argc: 1) { context, _, argc, argv in CaptureURL.redact(text(context, argc, argv, 0)) }
            JSModuleFunction("host", argc: 1) { context, _, argc, argv in CaptureURL.host(text(context, argc, argv, 0)) ?? "" }
            JSModuleFunction("hostMatches", argc: 2) { context, _, argc, argv in
                CaptureURL.hostMatches(text(context, argc, argv, 0), text(context, argc, argv, 1)) ? "1" : ""
            }
            JSModuleFunction("normalize", argc: 1) { context, _, argc, argv in CaptureURL.normalize(text(context, argc, argv, 0)) }
        }
        _ = try? context.evaluate("""
            import { redact as __r, host as __h, hostMatches as __m, normalize as __n } from "host";
            globalThis.__native = {
              redact: (s) => __r(String(s)),
              host: (s) => { const h = __h(String(s)); return h === "" ? null : h; },
              hostMatches: (h, p) => __m(String(h), String(p)) === "1",
              normalize: (s) => __n(String(s)),
            };
            """, options: EvalOptions(type: .module, filename: "native.js", strict: true))
    }

    private func run(_ source: String, module: Bool, filename: String) throws {
        do { _ = try context.evaluate(source, options: EvalOptions(type: module ? .module : .global, filename: filename, strict: true)) }
        catch { throw Failure(message: Self.describe(error)) }
    }

    private func string(_ expression: String) throws -> String {
        do {
            let value = try context.evaluate(expression, options: EvalOptions(type: .global, filename: "call.js", strict: true))
            guard let text = value.string else { throw Failure(message: "the rule returned no text") }
            return text
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? JSError {
        case .interrupted?: return "stopped after exceeding the time limit"
        case .exception(let message)?:
            if message.contains("interrupted") { return "stopped after exceeding the time limit" }
            if message.contains("out of memory") { return "stopped after exceeding the memory limit" }
            return message
        case .conversionFailed?: return "the rule returned a value that cannot be read"
        case nil: return error.localizedDescription
        }
    }

    private static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// Declarations a rule file may export.
    private static let exportPattern = try! NSRegularExpression(pattern: "^export (const|let|function|async function)\\b", options: [.anchorsMatchLines])

    /// Evaluates a rule's source, checks its `meta` and registers it by name.
    func load(name: String, source: String) throws -> CaptureRuleMeta {
        let body = Self.exportPattern.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "$1")
        let wrapped = """
            globalThis.__rules[\(Self.literal(name))] = (function () {
            \(body)
            ;return {
              meta: typeof meta === "undefined" ? undefined : meta,
              parse: typeof parse === "function" ? parse : undefined,
              check: typeof check === "function" ? check : undefined,
              transform: typeof transform === "function" ? transform : undefined,
              ocrRegions: typeof ocrRegions === "function" ? ocrRegions : undefined,
            };
            })();
            """
        arm()
        defer { disarm() }
        try run(wrapped, module: false, filename: "\(name).js")
        let described = try string("__describe(\(Self.literal(name)))")
        guard let object = try? JSONSerialization.jsonObject(with: Data(described.utf8)) as? [String: Any],
              let meta = object["meta"] as? [String: Any] else { throw Failure(message: "the rule must export a meta object") }
        guard (meta["api"] as? Double) == 1 else { throw Failure(message: "meta.api must be 1") }
        if let declared = meta["name"] as? String, declared != name {
            throw Failure(message: "meta.name is \"\(declared)\" but the file is called \(name).js")
        }
        let kind = (meta["kind"] as? String) ?? "parser"
        let required: String
        switch kind {
        case "parser": required = "parse"
        case "denylist": required = "check"
        case "transform": required = "transform"
        default: throw Failure(message: "unknown meta.kind \"\(kind)\"")
        }
        let functions = object["fns"] as? [String: Any] ?? [:]
        guard functions[required] != nil else { throw Failure(message: "a \(kind) rule must export a function \(required)") }
        var out = CaptureRuleMeta(kind: kind)
        if let match = meta["match"] as? [String: Any] {
            out.bundleIds = try Self.strings(match["bundleIds"], "bundleIds")
            out.hosts = try Self.strings(match["hosts"], "hosts")
            out.fallback = (match["fallback"] as? Bool) ?? false
        }
        out.readsScreen = kind == "parser" && functions["ocrRegions"] != nil
        return out
    }

    private static func strings(_ value: Any?, _ key: String) throws -> [String] {
        if value == nil || value is NSNull { return [] }
        guard let list = value as? [Any], let strings = list as? [String] else {
            throw Failure(message: "meta.match.\(key) must be an array of strings")
        }
        return strings
    }

    /// Runs `func` of a loaded rule on a JSON argument within the time limit and returns the JSON it gave.
    func invoke(rule: String, function: String, input: String) throws -> String {
        arm()
        defer { disarm() }
        context.setGlobalProperty(name: "__input", value: input)
        return try string("__invoke(\(Self.literal(rule)), \(Self.literal(function)), __input)")
    }
}

/// The rules in force: which file runs under each name and what each declared. Bundled rules are lookback's, copied unchanged. A file
/// of the same name in the user's rules folder replaces the bundled one, and any other file adds a rule.
final class CaptureRuleSet {
    enum Origin: String { case bundled, user }
    enum Status: String { case active, overridden, error }

    struct Info: Equatable {
        var name: String
        var kind: String
        var origin: Origin
        var status: Status
        var error: String?
    }

    struct Entry {
        var name: String
        var origin: Origin
        var source: String
        var meta: CaptureRuleMeta?
        var error: String?
        var active = false
    }

    private(set) var entries: [Entry] = []
    let limits: CaptureVM.Limits
    let folder: URL?

    /// Loads the bundled rules, then the user's. A user file that fails to load is reported and the bundled rule of the same name stays.
    init(folder: URL? = nil, limits: CaptureVM.Limits = .standard) {
        self.limits = limits
        self.folder = folder
        var user: [String: Result<String, Error>] = [:]
        if let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "js" && !url.lastPathComponent.hasPrefix("_") {
                user[url.deletingPathExtension().lastPathComponent] = Result { try String(contentsOf: url, encoding: .utf8) }
            }
        }
        let bundled = Dictionary(uniqueKeysWithValues: BundledCaptureRules.rules.map { ($0.name, $0.source) })
        let thread = CaptureRuleThread()
        let loaded: [Entry] = (try? thread.run {
            var entries: [Entry] = []
            let probe = Result { try CaptureVM(limits: limits) }
            func attempt(_ name: String, _ origin: Origin, _ source: Result<String, Error>) -> Entry {
                var entry = Entry(name: name, origin: origin, source: "")
                switch (probe, source) {
                case (_, .failure(let error)): entry.error = error.localizedDescription
                case (.failure(let error), _): entry.error = error.localizedDescription
                case (.success(let vm), .success(let text)):
                    entry.source = text
                    do { entry.meta = try vm.load(name: name, source: text) } catch { entry.error = error.localizedDescription }
                }
                return entry
            }
            for name in Set(bundled.keys).union(user.keys).sorted() {
                if let source = user[name] {
                    var candidate = attempt(name, .user, source)
                    if candidate.error == nil {
                        candidate.active = true
                        entries.append(candidate)
                        if let text = bundled[name] { entries.append(Entry(name: name, origin: .bundled, source: text)) }
                        continue
                    }
                    entries.append(candidate)
                }
                if let text = bundled[name] {
                    var entry = attempt(name, .bundled, .success(text))
                    entry.active = entry.error == nil
                    entries.append(entry)
                }
            }
            return entries
        }) ?? []
        entries = loaded
    }

    var active: [Entry] { entries.filter(\.active) }

    private func active(ofKind kind: String) -> [Entry] { active.filter { $0.meta?.kind == kind } }

    /// Rule names by kind, in the order they run.
    func names(ofKind kind: String) -> [String] { active(ofKind: kind).map(\.name) }

    func report(runtimeErrors: [String: String] = [:]) -> [Info] {
        entries.map { entry in
            let status: Status
            var error = entry.error
            if entry.error != nil { status = .error } else if !entry.active { status = .overridden } else if let runtime = runtimeErrors[entry.name] {
                status = .error
                error = runtime
            } else { status = .active }
            return Info(name: entry.name, kind: entry.meta?.kind ?? "", origin: entry.origin, status: status, error: error)
        }
    }

    /// The parser for a window: a host match first, then a bundle id match. Nil means only the fallback parser applies.
    func parser(forBundleId bundleId: String, pageURL: String?) -> String? {
        let parsers = active(ofKind: "parser")
        if let host = pageURL.flatMap(CaptureURL.host),
           let hit = parsers.first(where: { $0.meta?.hosts.contains { CaptureURL.hostMatches(host, $0) } ?? false }) { return hit.name }
        return parsers.first { $0.meta?.bundleIds.contains(bundleId) ?? false }?.name
    }

    func readsScreen(_ name: String) -> Bool { active.contains { $0.name == name && ($0.meta?.readsScreen ?? false) } }

    var fallback: String? { active(ofKind: "parser").first { $0.meta?.fallback ?? false }?.name }

    func buildVM() throws -> CaptureVM {
        let vm = try CaptureVM(limits: limits)
        for entry in active {
            do { _ = try vm.load(name: entry.name, source: entry.source) } catch { throw CaptureVM.Failure(message: "\(entry.name): \(error.localizedDescription)") }
        }
        return vm
    }
}

/// A rule set with a runtime built from it, and a record of the latest error of each rule. Calls are serialized, because a QuickJS
/// runtime is not thread safe. The capture pipeline calls from one queue.
///
/// Nothing is loaded until the first call, so with screen capture off no rule is compiled and no thread starts.
final class CaptureRules {
    private let lock = NSLock()
    private let folder: URL?
    private let limits: CaptureVM.Limits
    private var set: CaptureRuleSet?
    private var vm: CaptureVM?
    private var errors: [String: String] = [:]
    private var thread: CaptureRuleThread?

    /// Rules read from `folder` (the user's rules) over the bundled ones, on first use.
    init(folder: URL? = nil, limits: CaptureVM.Limits = .standard) {
        self.folder = folder
        self.limits = limits
    }

    /// A rule set that is already loaded.
    init(set: CaptureRuleSet) {
        folder = set.folder
        limits = set.limits
        self.set = set
    }

    var ruleSet: CaptureRuleSet {
        lock.lock()
        defer { lock.unlock() }
        return loadedSet()
    }

    private func loadedSet() -> CaptureRuleSet {
        if let set { return set }
        let loaded = CaptureRuleSet(folder: folder, limits: limits)
        set = loaded
        return loaded
    }

    /// Replaces the rule set. The runtime is rebuilt on the next call.
    func replace(_ new: CaptureRuleSet) {
        lock.lock()
        defer { lock.unlock() }
        set = new
        vm = nil
        errors = [:]
        // A runtime belongs to the thread that built it, so the old one goes with its thread.
        thread = nil
    }

    func report() -> [CaptureRuleSet.Info] {
        lock.lock()
        defer { lock.unlock() }
        return loadedSet().report(runtimeErrors: errors)
    }

    /// Runs one rule function on a JSON argument. A failure is recorded against the rule and the runtime is dropped, because a stopped
    /// script can leave it in a bad state.
    func invoke(rule: String, function: String, input: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        do {
            let set = loadedSet()
            let current = self.vm
            let runner = thread ?? CaptureRuleThread()
            thread = runner
            let (out, built) = try runner.run { () -> (String, CaptureVM) in
                let vm = try current ?? set.buildVM()
                return (try vm.invoke(rule: rule, function: function, input: input), vm)
            }
            vm = built
            errors[rule] = nil
            return out
        } catch {
            vm = nil
            errors[rule] = error.localizedDescription
            throw error
        }
    }
}
