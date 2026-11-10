import Carbon
import Foundation

/// System-wide shortcut via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?
    let isRegistered: Bool

    private let hotKeyID: UInt32

    init(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        hotKeyID = id
        Self.handlers[id] = handler
        Self.installDispatcher()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4952_5054), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
        if status != noErr { NSLog("ironpet: could not register hotkey \(id) (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[hotKeyID] = nil
    }

    private static func installDispatcher() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
