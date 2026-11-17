import Foundation

/// The question wording for the local decision model. It follows the evaluation in
/// `lookback/chore/decision-model-eval/eval/decisions/questions.py`, which found that the 4B decision models catch secrets (Q4) and match
/// related tasks (Q3 related) well, and are weak on follow-ups (Q1) and new tasks (Q3 new), so those still go to the larger model.
enum CaptureQuestions {
    static let followUp = "The text contains a follow-up item: something the user still has to do, answer or deliver, or a request addressed to the user that is not yet done."
    static let calendar = "The text mentions a calendar event: a meeting, call, appointment, or a date and time to be somewhere."
    static let newTask = "The text contains a task for the user that is not already covered by any task in existing_tasks."
    static func related(_ task: String) -> String { "The text is about or affects this existing task: \(task)" }
    static let sensitive = "The text contains sensitive information: an actual password, API key, token, private key, secret, one-time code, PIN, or a full card or bank account number (IBAN). Only mentioning that a password exists does not count. Text marked [redacted:...] has already had its secrets removed, so judge only what is left."
}

/// How the app reaches the local model. The two APIs answer the same questions; only H2O's gives probabilities.
protocol CaptureDecisionClient {
    /// The probability that each question's answer is yes.
    func probabilities(text: String, existingTasks: [String: String], questions: [(name: String, instructions: String)]) async throws -> [String: Double]
}

struct CaptureDecisionError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The local model must run on this Mac. A host that is not the loopback address is refused before any request, because captured text
/// would otherwise leave the Mac through a setting.
enum CaptureDecisionEndpoint {
    static func validate(_ baseURL: String) -> Result<URL, CaptureDecisionError> {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), let url = components.url else {
            return .failure(.init(message: "No local decision model is set. Captures stay on this Mac."))
        }
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
            return .failure(.init(message: "The decision model must run on this Mac (localhost or 127.0.0.1), not \(host). Captures stay on this Mac."))
        }
        return .success(url)
    }
}

/// H2O-Lightning-4B's `/v1/systemone`: one request holds a state and several typed yes/no questions.
struct SystemOneDecisionClient: CaptureDecisionClient {
    var baseURL: URL
    var session: URLSession = .shared
    var timeout: TimeInterval = 60

    func probabilities(text: String, existingTasks: [String: String], questions: [(name: String, instructions: String)]) async throws -> [String: Double] {
        let state: Any = existingTasks.isEmpty ? text : ["text": text, "existing_tasks": existingTasks]
        var typed: [String: Any] = [:]
        for q in questions { typed[q.name] = ["type": "noul", "instructions": q.instructions, "criteria": ["true": "Yes", "false": "No"]] }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["state": state, "questions": typed])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CaptureDecisionError(message: "the decision model answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let answers = object["answers"] as? [String: Any] else {
            throw CaptureDecisionError(message: "the decision model gave an answer ironpet cannot read")
        }
        var out: [String: Double] = [:]
        for q in questions {
            guard let answer = answers[q.name] as? [String: Any], let p = (answer["noul"] as? NSNumber)?.doubleValue else {
                throw CaptureDecisionError(message: "the decision model gave no answer for \(q.name)")
            }
            out[q.name] = p
        }
        return out
    }
}

/// An OpenAI-compatible chat server, as a fallback. It answers yes or no, so a probability is 1 or 0.
struct OpenAIDecisionClient: CaptureDecisionClient {
    var baseURL: URL
    var model: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 90

    func probabilities(text: String, existingTasks: [String: String], questions: [(name: String, instructions: String)]) async throws -> [String: Double] {
        var prompt = "TEXT:\n<<<\n\(text)\n>>>\n\n"
        if !existingTasks.isEmpty { prompt += "EXISTING OPEN TASKS:\n" + existingTasks.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n" }
        prompt += "Answer each question with true or false. Reply with one JSON object that maps each question name to a boolean, and nothing else.\n"
        prompt += questions.map { "- \($0.name): \($0.instructions)" }.joined(separator: "\n")
        let system = "You are a triage filter for text captured from a user's screen. Answer only about what the text says."
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "max_tokens": 400,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CaptureDecisionError(message: "the decision model answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let choices = object["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
              let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
              let answers = try JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any] else {
            throw CaptureDecisionError(message: "the decision model gave an answer ironpet cannot read")
        }
        var out: [String: Double] = [:]
        for q in questions {
            guard let value = answers[q.name] as? Bool else { throw CaptureDecisionError(message: "the decision model gave no answer for \(q.name)") }
            out[q.name] = value ? 1 : 0
        }
        return out
    }
}

/// What the filter decided about one item.
struct CaptureVerdict: Equatable {
    var secret: Double
    var calendar: Double
    var followUp: Double?
    var newTask: Double?
    /// Ids of open tasks the text is about.
    var related: [String]
    /// Still a secret after redaction: the item never leaves this Mac, and its text is dropped.
    var flagged: Bool
    /// Nothing in the item needs the larger model.
    var skip: Bool
}

/// Runs the local model over new items. It fails closed: when no model is set, it is not on this Mac, or it does not answer, the item
/// stays `new` and nothing reaches the larger model.
final class CaptureDecisionFilter {
    enum Status: Equatable {
        case unknown
        case ready(model: String)
        /// The reason an item cannot be filtered, shown in Settings.
        case unavailable(String)
    }

