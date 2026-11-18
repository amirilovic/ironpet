import AppKit
import ApplicationServices

/// An element the AX layer can act on. The service never looks inside it.
typealias DesktopElement = AnyObject

struct DesktopWindowInfo {
    var title: String?
    /// The window server id, so a screenshot is of this window and no other.
    var windowID: UInt32?
    var focused: Bool
    var element: DesktopElement
}

/// A live read of one window. `elements` lists the element behind every node of `root`, in pre-order.
struct DesktopRead {
    var app: CaptureApp
    var window: DesktopWindowInfo
    var root: AXNode
    var elements: [DesktopElement]
}

/// The live accessibility calls the desktop tools need, behind a protocol so tests can drive the service with a synthetic tree.
protocol DesktopAX: AnyObject {
    var isTrusted: Bool { get }
    var screenRecordingGranted: Bool { get }
    /// A running app by bundle id or name. An exact match wins over a partial one.
    func runningApp(matching query: String) -> CaptureApp?
    func windows(of app: CaptureApp) -> [DesktopWindowInfo]
    func read(app: CaptureApp, window: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead?
    /// The element's own fields, without children. Nil when the element is gone.
    func attributes(of element: DesktopElement) -> AXNode?
    func actions(of element: DesktopElement) -> [String]
    func perform(_ action: String, on element: DesktopElement) -> Bool
    func isSettable(_ attribute: String, on element: DesktopElement) -> Bool
    func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool
    /// Focuses the element, or raises it when it is a window.
    func focus(_ element: DesktopElement) -> Bool
    /// A PNG of the window, taken without writing a file. Nil when it cannot be captured.
    func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data?
}

/// Nothing is reachable. Test mode uses it, so an automated run never touches the real screen.
final class IdleDesktopAX: DesktopAX {
    var isTrusted: Bool { false }
    var screenRecordingGranted: Bool { false }
    func runningApp(matching query: String) -> CaptureApp? { nil }
    func windows(of app: CaptureApp) -> [DesktopWindowInfo] { [] }
    func read(app: CaptureApp, window: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead? { nil }
    func attributes(of element: DesktopElement) -> AXNode? { nil }
    func actions(of element: DesktopElement) -> [String] { [] }
    func perform(_ action: String, on element: DesktopElement) -> Bool { false }
    func isSettable(_ attribute: String, on element: DesktopElement) -> Bool { false }
    func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool { false }
    func focus(_ element: DesktopElement) -> Bool { false }
    func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data? { nil }
}

/// The macOS implementation. It reads through `AXCaptureSource`, so the live tree has the same node and time budgets, the same
/// Chromium and Electron switch and the same secure field rule as screen capture.
final class LiveDesktopAX: DesktopAX {
    private final class Box { let element: AXUIElement; init(_ element: AXUIElement) { self.element = element } }

    private let source = AXCaptureSource()

    var isTrusted: Bool { AXIsProcessTrusted() }
    var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    func runningApp(matching query: String) -> CaptureApp? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        func make(_ app: NSRunningApplication) -> CaptureApp {
            CaptureApp(bundleId: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "", pid: app.processIdentifier)
        }
        if let exact = apps.first(where: { $0.bundleIdentifier?.lowercased() == wanted || $0.localizedName?.lowercased() == wanted }) { return make(exact) }
        return apps.first { $0.localizedName?.lowercased().contains(wanted) == true }.map(make)
    }

    func windows(of app: CaptureApp) -> [DesktopWindowInfo] {
        guard isTrusted else { return [] }
        let root = source.appElement(for: app)
        let focused = AXCaptureSource.element(root, "AXFocusedWindow") ?? AXCaptureSource.element(root, "AXMainWindow")
        return AXCaptureSource.elements(root, "AXWindows").map { window in
            var id: CGWindowID = 0
            let windowID = _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
            let title = AXCaptureSource.string(window, "AXTitle").flatMap { $0.isEmpty ? nil : $0 }
            return DesktopWindowInfo(title: title, windowID: windowID, focused: focused.map { CFEqual($0, window) } ?? false, element: Box(window))
        }
    }

    func read(app: CaptureApp, window: DesktopWindowInfo, budget: CaptureReadBudget) -> DesktopRead? {
        guard let element = ax(window.element) else { return nil }
        let tracker = AXCaptureSource.Budget(budget, keepElements: true)
        guard let root = AXCaptureSource.convert(element, depth: 0, budget: tracker) else { return nil }
        return DesktopRead(app: app, window: window, root: root, elements: (tracker.elements ?? []).map { Box($0) })
    }

    func attributes(of element: DesktopElement) -> AXNode? {
        guard let el = ax(element) else { return nil }
        var head: CFArray?
        let names = ["AXRole", "AXSubrole", "AXTitle", "AXValue", "AXDescription"]
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &head) == .success,
              let values = head as? [AnyObject], values.count == names.count else { return nil }
        func get(_ index: Int) -> String? {
            let value = values[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return AXCaptureSource.text(value)
        }
        guard let role = get(0) else { return nil }
        func bare(_ text: String) -> String { text.hasPrefix("AX") ? String(text.dropFirst(2)) : text }
        var node = AXNode(role: bare(role), subrole: get(1).map(bare))
        // A secure field is never read, here or anywhere.
        if node.isSecure { return node }
        node.title = get(2)
        node.value = get(3)
        node.description = get(4)
        return node
    }

    func actions(of element: DesktopElement) -> [String] {
        guard let el = ax(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func perform(_ action: String, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        return AXUIElementPerformAction(el, action as CFString) == .success
    }

    func isSettable(_ attribute: String, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func set(_ attribute: String, to text: String, on element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        return AXUIElementSetAttributeValue(el, attribute as CFString, text as CFString) == .success
    }

    func focus(_ element: DesktopElement) -> Bool {
        guard let el = ax(element) else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &role)
        if role as? String == "AXWindow" {
            let raised = AXUIElementPerformAction(el, "AXRaise" as CFString) == .success
            let main = AXUIElementSetAttributeValue(el, "AXMain" as CFString, kCFBooleanTrue) == .success
            return raised || main
        }
        return AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue) == .success
    }

    func screenshot(of window: DesktopWindowInfo, app: CaptureApp) -> Data? {
        guard let id = window.windowID, let image = ScreenOCR.screenshot(ofWindow: id, ownedBy: app.pid) else { return nil }
        return NSBitmapImageRep(cgImage: Self.scaled(image, longEdge: 1_600)).representation(using: .png, properties: [:])
    }

    /// The image, smaller when its long edge is over `longEdge`, so a window picture stays a size an agent can take in.
    static func scaled(_ image: CGImage, longEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > longEdge else { return image }
        let factor = Double(longEdge) / Double(long)
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func ax(_ element: DesktopElement) -> AXUIElement? { (element as? Box)?.element }
}
