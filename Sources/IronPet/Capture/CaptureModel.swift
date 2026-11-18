import Foundation

/// The app a window belongs to.
struct CaptureApp: Equatable, Sendable {
    var bundleId: String
    var name: String
    var pid: pid_t = 0
}

/// Why a capture was taken. Stored with the capture, so a reader can tell a typing pause from the idle timer.
enum CaptureTrigger: String, Sendable {
    case appSwitch = "app_switch"
    case windowFocus = "window_focus"
    case typingPause = "typing_pause"
    case scrollStop = "scroll_stop"
    case click
    case idle
}

/// What happened on the Mac that may be worth a capture. Key events carry no key: only the fact that one was pressed.
enum CaptureSignal: Equatable, Sendable {
    case appSwitch
    case windowFocus
    case key
    case scroll
    case click
}

/// One accessibility element, reduced to what text extraction needs. Roles have the `AX` prefix removed.
struct AXNode: Equatable, Sendable {
    var role: String
    var subrole: String?
    var title: String?
    var value: String?
    var description: String?
    /// For a web area: the page address.
    var url: String?
    /// The element's id in the page (`AXDOMIdentifier`), when a web view has one. Stable across captures.
    var domId: String?
    var hidden = false
    var children: [AXNode] = []
    /// The subtree hash `CaptureTree` gave this node. Empty for a node that came straight from the source.
    var ref = ""

    init(role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, description: String? = nil, url: String? = nil,
         domId: String? = nil, hidden: Bool = false, children: [AXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.url = url
        self.domId = domId
        self.hidden = hidden
        self.children = children
    }

    /// A password field. Its value is never read, here or by the source.
    var isSecure: Bool { subrole == "SecureTextField" || role == "SecureTextField" }

    /// What the app calls this element: its title, else its description.
    var name: String? {
        for text in [title, description] { if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text } }
        return nil
    }
}

/// The focused window of an app as the source read it.
struct WindowRead: Equatable, Sendable {
    var app: CaptureApp
    var title: String?
    /// The page address of a web view in the window, when there is one.
    var url: String?
    var root: AXNode
    /// The window server id of the window that was read, so a screenshot is of that window and no other. Nil when it is unknown.
    var windowID: UInt32? = nil
}

/// What the source may spend on one window read.
struct CaptureReadBudget: Equatable, Sendable {
    var maxNodes = 6_000
    /// Seconds. An Electron tree can be huge, so the read takes what it got.
    var maxTime = 0.2
}

/// The macOS side of capture, behind a protocol so tests can drive the service with a synthetic tree and a fake clock.
protocol CaptureSource: AnyObject {
    /// Starts reporting signals. The callback may run on any thread.
    func start(onSignal: @escaping (CaptureSignal) -> Void)
    func stop()
    var isTrusted: Bool { get }
    func frontmostApp() -> CaptureApp?
    /// Reads the focused window's accessibility tree. Nil when there is no window or no access.
    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> WindowRead?
    /// Lines of text from a screenshot of the window `windowID` (the one `readFocusedWindow` returned), read on this Mac. The image is
    /// never written to disk. Nil when Screen Recording is not allowed, the id is unknown or that window is gone.
    func recognizeFocusedWindow(of app: CaptureApp, windowID: UInt32?) -> [String]?
}

/// One capture's text, as stored and as the MCP tools return it.
struct StoredCapture: Equatable, Identifiable, Sendable {
    var id: Int64
    var at: Date
    var app: String
    var appName: String
    var window: String
    var url: String?
    var trigger: String
    var text: String
    /// The root hash of the stored accessibility tree. Nil for a capture of text only.
    var root: String? = nil
}

/// A search result: the capture without its whole text.
struct CaptureHit: Equatable, Identifiable, Sendable {
    var id: Int64
    var at: Date
    var app: String
    var appName: String
    var window: String
    var url: String?
    var snippet: String
}
