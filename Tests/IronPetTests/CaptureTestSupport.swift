import Foundation
@testable import IronPet

/// A source with a window the test sets, so no capture test touches the real screen.
final class FakeCaptureSource: CaptureSource {
    var app = CaptureApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", pid: 100)
    var title: String? = "ana (DM) - Acme"
    var root = AXNode(role: "Window")
    var ocrLines: [String]? = ["Text read from a screenshot"]
    var trusted = true
    private(set) var reads = 0
    private(set) var ocrCalls = 0
    private(set) var ocrWindowIDs: [UInt32?] = []
    var url: String?
    var windowID: UInt32? = 42
    private(set) var started = false
    private(set) var stopped = false
    private var onSignal: ((CaptureSignal) -> Void)?

    func start(onSignal: @escaping (CaptureSignal) -> Void) {
        started = true
        self.onSignal = onSignal
    }

    func stop() { stopped = true }
    var isTrusted: Bool { trusted }
    func frontmostApp() -> CaptureApp? { app }

    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> WindowRead? {
        reads += 1
        return WindowRead(app: app, title: title, url: url, root: root, windowID: windowID)
    }

    func recognizeFocusedWindow(of app: CaptureApp, windowID: UInt32?) -> [String]? {
        ocrCalls += 1
        ocrWindowIDs.append(windowID)
        return ocrLines
    }

    func emit(_ signal: CaptureSignal) { onSignal?(signal) }
}

enum CaptureFixtures {
    /// A Slack-like web window: a toolbar of labelled buttons, a message list and a composer with a draft and a Send button.
    static func slack(messages: [String], draft: String = "", url: String? = "https://app.slack.com/client/T1/C1") -> AXNode {
        let toolbar = AXNode(role: "Group", children: ["Bold: off", "Italic: off", "Strikethrough: off", "Link", "Attach"].map {
            AXNode(role: "Button", title: $0, description: $0, children: [AXNode(role: "StaticText", value: $0)])
        })
        let list = AXNode(role: "List", children: messages.map {
            AXNode(role: "Group", children: [AXNode(role: "StaticText", value: "Ana"), AXNode(role: "StaticText", value: $0)])
        })
        let composer = AXNode(role: "Group", children: [
            toolbar,
            AXNode(role: "TextArea", value: draft, description: "Message to Ana"),
            AXNode(role: "Button", title: "Send now", children: [AXNode(role: "StaticText", value: "Send now")]),
        ])
        let web = AXNode(role: "WebArea", url: url, children: [AXNode(role: "Toolbar", children: [AXNode(role: "Button", title: "Back")]), list, composer])
        return AXNode(role: "Window", children: [web])
    }

    static func store() -> CaptureStore {
        CaptureStore(database: Database.open(path: nil, migrations: CaptureStore.migrations).database)
    }
}
