import XCTest
@testable import IronPet

/// Drives tasks and suggestions only through `IronPetAPI`, over an in-memory database.
@MainActor
final class TasksAPITests: XCTestCase {
    private var events: APIEventBus!
    private var seen: [APIEvent] = []
    private var api: IronPetAPI!

    override func setUp() async throws {
        events = APIEventBus()
        seen = []
        events.subscribe { [unowned self] in seen.append($0) }
        api = APITestSupport.makeAPI(events: events)
    }

    func testCreateListAndGet() throws {
        let item = try api.tasks.create(CreateTaskRequest(title: "Write the plan", notes: "Phase 0", source: .chat, by: "user"))
        XCTAssertEqual(item.status, .backlog)
        XCTAssertEqual(api.tasks.list().map(\.id), [item.id])
        let detail = try api.tasks.get(item.id)
        XCTAssertEqual(detail.task.notes, "Phase 0")
        XCTAssertEqual(detail.history.map(\.kind), [.created])
        XCTAssertEqual(detail.history.first?.by, "user")
    }

    func testListFiltersByStatusAndHidesDoneByDefault() throws {
        let open = try api.tasks.create(CreateTaskRequest(title: "Open", source: .user))
        let done = try api.tasks.create(CreateTaskRequest(title: "Done", status: .done, source: .user))
        XCTAssertEqual(api.tasks.list().map(\.id), [open.id])
        XCTAssertEqual(Set(api.tasks.list(TaskListRequest(includeDone: true)).map(\.id)), [open.id, done.id])
        XCTAssertEqual(api.tasks.list(TaskListRequest(statuses: [.done])).map(\.id), [done.id])
    }

    func testUpdateChangesFieldsAndClearsDueAndWaitingOn() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let item = try api.tasks.create(CreateTaskRequest(title: "Send deck", source: .meeting, due: due, waitingOn: "Ana"))
        var change = UpdateTaskRequest(id: item.id)
        change.status = .inProgress
        change.note = "started"
        change.by = "agent:mcp"
        XCTAssertEqual(try api.tasks.update(change).status, .inProgress)

