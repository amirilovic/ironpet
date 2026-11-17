import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// The macOS source: Accessibility notifications on a dedicated run-loop thread, a budgeted read of an app's focused window into the
/// normalized tree, and on-device OCR of small rectangles. Nothing here runs on the main thread except the workspace notification
/// callbacks, which only forward an event to the capture queue.
///
/// Nothing is requested until `CaptureService` starts it, so with the master switch off no permission prompt appears.
final class AXCaptureSource: CaptureSource {
    static let ownBundleId = Bundle.main.bundleIdentifier ?? "com.ironpet.app"

    /// HIServices keeps the pointer it receives in `AXObserverAddNotification` and uses it again later, when it re-registers after a
    /// remote process changes. A `String as CFString` made inside the call is freed right after it returns, so these are bridged once
    /// and held here for the life of the process. Always pass these instances, never a fresh bridge.
    static let notifications: [(name: CFString, kind: CaptureEventKind)] = ([
        ("AXFocusedUIElementChanged", .focusChanged), ("AXFocusedWindowChanged", .focusChanged), ("AXMainWindowChanged", .focusChanged),
        ("AXTitleChanged", .titleChanged), ("AXValueChanged", .valueChanged), ("AXSelectedChildrenChanged", .selectionChanged),
        ("AXSelectedRowsChanged", .selectionChanged), ("AXLoadComplete", .titleChanged), ("AXLiveRegionChanged", .liveRegionChanged),
    ] as [(String, CaptureEventKind)]).map { (name: $0.0 as NSString as CFString, kind: $0.1) }

    private static let focusedElementChanged = notifications[0].name

    /// Passed to the C callback through `refcon`.
    private final class Context {
        let app: CaptureApp
        let emit: (CaptureEvent) -> Void
        init(app: CaptureApp, emit: @escaping (CaptureEvent) -> Void) {
            self.app = app
            self.emit = emit
        }
    }

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var onEvent: ((CaptureEvent) -> Void)?
    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var context: Unmanaged<Context>?
    private var observerApp: pid_t?
    private var activation: NSObjectProtocol?
    private var webBundles: [String: Bool] = [:]

    // MARK: Lifecycle

