import Carbon
import Combine

/// Enter and Esc as global shortcuts, held only while a voice note is recording: Enter stops and transcribes, Esc
/// cancels. They follow `VoiceController.phase`, so every way a recording can end (stop, cancel, a microphone
/// failure, the length cap, voice notes switched off) gives the keys back to the other apps.
@MainActor
final class RecordingKeys {
    /// Registers a key with the given Carbon modifiers. The returned object unregisters the key when it is released.
    typealias Registrar = (_ keyCode: Int, _ modifiers: Int, _ id: UInt32, _ handler: @escaping () -> Void) -> AnyObject?

    static let defaultRegistrar: Registrar = { keyCode, modifiers, id, handler in
        let hotKey = HotKey(keyCode: keyCode, modifiers: modifiers, id: id) { MainActor.assumeIsolated { handler() } }
        return hotKey.isRegistered ? hotKey : nil
    }

    private let register: Registrar
    /// The voice shortcut's modifiers. Carbon matches modifiers exactly, so while they are still held (hold to talk)
    /// plain Enter and Esc would not fire; the same keys are also registered with them.
    private let heldModifiers: () -> Int
    private var held: [AnyObject] = []
    private var subscription: AnyCancellable?

    /// Whether the keys are registered right now.
    var isActive: Bool { !held.isEmpty }

    init(voice: VoiceController, heldModifiers: @escaping () -> Int = { 0 },
         register: @escaping Registrar = RecordingKeys.defaultRegistrar) {
        self.register = register
        self.heldModifiers = heldModifiers
        subscription = voice.$phase.sink { [weak self, weak voice] phase in
            guard let self, let voice else { return }
            if phase == .recording { self.hold(voice) } else { self.release() }
        }
    }

    private func hold(_ voice: VoiceController) {
        guard held.isEmpty else { return }
        var keys: [(Int, Int, UInt32, () -> Void)] = [
            (kVK_Return, 0, 6, { [weak voice] in voice?.stop() }),
            (kVK_Escape, 0, 7, { [weak voice] in voice?.cancel() }),
        ]
        let modifiers = heldModifiers()
        if modifiers != 0 {
            keys += [
                (kVK_Return, modifiers, 8, { [weak voice] in voice?.stop() }),
                (kVK_Escape, modifiers, 9, { [weak voice] in voice?.cancel() }),
            ]
        }
        held = keys.compactMap { register($0.0, $0.1, $0.2, $0.3) }
    }

    private func release() {
        held = []
    }
}
