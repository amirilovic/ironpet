import Foundation
import Security

/// Polls Sentry for new and escalating unresolved issues. Configured by `scripts/configure_sentry.sh`:
/// `~/.ironpet/sentry.json` holds host, org and optional projects; the auth token lives in the Keychain
/// (service `ironpet.sentry`, account = org).
@MainActor
final class SentryWatcher {
    struct Config: Decodable {
        var host: String?
        var org: String
        var projects: [String]?
    }

    static let configFile = Paths.root.appendingPathComponent("sentry.json")
    static let interval: TimeInterval = 120

    private let store: SignalStore
    private var timer: Timer?
    private var seeded = false
    private var seen: Set<String> = []

    init(store: SignalStore) {
        self.store = store
    }

    static var config: Config? {
        (try? Data(contentsOf: configFile)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }

    static func token(org: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ironpet.sentry",
                                    kSecAttrAccount as String: org, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool { Self.config != nil }

    func start() {
        guard let config = Self.config else { return }
        guard Self.token(org: config.org) != nil else { return NSLog("ironpet: Sentry configured but no token in Keychain") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func poll() {
        guard let config = Self.config, let token = Self.token(org: config.org) else { return }
        Task { [weak self] in
            let fresh = await Self.fetch(config: config, token: token, query: "is:unresolved firstSeen:-1h")
            let escalating = await Self.fetch(config: config, token: token, query: "is:unresolved is:escalating")
            guard let fresh, let escalating else { return }
            self?.apply(new: fresh, escalating: escalating)
        }
    }

    private func apply(new: [[String: Any]], escalating: [[String: Any]]) {
        let first = !seeded
        seeded = true
        for (issues, kind) in [(new, Signal.Kind.sentryNew), (escalating, .sentryEscalating)] {
            for issue in issues {
                guard let id = issue["id"] as? String, let link = issue["permalink"] as? String, let url = URL(string: link) else { continue }
                let key = "\(kind.rawValue):\(id)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let project = (issue["project"] as? [String: Any])?["slug"] as? String ?? "sentry"
                let count = issue["count"] as? String ?? "?"
                let culprit = (issue["culprit"] as? String).map { " · \($0)" } ?? ""
                store.add(Signal(id: "sentry:\(key)", kind: kind, title: issue["title"] as? String ?? "Sentry issue",
                                 subtitle: "\(project) · \(count) events\(culprit)", url: url), notify: !first)
            }
        }
    }

    private static func fetch(config: Config, token: String, query: String) async -> [[String: Any]]? {
        let host = (config.host ?? "https://sentry.io").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(host)/api/0/organizations/\(config.org)/issues/")
        var search = query
        if let projects = config.projects, !projects.isEmpty {
            search += " project:[\(projects.joined(separator: ","))]"
        }
        components?.queryItems = [URLQueryItem(name: "query", value: search), URLQueryItem(name: "statsPeriod", value: "24h"),
                                  URLQueryItem(name: "sort", value: "date"), URLQueryItem(name: "limit", value: "25")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}
