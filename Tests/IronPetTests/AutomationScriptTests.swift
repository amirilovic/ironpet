import XCTest
@testable import IronPet

final class AutomationScriptTests: XCTestCase {
    private func stub(_ answers: [String: CommandResult] = [:], calls: CallLog = CallLog()) -> AutomationScript.HostIO {
        .init(sh: { command, timeout in
            calls.shell.append((command, timeout))
            return answers[command] ?? CommandResult(code: 0, stdout: "out:\(command)")
        })
    }

    final class CallLog {
        var shell: [(String, TimeInterval)] = []
    }

    private func run(_ script: String, state: String? = nil, deadline: TimeInterval = 10, host: AutomationScript.HostIO? = nil) async throws -> AutomationScript.Output {
        try await AutomationScript.run(script: script, state: state, deadline: deadline, host: host ?? stub())
    }

    func testStateGoesInAndOutAndActionsComeBack() async throws {
        let script = """
            function poll(state) {
              const seen = state ? state.seen : [];
              const now = ["a", "b"].filter(x => !seen.includes(x));
              return { state: { seen: ["a", "b"], runs: (state ? state.runs : 0) + 1 },
                       actions: now.map(id => ({ type: "alert", id, title: "item " + id })).concat([{ type: "prompt", prompt: "why?" }]) };
            }
            """
        let first = try await run(script)
        XCTAssertEqual(first.actions.map { $0["type"]?.value as? String }, ["alert", "alert", "prompt"])
        XCTAssertEqual(first.actions.first?["title"]?.value as? String, "item a")
        let second = try await run(script, state: first.state)
        XCTAssertEqual(second.actions.count, 1, "only the prompt: both alerts were seen")
        XCTAssertTrue(second.state.contains("\"runs\":2"), second.state)
    }

    func testOnlyBubbleAlertAndPromptAreActions() async {
        for bad in ["{type: 'shell', command: 'ls'}", "{type: 'dismiss', id: 1}", "{title: 'no type'}", "'text'"] {
            do {
                _ = try await run("function poll() { return { actions: [\(bad)] }; }")
                XCTFail("\(bad) should be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("needs a type of bubble, alert, prompt"), error.localizedDescription)
            }
        }
    }

    func testShellGoesThroughTheHostAndCarriesTheTimeoutCap() async throws {
        let log = CallLog()
        let host = stub(["echo hi": CommandResult(code: 0, stdout: "hi\n")], calls: log)
        let out = try await run("""
            function poll(state) {
              const r = sh("echo hi", { timeoutSeconds: 5 });
              console.log("got", r.stdout.trim());
              return { state: { out: r.stdout.trim(), code: r.code } };
            }
            """, host: host)
        XCTAssertEqual(log.shell.map(\.0), ["echo hi"])
        XCTAssertEqual(log.shell.first?.1, 5)
        XCTAssertTrue(out.state.contains("\"out\":\"hi\""), out.state)
        XCTAssertEqual(out.logs, ["got hi"])
    }

    func testTheScriptHasNoFetchProcessFileOrModuleAccess() async throws {
        let out = try await run("""
            function poll() {
              const names = ["fetch", "require", "process", "std", "os", "XMLHttpRequest", "setTimeout", "setInterval", "WebSocket", "import", "Deno", "Bun", "scriptArgs", "__sh", "http"];
              return { state: names.filter(n => typeof globalThis[n] !== "undefined") };
            }
            """)
        XCTAssertEqual(out.state, "[]", "these globals exist: \(out.state)")
    }

    func testImportingStdOrOsFails() async {
        for module in ["std", "os", "node:fs"] {
            do {
                _ = try await AutomationScript.run(script: "import * as m from '\(module)'; function poll() { return {}; }", state: nil, deadline: 5, host: stub())
                XCTFail("importing \(module) should fail")
            } catch {}
        }
    }

    func testARunawayLoopIsStopped() async {
        let started = Date()
        do {
            _ = try await run("function poll() { while (true) {} }", deadline: 1)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ran too long"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testAMemoryBombFailsWithoutTakingTheAppDown() async {
        do {
            _ = try await run("function poll() { const a = []; while (true) a.push(new Array(1000000).fill(1)); }", deadline: 20)
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let after = try? await run("function poll() { return { state: 1 }; }")
        XCTAssertEqual(after?.state, "1", "the next run is fine")
    }

    /// Small allocations leave no room at the limit for the error's backtrace. Before the patch in Vendor/QuickJS-Swift this crashed with SIGSEGV.
    func testRunningOutOfMemoryOnSmallObjectsFailsWithoutCrashing() async {
        let scripts = [
            "function poll() { const a = []; while (true) a.push({ x: 1 }); }",
            "function poll() { const a = []; while (true) a.push(new Array(1000).fill(1)); }",
            "function poll() { const a = []; while (true) a.push('x'.repeat(100) + a.length); }",
            "function poll() { let s = 'x'; while (true) s += s; }",
        ]
        for script in scripts {
            for _ in 0..<5 {
                do {
                    _ = try await run(script, deadline: 20)
                    XCTFail("expected a failure for \(script)")
                } catch {
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                }
            }
        }
        let after = try? await run("function poll() { return { state: 1 }; }")
        XCTAssertEqual(after?.state, "1", "the next run is fine")
    }

    func testHostCallsAreLimitedPerRun() async {
        do {
            _ = try await run("function poll() { for (let i = 0; i < 20; i++) sh('true'); return {}; }")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too many"), error.localizedDescription)
        }
    }

    func testAnAsyncPollIsRefusedPlainly() async {
        do {
            _ = try await run("async function poll() { return {}; }")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("plain function"), error.localizedDescription)
        }
    }

    func testErrorsNameTheProblem() async {
        do { _ = try await run("function poll( {"); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        do { _ = try await run("function poll() { throw new Error('boom'); }"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("boom")) }
        do { _ = try await run("function poll() { return 5; }"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("object")) }
        do { _ = try await run("function other() {}"); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testNullResultKeepsTheState() async throws {
        let out = try await run("function poll() {}", state: #"{"keep":1}"#)
        XCTAssertEqual(out.state, #"{"keep":1}"#)
        XCTAssertTrue(out.actions.isEmpty)
    }

    func testSizeLimits() async {
        do {
            _ = try await run("function poll() { return { state: 'x'.repeat(300000) }; }")
            XCTFail("expected a failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("larger"), error.localizedDescription) }
        let many = try? await run("function poll() { return { actions: Array.from({length: 100}, (_, i) => ({ type: 'bubble', title: 'n' + i })) }; }")
        XCTAssertEqual(many?.actions.count, AutomationScript.maxActions)
        XCTAssertNotNil(AutomationScript.check(String(repeating: "a", count: AutomationScript.maxScriptBytes + 1)))
    }

    func testCheckRequiresAPollFunctionAndParses() {
        XCTAssertNil(AutomationScript.check("function poll(state) { return {}; }"))
        XCTAssertNotNil(AutomationScript.check("const x = 1;"))
        XCTAssertNotNil(AutomationScript.check("function poll( {"))
        XCTAssertNotNil(AutomationScript.check("while (true) {}"))
        XCTAssertNotNil(AutomationScript.check("function f(n) { return f(n + 1) + 1; } f(0); function poll() { return {}; }"))
    }

    func testRealShellThroughTheSandbox() async throws {
        let out = try await run("function poll() { const r = sh('echo real'); return { state: r.stdout.trim() }; }", host: .system)
        XCTAssertEqual(out.state, "\"real\"")
    }
}
