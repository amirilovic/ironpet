import Foundation

/// A failure a route reports. `message` is the API's or the validator's text, unchanged.
struct RemoteFailure: Error, Equatable {
    var status: Int
    var code: String
    var message: String

    static func invalid(_ message: String) -> RemoteFailure { RemoteFailure(status: 400, code: "invalid", message: message) }

    /// The HTTP status for an API error code.
    static func status(for code: APIError.Code) -> Int {
        switch code {
        case .notFound: return 404
        case .invalid: return 400
        case .conflict: return 409
        case .unavailable: return 503
        case .failed: return 500
        }
    }

    init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// Turns what a call to `IronPetAPI` throws into a failure.
    init(_ error: Error) {
        if let failure = error as? RemoteFailure {
            self = failure
        } else if let task = error as? TaskError {
            self.init(status: 400, code: APIError.Code.invalid.rawValue, message: task.message)
        } else {
            let api = APIError.wrap(error)
            self.init(status: Self.status(for: api.code), code: api.code.rawValue, message: api.message)
        }
    }
}

/// The task and suggestion routes, as calls on `IronPetAPI`. They take and return JSON objects with the same keys as the MCP tools and the
/// `IronPet tasks` command (snake_case, ISO 8601 dates). The device is the author, so each task event says `remote:<device id>`.
@MainActor
struct RemoteTasks {
    let api: IronPetAPI
    /// `remote:<device id>`, written to the history of every change.
    let by: String

    private var tasks: TasksAPI { api.tasks }

    private func available() throws {
        if let reason = tasks.unavailable { throw RemoteFailure(status: 503, code: "unavailable", message: DatabaseNotice.toolError(reason)) }
    }

    // MARK: Tasks

    /// `status` (comma separated or repeated), `include_done` and `label` (`key:value`, repeated).
    func list(query: [String: [String]]) throws -> [String: Any] {
        try available()
        var request = TaskListRequest()
        let given: [String] = query["status"] ?? []
        var statuses: [String] = []
        for value in given { statuses += value.split(separator: ",").map(String.init) }
        if !statuses.isEmpty { request.statuses = try statuses.map { try TaskValidator.status($0) } }
        request.includeDone = ["1", "true"].contains(query["include_done"]?.first ?? "")
        var labels: [String: Any] = [:]
        for pair in query["label"] ?? [] {
            guard let colon = pair.firstIndex(of: ":") else { throw RemoteFailure.invalid("label must be key:value") }
            labels[String(pair[..<colon])] = String(pair[pair.index(after: colon)...])
        }
        request.labels = try TaskValidator.labels(labels)
        return ["tasks": tasks.list(request).map(TaskJSON.json)]
    }

    func get(_ id: String) throws -> [String: Any] {
        try available()
        let detail = try tasks.get(id)
        var object = TaskJSON.json(detail.task)
        object["history"] = detail.history.map(TaskJSON.json)
        return object
    }

    func create(_ args: [String: Any]) throws -> [String: Any] {
        try available()
        let status = try args["status"].map { $0 is NSNull ? TaskStatus.backlog : try TaskValidator.status($0) } ?? .backlog
        let item = try tasks.create(CreateTaskRequest(
            title: try TaskValidator.title(args["title"]), notes: try TaskValidator.notes(args["notes"]), status: status,
            source: try TaskValidator.source(args["source"], default: .user), due: try TaskValidator.due(args["due"]),
            links: try TaskValidator.links(args["links"]), waitingOn: try TaskValidator.waitingOn(args["waiting_on"]),
            sourceRef: nil, labels: try TaskValidator.labels(args["labels"]), by: by))
        return TaskJSON.json(item)
    }

    func update(_ id: String, _ args: [String: Any]) throws -> [String: Any] {
        try available()
        let current = try tasks.get(id).task
        var request = UpdateTaskRequest(id: current.id, by: by)
        request.title = try args["title"].map { try TaskValidator.title($0) }
        request.notes = try args["notes"].map { try TaskValidator.notes($0) }
        request.status = try args["status"].map { try TaskValidator.status($0) }
        if args.keys.contains("due") {
            request.due = try TaskValidator.due(args["due"])
            request.clearDue = request.due == nil
        }
        request.links = try args["links"].map { try TaskValidator.links($0) }
        request.labels = try TaskValidator.labels(args["labels"])
        request.removeLabels = try TaskValidator.labelKeys(args["remove_labels"])
        if args.keys.contains("waiting_on") { request.waitingOn = try TaskValidator.waitingOn(args["waiting_on"]) ?? "" }
        request.note = try args["note"].map { try TaskValidator.notes($0) }
        return TaskJSON.json(try tasks.update(request))
    }

    /// Closing needs a note that says what shows the task is done, as it does for an agent.
    func close(_ id: String, _ args: [String: Any]) throws -> [String: Any] {
        try available()
        let target = try tasks.get(id).task
        let note = try TaskJSON.requiredNote(args["note"], for: "say what shows the task is done")
        return TaskJSON.json(try tasks.close(CloseTaskRequest(id: target.id, note: note, by: by)))
    }

    func delete(_ id: String) throws -> [String: Any] {
        try available()
        let item = try tasks.get(id).task
        try tasks.delete(DeleteTaskRequest(id: item.id, by: by))
        return ["deleted": item.id]
    }

    // MARK: Suggestions

    func suggestions() throws -> [String: Any] {
        try available()
        return ["suggestions": tasks.suggestions.map(TaskJSON.json)]
    }

    func accept(_ id: String, _ args: [String: Any]) throws -> [String: Any] {
        try available()
        var request = AcceptSuggestionRequest(id: id, by: by)
        if let raw = args["title"], !(raw is NSNull) { request.title = try TaskValidator.title(raw) }
        if let raw = args["due"], !(raw is NSNull) { request.due = try TaskValidator.due(raw) }
        if let raw = args["notes"], !(raw is NSNull) { request.notes = try TaskValidator.notes(raw) }
        if let raw = args["status"], !(raw is NSNull) { request.status = try TaskValidator.status(raw) }
        request.note = try args["note"].map { try TaskValidator.notes($0) }
        return TaskJSON.json(try tasks.accept(request))
    }

    func reject(_ id: String, _ args: [String: Any]) throws -> [String: Any] {
        try available()
        try tasks.reject(RejectSuggestionRequest(id: id, note: try args["note"].map { try TaskValidator.notes($0) }, by: by))
        return ["rejected": id]
    }
}
