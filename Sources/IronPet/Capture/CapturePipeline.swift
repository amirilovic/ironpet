import Foundation

/// The capture pipeline for one window read. In order: the Swift gate (pause, private mode, lock screen, excluded apps, URL scheme),
/// the secure-field scrub, the denylist rules, the parser rule, the transform rules, the hard floor, then the store.
///
/// The floor runs after every rule and no rule or user file can switch it off: it strips URL secrets, fixes the app to the one that
/// was read, rechecks the URL scheme and host, drops private browser windows, and drops empty content.
final class CapturePipeline {
    enum Outcome: Equatable {
        case stored(threadKey: String, result: CaptureStore.IngestResult)
        case skipped(CaptureSkip)
    }

    /// What a parser says about a snapshot.
    enum ParseOutcome: Equatable {
        case item(CaptureItem)
        /// Store nothing for this window (for example an empty composer).
        case refuse(String)
        /// Not this parser's page. The engine falls back to the generic parser.
        case notHandled
    }

    /// At most this many screen regions are read per window.
    static let maxOCRRegions = 2
    /// The tallest screen region read, in points: enough for a header, not for a message pane.
    static let maxOCRHeight = 160.0

    let privacy: CapturePrivacy
    let rules: CaptureRules
    let store: CaptureStore?

    init(privacy: CapturePrivacy, rules: CaptureRules, store: CaptureStore?) {
        self.privacy = privacy
        self.rules = rules
        self.store = store
    }

    // MARK: Rules

    private struct Denial: Decodable {
        var app: String?
        var host: String?
    }

