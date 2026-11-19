import XCTest

/// The rule in SPEC.md › API layer: only the API touches stores. A SwiftUI view, `MCPEndpoint`, a CLI handler and
/// `TelegramBridge` reach the app through `IronPetAPI`, so none of their files may name a store type. The scan reads the
/// source files, like the "no app names in Desktop sources" test.
final class BoundaryTests: XCTestCase {
    /// Types that hold app state. A client file that names one is calling around the API.
    static let stores = [
        "TaskStore", "SignalStore", "BubbleStore", "SessionStore", "AutomationStore", "AutomationService", "ConfigStore",
        "MeetingController", "MeetingLibrary", "MeetingRegenerator", "VoiceStore", "UsageStore", "CaptureStore", "CaptureService",
        "DesktopService", "ChatSession", "ThreadStore", "SpeechPlayer", "CapturePrivacy",
    ]

    /// Files that are clients by name, whatever they define. Each is an adapter that turns another protocol into API calls.
    static let adapters: Set<String> = [
        "Bridge/MCPEndpoint.swift", "Tasks/TaskMCP.swift", "Tasks/TaskJSON.swift", "Automations/AutomationMCP.swift",
        "Capture/ScreenMCP.swift", "Desktop/DesktopMCP.swift", "Jobs/AssistantMCP.swift", "Telegram/TelegramBridge.swift",
    ]

    /// Files that build every store from sample data to render screenshots. They are a test harness, not a client.
    static let harnesses: Set<String> = ["App/PreviewRenderer.swift"]

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IronPet")
    }

    private static func swiftFiles() -> [(path: String, text: String)] {
        let root = sources
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (String(url.path.dropFirst(root.path.count + 1)), text)
        }
    }

    /// A file that defines a SwiftUI view: a `struct … : View`, a view modifier, or a representable.
    static func definesView(_ text: String) -> Bool {
        text.range(of: #"(struct|extension)\s+\w+[^{\n]*:\s*[^{\n]*\b(View|ViewModifier|NSViewRepresentable|NSViewControllerRepresentable)\b"#,
                   options: .regularExpression) != nil
            || text.contains("var body: some View")
    }

    /// The code of a file without comment lines, so a doc comment may still say what a type is called.
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    static func stores(named text: String) -> [String] {
        let code = code(text)
        return stores.filter { code.range(of: #"\b"# + $0 + #"\b"#, options: .regularExpression) != nil }
    }

    func testNoViewAdapterOrBridgeNamesAStore() {
        var violations: [String] = []
        for file in Self.swiftFiles() {
            let isClient = Self.adapters.contains(file.path) || (Self.definesView(file.text) && !file.path.hasPrefix("API/"))
            guard isClient, !Self.harnesses.contains(file.path) else { continue }
            let named = Self.stores(named: file.text)
            if !named.isEmpty { violations.append("\(file.path): \(named.joined(separator: ", "))") }
        }
        XCTAssertTrue(violations.isEmpty, "client files reach a store directly. Go through IronPetAPI instead:\n" + violations.sorted().joined(separator: "\n"))
    }

    func testTheScanSeesTheClientsItGuards() {
        let files = Self.swiftFiles()
        XCTAssertGreaterThan(files.count, 100, "the scan found no sources, so it would pass on anything")
        for adapter in Self.adapters { XCTAssertTrue(files.contains { $0.path == adapter }, "\(adapter) moved: update BoundaryTests.adapters") }
        let views = files.filter { Self.definesView($0.text) }.map(\.path)
        for expected in ["Chat/ChatView.swift", "Pet/TaskListView.swift", "Pet/IronPetWindow.swift", "Meeting/TranscriptsView.swift", "App/SettingsWindow.swift"] {
            XCTAssertTrue(views.contains(expected), "\(expected) is not recognised as a view file")
        }
    }

    func testTheScanCatchesAViewThatCallsAStore() {
        let bad = """
            import SwiftUI
            struct Leaky: View {
                @ObservedObject var tasks: TaskStore
                var body: some View { Text("\\(tasks.tasks.count)") }
            }
            """
        XCTAssertTrue(Self.definesView(bad))
        XCTAssertEqual(Self.stores(named: bad), ["TaskStore"])
        XCTAssertEqual(Self.stores(named: "// the TaskStore is behind the API\nlet x = 1"), [])
        XCTAssertEqual(Self.stores(named: "let x = TaskStoreProxy()"), [], "a longer name is a different type")
    }
}
