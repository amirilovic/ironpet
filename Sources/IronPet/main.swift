import AppKit
import SwiftUI

let app = NSApplication.shared

if CommandLine.arguments.contains("--uninstall") {
    // Used by scripts/uninstall.sh: removes only ironpet's hooks and its login item, then exits.
    do {
        let changed = try HookInstaller().uninstall()
        print(changed.isEmpty ? "No ironpet hooks found" : changed.map { "Removed ironpet hooks from \($0.path)" }.joined(separator: "\n"))
    } catch {
        FileHandle.standardError.write(Data("Could not remove hooks: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    if LoginItem.isEnabled {
        LoginItem.set(false)
        print("Removed the login item")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-chat-preview"), CommandLine.arguments.count > index + 1 {
    // Renders the chat bubble with sample content to a PNG, for checking the design without clicking through it.
    MainActor.assumeIsolated {
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        for (suffix, running) in [("running", true), ("done", false)] {
            let session = ChatSession()
            session.loadPreview(running: running)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: ChatView(session: session, close: {}))
            window.contentView = host
            let size = CGSize(width: 520, height: 640)
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = output.deletingPathExtension().appendingPathExtension("\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            print("wrote \(file.path)")
        }
    }
    exit(0)
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