    func start(onEvent: @escaping (CaptureEvent) -> Void) {
        lock.lock()
        self.onEvent = onEvent
        let running = thread != nil
        lock.unlock()
        if running { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            // A far-future timer keeps the run loop alive while no observer is attached.
            var timerContext = CFRunLoopTimerContext()
            let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, { _, _ in }, &timerContext)
            CFRunLoopAddTimer(loop, timer, .defaultMode)
            self?.lock.lock()
            self?.runLoop = loop
            self?.lock.unlock()
            ready.signal()
            while self?.thread?.isCancelled == false { CFRunLoopRunInMode(.defaultMode, 3600, false) }
        }
        thread.name = "ironpet.capture.ax"
        thread.qualityOfService = .utility
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
        _ = ready.wait(timeout: .now() + 5)
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let app = Self.app(running) else { return }
            self?.attach(to: app)
        }
        if let front = frontmostApp() { attach(to: front) }
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        detach()
        lock.lock()
        thread?.cancel()
        let loop = runLoop
        thread = nil
        runLoop = nil
        onEvent = nil
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    private func attach(to app: CaptureApp) {
        guard app.bundleId != Self.ownBundleId else { return }
        lock.lock()
        let loop = runLoop
        let emit = onEvent
        lock.unlock()
        guard let loop, let emit else { return }
        detach()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
            let kind = AXCaptureSource.notifications.first { CFEqual($0.name, notification) }?.kind ?? .focusChanged
            let button = kind == .focusChanged && CFEqual(notification, AXCaptureSource.focusedElementChanged) ? AXCaptureSource.buttonTitle(element) : nil
            context.emit(CaptureEvent(app: context.app, kind: kind, button: button))
        }
        guard AXObserverCreate(app.pid, callback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(app.pid)
        let context = Unmanaged.passRetained(Context(app: app, emit: emit))
        for entry in Self.notifications { AXObserverAddNotification(observer, element, entry.name, context.toOpaque()) }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(loop, source, .defaultMode)
        CFRunLoopWakeUp(loop)
        lock.lock()
        self.observer = observer
        observerApp = app.pid
        observerSource = source
        self.context = context
        lock.unlock()
        emit(CaptureEvent(app: app, kind: .appActivated))
    }

    private func detach() {
        lock.lock()
        let loop = runLoop, source = observerSource, context = self.context, observer = self.observer, observerApp = self.observerApp
        self.observer = nil
        self.observerApp = nil
        observerSource = nil
        self.context = nil
        lock.unlock()
        // Order matters: stop HIServices from calling back, then drop the refcon it was given.
        if let observer, let app = observerApp {
            let element = AXUIElementCreateApplication(app)
            for entry in Self.notifications { AXObserverRemoveNotification(observer, element, entry.name) }
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
            if let loop { CFRunLoopRemoveSource(loop, source, .defaultMode) }
        }
        context?.release()
    }

    // MARK: Apps

    private static func app(_ running: NSRunningApplication) -> CaptureApp? {
        guard let bundleId = running.bundleIdentifier else { return nil }
        return CaptureApp(bundleId: bundleId, name: running.localizedName ?? bundleId, pid: running.processIdentifier)
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func frontmostApp() -> CaptureApp? { NSWorkspace.shared.frontmostApplication.flatMap(Self.app) }

    func isWebApp(_ app: CaptureApp) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: app.pid)?.bundleURL else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let known = webBundles[url.path] { return known }
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? []
        let web = frameworks.contains { name in
            let lower = name.lowercased()
            return lower == "electron framework.framework" || lower == "chromium embedded framework.framework"
                || (lower.hasSuffix(" framework.framework")
                    && FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/\(name)/Libraries/libvk_swiftshader.dylib").path))
        }
        webBundles[url.path] = web
        return web
    }

    func enableWebAccessibility(_ app: CaptureApp) {
        // Chromium builds its renderer tree only for assistive clients that ask.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: Reading

    private final class Budget {
        let maxNodes: Int
        let deadline: TimeInterval
        var nodes = 0
        var truncated = false
        init(_ budget: CaptureReadBudget) {
            maxNodes = budget.maxNodes
            deadline = ProcessInfo.processInfo.systemUptime + budget.maxTime
        }

        func allow() -> Bool {
            if nodes >= maxNodes || ProcessInfo.processInfo.systemUptime > deadline {
                truncated = true
                return false
            }
            nodes += 1
            return true
        }
    }

    func readFocusedWindow(of app: CaptureApp, budget: CaptureReadBudget) -> CaptureSnapshot? {
        guard isTrusted else { return nil }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        let web = isWebApp(app)
        // A dormant Chromium or Electron tree needs a moment after AXManualAccessibility.
        let attempts = web ? 4 : 1
        var last: (CaptureNode, String?, Bool)?
        for attempt in 0..<attempts {
            guard let window = Self.element(element, "AXFocusedWindow") ?? Self.element(element, "AXMainWindow")
                    ?? Self.elements(element, "AXWindows").first else { return nil }
            let tracker = Budget(budget)
            let root = Self.convert(window, depth: 0, budget: tracker, forceDOM: web, inWeb: false)
            let title = Self.string(window, "AXTitle").flatMap { $0.isEmpty ? nil : $0 }
            let dormant = web && (root.map(Self.isDormant) ?? true)
            if let root { last = (root, title, tracker.truncated) }
            if !dormant || attempt == attempts - 1 { break }
            Thread.sleep(forTimeInterval: 0.12)
        }
        guard let (root, title, truncated) = last else { return nil }
        return CaptureSnapshot(app: app, windowTitle: title, url: Self.primaryWebAreaURL(root, windowTitle: title), root: root,
                               capturedAt: Int64(Date().timeIntervalSince1970 * 1000), truncated: truncated)
    }

    private static func isDormant(_ root: CaptureNode) -> Bool {
        var count = 0
        var signal = false
        func walk(_ node: CaptureNode) {
            count += 1
            signal = signal || !(node.value ?? "").isEmpty || node.attrs["url"] != nil
            node.children.forEach(walk)
        }
        walk(root)
        return count < 6 || !signal
    }

    // MARK: Web area

    private static func primaryWebAreaURL(_ root: CaptureNode, windowTitle: String?) -> String? {
        func readable(_ node: CaptureNode) -> Bool {
            ((node.role == "StaticText" || node.role == "Heading") && !(node.value ?? "").isEmpty) || node.children.contains(where: readable)
        }
        func score(_ node: CaptureNode) -> Int {
            var total = 0
            if node.focused { total += 20 }
            if let frame = node.frame, frame.width > 1, frame.height > 1 { total += 10 }
            if readable(node) { total += 10 }
            if node.attrs["url"] != nil { total += 20 }
            if let name = node.name?.lowercased(), let title = windowTitle?.lowercased(), !name.isEmpty, !title.isEmpty, name.contains(title) || title.contains(name) { total += 5 }
            return total
        }
        var best: (Int, CaptureNode)?
        func walk(_ node: CaptureNode) {
            if node.role == "WebArea" {
                let value = score(node)
                if best == nil || value > best!.0 { best = (value, node) }
            }
            node.children.forEach(walk)
        }
        walk(root)
        return best?.1.attrs["url"]
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

    private static func rect(_ value: CFTypeRef) -> CaptureRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var out = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &out) else { return nil }
        return CaptureRect(x: out.origin.x, y: out.origin.y, width: out.size.width, height: out.size.height)
    }

    /// The title of `el` when it is a button. A click on a button moves focus to it, which is how a submit is noticed.
    private static func buttonTitle(_ el: AXUIElement) -> String? {
        guard string(el, "AXRole") == "AXButton" else { return nil }
        return [string(el, "AXTitle"), string(el, "AXDescription")].compactMap { $0 }.first { !$0.isEmpty }
    }

    private static let textEntry: Set<String> = ["TextArea", "TextField", "SearchField", "ComboBox"]

    /// The attribute that lists only the on-screen children of a native list-like element. Asking for all rows makes a view-based
    /// table build the ones off screen, which can scroll it and fire more events.
    private static func visibleChildrenAttribute(role: String, web: Bool) -> String? {
        if web { return nil }
        switch role {
        case "AXTable", "AXOutline": return "AXVisibleRows"
        case "AXList", "AXGrid", "AXBrowser": return "AXVisibleChildren"
        default: return nil
        }
    }

    /// Reads one element and its subtree. A secure field is read for role and subrole only, so its value, placeholder, selection and
    /// children never enter this process's memory.
    private static func convert(_ el: AXUIElement, depth: Int, budget: Budget, forceDOM: Bool, inWeb: Bool) -> CaptureNode? {
        guard depth <= 64, budget.allow() else { return nil }
        var head: CFArray?
        AXUIElementCopyMultipleAttributeValues(el, ["AXRole", "AXSubrole"] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &head)
        let headValues = (head as? [AnyObject]) ?? []
        let roleName = headValues.first.flatMap { text($0) } ?? "?"
        let subrole = headValues.count > 1 ? text(headValues[1]) : nil
        var node = CaptureNode(role: roleName.hasPrefix("AX") ? String(roleName.dropFirst(2)) : roleName)
        if let subrole { node.attrs["subrole"] = subrole }
        if node.isSecure { return node }

        let entry = textEntry.contains(node.role)
        let readsDOM = inWeb || forceDOM || roleName == "AXWebArea"
        var names = ["AXTitle", "AXValue", "AXURL", "AXDocument", "AXDescription", "AXHelp", "AXIdentifier", "AXFocused", "AXSelected", "AXHidden", "AXFrame"]
        let visible = visibleChildrenAttribute(role: roleName, web: readsDOM)
        names.append(visible ?? "AXChildren")
        if roleName == "AXHeading" { names.append("AXHeadingLevel") }
        if entry { names += ["AXPlaceholderValue", "AXSelectedText"] }
        if readsDOM { names += ["AXDOMClassList", "AXDOMIdentifier"] }
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
        node.name = get("AXTitle").flatMap { text($0) }
        node.value = get("AXValue").flatMap { text($0) }
        if let url = get("AXURL").flatMap({ text($0) }) ?? get("AXDocument").flatMap({ text($0) }) { node.attrs["url"] = url }
        if let label = get("AXDescription").flatMap({ text($0) }) ?? get("AXHelp").flatMap({ text($0) }) { node.attrs["label"] = label }
        if let identifier = get("AXIdentifier").flatMap({ text($0) }) { node.attrs["identifier"] = identifier }
        // The label element of a field, for the form body. One extra read per input, not per node.
        if CaptureForm.inputs.contains(node.role), let label = element(el, "AXTitleUIElement"),
           let title = string(label, "AXValue") ?? string(label, "AXTitle"), !title.isEmpty { node.attrs["title_ui"] = title }
        node.focused = (get("AXFocused") as? NSNumber)?.boolValue ?? false
        node.selected = (get("AXSelected") as? NSNumber)?.boolValue ?? false
        node.hidden = (get("AXHidden") as? NSNumber)?.boolValue ?? false
        node.frame = get("AXFrame").flatMap(rect)
        if let level = get("AXHeadingLevel").flatMap({ text($0) }) { node.attrs["heading_level"] = level }
        if let placeholder = get("AXPlaceholderValue").flatMap({ text($0) }) { node.attrs["placeholder"] = placeholder }
        if let selected = get("AXSelectedText").flatMap({ text($0) }) { node.attrs["selected_text"] = selected }
        if let classes = get("AXDOMClassList") as? [String], !classes.isEmpty { node.attrs["dom_classes"] = classes.joined(separator: " ") }
        if let domId = get("AXDOMIdentifier").flatMap({ text($0) }) { node.attrs["dom_id"] = domId }

        var children: [AnyObject]?
        if let list = get(visible ?? "AXChildren") as? [AnyObject] { children = list }
        else if visible != nil {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &value) == .success { children = value as? [AnyObject] }
        }
        for child in children ?? [] where CFGetTypeID(child) == AXUIElementGetTypeID() {
            guard let converted = convert(child as! AXUIElement, depth: depth + 1, budget: budget, forceDOM: forceDOM, inWeb: readsDOM) else { break }
            node.children.append(converted)
        }
        return node
    }

    // MARK: Screen text

    var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    func readText(in rect: CaptureRect) -> [String]? {
        guard hasScreenAccess else { return nil }
        guard #available(macOS 15.2, *) else { return nil }
        let area = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        SCScreenshotManager.captureImage(in: area) { result, _ in
            image = result
            done.signal()
        }
        guard done.wait(timeout: .now() + 1.5) == .success, let image else { return nil }
        return Self.recognize(image)
    }

    /// Lines of text in an image, top to bottom and then left to right. The image is not kept.
    static func recognize(_ image: CGImage) -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Names are not dictionary words; correction would turn a surname into dictionary words.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        var lines: [(top: Double, left: Double, text: String)] = []
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let box = observation.boundingBox
            lines.append((1 - (box.origin.y + box.size.height), box.origin.x, text))
        }
        lines.sort { abs($0.top - $1.top) < 0.02 ? $0.left < $1.left : $0.top < $1.top }
        return lines.map(\.text)
    }
}
