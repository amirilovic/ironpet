import AppKit
import SwiftUI

/// The text of the Screen section, kept apart from the view so tests can check it.
enum ScreenSectionText {
    static func summary(captures: Int, lastCapture: Date?, now: Date = Date()) -> String {
        guard captures > 0 else { return "Nothing captured yet." }
        let count = "\(captures) \(captures == 1 ? "capture" : "captures") stored"
        guard let lastCapture else { return count }
        return count + ", the last one \(lastCapture.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    /// The first `lines` lines of a capture, with `…` when there are more.
    static func preview(_ text: String, lines: Int = 2) -> String {
        let all = text.split(whereSeparator: \.isNewline).map(String.init)
        let head = all.prefix(lines).joined(separator: "\n")
        return all.count > lines ? head + " …" : head
    }

    /// The window title, or the address when a page has no title.
    static func windowLabel(_ capture: StoredCapture) -> String { capture.window.isEmpty ? (capture.url ?? "Untitled window") : capture.window }
}

/// The Screen section: the most recent captures and a search over everything stored. It reads the local database only. Nothing here
/// goes to a model, to MCP or to a log.
struct ScreenSection: View {
    @ObservedObject var model: CaptureStatusModel
    @ObservedObject private var config = ConfigStore.shared
    /// The capture database. Nil before the app has started.
    var store: CaptureStore?
    var onOpenSettings: () -> Void = {}
    var onAppear: () -> Void = {}

    @State private var recent: [StoredCapture] = []
    @State private var hits: [CaptureHit] = []
    @State private var search = ""
    @State private var open: Set<Int64> = []
    @State private var openText: [Int64: String] = [:]
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(ScreenSectionText.summary(captures: model.captureCount, lastCapture: model.lastCapture))
                if !config.config.screenCapture.enabled {
                    HStack {
                        Text("Screen capture is off").foregroundStyle(.secondary)
                        Button("Open Settings", action: onOpenSettings)
                    }
                }
                TextField("Search captures", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if query.isEmpty {
                        if recent.isEmpty { Text("Captures appear here once screen capture has read a window.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(recent) { capture in
                            row(id: capture.id, at: capture.at, app: capture.appName, window: ScreenSectionText.windowLabel(capture),
                                text: ScreenSectionText.preview(capture.text))
                        }
                    } else {
                        if hits.isEmpty { Text("No capture has all of those words.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(hits) { hit in
                            row(id: hit.id, at: hit.at, app: hit.appName, window: hit.window.isEmpty ? (hit.url ?? "Untitled window") : hit.window, text: hit.snippet)
                        }
                    }
                    Text("Text is stored on this Mac with secrets redacted, and is deleted after \(config.config.screenCapture.retentionDays) days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .pageHeader(IronPetSection.screen.title)
        .onAppear { onAppear(); refresh() }
        .onReceive(timer) { _ in if query.isEmpty { refresh() } }
        .onChange(of: model.captureCount) { _ in refresh() }
        .onChange(of: search) { _ in refresh() }
    }

    private func row(id: Int64, at: Date, app: String, window: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if open.contains(id) { open.remove(id) } else { open.insert(id); loadText(id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(app): \(window)").font(.headline).lineLimit(1)
                        Spacer()
                        Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !open.contains(id) { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.contains(id) {
                Text(openText[id] ?? text).font(.caption).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Reads the database off the main thread. An answer for a search the user has since changed is dropped.
    private func refresh() {
        guard let store else { return }
        let asked = query
        Task.detached(priority: .userInitiated) {
            let found = asked.isEmpty ? store.recent(limit: 50) : []
            let matched = asked.isEmpty ? [] : store.search(asked, limit: 50)
            await MainActor.run {
                guard asked == query else { return }
                if asked.isEmpty { recent = found } else { hits = matched }
            }
        }
    }

    private func loadText(_ id: Int64) {
        guard let store else { return }
        Task.detached(priority: .userInitiated) {
            let text = store.capture(id: id)?.text
            await MainActor.run { openText[id] = text }
        }
    }
}
