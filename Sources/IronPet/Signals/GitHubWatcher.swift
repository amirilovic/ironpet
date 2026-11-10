import Foundation

/// Polls every host `gh` is logged in to for the user's open PRs (CI and review state) and review requests.
/// The first poll per host only records state, so existing PRs don't flood notifications; current CI failures
/// and change requests still show in the list.
@MainActor
final class GitHubWatcher {
    private let store: SignalStore
    private var timer: Timer?
    private var seeded: Set<String> = []
    /// "host|owner/repo#n" -> (CI state, review decision)
    private var prState: [String: (ci: String?, review: String?)] = [:]
    private var reviewRequests: Set<String> = []

    static let interval: TimeInterval = 120
    private static let query = """
        query {
          viewer {
            pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { number title url isDraft repository { nameWithOwner } reviewDecision
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
            }
          }
          search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 50) {
            nodes { ... on PullRequest { number title url repository { nameWithOwner } author { login } } }
          }
        }
        """

    init(store: SignalStore) {
        self.store = store
    }

    static var ghExecutable: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Hosts from `~/.config/gh/hosts.yml` (top-level keys).
    static var hosts: [String] {
        let file = Paths.home.appendingPathComponent(".config/gh/hosts.yml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return ["github.com"] }
        let hosts = text.split(separator: "\n")
            .filter { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasSuffix(":") }
            .map { String($0.dropLast()) }
        return hosts.isEmpty ? ["github.com"] : hosts
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        guard Self.ghExecutable != nil else { return NSLog("ironpet: gh not found, GitHub alerts disabled") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Stops polling and drops GitHub alerts. State is reset so turning alerts back on re-seeds quietly.
    func stop() {
        timer?.invalidate()
        timer = nil
        seeded = []
        prState = [:]
        reviewRequests = []
        store.removeAll { $0.kind.isGitHub }
    }

    func poll() {
        for host in Self.hosts {
            Task { [weak self] in
                guard let data = await Self.fetch(host: host) else { return }
                self?.apply(host: host, data: data)
            }
        }
    }

    private static func fetch(host: String) async -> [String: Any]? {
        guard let gh = ghExecutable else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = gh
                process.arguments = ["api", "--hostname", host, "graphql", "-f", "query=\(query)"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    continuation.resume(returning: process.terminationStatus == 0 ? object?["data"] as? [String: Any] : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func apply(host: String, data: [String: Any]) {
        let firstPoll = !seeded.contains(host)
        seeded.insert(host)

        let prs = ((data["viewer"] as? [String: Any])?["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for pr in prs {
            guard let number = pr["number"] as? Int, let urlString = pr["url"] as? String, let url = URL(string: urlString),
                  let repo = (pr["repository"] as? [String: Any])?["nameWithOwner"] as? String else { continue }
            let key = "\(host)|\(repo)#\(number)"
            let title = pr["title"] as? String ?? "Pull request"
            let commit = ((pr["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any]
            let ci = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String
            let review = pr["reviewDecision"] as? String
            let previous = prState[key]
            prState[key] = (ci, review)
            let subtitle = "\(repo) #\(number)"

            func signal(_ kind: Signal.Kind) -> Signal {
                Signal(id: "gh:\(key):\(kind.rawValue)", kind: kind, title: title, subtitle: subtitle, url: url)
            }

            if firstPoll || previous == nil {
                if ci == "FAILURE" || ci == "ERROR" { store.add(signal(.ciFailed), notify: false) }
                if review == "CHANGES_REQUESTED" { store.add(signal(.changesRequested), notify: false) }
                continue
            }
            if ci != previous?.ci {
                switch ci {
                case "FAILURE", "ERROR":
                    store.add(signal(.ciFailed), notify: true)
                case "SUCCESS" where previous?.ci == "PENDING" || previous?.ci == "EXPECTED" || previous?.ci == "FAILURE":
                    store.dismiss(signal(.ciFailed).id)
                    store.add(signal(.ciPassed), notify: true)
                default:
                    break
                }
            }
            if review != previous?.review {
                if review == "APPROVED" { store.add(signal(.approved), notify: true) }
                if review == "CHANGES_REQUESTED" { store.add(signal(.changesRequested), notify: true) }
            }
        }

        let requested = (data["search"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        for pr in requested {
            guard let number = pr["number"] as? Int, let urlString = pr["url"] as? String, let url = URL(string: urlString),
                  let repo = (pr["repository"] as? [String: Any])?["nameWithOwner"] as? String else { continue }
            let key = "\(host)|\(repo)#\(number)"
            guard !reviewRequests.contains(key) else { continue }
            reviewRequests.insert(key)
            if firstPoll { continue }
            let author = (pr["author"] as? [String: Any])?["login"] as? String
            store.add(Signal(id: "gh:\(key):reviewRequested", kind: .reviewRequested, title: pr["title"] as? String ?? "Pull request",
                             subtitle: "\(repo) #\(number)" + (author.map { " by \($0)" } ?? ""), url: url), notify: true)
        }
    }
}
