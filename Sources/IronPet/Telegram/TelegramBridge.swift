import Foundation

/// What the Telegram bridge needs from the chat. `ChatSession` is the real one.
@MainActor
protocol TelegramChatHost: AnyObject {
    /// The current chat's title, for /status.
    var telegramTitle: String { get }
    var isRunning: Bool { get }
    var telegramQueueCount: Int { get }
    var onTelegram: ((Int64, ChatSession.TelegramEvent) -> Void)? { get set }
    func submitFromTelegram(_ text: String, chat: Int64, files: [URL])
    func hasPendingApproval(_ id: UUID) -> Bool
    func decideFromTelegram(id: UUID, allow: Bool)
    /// Forgets queued messages and the pending answer for a Telegram chat.
    func cancelTelegram(chat: Int64)
}

extension ChatSession: TelegramChatHost {
    var telegramTitle: String {
        guard let first = items.lazy.compactMap({ item -> String? in
            if case .user(let text) = item.kind { return text } else { return nil }
        }).first else { return "New chat" }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }
}

/// Chat with the pet from Telegram: long-polls the user's bot, accepts messages only from allowed user ids, hands
/// them to the open chat and sends the answer of a Telegram-started turn back.
@MainActor
final class TelegramBridge: ObservableObject {
    enum Status: Equatable {
        case off
        case connecting
        case polling(bot: String)
        case error(String, Date)
    }

    struct Pending: Identifiable, Equatable {
        let user: TelegramUser
        let chat: Int64
        var id: Int64 { user.id }
    }

    /// The pieces of state the bridge reads and writes outside itself, so tests can run without config.json.
    struct Storage {
        var users: () -> [Config.Telegram.User]
        var add: (Config.Telegram.User) -> Void
        var remove: (Int64) -> Void
        var offset: () -> Int
        var setOffset: (Int) -> Void
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var hasToken = false

    /// A /start from an unknown user needs an Allow or Deny on the Mac.
    var onPairingRequest: ((Pending) -> Void)?
    /// A pairing request was answered, here or in Settings.
    var onPairingResolved: ((Int64) -> Void)?

    static let maxPending = 3
    static let pollTimeout = 30
    static let typingInterval: TimeInterval = 4

    private let client: TelegramClient
    private weak var host: TelegramChatHost?
    private let tokens: TelegramTokenStore
    private let storage: Storage
    private let petName: () -> String
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?
    private var typing: [Int64: Task<Void, Never>] = [:]
    private var outbox: Task<Void, Never>?
    private var denied: Set<Int64> = []
    private var botName: String?
    private let filesDirectory: URL
    private let voiceEnabled: () -> Bool
    /// Turns a voice file's bytes and name into text.
    private let transcribe: @Sendable (Data, String) async throws -> String
    private var inbox: Task<Void, Never>?
    private var inboxPending = 0
    /// Bumps on stop(), so incoming work from before it (a download in flight) is dropped.
    private var epoch = 0
    /// The enable setting, which outlives a stop caused by a missing token.
    private var wanted = false
    private var callbackAnswers: [Task<Void, Never>] = []

    /// An approval sent to Telegram, so the message can be edited when the Mac or Telegram answers it.
    private struct SentApproval {
        let chat: Int64
        let text: String
        var messageID: Int64?
        var outcome: String?
    }
    private var approvalMessages: [UUID: SentApproval] = [:]
    /// Approvals being decided by a Telegram tap right now, to tell them from ones the Mac answered.
    private var applying: Set<UUID> = []

    init(client: TelegramClient, host: TelegramChatHost, tokens: TelegramTokenStore, storage: Storage,
         filesDirectory: URL = Paths.telegramFiles,
         voiceEnabled: (() -> Bool)? = nil,
         transcribe: (@Sendable (Data, String) async throws -> String)? = nil,
         petName: @escaping () -> String = { "Ghost" },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         now: @escaping () -> Date = Date.init) {
        self.client = client
        self.host = host
        self.tokens = tokens
        self.storage = storage
        self.filesDirectory = filesDirectory
        self.voiceEnabled = voiceEnabled ?? { ConfigStore.shared.config.voice.enabled }
        self.transcribe = transcribe ?? TelegramVoice.configuredTranscribe
        self.petName = petName
        self.sleep = sleep
        self.now = now
        host.onTelegram = { [weak self] chat, event in self?.hostEvent(chat, event) }
    }

