import AppKit
import ApplicationServices

/// The macOS source. Signals come from the workspace (app switches), Accessibility notifications (window focus and title changes) and
/// global event monitors (key, scroll and click, as timing only: no key is read). A read is one budgeted walk of the focused window.
///
/// Nothing is requested until `CaptureService` starts it, so with the master switch off no permission prompt appears.
/// The window server id of an accessibility window element. It is a long-standing private symbol of HIServices that most
/// window managers use; without it OCR is skipped, never pointed at another window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

final class AXCaptureSource: CaptureSource {
    static let ownBundleId = Bundle.main.bundleIdentifier ?? "com.ironpet.app"

    /// HIServices keeps the pointer it receives in `AXObserverAddNotification`, so these are bridged once and held for the life of the
    /// process. Always pass these instances, never a fresh bridge.
    static let notifications: [CFString] = ["AXFocusedWindowChanged", "AXMainWindowChanged", "AXTitleChanged"].map { $0 as NSString as CFString }

    private let lock = NSLock()
    private var onSignal: ((CaptureSignal) -> Void)?
    private lazy var host = AXObserverHost(attach: Self.observe, onEvent: { [weak self] in self?.emit(.windowFocus) })
    private var activation: NSObjectProtocol?
    private var monitors: [Any] = []
    private var webBundles: [String: Bool] = [:]

    // MARK: Lifecycle

