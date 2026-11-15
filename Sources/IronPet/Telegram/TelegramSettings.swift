import SwiftUI

/// The Telegram accordion of Settings → Integrations.
struct TelegramIntegration: View {
    @ObservedObject var bridge: TelegramBridge
    @ObservedObject private var store = ConfigStore.shared
    @State private var token = ""
    @State private var tokenError = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var newUser = ""

    private var telegram: Config.Telegram { store.config.telegram }

    var body: some View {
        IntegrationAccordion(
            title: "Telegram",
            status: Self.status(bridge.status, enabled: telegram.enabled, hasToken: bridge.hasToken),
            isOn: Binding(get: { telegram.enabled }, set: { on in store.update { $0.telegram.enabled = on } })
        ) {
            Text("Off by default. When on, ironpet asks Telegram for new messages every few seconds through your own bot. A message from an allowed user goes into the chat that is open on this Mac, and the answer comes back to Telegram. Turns you start on the Mac stay on the Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(bridge.hasToken ? "Saved in Keychain" : "Bot token from BotFather", text: $token)
                    .onSubmit(saveToken)
                if !token.isEmpty { Button("Save", action: saveToken) }
                if bridge.hasToken && token.isEmpty {
                    Button("Remove") {
                        bridge.saveToken("")
                        testResult = nil
                    }
                }
                if testing { ProgressView().controlSize(.small) }
                Button("Test", action: test).disabled(testing || (!bridge.hasToken && token.isEmpty))
            }
            if tokenError {
                Text("Could not save the token to the Keychain.").font(.caption).foregroundStyle(.red)
            }
            if let testResult {
                Text(testResult.text)
                    .font(.caption)
                    .foregroundStyle(testResult.ok ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
            if !bridge.pending.isEmpty {
                Text("Waiting for approval").font(.subheadline.weight(.semibold))
                ForEach(bridge.pending) { request in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(request.user.displayName)
                            Text(Self.detail(name: request.user.username, id: request.user.id))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Allow") { bridge.allow(request.id) }.buttonStyle(.borderedProminent)
                        Button("Deny") { bridge.deny(request.id) }
                    }
                }
            }
            Text("Allowed users").font(.subheadline.weight(.semibold))
            if telegram.allowedUsers.isEmpty {
                Text("Nobody yet. Message your bot /start and allow the request.").foregroundStyle(.secondary)
            }
            ForEach(telegram.allowedUsers) { user in
                HStack {
                    VStack(alignment: .leading) {
                        Text(user.name)
                        Text(Self.detail(name: user.username, id: user.id)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { bridge.removeUser(id: user.id) }
                }
            }
            HStack {
                TextField("Add a Telegram user id", text: $newUser).onSubmit(addUser)
                Button("Add", action: addUser).disabled(Int64(newUser.trimmingCharacters(in: .whitespaces)) == nil)
            }
            Text("Only these Telegram users can reach the chat. Anyone else is ignored.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Set up").font(.subheadline.weight(.semibold))
            Text("1. In Telegram, open @BotFather and send /newbot.\n2. Paste the token it gives you above, press Save, then Test.\n3. Turn on the switch.\n4. Message your new bot /start, then press Allow in the bubble that appears next to the pet.\n\nPhotos, files and voice messages work too. Voice messages need voice notes turned on in Settings → Voice. Tool approvals arrive in Telegram with Approve and Reject buttons.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { bridge.refreshToken() }
    }

    private func saveToken() {
        tokenError = !bridge.saveToken(token)
        if !tokenError { token = "" }
    }

    private func addUser() {
        guard let id = Int64(newUser.trimmingCharacters(in: .whitespaces)) else { return }
        bridge.addUser(id: id)
        newUser = ""
    }

    private func test() {
        if !token.isEmpty { saveToken() }
        guard !tokenError else { return }
        testing = true
        testResult = nil
        Task {
            switch await bridge.test() {
            case .success(let name): testResult = (true, "Connected as \(name)")
            case .failure(let error): testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }

    static func detail(name: String?, id: Int64) -> String {
        (name.map { "@\($0), " } ?? "") + "id \(id)"
    }

    /// The header badge: Connected, Failed, Off, or Connecting while it starts. A failure carries its error for the info
    /// icon.
    static func status(_ status: TelegramBridge.Status, enabled: Bool, hasToken: Bool) -> IntegrationStatus {
        switch status {
        case .off:
            if !enabled { return .init(label: "Off", color: .secondary) }
            if !hasToken { return .init(label: "Failed", color: .red, detail: "No bot token saved. Paste the token from BotFather.") }
            return .init(label: "Connecting", color: .secondary)
        case .connecting:
            return .init(label: "Connecting", color: .secondary)
        case .polling(let bot):
            return .init(label: "Connected", color: .green, help: bot.isEmpty ? nil : "Connected as \(bot)")
        case .error(let message, let date):
            let time = date.formatted(date: .omitted, time: .standard)
            return .init(label: "Failed", color: .red, detail: "\(message)\n\nLast try \(time). ironpet keeps retrying, waiting longer after each failure.")
        }
    }
}

/// What an integration's header shows: a short label, and for a failure the error behind an info icon.
struct IntegrationStatus: Equatable {
    var label: String
    var color: Color
    var detail: String? = nil
    var help: String? = nil
}

/// One integration in Settings → Integrations: a header with a title, a short status and an on/off switch. Clicking the
/// header folds the settings below it open or shut. Turning the switch on opens it, so the setup is in view.
struct IntegrationAccordion<Content: View>: View {
    let title: String
    var status: IntegrationStatus
    @Binding var isOn: Bool
    @ViewBuilder var content: () -> Content
    @State private var expanded = false
    @State private var showingDetail = false

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                        Text(title).font(.headline)
                        Text(status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(status.color)
                            .help(status.help ?? "")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(expanded ? "collapse" : "expand")")
                if let detail = status.detail {
                    Button { showingDetail.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(status.color)
                    }
                    .buttonStyle(.plain)
                    .help("Show the error")
                    .accessibilityLabel("Show the error")
                    .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                        Text(detail)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(width: 280, alignment: .leading)
                            .padding(12)
                    }
                }
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if expanded { content() }
        }
        .onChange(of: isOn) { _, on in
            if on { withAnimation(.easeInOut(duration: 0.15)) { expanded = true } }
        }
    }
}