        var clear = UpdateTaskRequest(id: item.id)
        clear.clearDue = true
        clear.waitingOn = ""
        let cleared = try api.tasks.update(clear)
        XCTAssertNil(cleared.due)
        XCTAssertNil(cleared.waitingOn)
        XCTAssertEqual(try api.tasks.get(item.id).history.last?.kind, .edited)
    }

    func testCloseAndDeleteAndMissingIdsAreNotFound() throws {
        let item = try api.tasks.create(CreateTaskRequest(title: "Fix login", source: .chat))
        let closed = try api.tasks.close(CloseTaskRequest(id: item.id, note: "merged"))
        XCTAssertEqual(closed.status, .done)
        try api.tasks.delete(DeleteTaskRequest(id: item.id))
        XCTAssertThrowsError(try api.tasks.get(item.id)) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
        XCTAssertThrowsError(try api.tasks.close(CloseTaskRequest(id: "nope"))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testInvalidTitleIsAnInvalidError() {
        XCTAssertThrowsError(try api.tasks.create(CreateTaskRequest(title: "  ", source: .user))) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalid)
        }
    }

    func testSuggestAcceptAndReject() throws {
        let draft = TaskSuggestion.Draft(key: "mail-1", title: "Reply to Sam", due: nil)
        XCTAssertEqual(api.tasks.suggest(SuggestTaskRequest(draft: draft, kind: .email, sourceRef: "mail:1")).count, 1)
        XCTAssertTrue(api.tasks.suggest(SuggestTaskRequest(draft: draft, kind: .email, sourceRef: "mail:1")).isEmpty, "a repeated key is ignored")
        let other = TaskSuggestion.Draft(key: "mail-2", title: "Book the room", due: nil)
        api.tasks.suggest(SuggestTaskRequest(draft: other, kind: .email, sourceRef: "mail:2"))
        XCTAssertEqual(api.tasks.suggestions.count, 2)

        let reply = try XCTUnwrap(api.tasks.suggestions.first { $0.title == "Reply to Sam" })
        let accepted = try api.tasks.accept(AcceptSuggestionRequest(id: reply.id, status: .needsYou, note: "holds", by: "agent:mcp"))
        XCTAssertEqual(accepted.status, .needsYou)
        XCTAssertEqual(api.tasks.suggestions.count, 1)

        let room = try XCTUnwrap(api.tasks.suggestions.first)
        try api.tasks.reject(RejectSuggestionRequest(id: room.id, note: "duplicate"))
        XCTAssertTrue(api.tasks.suggestions.isEmpty)
        XCTAssertThrowsError(try api.tasks.accept(AcceptSuggestionRequest(id: room.id))) { XCTAssertEqual(($0 as? APIError)?.code, .notFound) }
    }

    func testAcceptAllAndSkip() {
        for key in ["a", "b", "c"] {
            api.tasks.suggest(SuggestTaskRequest(draft: .init(key: key, title: "Task \(key)", due: nil), kind: .email, sourceRef: key))
        }
        api.tasks.skip(api.tasks.suggestions[0].id)
        api.tasks.acceptAll()
        XCTAssertTrue(api.tasks.suggestions.isEmpty)
        XCTAssertEqual(api.tasks.list().count, 2)
    }

    func testLabelsAreSetFilteredAddedAndRemovedThroughTheAPI() throws {
        let a = try api.tasks.create(CreateTaskRequest(title: "Merge it", source: .agent, labels: ["merge": "auto", "repo": "band"]))
        _ = try api.tasks.create(CreateTaskRequest(title: "Other", source: .agent, labels: ["merge": "manual"]))
        XCTAssertEqual(api.tasks.list(TaskListRequest(labels: ["merge": "auto"])).map(\.id), [a.id])
        XCTAssertEqual(api.tasks.list(TaskListRequest(labels: ["merge": "auto", "repo": "web"])).count, 0)
        let changed = try api.tasks.update(UpdateTaskRequest(id: a.id, labels: ["ci": "green"], removeLabels: ["repo"]))
        XCTAssertEqual(changed.labels, ["merge": "auto", "ci": "green"])
        let untouched = try api.tasks.update(UpdateTaskRequest(id: a.id, title: "Merge it now"))
        XCTAssertEqual(untouched.labels, changed.labels, "other changes keep labels")
        XCTAssertTrue(api.tasks.allLabels.contains { $0.key == "ci" && $0.value == "green" })
        let tooMany = Dictionary(uniqueKeysWithValues: (0..<21).map { ("k\($0)", "v") })
        XCTAssertThrowsError(try api.tasks.create(CreateTaskRequest(title: "Many", source: .agent, labels: tooMany))) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalid)
        }
    }

    func testChangesArriveOnTheEventBus() throws {
        let item = try api.tasks.create(CreateTaskRequest(title: "Watch events", source: .user))
        try api.tasks.close(CloseTaskRequest(id: item.id, note: "x"))
        api.tasks.suggest(SuggestTaskRequest(draft: .init(key: "k", title: "Suggested", due: nil), kind: .pr, sourceRef: "pr:1"))
        XCTAssertEqual(seen.map(\.kind), [.tasksChanged, .tasksChanged, .suggestionsChanged])
        XCTAssertEqual(seen.first?.id, item.id)
        XCTAssertEqual(seen.map(\.seq), [1, 2, 3])
    }

    func testRequestsAndResponsesRoundTripAsJSON() throws {
        let item = try api.tasks.create(CreateTaskRequest(title: "Round trip", source: .cli, links: [TaskLink(kind: .url, ref: "https://example.com", label: nil)]))
        let detail = try api.tasks.get(item.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TaskWithHistory.self, from: encoder.encode(detail))
        XCTAssertEqual(back.task.id, detail.task.id)
        XCTAssertEqual(back.task.links, detail.task.links)
        let request = UpdateTaskRequest(id: item.id, title: "Renamed", clearDue: true)
        XCTAssertEqual(try decoder.decode(UpdateTaskRequest.self, from: encoder.encode(request)), request)
    }

    func testJSONAdapterGoesThroughTheAPI() throws {
        let created = TaskJSON.call(api.tasks, "create", ["title": "Via MCP", "origin": ["kind": "agent", "ref": "s1", "reason": "asked"]], by: "agent:mcp")
        guard case .success(let value) = created, let object = value as? [String: Any], let id = object["id"] as? String else { return XCTFail("\(created)") }
        XCTAssertEqual(try api.tasks.get(id).task.title, "Via MCP")
        XCTAssertEqual(try api.tasks.get(id).history.first?.by, "agent:mcp")
        guard case .failure(let error) = TaskJSON.call(api.tasks, "close", ["id": id], by: "agent:mcp") else { return XCTFail("closed without a note") }
        XCTAssertTrue(error.message.contains("note is required"))
    }
}