    private let settings: () -> Config.ScreenCapture.Decision
    /// Replaced in test mode.
    var makeClient: (Config.ScreenCapture.Decision, URL) -> CaptureDecisionClient
    /// False once the master switch is off. A pass then stops before asking the model.
    var isEnabled: () -> Bool = { true }
    private let lock = NSLock()
    private var _status: Status = .unknown

    init(settings: @escaping () -> Config.ScreenCapture.Decision,
         makeClient: @escaping (Config.ScreenCapture.Decision, URL) -> CaptureDecisionClient = CaptureDecisionFilter.defaultClient) {
        self.settings = settings
        self.makeClient = makeClient
    }

    static func defaultClient(_ decision: Config.ScreenCapture.Decision, _ url: URL) -> CaptureDecisionClient {
        decision.api == "openai" ? OpenAIDecisionClient(baseURL: url, model: decision.model) : SystemOneDecisionClient(baseURL: url)
    }

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    private func set(_ status: Status) {
        lock.lock()
        _status = status
        lock.unlock()
    }

    /// Asks one trivial question to see whether the model answers. Used by Settings.
    func test() async -> Status {
        let decision = settings()
        switch CaptureDecisionEndpoint.validate(decision.baseUrl) {
        case .failure(let error):
            set(.unavailable(error.message))
        case .success(let url):
            do {
                _ = try await makeClient(decision, url).probabilities(text: "The password is hunter2-example.", existingTasks: [:], questions: [("q4", CaptureQuestions.sensitive)])
                set(.ready(model: decision.model))
            } catch {
                set(.unavailable("The decision model at \(url.absoluteString) did not answer: \(error.localizedDescription). Captures stay on this Mac."))
            }
        }
        return status
    }

    /// The verdict for one item, or an error when the model cannot be asked. A thrown error means the item must not be sent.
    func evaluate(text: String, openTasks: [CaptureTask]) async throws -> CaptureVerdict {
        let decision = settings()
        let url: URL
        switch CaptureDecisionEndpoint.validate(decision.baseUrl) {
        case .failure(let error):
            set(.unavailable(error.message))
            throw error
        case .success(let valid): url = valid
        }
        let client = makeClient(decision, url)
        do {
            let secret = try await client.probabilities(text: text, existingTasks: [:], questions: [("q4", CaptureQuestions.sensitive)])["q4"] ?? 1
            if secret >= decision.secretThreshold {
                set(.ready(model: decision.model))
                return CaptureVerdict(secret: secret, calendar: 0, followUp: nil, newTask: nil, related: [], flagged: true, skip: false)
            }
            let calendar = try await client.probabilities(text: text, existingTasks: [:], questions: [("q2", CaptureQuestions.calendar)])["q2"] ?? 1
            var questions: [(name: String, instructions: String)] = [("new", CaptureQuestions.newTask)]
            var existing: [String: String] = [:]
            for task in openTasks.prefix(15) {
                existing[task.id] = task.title
                questions.append(("rel_" + task.id, CaptureQuestions.related(task.title)))
            }
            let answers = try await client.probabilities(text: text, existingTasks: existing, questions: questions)
            let related = existing.keys.sorted().filter { (answers["rel_" + $0] ?? 0) >= 0.5 }
            var followUp: Double?
            if decision.skipThreshold > 0 {
                followUp = try await client.probabilities(text: text, existingTasks: [:], questions: [("q1", CaptureQuestions.followUp)])["q1"]
            }
            let newTask = answers["new"]
            // The evaluation found the follow-up and new-task answers unreliable, so an item is skipped only when the user raised the
            // threshold, and never when it may hold a calendar event or touch an open task.
            let skip = decision.skipThreshold > 0 && related.isEmpty && calendar < decision.calendarThreshold
                && (followUp ?? 1) < decision.skipThreshold && (newTask ?? 1) < decision.skipThreshold
            set(.ready(model: decision.model))
            return CaptureVerdict(secret: secret, calendar: calendar, followUp: followUp, newTask: newTask, related: related, flagged: false, skip: skip)
        } catch {
            set(.unavailable("The decision model at \(url.absoluteString) did not answer: \(error.localizedDescription). Captures stay on this Mac."))
            throw error
        }
    }

    static let flaggedReason = "still flagged after redaction, kept local"

    /// Filters every `new` item in the store. Items the model cannot be asked about stay `new`.
    @discardableResult
    func run(on store: CaptureStore, tasks: CaptureTaskList) async -> FilterResult {
        var done = 0
        var ready = 0
        let open = await tasks.open()
        for item in store.items(inState: "new") {
            guard isEnabled() else { return FilterResult(done: done, ready: ready) }
            do {
                let verdict = try await evaluate(text: item.body, openTasks: open)
                if verdict.flagged {
                    // The rules already redacted what they know. The model still calls this a secret, so it stays on the Mac.
                    store.setState(item.id, "local", reason: Self.flaggedReason, secret: verdict.secret)
                    store.dropText(item.id)
                } else if verdict.skip {
                    store.setState(item.id, "local", reason: "nothing to act on", secret: verdict.secret, related: verdict.related, calendar: verdict.calendar, task: verdict.newTask)
                } else {
                    store.setState(item.id, "ready", secret: verdict.secret, related: verdict.related, calendar: verdict.calendar, task: verdict.newTask)
                    ready += 1
                }
                done += 1
            } catch {
                return FilterResult(done: done, ready: ready)
            }
        }
        return FilterResult(done: done, ready: ready)
    }

    /// `done` counts every item decided. `ready` counts only those that will be sent, and only those restart the quiet period.
    struct FilterResult: Equatable {
        var done = 0
        var ready = 0
    }
}