    /// Runs every denylist rule on an app and an optional URL. A rule that fails denies, so a broken denylist can only store less.
    private func denylistCheck(app: CaptureApp, pageURL: String?) -> CaptureSkip? {
        let target: [String: Any?] = ["bundle_id": app.bundleId, "name": app.name, "url": pageURL, "host": pageURL.flatMap(CaptureURL.host)]
        let object = target.mapValues { $0 ?? NSNull() }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input = String(data: data, encoding: .utf8) else {
            return .ruleFailed("denylist input")
        }
        let names = rules.ruleSet.names(ofKind: "denylist")
        if names.isEmpty { return .ruleFailed("no denylist rule is active") }
        for name in names {
            do {
                let out = try rules.invoke(rule: name, function: "check", input: input)
                if out == "null" { continue }
                guard let denial = CaptureJSON.decode(Denial?.self, out) else { return .ruleFailed("\(name): bad result") }
                if let denial {
                    if let app = denial.app { return .deniedApp(app) }
                    if let host = denial.host { return .deniedHost(host) }
                    return .deniedApp(app.bundleId)
                }
            } catch {
                return .ruleFailed("\(name): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func decodeOutcome(_ text: String) throws -> ParseOutcome {
        if text == "null" { return .notHandled }
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let reason = object["refuse"] as? String {
            return .refuse(reason)
        }
        guard let item = CaptureJSON.decode(CaptureItem.self, text) else { throw CaptureVM.Failure(message: "not a capture item") }
        return .item(item)
    }

    /// Runs the parser rule for a snapshot, falling back to the fallback parser when the rule declines. A failure of either rule is
    /// an error, so nothing is stored.
    func parse(_ snapshot: CaptureSnapshot) throws -> ParseOutcome {
        let set = rules.ruleSet
        guard let input = CaptureJSON.string(snapshot) else { throw CaptureVM.Failure(message: "the snapshot cannot be encoded") }
        func run(_ name: String) throws -> ParseOutcome {
            do { return try decodeOutcome(try rules.invoke(rule: name, function: "parse", input: input)) }
            catch { throw CaptureVM.Failure(message: "\(name): \(error.localizedDescription)") }
        }
        if let name = set.parser(forBundleId: snapshot.app.bundleId, pageURL: snapshot.url) {
            // A rule that fails is not skipped for the generic parser: the app rule may be the one that refuses to read this window.
            let outcome = try run(name)
            if outcome != .notHandled { return outcome }
        }
        guard let fallback = set.fallback else { throw CaptureVM.Failure(message: "no fallback parser rule is loaded") }
        return try run(fallback)
    }

    /// A screen rectangle a parser wants read as text, in global coordinates.
    struct OCRRegion: Equatable {
        var name: String
        var rect: CaptureRect
    }

    private static func clip(_ r: CaptureRect, to window: CaptureRect) -> CaptureRect? {
        let x0 = max(r.x, window.x), y0 = max(r.y, window.y)
        let x1 = min(r.x + r.width, window.x + window.width), y1 = min(r.y + r.height, window.y + window.height)
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CaptureRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The screen regions the window's parser asks to have read as text, after the same gate and denylist a capture passes. Regions
    /// are clipped to the window and capped in number and height, so a rule can name a header strip but cannot read the whole screen.
    func ocrRegions(for snapshot: CaptureSnapshot) -> [OCRRegion] {
        if privacy.check(snapshot) != nil || isPrivateWindow(snapshot) || CaptureFloor.deniesApp(snapshot.app.bundleId) { return [] }
        if denylistCheck(app: snapshot.app, pageURL: snapshot.url) != nil { return [] }
        let set = rules.ruleSet
        guard let name = set.parser(forBundleId: snapshot.app.bundleId, pageURL: snapshot.url), set.readsScreen(name),
              let window = snapshot.root.frame, let input = CaptureJSON.string(snapshot),
              let out = try? rules.invoke(rule: name, function: "ocrRegions", input: input),
              let list = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] else { return [] }
        var regions: [OCRRegion] = []
        for entry in list {
            guard let regionName = entry["name"] as? String, let x = entry["x"] as? Double, let y = entry["y"] as? Double,
                  let width = entry["width"] as? Double, let height = entry["height"] as? Double,
                  let rect = Self.clip(CaptureRect(x: x, y: y, width: width, height: height), to: window), rect.height <= Self.maxOCRHeight else { continue }
            regions.append(OCRRegion(name: regionName, rect: rect))
        }
        return Array(regions.prefix(Self.maxOCRRegions))
    }

    // MARK: Floor

    /// Title words that mark a private browser window. A browser does not say so any other way through accessibility.
    static let privateWindowMarkers = ["private browsing", "incognito", "inprivate", "(private)", "— private", "- private", "private window"]

    func isPrivateWindow(_ snapshot: CaptureSnapshot) -> Bool {
        guard CaptureFloor.isBrowser(snapshot.app.bundleId) || snapshot.app.bundleId.lowercased().contains("browser") else { return false }
        let title = (snapshot.windowTitle ?? "").lowercased()
        if Self.privateWindowMarkers.contains(where: { title.contains($0) }) { return true }
        let label = (snapshot.root.attrs["label"] ?? "").lowercased()
        return label.contains("incognito") || label.contains("private browsing")
    }

    /// The floor for an item a rule produced: the app is the one that was read, URL secrets are gone from the URL, the thread key, the
    /// title, the window title and the account.
    static func applyFloor(_ item: inout CaptureItem, snapshot: CaptureSnapshot) {
        item.app = snapshot.app
        item.url = item.url.map(CaptureURL.redact)
        item.threadKey = CaptureURL.redactURLs(in: item.threadKey)
        item.threadTitle = CaptureURL.redactURLs(in: item.threadTitle)
        item.windowTitle = item.windowTitle.map(CaptureURL.redactURLs(in:))
        item.account = item.account.map(CaptureURL.redactURLs(in:))
    }

    // MARK: Pipeline

    /// Whether an app's window may be read at all. Runs before the read, so paused, private, excluded and denylisted apps (password
    /// managers, System Settings) are never touched through the accessibility API. A denylist rule that fails answers no.
    func mayRead(_ app: CaptureApp) -> Bool {
        privacy.checkApp(app) == nil && denylistCheck(app: app, pageURL: nil) == nil
    }

    /// Everything up to the store: gate, parse, transforms and the floor.
    func prepare(_ snapshot: CaptureSnapshot) -> Result<CaptureItem, CaptureSkip> {
        if let skip = privacy.check(snapshot) { return .failure(skip) }
        if isPrivateWindow(snapshot) { return .failure(.privateWindow) }
        var snapshot = snapshot
        snapshot.root = snapshot.root.scrubbed()
        if let skip = denylistCheck(app: snapshot.app, pageURL: snapshot.url) { return .failure(skip) }
        let outcome: ParseOutcome
        do { outcome = try parse(snapshot) } catch { return .failure(.ruleFailed(error.localizedDescription)) }
        var item: CaptureItem
        switch outcome {
        case .item(let parsed): item = parsed
        case .refuse(let reason): return .failure(.refused(reason))
        case .notHandled: return .failure(.noParser)
        }
        for name in rules.ruleSet.names(ofKind: "transform") {
            guard let input = CaptureJSON.string(item) else { return .failure(.ruleFailed("\(name): item")) }
            do {
                let out = try rules.invoke(rule: name, function: "transform", input: input)
                if out == "null" { return .failure(.refused("dropped by rule \(name)")) }
                guard let next = CaptureJSON.decode(CaptureItem.self, out) else { return .failure(.ruleFailed("\(name): not a capture item")) }
                item = next
            } catch {
                return .failure(.ruleFailed("\(name): \(error.localizedDescription)"))
            }
        }
        Self.applyFloor(&item, snapshot: snapshot)
        // A rule may learn or set the URL, so check what came out as well.
        if let page = item.url {
            if let skip = CaptureFloor.checkURL(bundleId: snapshot.app.bundleId, raw: page) { return .failure(skip) }
            if let skip = denylistCheck(app: snapshot.app, pageURL: page) { return .failure(skip) }
        }
        if item.content.isEmpty { return .failure(.emptyContent) }
        return .success(item)
    }

    /// Prepares `snapshot`, which `earlier` must confirm: it is stored only if both resolve to the same thread. Otherwise the window
    /// was mid-change (a chat header that already shows the new chat over the old messages) and nothing is stored.
    func process(_ snapshot: CaptureSnapshot, confirmedBy earlier: CaptureSnapshot? = nil, now: Date = Date()) -> Outcome {
        let item: CaptureItem
        switch prepare(snapshot) {
        case .failure(let skip): return .skipped(skip)
        case .success(let prepared): item = prepared
        }
        if let earlier {
            guard case .success(let first) = prepare(earlier), first.threadKey == item.threadKey else { return .skipped(.unsettled) }
        }
        guard let store else { return .skipped(.ruleFailed("no store")) }
        do {
            return .stored(threadKey: item.threadKey, result: try store.ingest(item, now: now))
        } catch {
            return .skipped(.ruleFailed("store: \(error.localizedDescription)"))
        }
    }
}
