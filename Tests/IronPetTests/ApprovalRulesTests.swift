import XCTest
@testable import IronPet

final class ApprovalRulesTests: XCTestCase {
    private func policy(_ call: ACPToolCall, auto: Bool = false) -> ApprovalPolicy {
        ApprovalRules.policy(for: call, auto: auto, isMemoryFile: { $0.hasPrefix("/memory/") })
    }

    private func shell(_ command: String, viaTitleOnly: Bool = false) -> ACPToolCall {
        viaTitleOnly ? ACPToolCall(id: "1", title: "`\(command)`", kind: "execute")
                     : ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": command])
    }

    func testAutoModeRunsLsWithoutACardButRmRfStillAsks() {
        XCTAssertEqual(policy(shell("ls ."), auto: true), .allow)
        XCTAssertEqual(policy(shell("rm -rf /tmp/some-dir"), auto: true), .ask(title: "Run a destructive command?", detail: "rm -rf /tmp/some-dir"))
    }

    func testWithoutAutoShellCommandsAsk() {
        XCTAssertEqual(policy(shell("ls .")), .ask(title: "Run this command?", detail: "ls ."))
    }

    func testCommandIsReadFromTheTitleWhenTheAgentSendsNoArguments() {
        // Cursor's permission request has the command only in the title.
        XCTAssertEqual(policy(shell("rm -rf build", viaTitleOnly: true), auto: true),
                       .ask(title: "Run a destructive command?", detail: "rm -rf build"))
        XCTAssertEqual(policy(shell("touch a.txt", viaTitleOnly: true), auto: true), .allow)
    }

    func testDestructivePatterns() {
        for command in ["git push --force origin main", "git reset --hard HEAD~3", "git clean -fd", "psql -c 'DROP TABLE users'",
                        "mkfs.ext4 /dev/disk2", "dd if=/dev/zero of=/dev/disk2", "rm -fr x", "rm -r -f x"] {
            XCTAssertNotEqual(policy(shell(command), auto: true), .allow, command)
        }
        for command in ["git push origin main", "rm file.txt", "git status"] {
            XCTAssertEqual(policy(shell(command), auto: true), .allow, command)
        }
    }

    func testReadOnlyKindsAreAllowed() {
        for kind in ["read", "search", "think", "fetch"] {
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: "x", kind: kind)), .allow, kind)
        }
    }

    func testEditsAskUnlessAutoOrMemoryFile() {
        let edit = ACPToolCall(id: "1", title: "Edit", kind: "edit", rawInput: ["file_path": "/work/app.swift", "new_string": "let a = 1"])
        guard case .ask(let title, let detail) = policy(edit) else { return XCTFail("an edit asks") }
        XCTAssertEqual(title, "Edit app.swift?")
        XCTAssertTrue(detail.contains("/work/app.swift") && detail.contains("let a = 1"))
        XCTAssertEqual(policy(edit, auto: true), .allow)
        let memory = ACPToolCall(id: "2", title: "Edit", kind: "edit", paths: ["/memory/me.md"])
        XCTAssertEqual(policy(memory), .allow)
    }

    func testEditPathComesFromLocations() {
        var call = ACPToolCall(json: ["toolCallId": "9", "title": "Write", "kind": "edit", "locations": [["path": "/work/b.txt"]]])
        XCTAssertEqual(call.path, "/work/b.txt")
        call.merge(["toolCallId": "9", "status": "pending"])
        XCTAssertEqual(call.path, "/work/b.txt", "an update without locations keeps them")
    }

    func testMCPCallsAllowReadOnlyVerbsAndAskForTheRest() {
        let read = ACPToolCall(id: "1", title: "mcp__sentry__search_issues", kind: "other")
        XCTAssertEqual(policy(read), .allow)
        let write = ACPToolCall(id: "2", title: "mcp__db__run_query", kind: "other", rawInput: ["sql": "update t set a=1"])
        guard case .ask(let title, _) = policy(write) else { return XCTFail("a write tool asks") }
        XCTAssertEqual(title, "Use run_query (db)?")
        XCTAssertEqual(policy(write, auto: true), .allow)
        let drop = ACPToolCall(id: "3", title: "mcp__db__run_query", kind: "other", rawInput: ["sql": "DROP TABLE users"])
        guard case .ask(let dropTitle, _) = policy(drop, auto: true) else { return XCTFail("a destructive tool asks even in Auto") }
        XCTAssertTrue(dropTitle.hasPrefix("Run a destructive tool"))
    }

    func testMCPNameFromAgentMetadata() {
        let call = ACPToolCall(json: ["toolCallId": "1", "title": "Query", "kind": "other", "_meta": ["claudeCode": ["toolName": "mcp__langfuse__getHealth"]]])
        XCTAssertEqual(call.mcp?.server, "langfuse")
        XCTAssertEqual(policy(call), .allow)
    }

    func testPermissionOptionsMapToTheDecision() {
        let options: [JSON] = [["optionId": "a1", "kind": "allow_once"], ["optionId": "a2", "kind": "allow_always"],
                               ["optionId": "r1", "kind": "reject_once"]]
        func chosen(_ decision: ApprovalDecision, _ offered: [JSON]) -> String? {
            ((ACPBackend.outcome(decision, options: offered)["outcome"] as? JSON)?["optionId"]) as? String
        }
        XCTAssertEqual(chosen(.allow, options), "a1")
        XCTAssertEqual(chosen(.deny(), options), "r1")
        XCTAssertEqual(chosen(.allow, [["optionId": "x", "kind": "allow_always"]]), "x")
        XCTAssertNil(chosen(.deny(), [["optionId": "a1", "kind": "allow_once"]]), "no reject option offered means cancelled")
        XCTAssertEqual((ACPBackend.outcome(.deny(), options: [])["outcome"] as? JSON)?["outcome"] as? String, "cancelled")
    }

    func testToolSummaries() {
        XCTAssertEqual(shell("npm test").summary, "Ran `npm test`")
        XCTAssertEqual(ACPToolCall(id: "1", title: "", kind: "read", paths: ["/a/b/c.ts"]).summary, "Read c.ts")
        XCTAssertEqual(ACPToolCall(id: "1", title: "", kind: "edit", paths: ["/a/b/c.ts"]).summary, "Edited c.ts")
        XCTAssertEqual(ACPToolCall(id: "1", title: "Do the thing", kind: "other").summary, "Do the thing")
    }
}
