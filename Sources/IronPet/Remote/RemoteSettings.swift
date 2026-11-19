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
    @ObservedObject var remote: RemoteController
    @ObservedObject private var store = SettingsAPI.live
    @State private var baseURL = ""
    @State private var confirmRotate = false
    @State private var copied = false

    private var config: Config.Remote { store.config.remote }

    var body: some View {
        Form {
            switchSection
            if config.enabled {
                tailscaleSection
                pairSection
            }
            devicesSection
        }
        .onAppear { baseURL = config.baseUrl; remote.refreshDevices() }
    }

    private var switchSection: some View {
        Section {
            Toggle("Remote API", isOn: Binding(get: { config.enabled }, set: { on in store.update { $0.remote.enabled = on } }))
            LabeledContent("Status") { statusLabel }
        } footer: {
            Text("Off by default. When on, ironpet listens on 127.0.0.1 only, and a paired device with its own token can read and change your tasks. Anything that can reach the port still needs that token. Reach it from your phone through your own HTTPS front, such as Tailscale. Turning it off closes the port and every open connection, and paired devices stay paired.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch remote.status {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .listening(let port): Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
    }

    private var tailscaleSection: some View {
        Section("Reach it from your phone") {
            TextField("Address your phone uses", text: $baseURL, prompt: Text("https://mac.tailnet.ts.net"))
                .onSubmit { store.update { $0.remote.baseUrl = baseURL } }
                .onChange(of: baseURL) { _ in store.update { $0.remote.baseUrl = baseURL } }
            Text("Point tailscale serve at port \(String(config.port)), never 47321.").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(RemoteController.serveCommand(port: config.port)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Port 47321 is the hook server, which has no per-device tokens. The command follows `tailscale serve --help` of Tailscale 1.102 and has not been run against your tailnet here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pairSection: some View {
        Section("Pair a device") {
            if let code = remote.pairing, let link = RemoteController.pairingLink(baseURL: config.baseUrl, code: code) {
                HStack(alignment: .top, spacing: 14) {
                    if let image = Self.qr(link) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this with the ironpet app on your phone. It works once and expires in five minutes.").font(.caption)
                        Button(copied ? "Copied" : "Copy pairing link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            copied = true
                        }
                        Button("Close") { remote.stopPairing(); copied = false }
                    }
                }
            } else {
                Button("Pair a device") { copied = false; remote.startPairing() }
                    .disabled(config.baseUrl.isEmpty || remote.status == .off)
                if config.baseUrl.isEmpty { Text("Enter the address first.").font(.caption).foregroundStyle(.secondary) }
            }
            if let note = remote.pairingNote { Text(note).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var devicesSection: some View {
        Section("Paired devices") {
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
                    .confirmationDialog("Revoke every device and make a new key?", isPresented: $confirmRotate) {
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