    func start(onSignal: @escaping (CaptureSignal) -> Void) {
        lock.withLock { self.onSignal = onSignal }
        host.start()
        DispatchQueue.main.async { [self] in
            guard activation == nil else { return }
            activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let app = Self.app(running) else { return }
                self?.attach(to: app)
                if app.bundleId != Self.ownBundleId { self?.emit(.appSwitch) }
            }
            let mask: NSEvent.EventTypeMask = [.keyDown, .scrollWheel, .leftMouseDown, .rightMouseDown]
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                switch event.type {
                case .keyDown: self?.emit(.key)
                case .scrollWheel: self?.emit(.scroll)
                default: self?.emit(.click)
                }
            }) { monitors.append(monitor) }
            if let front = NSWorkspace.shared.frontmostApplication.flatMap(Self.app) { attach(to: front) }
        }
    }

    func stop() {
        lock.withLock { onSignal = nil }
        DispatchQueue.main.async { [self] in
            if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
            activation = nil
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            host.stop()
        }
    }

    private func emit(_ signal: CaptureSignal) {
        let callback = lock.withLock { onSignal }
        callback?(signal)
    }

    private func attach(to app: CaptureApp) {
        host.detach()
        guard app.bundleId != Self.ownBundleId, isTrusted else { return }
        host.attach(to: app.pid)
    }

    /// Runs on the host's thread. The callback runs there too, so the teardown cannot overlap it.
    private static func observe(pid: pid_t, fire: @escaping () -> Void) -> (() -> Void)? {
        final class Context {
            let fire: () -> Void
            init(_ fire: @escaping () -> Void) { self.fire = fire }
        }
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue().fire()
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return nil }
        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passRetained(Context(fire))
        for name in notifications { AXObserverAddNotification(observer, element, name, context.toOpaque()) }
        let source = AXObserverGetRunLoopSource(observer)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .defaultMode)
        // The closure holds the observer, so it lives until the teardown has run.
        return {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            for name in notifications { AXObserverRemoveNotification(observer, element, name) }
            context.release()
        }
    }

    // MARK: Apps

    private static func app(_ running: NSRunningApplication) -> CaptureApp? {
        guard let bundleId = running.bundleIdentifier else { return nil }
        return CaptureApp(bundleId: bundleId, name: running.localizedName ?? bundleId, pid: running.processIdentifier)
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func frontmostApp() -> CaptureApp? { NSWorkspace.shared.frontmostApplication.flatMap(Self.app) }

    private func isWebApp(_ app: CaptureApp) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: app.pid)?.bundleURL else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let known = webBundles[url.path] { return known }
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let web = frameworks.contains { name in
            let lower = name.lowercased()
            return lower == "electron framework.framework" || lower == "chromium embedded framework.framework"
        }
        webBundles[url.path] = web
        return web
    }

    // MARK: Reading

    private final class Budget {
        let maxNodes: Int
        let deadline: TimeInterval
        var nodes = 0
        init(_ budget: CaptureReadBudget) {
            maxNodes = budget.maxNodes
            deadline = ProcessInfo.processInfo.systemUptime + budget.maxTime
        }

        func allow() -> Bool {
            if nodes >= maxNodes || ProcessInfo.processInfo.systemUptime > deadline { return false }
            nodes += 1
            return true
        }
    }

    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> WindowRead? {
        guard isTrusted else { return nil }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Chromium and Electron build their page tree only for a client that asks.
        if isWebApp(app) { AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        guard let window = Self.element(element, "AXFocusedWindow") ?? Self.element(element, "AXMainWindow") ?? Self.elements(element, "AXWindows").first else { return nil }
        let tracker = Budget(budget)
        guard let root = Self.convert(window, depth: 0, budget: tracker) else { return nil }
        let title = Self.string(window, "AXTitle").flatMap { $0.isEmpty ? nil : $0 }
        var id: CGWindowID = 0
        let windowID = _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
        return WindowRead(app: app, title: title, url: nil, root: root, windowID: windowID)
    }

    func recognizeFocusedWindow(of app: CaptureApp, windowID: UInt32?) -> [String]? {
        guard let windowID else { return nil }
        return ScreenOCR.recognizeWindow(id: windowID, ownedBy: app.pid)
    }

    // MARK: AX helpers

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let list = value as? [AnyObject] else { return [] }
        return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        return text(value)
    }

    private static func text(_ value: CFTypeRef) -> String? {
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL as URL).absoluteString }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// The attribute that lists only the on-screen children of a native list-like element. Asking for all rows makes a view-based
    /// table build the ones off screen, which can scroll it and fire more events.
    private static func visibleChildrenAttribute(role: String) -> String? {
        switch role {
        case "AXTable", "AXOutline": return "AXVisibleRows"
        case "AXList", "AXGrid", "AXBrowser": return "AXVisibleChildren"
        default: return nil
        }
    }

    /// Reads one element and its subtree. A secure field is read for role and subrole only, so its value, selection and children never
    /// enter this process's memory. A control that the text walk drops is read for its role and nothing under it.
    private static func convert(_ el: AXUIElement, depth: Int, budget: Budget) -> AXNode? {
        guard depth <= 64, budget.allow() else { return nil }
        var head: CFArray?
        AXUIElementCopyMultipleAttributeValues(el, ["AXRole", "AXSubrole"] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &head)
        let headValues = (head as? [AnyObject]) ?? []
        let roleName = headValues.first.flatMap { text($0) } ?? "?"
        let subrole = headValues.count > 1 ? text(headValues[1]) : nil
        var node = AXNode(role: roleName.hasPrefix("AX") ? String(roleName.dropFirst(2)) : roleName,
                          subrole: subrole.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 })
        if node.isSecure || CaptureText.chromeRoles.contains(node.role) || node.subrole.map(CaptureText.chromeSubroles.contains) == true { return node }

        let visible = visibleChildrenAttribute(role: roleName)
        var names = ["AXTitle", "AXValue", "AXDescription", "AXHidden", visible ?? "AXChildren"]
        if roleName == "AXWebArea" { names.append("AXURL") }
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let values = (raw as? [AnyObject]) ?? []
        func get(_ name: String) -> CFTypeRef? {
            guard let index = names.firstIndex(of: name), index < values.count else { return nil }
            let value = values[index]
            // An attribute the element lacks comes back as an AXValue of type axError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        node.title = get("AXTitle").flatMap { text($0) }
        node.value = get("AXValue").flatMap { text($0) }
        node.description = get("AXDescription").flatMap { text($0) }
        node.hidden = (get("AXHidden") as? NSNumber)?.boolValue ?? false
        if node.hidden { return node }
        node.url = get("AXURL").flatMap { text($0) }

        var children: [AnyObject]?
        if let list = get(visible ?? "AXChildren") as? [AnyObject] { children = list }
        else if visible != nil {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &value) == .success { children = value as? [AnyObject] }
        }
        for child in children ?? [] where CFGetTypeID(child) == AXUIElementGetTypeID() {
            guard let converted = convert(child as! AXUIElement, depth: depth + 1, budget: budget) else { break }
            node.children.append(converted)
        }
        return node
    }
}
