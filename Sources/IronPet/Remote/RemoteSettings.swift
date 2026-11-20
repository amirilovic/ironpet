import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → Devices: the switch for the remote API, the pairing code and the paired devices.
struct RemoteSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let remote = model.remote {
            RemoteSettingsBody(remote: remote).formStyle(.grouped)
        } else {
            Form { Text("The remote API is not available.").foregroundStyle(.secondary) }.formStyle(.grouped)
        }
    }
}

private struct RemoteSettingsBody: View {
    private static let customTag = "__custom__"

    @ObservedObject var remote: RemoteController
    @ObservedObject private var store = SettingsAPI.live
    @State private var machineName = ""
    @State private var customText = ""
    @State private var customMode = false
    @State private var confirmRotate = false
    @State private var copied = false

    private var config: Config.Remote { store.config.remote }

    var body: some View {
        Form {
            switchSection
            if config.enabled { pairSection }
            devicesSection
        }
        .onAppear {
            machineName = config.machineName
            let known = remote.addresses.contains { $0.value == config.address }
            customMode = !config.address.isEmpty && !known
            customText = customMode ? config.address : ""
            remote.refreshDevices()
            remote.refreshAddresses()
            remote.pageAppeared()
        }
        // The code is only good while this page shows it.
        .onDisappear { remote.stopPairing(); copied = false }
        .onChange(of: remote.pairing) { _ in remote.ensurePairing() }
    }

    private var switchSection: some View {
        Section {
            Toggle("Remote API", isOn: Binding(get: { config.enabled }, set: { on in store.update { $0.remote.enabled = on } }))
            LabeledContent("Status") { statusLabel }
        } footer: {
            Text("Off by default. When on, ironpet listens on the network address you pick below over HTTPS, and on 127.0.0.1. A paired device with its own token can read and change your tasks, and anything else that reaches the port is refused without one. On a public Wi-Fi, others on that network can reach the pairing endpoint, so keep it off there. Turning it off closes the port and every open connection, and paired devices stay paired.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch remote.status {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .listening(let port): Label(listeningText(port), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
    }

    private func listeningText(_ port: Int) -> String {
        switch remote.endpoint {
        case .direct(let ip, _): return "Listening on \(ip):\(String(port)) (HTTPS)"
        case .front, .none: return "Listening on 127.0.0.1:\(String(port))"
        }
    }

    private var selection: Binding<String> {
        Binding(get: {
            if customMode { return Self.customTag }
            if config.address.isEmpty { return remote.addresses.first?.value ?? "" }
            return remote.addresses.contains { $0.value == config.address } ? config.address : Self.customTag
        }, set: { value in
            if value == Self.customTag {
                customMode = true
            } else {
                customMode = false
                store.update { $0.remote.address = value }
            }
        })
    }

    private var pairSection: some View {
        Section("Pair this Mac") {
            TextField("Name", text: $machineName, prompt: Text(RemoteController.machineName("")))
                .onChange(of: machineName) { _ in store.update { $0.remote.machineName = machineName } }
            HStack {
                Picker("Network", selection: selection) {
                    ForEach(remote.addresses) { Text($0.label).tag($0.value) }
                    Text("Add custom address…").tag(Self.customTag)
                }
                Button { remote.refreshAddresses() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the network addresses again")
            }
            if selection.wrappedValue == Self.customTag { customHelp }
            if let link = remote.pairingLink, let code = remote.pairing {
                qrBlock(link: link, code: code)
            } else if remote.endpoint == .none, case .listening = remote.status {
                Text("No network address found. Connect to Wi-Fi or Tailscale and press refresh, or add a custom address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = remote.pairingNote {
                Text(note).font(.caption).foregroundStyle(.orange)
                Button("Regenerate code") { copied = false; remote.startPairing() }
            }
            Text("Phone must be on this Wi-Fi or connected through Tailscale.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func qrBlock(link: String, code: RemotePairingCode) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let image = Self.qr(link) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan this with the ironpet app on your phone. The code works once and expires in five minutes.").font(.caption)
                Button("Regenerate code") { copied = false; remote.startPairing() }
                Button(copied ? "Copied" : "Copy pairing link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                }
            }
        }
    }

    private var customHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Custom address", text: $customText, prompt: Text("https://mac.tailnet.ts.net"))
                .onSubmit { store.update { $0.remote.address = customText } }
            // Saving on every keystroke would restart the listener on each partial address.
            Button("Use this address") { store.update { $0.remote.address = customText } }
                .disabled(customText.trimmingCharacters(in: .whitespaces) == config.address)
            Text("An IPv4 address of this Mac makes ironpet listen there over HTTPS. A URL or host name is your own HTTPS front, such as Tailscale Serve or a tunnel. It forwards to 127.0.0.1:\(String(config.port)) and has its own certificate, so the code carries no certificate pin.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Point a front at port \(String(config.port)), never 47321, the hook server.").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(RemoteController.serveCommand(port: config.port)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var devicesSection: some View {
        Section("Devices paired with \(remote.machineName)") {
            if remote.devices.isEmpty { Text("No devices are paired.").foregroundStyle(.secondary) }
            ForEach(remote.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(Self.detail(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { remote.revoke(device.id) }
                }
            }
            if !remote.devices.isEmpty {
                Button("Revoke all and rotate", role: .destructive) { confirmRotate = true }
                    .confirmationDialog("Revoke every device and make a new certificate?", isPresented: $confirmRotate) {
                        Button("Revoke all", role: .destructive) { remote.revokeAllAndRotate() }
                    } message: { Text("Every device must pair again, and QR codes made earlier stop working.") }
            }
        }
    }

    static func detail(_ device: RemoteDevice) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        var parts = ["Paired \(device.created.formatted(style))"]
        parts.append(device.lastSeen.map { "last seen \($0.formatted(style))" } ?? "never seen")
        if let origin = device.origin, !origin.isEmpty { parts.append("from \(origin)") }
        return parts.joined(separator: ", ")
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
