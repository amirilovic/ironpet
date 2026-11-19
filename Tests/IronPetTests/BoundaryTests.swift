import XCTest

/// The rule in SPEC.md › API layer: only the API touches stores. A SwiftUI view, `MCPEndpoint`, a CLI handler and
/// `TelegramBridge` reach the app through `IronPetAPI`, so none of their files may name a store type. The scan reads the
/// source files, like the "no app names in Desktop sources" test.
final class BoundaryTests: XCTestCase {
    /// Types that hold app state. A client file that names one is calling around the API.
    static let stores = [
        "TaskStore", "SignalStore", "BubbleStore", "SessionStore", "AutomationStore", "AutomationService", "ConfigStore",
        "MeetingController", "MeetingLibrary", "MeetingRegenerator", "VoiceStore", "UsageStore", "CaptureStore", "CaptureService",
        "DesktopService", "ChatSession", "ThreadStore", "SpeechPlayer", "CapturePrivacy", "NotificationStore",
    ]

    /// Files that are clients by name, whatever they define. Each is an adapter that turns another protocol into API calls.
    static let adapters: Set<String> = [
        "Bridge/MCPEndpoint.swift", "Tasks/TaskMCP.swift", "Tasks/TaskJSON.swift", "Automations/AutomationMCP.swift",
        "Capture/ScreenMCP.swift", "Desktop/DesktopMCP.swift", "Jobs/AssistantMCP.swift", "Telegram/TelegramBridge.swift",
        "Notifications/NotificationMCP.swift",
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

    // MARK: ChatAPI is what a remote client will call

    /// Types ChatAPI may name besides the Codable ones it declares in `API/`.
    private static let plain: Set<String> = ["String", "Int", "Int64", "Bool", "Double", "Date", "Data", "URL", "UUID", "TimeInterval", "Void",
                                             "Array", "Optional", "Dictionary", "APIError", "Self", "Any"]
    /// Codable types declared outside `API/` that ChatAPI hands out. The test checks each really is Codable.
    private static let outsideAPI = ["ChatItem": "struct Item: Identifiable, Codable", "ChatReply": "struct Reply: Codable",
                                     "ChatTurnEvent": "enum TurnEvent: Equatable, Codable", "ChatApprovalOutcome": "enum ApprovalOutcome: Equatable, Codable",
                                     "ElicitationForm": "struct ElicitationForm: Equatable, Codable", "ElicitationValue": "enum ElicitationValue: Equatable, Codable"]

    private static func apiFiles() -> [(path: String, text: String)] { swiftFiles().filter { $0.path.hasPrefix("API/") } }

    /// The type names a declaration line mentions.
    private static func typeNames(in line: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9]*\b"#)
        let range = NSRange(line.startIndex..., in: line)
        return Set(regex.matches(in: line, range: range).compactMap { Range($0.range, in: line).map { String(line[$0]) } })
    }

    func testChatAPIPublicSurfaceIsCodableOnly() throws {
        let files = Self.apiFiles()
        let chat = try XCTUnwrap(files.first { $0.path == "API/ChatAPI.swift" }, "API/ChatAPI.swift moved")
        // Codable types declared in the API folder.
        var codable = Self.plain
        let declaration = try NSRegularExpression(pattern: #"(?:struct|enum)\s+(\w+)[^\n{]*\bCodable\b"#)
        for file in files {
            let range = NSRange(file.text.startIndex..., in: file.text)
            for match in declaration.matches(in: file.text, range: range) {
                if let r = Range(match.range(at: 1), in: file.text) { codable.insert(String(file.text[r])) }
            }
        }
        // Typealiases of Codable types, and the Codable types outside the folder.
        let all = Self.swiftFiles().map(\.text).joined(separator: "\n")
        for (name, declaration) in Self.outsideAPI {
            XCTAssertTrue(all.contains(declaration), "\(name) must stay Codable: expected `\(declaration)`")
            codable.insert(name)
        }
        var problems: [String] = []
        var depth = 0
        var inClass = false
        for raw in chat.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count }
            if trimmed.hasPrefix("final class ChatAPI") { inClass = true; depth = 0 }
            guard inClass else { continue }
            // Members of ChatAPI itself: one level inside `final class ChatAPI`.
            guard depth == 1, !trimmed.hasPrefix("//"), !trimmed.hasPrefix("private"), !trimmed.hasPrefix("fileprivate") else { continue }
            let isMember = trimmed.hasPrefix("func ") || trimmed.hasPrefix("static func ") || trimmed.hasPrefix("var ") || trimmed.hasPrefix("let ")
                || trimmed.hasPrefix("init(") || trimmed.hasPrefix("@discardableResult")
            guard isMember, !trimmed.hasPrefix("@discardableResult") else { continue }
            // The engine is handed to the initializer by the app; no client ever sees it.
            if trimmed.hasPrefix("init(") { continue }
            let signature = trimmed.components(separatedBy: " {").first ?? trimmed
            for name in Self.typeNames(in: signature) where !codable.contains(name) { problems.append("\(trimmed): \(name) is not a Codable type") }
            let name = trimmed.replacingOccurrences(of: "static ", with: "").dropFirst(5).prefix { $0 != "(" }
            if trimmed.contains("func "), !signature.contains("async"), !["snapshot", "onTurn", "onFormsChanged", "cachedModels"].contains(String(name)) {
                problems.append("\(trimmed): a call must be async")
            }
        }
        XCTAssertTrue(problems.isEmpty, "ChatAPI's public surface must be Codable values and async calls:\n" + problems.joined(separator: "\n"))
        for forbidden in ["ObservableObject", "@Published", "import Combine", "AnyView", "NSImage", "VoiceController", "SlashPopupState"] {
            XCTAssertFalse(chat.text.contains(forbidden), "ChatAPI must not mention \(forbidden): that is Mac window state")
        }
    }

    func testTheScanForTheCodableSurfaceCatchesALeak() {
        XCTAssertEqual(Self.typeNames(in: "func start(_ session: ChatSession) async -> SlashPopupState"), ["ChatSession", "SlashPopupState"])
    }
}
