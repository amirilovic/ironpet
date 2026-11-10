import AppKit
import SwiftUI

/// `--render-previews <dir> [--sprite <sheet.png>]`: renders the main UI with made-up sample data to PNGs, for checking
/// the design without clicking through it and for the README screenshots (`scripts/screenshots.sh`).
/// Nothing here reads your sessions, alerts or chats.
@MainActor
enum PreviewRenderer {
    static func run(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--render-previews"), arguments.count > index + 1 else { return }
        let dir = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sprite = arguments.firstIndex(of: "--sprite").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        // Default settings (the pet is called Ghost), whatever is in your config.json.
        var config = Config()
        config.pet.sprite = sprite
        ConfigStore.shared.usePreview(config)
        let atlas = Atlas.loadDefault(sprite: sprite)
        let name = config.pet.name

        for (file, preview) in [("chat", ChatSession.Preview.done), ("chat-approval", .approval)] {
            let session = ChatSession()
            session.loadPreview(preview)
            render(ChatView(session: session, close: {}).frame(width: 520, height: 640).panel(), to: dir, file)
        }

        let sessions = SessionStore()
        sessions.loadPreview(sampleSessions)
        let signals = SignalStore()
        sampleSignals.forEach { signals.add($0, notify: false) }
        render(SessionListView(store: sessions, signals: signals, onJump: { _ in }, onAsk: { _ in }, onTrick: { _ in }).panel(),
               to: dir, "agents")
        // The list opens on Alerts when no agent needs you or is working.
        render(SessionListView(store: SessionStore(), signals: signals, onJump: { _ in }, onAsk: { _ in }, onTrick: { _ in }).panel(),
               to: dir, "alerts")

        let done = Bubble(id: "done", symbol: AgentStatus.done.symbol, tint: AgentStatus.done.tint, title: "demo-app: Done",
                          subtitle: "Claude Code", body: "Edited 3 files · Fixed the flaky login test.",
                          actions: [.init(title: "Open in iTerm", style: .primary) {}])
        let approval = Bubble(id: "approval", symbol: "hand.raised.fill", tint: .orange, title: "\(name) wants to: Run this command?",
                              body: "npm test -- login --runInBand",
                              actions: [.init(title: "Allow", style: .primary) {}, .init(title: "Deny", style: .destructive) {},
                                        .init(title: "Open chat") {}])
        render(PetScene(atlas: atlas, row: .waiting, frame: 2, bubbles: [done, approval]), to: dir, "pet")

        let water = ReminderScheduler.Kind.water
        let reminder = Bubble(id: "reminder", symbol: water.symbol, tint: .cyan, title: water.title,
                              subtitle: "Your agent is still working, good moment for it.", body: water.body,
                              actions: [.init(title: "Done", style: .primary) {}, .init(title: "Snooze 10 min") {}])
        render(PetScene(atlas: atlas, row: .drinking, frame: 3, bubbles: [reminder]), to: dir, "reminder")
    }

    private static func render(_ view: some View, to dir: URL, _ name: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = dir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("wrote \(file.path)")
    }

    private static var sampleSessions: [AgentSession] {
        func session(_ id: String, _ source: AgentSource, _ status: AgentStatus, _ project: String, prompt: String,
                     detail: String? = nil, edited: [String] = [], reply: String? = nil, minutes: Double,
                     iTerm: Bool = false) -> AgentSession {
            var s = AgentSession(id: id, source: source, status: status, prompt: prompt, detail: detail)
            s.origin = SessionOrigin(workspace: "/Users/you/code/\(project)", termProgram: iTerm ? "iTerm.app" : nil,
                                     itermSessionID: iTerm ? "w0t0p0" : nil)
            s.turnStartedAt = Date().addingTimeInterval(-minutes * 60)
            s.updatedAt = s.turnStartedAt
            s.editedFiles = edited
            s.lastResponse = reply
            return s
        }
        return [
            session("1", .claude, .needsInput, "api-server", prompt: "Add rate limiting to the public endpoints",
                    detail: "Run `npm install express-rate-limit`?", minutes: 3, iTerm: true),
            session("2", .cursor, .running, "web-app", prompt: "Make the settings page work on mobile",
                    detail: "Editing SettingsPage.tsx", minutes: 2),
            session("3", .claude, .done, "demo-app", prompt: "Why is the login test flaky?",
                    edited: ["a", "b", "c"], reply: "Fixed the flaky login test.", minutes: 6, iTerm: true),
            session("4", .cursor, .failed, "docs-site", prompt: "Upgrade to the new docs theme",
                    reply: "The build fails because the theme needs Node 20.", minutes: 11),
        ]
    }

    private static var sampleSignals: [Signal] {
        let url = URL(string: "https://github.com/you/web-app/pull/42")!
        return [
            Signal(id: "1", kind: .ciFailed, title: "Make the settings page responsive", subtitle: "you/web-app #42 · build",
                   url: url, date: Date().addingTimeInterval(-119.5)),
            Signal(id: "2", kind: .reviewRequested, title: "Add rate limiting to public endpoints", subtitle: "you/api-server #17",
                   url: url, date: Date().addingTimeInterval(-899.5)),
            Signal(id: "3", kind: .approved, title: "Fix flaky login test", subtitle: "you/demo-app #8",
                   url: url, date: Date().addingTimeInterval(-1799.5)),
        ].reversed()
    }
}

private extension View {
    /// Rounded window look, since the real panels' blur and shadow don't render offscreen.
    func panel() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(1)
    }
}

/// The pet with its speech bubbles on a plain backdrop, laid out the way they sit on screen.
private struct PetScene: View {
    let atlas: Atlas?
    let row: AtlasRow
    let frame: Int
    private let store = BubbleStore()

    init(atlas: Atlas?, row: AtlasRow, frame: Int, bubbles: [Bubble]) {
        self.atlas = atlas
        self.row = row
        self.frame = frame
        bubbles.forEach(store.show)
    }

    var body: some View {
        let size = CGSize(width: Atlas.cell.width * 0.9, height: Atlas.cell.height * 0.9)
        HStack(alignment: .bottom, spacing: -30) {
            BubbleStackView(store: store)
                .padding(.bottom, size.height * 0.62 - BubbleStackView.tailFromBottom)
            Group {
                if let image = atlas?.frame(row, frame) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Image(systemName: "pawprint.fill").resizable().scaledToFit().padding(40)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.09, green: 0.1, blue: 0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