    /// Reads the Keychain. Called when Settings opens or polling starts, not at launch, so a user who never turns
    /// Telegram on never touches the Keychain.
    func refreshToken() { hasToken = tokens.load() != nil }

    var isRunning: Bool { pollTask != nil }

    static func backoff(failures: Int) -> TimeInterval {
        min(300, pow(2, Double(max(1, failures))))
    }

    // MARK: Settings actions

    /// Turns polling on or off to match the setting.
    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        if enabled {
            start()
        } else {
            stop()
            for request in pending { onPairingResolved?(request.id) }
            pending = []
            denied = []
            for user in storage.users() { host?.cancelTelegram(chat: user.id) }
        }
    }

    /// Saves the pasted token to the Keychain. A different bot starts with a fresh update offset.
    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = trimmed != tokens.load()
        guard tokens.save(trimmed) else { return false }
        hasToken = tokens.load() != nil
        if changed {
            storage.setOffset(0)
            botName = nil
            for request in pending { onPairingResolved?(request.id) }
            pending = []
            let restart = isRunning || wanted
            if restart {
                stop()
                if hasToken { start() }
            }
        }
        return true
    }

    /// Asks Telegram who the saved token belongs to.
    func test() async -> Result<String, TelegramError> {
        do {
            let bot = try await client.getMe()
            return .success("@" + (bot.username ?? bot.displayName))
        } catch let error as TelegramError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    func start() {
        guard pollTask == nil else { return }
        refreshToken()
        status = .connecting
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        epoch += 1
        pollTask?.cancel()
        pollTask = nil
        for task in typing.values { task.cancel() }
        typing = [:]
        status = .off
    }

    func allow(_ id: Int64) {
        guard let request = pending.first(where: { $0.id == id }), storage.users().isEmpty else { return }
        pending.removeAll { $0.id == id }
        storage.add(Config.Telegram.User(id: id, name: request.user.displayName, username: request.user.username))
        onPairingResolved?(id)
        // Pairing is for the first user only. Other waiting requests would need a deliberate add in Settings.
        for other in pending { onPairingResolved?(other.id) }
        pending = []
        reply(request.chat, "Connected. Send a message to chat with \(petName()).")
    }

    func deny(_ id: Int64) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        denied.insert(id)
        onPairingResolved?(id)
    }

    /// For ids typed by hand in Settings.
    func addUser(id: Int64) {
        guard !storage.users().contains(where: { $0.id == id }) else { return }
        storage.add(Config.Telegram.User(id: id, name: "Telegram user \(id)", username: nil))
        // A user added by hand ends pairing, like Allow does.
        for other in pending { onPairingResolved?(other.id) }
        pending = []
        onPairingResolved?(id)
    }

    /// Removes an allowed user. Their queued messages are dropped and the answer to a turn in flight is not sent.
    func removeUser(id: Int64) {
        storage.remove(id)
        stopTyping(id)
        host?.cancelTelegram(chat: id)
    }

    // MARK: Polling

    private func pollLoop() async {
        var failures = 0
        var offset = storage.offset()
        var skippedBacklog = false
        while !Task.isCancelled {
            do {
                if botName == nil {
                    let bot = try await client.getMe()
                    try Task.checkCancellation()
                    botName = "@" + (bot.username ?? bot.displayName)
                }
                if offset == 0, !skippedBacklog {
                    // A new bot's backlog is old news: skip it instead of running days-old messages through the agent.
                    let last = try await client.getUpdates(offset: -1, timeout: 0)
                    offset = (last.last?.updateId ?? -1) + 1
                    skippedBacklog = true
                    try Task.checkCancellation()
                    if offset > 0 { storage.setOffset(offset) }
                }
                try Task.checkCancellation()
                if failures == 0 { status = .polling(bot: botName ?? "") }
                let updates = try await client.getUpdates(offset: offset, timeout: Self.pollTimeout)
                try Task.checkCancellation()
                failures = 0
                status = .polling(bot: botName ?? "")
                for update in updates { offset = max(offset, update.updateId + 1) }
                handle(updates)
                if !updates.isEmpty { storage.setOffset(offset) }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                if case TelegramError.noToken = error { botName = nil }
                status = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, now())
                if case TelegramError.api(401, _) = error { botName = nil }
                do { try await sleep(Self.backoff(failures: failures)) } catch { return }
            }
        }
    }

    // MARK: Incoming

    func handle(_ update: TelegramUpdate) { handle([update]) }

    /// One poll's updates. Photos or documents of one album arrive as separate messages with a shared
    /// `media_group_id`; they become one message to the chat.
    func handle(_ updates: [TelegramUpdate]) {
        var groups: [[TelegramMessage]] = []
        for update in updates {
            if let callback = update.callbackQuery {
                handleCallback(callback)
            } else if let message = update.message, let from = message.from, from.isBot != true, message.chat.type == "private" {
                if let id = message.mediaGroupId, let last = groups.last?.last, last.mediaGroupId == id, last.from?.id == from.id {
                    groups[groups.count - 1].append(message)
                } else {
                    groups.append([message])
                }
            }
        }
        for group in groups {
            guard let first = group.first, let from = first.from else { continue }
            if storage.users().contains(where: { $0.id == from.id }) {
                handleAllowed(group)
            } else {
                handleStranger(first, from: from)
            }
        }
    }

    private static func command(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
        // A file path such as /Users/me/main.swift is a prompt, not a command.
        guard !word.dropFirst().contains("/") else { return nil }
        return word.split(separator: "@").first.map { String($0).lowercased() }
    }

    /// Someone who is not allowed. The only thing that gets a reaction is /start while nobody is paired yet.
    private func handleStranger(_ message: TelegramMessage, from: TelegramUser) {
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.command(text) == "/start", storage.users().isEmpty, !denied.contains(from.id),
              !pending.contains(where: { $0.id == from.id }), pending.count < Self.maxPending else { return }
        let request = Pending(user: from, chat: message.chat.id)
        pending.append(request)
        onPairingRequest?(request)
        reply(message.chat.id, "Waiting for approval on the Mac.")
    }

    /// Messages from an allowed user. Text goes straight in when nothing is downloading, so messages keep their order;
    /// anything with a file waits in line behind earlier downloads.
    private func handleAllowed(_ group: [TelegramMessage]) {
        guard let first = group.first else { return }
        let chat = first.chat.id
        let media = group.flatMap(TelegramMediaStore.media(in:))
        let text = group.compactMap { ($0.caption ?? $0.text)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if media.isEmpty {
            if text.isEmpty { return reply(chat, "That kind of message is not supported. Send text, a photo, a file or a voice message.") }
            if inboxPending == 0 {
                handleText(text, chat: chat)
            } else {
                enqueueIncoming { [self] in handleText(text, chat: chat) }
            }
        } else {
            enqueueIncoming { [self] in await handleMedia(media, text: text, chat: chat) }
        }
    }

    private func handleText(_ text: String, chat: Int64) {
        guard let host else { return }
        switch Self.command(text) {
        case "/start":
            reply(chat, "Connected. Send a message to chat with \(petName()).")
        case "/status":
            let queued = host.telegramQueueCount
            let state = host.isRunning ? "busy" + (queued > 0 ? " (\(queued) queued)" : "") : "idle"
            reply(chat, "Connected. Chat: \(host.telegramTitle). \(petName()) is \(state).")
        default:
            // Anything else, including /review or a path, is a prompt.
            host.submitFromTelegram(text, chat: chat, files: [])
        }
    }

    /// Downloads the files, transcribes a voice message, and only then sends one message to the chat. Any failure
    /// replies in Telegram and sends nothing.
    private func handleMedia(_ media: [TelegramMedia], text: String, chat: Int64) async {
        let started = epoch
        // Refuse before downloading anything, so one oversized file does not leave the others half attached.
        for item in media where (item.attachment.fileSize ?? 0) > TelegramMediaStore.maxBytes {
            return reply(chat, TelegramMediaError.tooLarge(name: item.name, bytes: item.attachment.fileSize).localizedDescription)
        }
        let voices = media.filter { $0.kind == .voice }
        if !voices.isEmpty, !voiceEnabled() {
            return reply(chat, "Voice messages need voice notes turned on in Settings → Voice on the Mac.")
        }
        var urls: [URL] = []
        var transcripts: [String] = []
        do {
            for item in media {
                let (data, name) = try await TelegramMediaStore.fetch(item, with: client)
                if item.kind == .voice {
                    let transcript = try await transcribe(data, name)
                    guard !transcript.isEmpty else {
                        return reply(chat, "I could not hear any speech in that voice message.")
                    }
                    transcripts.append(transcript)
                } else {
                    urls.append(try TelegramMediaStore.save(data, name: name, chat: chat, root: filesDirectory))
                }
            }
        } catch let error as TelegramMediaError {
            return reply(chat, error.localizedDescription)
        } catch {
            let what = voices.isEmpty ? "get that file" : "transcribe that voice message"
            return reply(chat, "Could not \(what): \(error.localizedDescription)")
        }
        guard epoch == started, storage.users().contains(where: { $0.id == chat }) else { return }
        for transcript in transcripts { reply(chat, "🎙 \(transcript)") }
        let message = ([text] + transcripts).filter { !$0.isEmpty }.joined(separator: "\n")
        host?.submitFromTelegram(message, chat: chat, files: urls)
    }

    /// Runs incoming work one item at a time, in arrival order.
    private func enqueueIncoming(_ work: @escaping @MainActor () async -> Void) {
        inboxPending += 1
        let previous = inbox
        let started = epoch
        inbox = Task { @MainActor [weak self] in
            await previous?.value
            if self?.epoch == started { await work() }
            self?.inboxPending -= 1
        }
    }

    /// A tap on an Approve or Reject button.
    private func handleCallback(_ callback: TelegramCallback) {
        func answer(_ text: String, alert: Bool = false) {
            // Not on the ordered outbox: Telegram only accepts the answer for a short while.
            callbackAnswers.append(Task { [client] in try? await client.answerCallback(id: callback.id, text: text, alert: alert) })
        }
        guard callback.from.isBot != true, storage.users().contains(where: { $0.id == callback.from.id }) else {
            return answer("Not authorised.", alert: true)
        }
        let parts = (callback.data ?? "").split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "a", let id = UUID(uuidString: parts[1]), parts[2] == "1" || parts[2] == "0",
              callback.message?.chat.id == callback.from.id, approvalMessages[id]?.chat == callback.from.id else {
            return answer("That button is no longer active.")
        }
        guard let host, host.hasPendingApproval(id) else {
            return answer("Already answered.")
        }
        let allow = parts[2] == "1"
        applying.insert(id)
        host.decideFromTelegram(id: id, allow: allow)
        applying.remove(id)
        answer(allow ? "Approved." : "Rejected.")
    }

    // MARK: Outgoing

    private func hostEvent(_ chat: Int64, _ event: ChatSession.TelegramEvent) {
        // In a private chat the chat id is the user id. Nothing goes to someone who was removed.
        guard storage.users().contains(where: { $0.id == chat }) else { return }
        switch event {
        case .queued:
            reply(chat, "\(petName()) is busy on the Mac. Your message is queued.")
        case .started:
            startTyping(chat)
        case .approval(let id, let title, let detail):
            sendApproval(id: id, chat: chat, title: title, detail: detail)
        case .approvalDecided(let id, let outcome):
            approvalDecided(id: id, outcome: outcome)
        case .finished(let text):
            stopTyping(chat)
            send(chat, markdown: text ?? "(\(petName()) finished without a written answer.)")
        case .failed(let message):
            stopTyping(chat)
            reply(chat, "That did not work: \(message)")
        }
    }

    /// Sends the approval with the same title and detail the Mac shows, and Approve and Reject buttons. The Mac
    /// offers no "Always", so there is no such button.
    private func sendApproval(id: UUID, chat: Int64, title: String, detail: String) {
        let text = "\(petName()) wants to: \(title.prefix(500))\n\n\(detail.prefix(2500))"
        approvalMessages[id] = SentApproval(chat: chat, text: text)
        let buttons = [TelegramButton(text: "Approve", data: "a:\(id.uuidString):1"),
                       TelegramButton(text: "Reject", data: "a:\(id.uuidString):0")]
        enqueue { [client, weak self] in
            do {
                let messageID = try await client.sendMessage(chat: chat, text: text, html: false, buttons: buttons)
                await self?.approvalSent(id: id, messageID: messageID)
            } catch {
                await self?.approvalSendFailed(id: id, chat: chat)
            }
        }
    }

    private func approvalSendFailed(id: UUID, chat: Int64) {
        approvalMessages.removeValue(forKey: id)
        reply(chat, "\(petName()) needs an approval, but it could not be shown here. Answer it on the Mac.")
    }

    private func approvalSent(id: UUID, messageID: Int64) {
        guard var sent = approvalMessages[id] else { return }
        sent.messageID = messageID
        approvalMessages[id] = sent
        // Answered before Telegram confirmed the message: edit it now.
        if sent.outcome != nil { editApproval(id) }
    }

    private func approvalDecided(id: UUID, outcome: ChatSession.ApprovalOutcome) {
        guard var sent = approvalMessages[id] else { return }
        switch outcome {
        case .allowed: sent.outcome = applying.contains(id) ? "✅ Approved from Telegram." : "Answered on the Mac: allowed."
        case .denied: sent.outcome = applying.contains(id) ? "❌ Rejected from Telegram." : "Answered on the Mac: denied."
        case .ended: sent.outcome = "No longer needed: the turn ended."
        }
        approvalMessages[id] = sent
        if sent.messageID != nil { editApproval(id) }
    }

    private func editApproval(_ id: UUID) {
        guard let sent = approvalMessages.removeValue(forKey: id), let messageID = sent.messageID, let outcome = sent.outcome else { return }
        enqueue { [client] in
            try? await client.editMessage(chat: sent.chat, messageID: messageID, text: String(sent.text.prefix(3500)) + "\n\n" + outcome)
        }
    }

    private func startTyping(_ chat: Int64) {
        typing[chat]?.cancel()
        typing[chat] = Task { [client, sleep] in
            while !Task.isCancelled {
                try? await client.sendChatAction(chat: chat)
                do { try await sleep(Self.typingInterval) } catch { return }
            }
        }
    }

    private func stopTyping(_ chat: Int64) {
        typing.removeValue(forKey: chat)?.cancel()
    }

    /// A short plain-text message.
    private func reply(_ chat: Int64, _ text: String) {
        enqueue { [client] in try? await client.sendMessage(chat: chat, text: text, html: false) }
    }

    /// An agent answer: converted to Telegram HTML, split at the message limit, and sent in order. If Telegram
    /// refuses the HTML, that part goes out as plain text.
    private func send(_ chat: Int64, markdown: String) {
        let parts = TelegramFormat.parts(markdown)
        enqueue { [client] in
            for part in parts {
                do {
                    try await client.sendMessage(chat: chat, text: part.html, html: true)
                } catch TelegramError.api(let code, _) where code == 400 {
                    var rest = Substring(part.source)
                    while !rest.isEmpty {
                        try? await client.sendMessage(chat: chat, text: String(rest.prefix(TelegramFormat.limit)), html: false)
                        rest = rest.dropFirst(TelegramFormat.limit)
                    }
                } catch {
                    NSLog("ironpet: could not send a Telegram message: \(error.localizedDescription)")
                    // Sending on would leave a gap in the answer.
                    _ = try? await client.sendMessage(chat: chat, text: "The rest of that answer could not be sent.", html: false)
                    return
                }
            }
        }
    }

    /// Sends run one after another, so a long answer's parts and the replies around it keep their order.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = outbox
        outbox = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits until everything queued so far has been sent. For tests.
    func flush() async {
        // Incoming work queues replies, and replies can finish an approval that queues an edit, so go round twice.
        for _ in 0..<3 {
            await inbox?.value
            await outbox?.value
            let answers = callbackAnswers
            callbackAnswers = []
            for task in answers { await task.value }
        }
    }
}
