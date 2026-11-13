import Carbon
import Foundation

/// System-wide shortcut via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var releaseHandlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?
    let isRegistered: Bool

    private let hotKeyID: UInt32

    /// `onRelease` makes it a hold-to-talk key: `handler` runs on press and `onRelease` when the key comes up.
    init(keyCode: Int, modifiers: Int, id: UInt32, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) {
        hotKeyID = id
        Self.handlers[id] = handler
        Self.releaseHandlers[id] = onRelease
        Self.installDispatcher()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4952_5054), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
        if status != noErr { NSLog("ironpet: could not register hotkey \(id) (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[hotKeyID] = nil
        Self.releaseHandlers[hotKeyID] = nil
    }

    private static func installDispatcher() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async { (released ? HotKey.releaseHandlers[id] : HotKey.handlers[id])?() }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}
