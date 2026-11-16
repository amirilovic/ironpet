import AppKit
import ImageIO
import SwiftUI

struct ChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var config = ConfigStore.shared
    let close: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var showSettings = false
    @State private var follow = TranscriptFollow()
    @State private var topRowID: UUID?
    @State private var scrollActivity = ScrollActivity()
    @State private var lastContentHeight: CGFloat = 0
    @State private var lastItemID: UUID?
    @State private var lastContentKey = ""
    @State private var settleScroll: DispatchWorkItem?
    @State private var lastGap: CGFloat = 0
    @State private var lastWidth: CGFloat = 0
    @State private var resizing = false
    @State private var resizeWasPinned = true
    @State private var resizeAnchor: UUID?
    @State private var resizeEnd: DispatchWorkItem?
    /// How many of the newest items the transcript renders. A resumed session can hold thousands.
    @State private var shownItems = TranscriptGroup.pageSize
    @State private var findQuery = ""
    /// The query after a 150 ms pause, so typing does not search and re-render on every keystroke.
    @State private var activeQuery = ""
    @State private var findMatches: [ChatFind.Match] = []
    @State private var findIndex: Int?
    @State private var findDebounce: DispatchWorkItem?
    @State private var streamRecount: DispatchWorkItem?
    @State private var findScrollTick = 0
    /// A tap on a quote asks to scroll to its original. Each tap is a new value, so tapping twice scrolls twice.
    struct JumpRequest: Equatable { let id = UUID(); let target: UUID }
    @State private var jumpTick: JumpRequest?
    @State private var highlightedID: UUID?
    @State private var highlightClear: DispatchWorkItem?
    struct SelectionAsk { let item: ChatSession.Item; let point: CGPoint }
    /// The Ask button shown beside a text selection, with where the selection ended.
    @State private var selectionAsk: SelectionAsk?
    @State private var hoverTracker = HoverTracker()
    @State private var selectionMonitor: Any?
    /// `--render-previews` only: draw the settings popover's content on its own, since a popover can't render offscreen.
    var settingsOnly = false
    /// The row SwiftUI reports at the top of the transcript. Tests compare it before and after content arrives, because
    /// the scroll offset in points moves when SwiftUI re-estimates the heights of rows that are not on screen.
    nonisolated(unsafe) static var topRowForTesting: UUID?

    var body: some View {
        if settingsOnly { settingsPopover } else { chat }
    }

    private var chat: some View {
        // The header and composer float as glass over the content; safe-area insets keep the first and
        // last rows clear of them at the scroll ends while letting everything scroll underneath.
        SwiftUI.Group {
            if session.items.isEmpty && session.approvals.isEmpty {
                welcome
            } else {
                transcript
            }
        }
        .glassBar(.top) {
            VStack(spacing: 0) {
                header
                if session.findOpen {
                    FindBar(query: $findQuery, label: findLabel, hasMatches: !findMatches.isEmpty,
                            focusTick: session.findFocusTick, step: stepFind, close: closeFind)
                }
            }
        }
        .glassBar(.bottom) { composer }
        .frame(minWidth: ChatPanel.minimumSize.width, maxWidth: .infinity,
               minHeight: ChatPanel.minimumSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // The panel has a hidden, transparent title bar; without this its 28pt safe area sits empty above the header.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { inputFocused = true }
        .onChange(of: findQuery) { scheduleFind() }
        .onChange(of: session.findOpen) { if !session.findOpen { resetFind() } }
        .onChange(of: scrollKey) { if session.findOpen { scheduleStreamRecompute() } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let saved = FileIntake.attach([url])
                    DispatchQueue.main.async { saved.forEach(session.attach) }
                }
            }
            return true
        }
    }

    // MARK: Header

    private var header: some View {
        GlassGroup {
            ZStack {
                HStack(spacing: 10) {
                    closeButtonPill
                    Spacer()
                    headerControls
                }
                HStack(spacing: 8) {
                    PetAvatar(size: 30)
                    Text(ConfigStore.shared.config.pet.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .chromeGlass(in: Capsule())
                // Equal insets keep the pill centered and a long name clear of the side pills.
                .padding(.horizontal, 96)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var headerControls: some View {
        HStack(spacing: 2) {
            if session.autoMode {
                // The switch lives in settings; this stays so it is always obvious the agent runs unattended.
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("Auto is on: the agent edits and runs commands without asking")
                    .padding(.horizontal, 6)
            }
            settingsButton
        }
        .padding(4)
        .chromeGlass(in: Capsule())
    }

    private var closeButtonPill: some View {
        iconButton("xmark", help: "Close (Esc)", action: close)
            .padding(4)
            .chromeGlass(in: Capsule())
    }

    /// Project, agent, model and dictation live behind one button, so the header and composer stay clear.
    private var settingsButton: some View {
        Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 13)) }
            .buttonStyle(CircleHoverIconStyle())
            .help("Chat settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
    }

    /// Laid out like System Settings: grouped cards, label on the left, value or control on the right.
    private var settingsPopover: some View {
        VStack(spacing: 10) {
            SettingsCard {
                SettingsRow("Project") { projectMenu }
                SettingsRow("Agent", last: session.models.isEmpty) { backendMenu }
                if !session.models.isEmpty { SettingsRow("Model", last: true) { modelMenu } }
            }
            SettingsCard {
                SettingsRow("Auto") {
                    Toggle("", isOn: $session.autoMode)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.orange)
                        .pointerCursor()
                }
                .help("Let the agent edit and run commands without asking (destructive commands still ask)")
                SettingsRow("Send voice notes automatically", last: true) {
                    Toggle("", isOn: $session.sendAfterDictation)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .pointerCursor()
                }
                .help("Send a voice note recorded in ironpet as soon as it is transcribed. Pasted, typed and Wispr Flow text is never sent automatically")
            }
            HStack(spacing: 8) {
                Button {
                    session.newChat()
                    showSettings = false
                } label: { Label("New chat", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
                historyMenu
                Button {
                    NSWorkspace.shared.open(Memory.directory)
                    showSettings = false
                } label: { Label("Memory folder", systemImage: "brain") }
                .pointerCursor()
                .help("Open the notes Ghost keeps about you and your projects")
            }
            .controlSize(.small)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 360)
    }

    private var projectMenu: some View {
        Menu {
            ForEach(session.recents, id: \.self) { url in
                Button(url.lastPathComponent) { session.use(url) }
            }
            Divider()
            Button("No project (general question)", action: session.useNoProject)
            Button("Choose folder…", action: chooseFolder)
        } label: {
            Text(session.needsWorkspace ? "Choose…" : session.workspaceLabel)
        }
        .settingsValueMenu()
        .disabled(session.isRunning)
        .help("Folder the agent works in. Switching starts a new chat.")
    }

    private var historyMenu: some View {
        Menu {
            if session.history.isEmpty { Text("No previous chats") }
            ForEach(session.history) { thread in
                Button("\(thread.title) — \(URL(fileURLWithPath: thread.workspace).lastPathComponent)") {
                    session.open(thread)
                    showSettings = false
                }
            }
        } label: {
            Label("Previous chats", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)) }
            .buttonStyle(CircleHoverIconStyle())
            .help(help)
    }

    // MARK: Transcript

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(spacing: 14) {
                PetAvatar(size: 64)
                    .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.5).padding(-4))
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 14)
                if session.needsWorkspace {
                    projectPicker
                } else {
                    VStack(spacing: 4) {
                        Text("What can I help with?").font(.system(size: 17, weight: .semibold))
                        Text("Working in **\(session.workspaceLabel)** with \(session.agent.name)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            hints.padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    /// Shown when the chat was opened from an app that is not a coding app.
    private var projectPicker: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Which project is this about?").font(.system(size: 17, weight: .semibold))
                Text("Ghost runs the agent in that folder").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                let recents = Array(session.recents.prefix(5))
                ForEach(recents, id: \.self) { url in
                    PickerRow(symbol: "folder.fill", tint: .accentColor, title: url.lastPathComponent,
                              subtitle: url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        session.use(url)
                    }
                    Hairline().padding(.leading, 44)
                }
                PickerRow(symbol: "bubble.left.fill", tint: .purple, title: "No project", subtitle: "General question", action: session.useNoProject)
                Hairline().padding(.leading, 44)
                PickerRow(symbol: "folder.badge.plus", tint: .gray, title: "Choose folder…", subtitle: nil, action: chooseFolder)
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            .frame(maxWidth: 300)
        }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            // With voice notes on, the voice shortcut is ironpet's own; otherwise it is Wispr Flow's fn.
            if let voiceKey = VoiceController.hotkey(in: config.config).flatMap(Shortcut.display) {
                hint("mic.fill", keys: [voiceKey], config.config.voice.holdToTalk ? "hold to talk" : "press to talk")
            } else {
                hint("mic.fill", keys: ["fn"], "talk")
            }
            hint("macwindow", keys: ["⇧⌥⌘G"], "window")
            hint("crop", keys: ["⌃⌥⌘G"], "region")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private func hint(_ symbol: String, keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            ForEach(keys, id: \.self) { Keycap(text: $0) }
            Text(text)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if hiddenItems > 0 {
                        Button("Show earlier messages (\(hiddenItems))") { shownItems += TranscriptGroup.pageSize }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    let highlights = findHighlights
                    ForEach(groupedItems, id: \.id) { group in
                        groupView(group, highlights: highlights).id(group.id)
                    }
                    if session.isRunning, session.approvals.isEmpty {
                        TypingIndicator(started: session.runStartedAt).id("typing")
                    }
                    ForEach(session.approvals) { approval in approvalCard(approval).id(approval.id) }
                    if let agent = session.runtimeOffer { runtimeCard(agent).id("runtime") }
                    if !session.signInOptions.isEmpty { signInCard.id("signin") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                .padding(14)
                .background(ScrollObserver(activity: scrollActivity) { metrics, userDriven in
                    scrollMetricsChanged(metrics, userDriven: userDriven, proxy: proxy)
                })
            }
            // The top row only matters while the reader is away from the end: it keeps their row in place as content
            // arrives and is where a resize puts them back. At the end it is nil, because a stale row would pull the
            // view away from the bottom each time scrollTo put it there.
            .scrollPosition(id: Binding(get: { follow.pinned ? nil : topRowID },
                                        set: { ChatView.topRowForTesting = $0; if !follow.pinned { topRowID = $0 } }), anchor: .top)
            .frame(maxHeight: .infinity)
            .softScrollEdges()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in widthChanged(width, proxy: proxy) }
            .overlay(alignment: .bottom) {
                if follow.newBelow {
                    Button {
                        follow.jumpedToLatest()
                        scrollToEnd(proxy)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .chromeGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(.bottom, 8)
                    .transition(.opacity)
                    .accessibilityIdentifier("jump-to-latest")
                }
            }
            .onChange(of: scrollKey) {
                // Streaming only follows the end while the reader is there. Sending a message always jumps to it.
                // Only a new user message typed here jumps. While the agent works the last item stays that message,
                // and every status change must not drag a reader who scrolled up back down.
                let last = session.items.last
                var readerSent = false
                if last?.id != lastItemID, case .user = last?.kind, last?.origin == nil { readerSent = true }
                lastItemID = last?.id
                let contentKey = "\(session.items.count)-\(session.approvals.count)-\(lastAssistantLength)"
                follow.contentArrived(readerSent: readerSent, newContent: contentKey != lastContentKey)
                lastContentKey = contentKey
                // With the find bar on a match, the view stays on it; only sending jumps away.
                guard follow.pinned, currentFindMatch == nil || readerSent else { return }
                scrollToEnd(proxy)
            }
            .onAppear {
                lastItemID = session.items.last?.id
                lastContentKey = "\(session.items.count)-\(session.approvals.count)-\(lastAssistantLength)"
                scrollToEnd(proxy)
            }
            .onChange(of: findScrollTick) { revealCurrentMatch(proxy) }
            .overlay { selectionButton }
            .onAppear(perform: installSelectionMonitor)
            .onDisappear { if let monitor = selectionMonitor { NSEvent.removeMonitor(monitor); selectionMonitor = nil }; selectionAsk = nil }
            .onChange(of: jumpTick) { if let request = jumpTick { jump(to: request.target, proxy) } }
            // A new chat or another thread starts with the default window again.
            .onChange(of: session.items.first?.id) { shownItems = TranscriptGroup.pageSize }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        scrollActivity.noteProgrammaticScroll()
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func scrollMetricsChanged(_ metrics: ScrollMetrics, userDriven: Bool, proxy: ScrollViewProxy) {
        let grew = metrics.contentHeight != lastContentHeight
        lastContentHeight = metrics.contentHeight
        follow.geometryChanged(distanceFromBottom: metrics.distanceFromBottom, userDriven: userDriven)
        // Rows below the viewport only have estimated heights, so the end moves as they are measured.
        lastGap = metrics.distanceFromBottom
        if follow.pinned, topRowID != nil { topRowID = nil }
        guard follow.pinned, !userDriven, !resizing, grew, metrics.distanceFromBottom > TranscriptFollow.bottomTolerance else { return }
        settleAtEnd(proxy, attempt: 0)
    }

    /// Scrolling realizes rows, which changes the estimated height, which would scroll again. So this jumps once after
    /// the changes pause, and checks a few times that the jump reached the real end, which estimates can leave short.
    private func settleAtEnd(_ proxy: ScrollViewProxy, attempt: Int) {
        settleScroll?.cancel()
        let work = DispatchWorkItem {
            guard follow.pinned, !resizing else { return }
            if lastGap > TranscriptFollow.bottomTolerance { scrollToEnd(proxy) }
            if attempt < 3 { settleAtEnd(proxy, attempt: attempt + 1) }
        }
        settleScroll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// A width change re-wraps every row, and rows off screen only have estimated heights, so the scroll position would
    /// land at the top. The first change of a resize remembers where the reader was, and each frame puts it back.
    private func widthChanged(_ width: CGFloat, proxy: ScrollViewProxy) {
        defer { lastWidth = width }
        guard lastWidth > 0, abs(width - lastWidth) > 0.5 else { return }
        if !resizing {
            resizing = true
            resizeWasPinned = follow.pinned
            resizeAnchor = topRowID
        }
        restoreScroll(proxy)
        resizeEnd?.cancel()
        let end = DispatchWorkItem {
            restoreScroll(proxy)
            // Layout settles one pass later; only then are the bottom marker and top row trustworthy again.
            DispatchQueue.main.async { restoreScroll(proxy); resizing = false }
        }
        resizeEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
    }

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        scrollActivity.noteProgrammaticScroll()
        if resizeWasPinned {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else if let id = resizeAnchor {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    // MARK: Find

    private var currentFindMatch: ChatFind.Match? {
        guard session.findOpen, let findIndex, findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex]
    }

    private var findLabel: String {
        ChatFind.label(query: activeQuery, count: findMatches.count, index: findIndex)
    }

    /// Rows that hold a match, with what each needs to draw.
    private var findHighlights: [UUID: ChatFind.RowHighlight] {
        guard session.findOpen else { return [:] }
        return ChatFind.highlights(query: activeQuery, matches: findMatches, current: currentFindMatch)
    }

    private func scheduleFind() {
        findDebounce?.cancel()
        let work = DispatchWorkItem {
            activeQuery = findQuery
            recomputeFind(keepCurrent: false)
            findScrollTick += 1
        }
        findDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// A streaming reply changes the transcript on every token. Recount at most once per pause so a long chat stays responsive.
    private func scheduleStreamRecompute() {
        // Keep the pending recount instead of re-arming it, or a fast stream would never let it run.
        guard findQuery == activeQuery, streamRecount == nil else { return }
        let work = DispatchWorkItem {
            streamRecount = nil
            recomputeFind(keepCurrent: true)
        }
        streamRecount = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Recounts after the query or the transcript changed. A streaming reply keeps the current match in place.
    private func recomputeFind(keepCurrent: Bool) {
        let matches = ChatFind.matches(query: activeQuery, in: session.items)
        // A new query restarts at the first match even when the set of matches did not change.
        guard matches != findMatches || !keepCurrent else {
            if !keepCurrent { findIndex = matches.isEmpty ? nil : 0 }
            return
        }
        let previous = keepCurrent ? currentFindMatch : nil
        let previousIndex = findIndex
        findMatches = matches
        findIndex = ChatFind.reconcile(current: previous, previousIndex: previousIndex, in: matches)
    }

    private func stepFind(_ delta: Int) {
        // A pending debounce would replace the matches right after stepping, so apply the typed query first.
        if findQuery != activeQuery {
            findDebounce?.cancel()
            activeQuery = findQuery
            recomputeFind(keepCurrent: false)
            if delta < 0, !findMatches.isEmpty { findIndex = findMatches.count - 1 }
            findScrollTick += 1
            return
        }
        guard let next = ChatFind.step(from: findIndex, count: findMatches.count, by: delta) else { return }
        findIndex = next
        findScrollTick += 1
    }

    private func closeFind() {
        session.findOpen = false
        DispatchQueue.main.async { inputFocused = true }
    }

    private func resetFind() {
        findDebounce?.cancel()
        streamRecount?.cancel()
        streamRecount = nil
        findQuery = ""
        activeQuery = ""
        findMatches = []
        findIndex = nil
    }

    /// Scrolls the row holding the current match into view, first widening the window over an older one.
    private func revealCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let match = currentFindMatch, let position = session.items.firstIndex(where: { $0.id == match.item }) else { return }
        let needed = session.items.count - position
        if needed > shownItems {
            shownItems = needed + TranscriptGroup.pageSize / 3
            // The older rows join the lazy stack on the next render, so scroll once they exist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scrollToMatch(match, proxy) }
            return
        }
        scrollToMatch(match, proxy)
    }

    /// Which message the pointer is over. A plain object, not state, so moving the pointer does not re-render the transcript.
    final class HoverTracker { var current: UUID?; var buttonFrame: CGRect = .zero }

    private func hoverChanged(_ id: UUID, _ hovering: Bool) {
        if hovering { hoverTracker.current = id } else if hoverTracker.current == id { hoverTracker.current = nil }
    }

    /// Asks about the text selected in `item`. With nothing selected it replies to the whole message.
    private func askAbout(_ item: ChatSession.Item) {
        session.reply(to: item, selection: SelectionProbe.selectedText())
        selectionAsk = nil
    }

    private func copyText(_ item: ChatSession.Item, _ whole: String) {
        let text = SelectionProbe.selectedText(keepOnPasteboard: true)
        if text == nil {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(whole, forType: .string)
        }
    }

    /// After a mouse-up, checks whether text is selected in the message under the pointer and shows the Ask button there.
    private func selectionMayHaveChanged(_ event: NSEvent) {
        if selectionAsk != nil, hoverTracker.buttonFrame.contains(CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)) { return }
        guard let id = hoverTracker.current, let item = session.items.first(where: { $0.id == id }),
              let window = event.window, window == NSApp.keyWindow else { selectionAsk = nil; return }
        let point = CGPoint(x: event.locationInWindow.x, y: (window.contentView?.bounds.height ?? 0) - event.locationInWindow.y)
        DispatchQueue.main.async {
            if SelectionProbe.selectedText() != nil { selectionAsk = SelectionAsk(item: item, point: point) } else { selectionAsk = nil }
        }
    }

    private func installSelectionMonitor() {
        guard selectionMonitor == nil else { return }
        selectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .scrollWheel]) { event in
            if event.type == .scrollWheel { if selectionAsk != nil { selectionAsk = nil } } else { selectionMayHaveChanged(event) }
            return event
        }
    }

    @ViewBuilder
    private var selectionButton: some View {
        if let ask = selectionAsk {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                Button {
                    askAbout(ask.item)
                } label: {
                    Label("Ask about this", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .chromeGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask-about-selection")
                .pointerCursor()
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    // The monitor compares against window coordinates with a bottom-left origin.
                    let height = NSApp.keyWindow?.contentView?.bounds.height ?? 0
                    hoverTracker.buttonFrame = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
                }
                .position(x: min(max(ask.point.x - origin.x + 70, 80), geo.size.width - 80),
                          y: min(max(ask.point.y - origin.y + 24, 20), geo.size.height - 20))
            }
        }
    }

    /// Scrolls to the original message of a quote and highlights it briefly. Nothing happens when it is gone.
    private func jump(to id: UUID, _ proxy: ScrollViewProxy) {
        guard let position = session.items.firstIndex(where: { $0.id == id }) else { return }
        let needed = session.items.count - position
        let scroll = {
            follow.leftTheEnd()
            scrollActivity.noteProgrammaticScroll()
            proxy.scrollTo(id, anchor: .center)
            highlightedID = id
            highlightClear?.cancel()
            let clear = DispatchWorkItem { highlightedID = nil }
            highlightClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: clear)
        }
        if needed > shownItems {
            shownItems = needed + TranscriptGroup.pageSize / 3
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: scroll)
        } else {
            scroll()
        }
    }

    private func scrollToMatch(_ match: ChatFind.Match, _ proxy: ScrollViewProxy) {
        let target = groupedItems.first { group in
            switch group {
            case .item(let item): return item.id == match.item
            case .tools(let items): return items.contains { $0.id == match.item }
            }
        }?.id
        guard let target else { return }
        // A match is somewhere in the history, so streaming must not pull the view back to the end.
        follow.leftTheEnd()
        scrollActivity.noteProgrammaticScroll()
        proxy.scrollTo(target, anchor: .center)
        // Rows below the viewport only have estimated heights, so settle once layout has caught up.
        DispatchQueue.main.async { scrollActivity.noteProgrammaticScroll(); proxy.scrollTo(target, anchor: .center) }
    }

    private var scrollKey: String {
        "\(session.items.count)-\(session.approvals.count)-\(session.isRunning)-\(lastAssistantLength)"
    }

    private var lastAssistantLength: Int {
        if case .assistant(let text) = session.items.last?.kind { return text.count }
        return 0
    }

    private var groupedItems: [TranscriptGroup] {
        let start = TranscriptGroup.windowStart(session.items, limit: shownItems)
        return TranscriptGroup.make(session.items[start...])
    }

    private var hiddenItems: Int {
        TranscriptGroup.windowStart(session.items, limit: shownItems)
    }

    @ViewBuilder
    private func groupView(_ group: TranscriptGroup, highlights: [UUID: ChatFind.RowHighlight]) -> some View {
        switch group {
        case .tools(let items):
            ToolSteps(items: items, finds: items.compactMap { item in highlights[item.id].map { (item.id, $0) } })
        case .item(let item):
            switch item.kind {
            case .user(let text):
                UserBubble(text: text, date: item.date, reply: item.reply, highlighted: highlightedID == item.id,
                           onReply: { session.reply(to: item) }, onQuoteTap: { if let reply = item.reply { jumpTick = JumpRequest(target: reply.itemID) } },
                           onAsk: { askAbout(item) }, onCopy: { copyText(item, text) }, onHoverChange: { hoverChanged(item.id, $0) },
                           source: item.origin, find: highlights[item.id])
            case .screenshot(let path):
                HStack {
                    Spacer(minLength: 60)
                    Thumbnail(path: path, height: 110)
                }
            case .assistant(let text):
                AssistantBubble(text: text, date: item.date, highlighted: highlightedID == item.id,
                                onReply: { session.reply(to: item) }, onAsk: { askAbout(item) }, onCopy: { copyText(item, text) },
                                onHoverChange: { hoverChanged(item.id, $0) }, find: highlights[item.id])
            case .tool:
                EmptyView()
            case .error(let text):
                VStack(alignment: .leading, spacing: 8) {
                    Label { ChatFind.text(AttributedString(text), segment: 0, find: highlights[item.id]) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    if session.voiceRetryItem == item.id {
                        Button("Retry", action: session.retryVoice)
                            .pointerCursor()
                            .controlSize(.small)
                            .help("Send the same recording again")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func approvalCard(_ approval: ChatSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button { session.decide(approval, allow: true) } label: {
                    Label("Allow", systemImage: "checkmark").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
                .keyboardShortcut(.return, modifiers: .command)
                Button { session.decide(approval, allow: false) } label: {
                    Label("Deny", systemImage: "xmark").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .pointerCursor()
                Spacer()
                Text("⌘↩ to allow").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5)))
    }

    private func runtimeCard(_ agent: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(agent) needs a JavaScript runtime", systemImage: "arrow.down.circle")
                .font(.system(size: 13, weight: .semibold))
            Text("ironpet runs \(agent) through a small adapter. It needs Node 22 or newer, which it did not find. It can download Bun \(BunRuntime.version) (\(BunRuntime.sizeDescription)) from github.com/oven-sh/bun, check it against the published SHA-256 and keep it in ~/.ironpet/runtime.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Button { session.installRuntime() } label: {
                    Text(session.installingRuntime ? "Downloading…" : "Download Bun").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
                .disabled(session.installingRuntime)
                Button("Not now") { session.declineRuntime() }
                    .buttonStyle(.bordered)
                    .pointerCursor()
                    .disabled(session.installingRuntime)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.4)))
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sign in to \(session.agent.name)", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
            HStack {
                ForEach(session.signInOptions) { method in
                    Button(method.name) { session.signIn(method) }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                        .help(method.detail)
                }
                Button("Try again") { session.retryAfterFix() }
                    .buttonStyle(.bordered)
                    .pointerCursor()
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.4)))
    }

    // MARK: Composer

    /// Laid out like Telegram: a round attach button, the field in its own glass capsule, round mic and send buttons.
    private var composer: some View {
        VStack(spacing: 8) {
            // The composer is a bar over the transcript, so the popup floats over the history like Telegram's.
            let matches = session.slashMatches
            if !matches.isEmpty {
                SlashPopup(commands: matches, selection: min(session.slash.selection, matches.count - 1), pick: session.completeSlash)
            }
            queueRows
            composerBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .onChange(of: session.voice.phase) { _, phase in
            if phase == .idle { inputFocused = true }
        }
    }

    private var composerBar: some View {
        GlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                if !voiceActive {
                    Button(action: chooseFiles) { Image(systemName: "paperclip") }
                        .buttonStyle(GlassCircleButtonStyle())
                        .help("Attach files")
                }
                composerField
                if !voiceActive {
                    if config.config.voice.enabled {
                        Button { session.voice.start() } label: { Image(systemName: "mic") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help("Record a voice note")
                    }
                    if session.isRunning {
                        sendButton("stop.fill", color: .red, help: "Stop (Esc)", action: session.stop)
                    }
                    sendButton("arrow.up", color: .accentColor, help: session.isRunning ? "Queue (Enter)" : "Send (Enter)", action: session.send)
                        .disabled(session.input.trimmingCharacters(in: .whitespaces).isEmpty && session.attachments.isEmpty)
                }
            }
        }
    }

    private var voiceActive: Bool { session.voice.phase != .idle }

    private var composerField: some View {
        SwiftUI.Group {
            if voiceActive {
                VoiceBar(voice: session.voice)
            } else {
                composerInput
            }
        }
        .padding(4)
        .frame(minHeight: GlassCircleButtonStyle.size)
        .chromeGlass(in: RoundedRectangle(cornerRadius: GlassCircleButtonStyle.size / 2, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !voiceActive { inputFocused = true } }
        .animation(.easeOut(duration: 0.12), value: inputFocused)
    }

    private var composerInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = session.replyingTo {
                HStack(spacing: 4) {
                    ReplyQuote(reply: reply)
                    Button { session.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel reply (Esc)")
                    .accessibilityLabel("Cancel reply")
                    .accessibilityIdentifier("reply-cancel")
                    .pointerCursor()
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
            if !session.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.attachments, id: \.self) { url in
                        Thumbnail(path: url.path, height: 48)
                            .overlay(alignment: .topTrailing) {
                                Button { session.attachments.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .padding(2)
                            }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(session.isRunning ? "\(ConfigStore.shared.config.pet.name) is working. Enter queues your message." : "Ask \(ConfigStore.shared.config.pet.name)…", text: $session.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit(session.send)
                    // Return sends; Shift-Return adds a line break at the caret (Option-Return already did).
                    .onKeyPress(.return, phases: .down) { press in
                        if !press.modifiers.contains(.shift), session.completeSlash() { return .handled }
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { _ in session.completeSlash() ? .handled : .ignored }
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        guard !session.slashMatches.isEmpty else { return .ignored }
                        session.moveSlashSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        guard !session.slashMatches.isEmpty else { return .ignored }
                        session.moveSlashSelection(1)
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        if session.dismissSlash() { return .handled }
                        guard session.replyingTo != nil else { return .ignored }
                        session.replyingTo = nil
                        return .handled
                    }
                    .onChange(of: session.replyFocusTick) { inputFocused = true }
                    .onChange(of: session.input) { old, new in session.inputChanged(from: old, to: new) }
                    // The system focus ring is a rectangle; inside the rounded field it showed as a line at each end.
                    .focusEffectDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder
    private var queueRows: some View {
        if !session.queue.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(session.queue) { message in
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(message.text.isEmpty ? "Screenshot" : (message.text.components(separatedBy: .newlines).first ?? message.text))
                            .font(.system(size: 12))
                            .lineLimit(1)
                        if !message.attachments.isEmpty {
                            Label("\(message.attachments.count)", systemImage: "photo")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { session.removeQueued(message.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Remove from queue")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(6)
            .chromeGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func sendButton(_ symbol: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: GlassCircleButtonStyle.size, height: GlassCircleButtonStyle.size)
                .tintedCircle(color)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    private var backendMenu: some View {
        Menu {
            ForEach(session.agents) { agent in
                Button { session.setAgent(agent) } label: {
                    if session.agent == agent { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
                }
            }
        } label: {
            Text(session.agent.name)
        }
        .settingsValueMenu()
        .disabled(session.isRunning)
        .help("Agent that runs your request. Switching starts a new chat.")
    }

    private var modelMenu: some View {
        let families = session.models.reduce(into: [(String, [ChatModel])]()) { groups, model in
            if let index = groups.firstIndex(where: { $0.0 == model.family }) {
                groups[index].1.append(model)
            } else {
                groups.append((model.family, [model]))
            }
        }
        return Menu {
            Button {
                session.model = nil
            } label: {
                if session.model == nil { Label("Default (agent setting)", systemImage: "checkmark") } else { Text("Default (agent setting)") }
            }
            Divider()
            ForEach(families, id: \.0) { family, models in
                if models.count == 1, let only = models.first {
                    modelButton(only)
                } else {
                    Menu(family) { ForEach(models) { modelButton($0) } }
                }
            }
        } label: {
            Text(session.modelName)
        }
        .settingsValueMenu()
        .disabled(session.isRunning)
        .help("Model used for the next message")
    }

    @ViewBuilder
    private func modelButton(_ model: ChatModel) -> some View {
        Button {
            session.model = model.id
        } label: {
            if session.model == model.id { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Attach files to your message"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        FileIntake.attach(panel.urls).forEach(session.attach)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = session.workspace
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { session.use(url) }
    }
}

// MARK: - Pieces

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}()

/// The reply button shown beside a message's time while the pointer is over the row.
private struct ReplyButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .help("Reply")
        .accessibilityLabel("Reply")
        .accessibilityIdentifier("reply-button")
        .pointerCursor()
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

/// The quoted original: sender and the first two lines. Tapping it jumps to the original message.
private struct ReplyQuote: View {
    let reply: ChatSession.Reply
    var onUser = false
    var tap: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(onUser ? Color.white.opacity(0.8) : Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.sender).font(.system(size: 11, weight: .semibold))
                Text(reply.text).font(.system(size: 11.5)).lineLimit(2).truncationMode(.tail)
            }
            .foregroundStyle(onUser ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .background((onUser ? Color.white.opacity(0.18) : Color.primary.opacity(0.07)), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { tap?() }
        .pointerCursor()
        .accessibilityIdentifier("reply-quote")
    }
}

private struct UserBubble: View {
    let text: String
    let date: Date?
    var reply: ChatSession.Reply?
    var highlighted = false
    var onReply: () -> Void = {}
    var onQuoteTap: () -> Void = {}
    var onAsk: () -> Void = {}
    var onCopy: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Hover is per row, so moving the pointer re-renders this bubble and not the whole transcript.
    @State private var hovering = false
    /// Where the message came from when it was not typed in this chat, such as "telegram".
    var source: String?
    var find: ChatFind.RowHighlight?
    @ObservedObject private var paths = PathCache.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 6) {
                if let reply { ReplyQuote(reply: reply, onUser: true, tap: onQuoteTap) }
                let linked = FilePathLinks.link(AttributedString(text), underline: true)
                ChatFind.text(linked, segment: 0, find: find)
                    .font(.system(size: 13.5))
                    .linkCursor(linked, size: 13.5)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .environment(\.openURL, OpenURLAction { FilePathLinks.handle($0) })
                    .textSelection(.enabled)
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))
            HStack(spacing: 4) {
                ReplyButton(visible: hovering, action: onReply)
                if source == ChatSession.telegramOrigin {
                    Image(systemName: "paperplane.fill").font(.system(size: 9))
                    Text("Telegram").font(.system(size: 10))
                }
                if let date { Text(timeFormatter.string(from: date)).font(.system(size: 10)) }
            }
            .foregroundStyle(.tertiary)
            .help(source == ChatSession.telegramOrigin ? "Sent from Telegram" : "")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 50)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.25), value: highlighted)
        .contentShape(Rectangle())
        .onHover { hovering = $0; onHoverChange($0) }
        .contextMenu { RowMenu(onReply: onReply, onAsk: onAsk, onCopy: onCopy) }
    }
}

/// The right-click menu of a message. A custom menu replaces the system one, so Copy is here too.
private struct RowMenu: View {
    let onReply: () -> Void
    let onAsk: () -> Void
    let onCopy: () -> Void

    var body: some View {
        Button("Reply", action: onReply)
        Button("Ask about selection", action: onAsk)
        Button("Copy", action: onCopy)
    }
}

private struct AssistantBubble: View {
    let text: String
    let date: Date?
    var highlighted = false
    var onReply: () -> Void = {}
    var onAsk: () -> Void = {}
    var onCopy: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }
    var find: ChatFind.RowHighlight?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(size: 24)
            VStack(alignment: .leading, spacing: 3) {
                MarkdownView(text: text, find: find)
                    .font(.system(size: 13.5))
                    .padding(.top, 3)
                HStack(spacing: 4) {
                    if let date { Text(timeFormatter.string(from: date)).font(.system(size: 10)) }
                    ReplyButton(visible: hovering, action: onReply)
                }
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 30)
        }
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.25), value: highlighted)
        .contentShape(Rectangle())
        .onHover { hovering = $0; onHoverChange($0) }
        .contextMenu { RowMenu(onReply: onReply, onAsk: onAsk, onCopy: onCopy) }
    }
}

/// A run of consecutive tool steps, folded into one line ("Ran 3 commands, read 2 files ›") that expands on click.
/// While a step is still running, the line shows it with a spinner so you can see progress without expanding.
private struct ToolSteps: View {
    let items: [ChatSession.Item]
    /// Highlights for the steps that hold a match, by item id.
    var finds: [(UUID, ChatFind.RowHighlight)] = []
    @State private var expanded = false
    @State private var hovering = false

    private var steps: [(id: UUID, summary: String, ok: Bool?)] {
        items.compactMap { item in
            if case .tool(let summary, let ok) = item.kind { return (item.id, summary, ok) }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    headerIcon
                    Text(LocalizedStringKey(headerText)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0.6)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering = $0 }
            .help(expanded ? "Hide steps" : "Show steps")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
                        HStack(spacing: 6) {
                            icon(step.ok)
                            stepText(step)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 32)
        // The step holding the current match opens, so the highlight is visible. Collapsed steps still count.
        .onChange(of: finds.first { $0.1.current != nil }?.0) { _, id in
            if id != nil, !expanded { withAnimation(.easeInOut(duration: 0.15)) { expanded = true } }
        }
        // A lazy row scrolled to from far away is created with the match already current, so onChange never fires.
        .onAppear {
            if finds.contains(where: { $0.1.current != nil }) { expanded = true }
        }
    }

    private func stepText(_ step: (id: UUID, summary: String, ok: Bool?)) -> Text {
        guard let find = finds.first(where: { $0.0 == step.id })?.1 else { return Text(LocalizedStringKey(step.summary)) }
        return ChatFind.text(Markdown.inline(step.summary), segment: 0, find: find)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if steps.contains(where: { $0.ok == nil }) {
            icon(nil)
        } else if steps.contains(where: { $0.ok == false }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    /// The running step while one is in flight, otherwise a count per kind of step.
    private var headerText: String {
        if !expanded, let running = steps.last(where: { $0.ok == nil }) { return running.summary }
        var counts: [(verb: String, noun: String, count: Int)] = []
        for step in steps {
            let (verb, noun) = Self.kind(of: step.summary)
            if let i = counts.firstIndex(where: { $0.verb == verb }) { counts[i].count += 1 } else { counts.append((verb, noun, 1)) }
        }
        let parts = counts.map { "\($0.verb) \($0.count) \($0.noun)\($0.count == 1 ? "" : "s")" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func kind(of summary: String) -> (String, String) {
        let first = summary.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        switch first {
        case "ran": return ("ran", "command")
        case "read": return ("read", "file")
        case "edited", "wrote", "created": return ("edited", "file")
        case "deleted": return ("deleted", "file")
        case "searched", "grepped", "listed", "found": return ("searched", "time")
        default: return ("used", "tool")
        }
    }

    @ViewBuilder
    private func icon(_ ok: Bool?) -> some View {
        switch ok {
        case nil: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Shown while the agent works: the pet, animated dots and how long this turn has been running.
/// Nothing here ticks through SwiftUI every frame: a per-frame `TimelineView` re-ran layout of the whole
/// transcript on each tick, which pinned the main thread at 100% CPU in long chats. The dots animate in
/// Core Animation, and the elapsed time re-renders once a second.
private struct TypingIndicator: View {
    let started: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PetAvatar(size: 24)
            // Same layout as a finished reply: the bubble, then the elapsed time where its timestamp goes.
            VStack(alignment: .leading, spacing: 3) {
                PulsingDots()
                    .frame(width: 30, height: 6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                if let started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(started)))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// Three dots that light up in turn, animated by Core Animation so SwiftUI never re-evaluates for a frame.
private struct PulsingDots: NSViewRepresentable {
    func makeNSView(context: Context) -> DotsView { DotsView() }
    func updateNSView(_ view: DotsView, context: Context) {}

    final class DotsView: NSView {
        private var dots: [CALayer] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for i in 0..<3 {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
                dot.cornerRadius = 3
                dot.backgroundColor = NSColor.secondaryLabelColor.cgColor
                dot.opacity = 0.35
                // One third of the cycle each, like the old 0.15s phase steps.
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [1, 0.35, 0.35]
                pulse.keyTimes = [0, 0.33, 1]
                pulse.duration = 0.45
                pulse.beginTime = CACurrentMediaTime() + 0.15 * Double(i)
                pulse.repeatCount = .infinity
                pulse.calculationMode = .discrete
                dot.add(pulse, forKey: "pulse")
                layer?.addSublayer(dot)
                dots.append(dot)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            for (i, dot) in dots.enumerated() { dot.position = CGPoint(x: 3 + 10 * CGFloat(i), y: bounds.midY) }
        }

        override func viewDidChangeEffectiveAppearance() {
            dots.forEach { $0.backgroundColor = NSColor.secondaryLabelColor.cgColor }
        }
    }
}

/// Consecutive tool steps are shown together as one activity block.
enum TranscriptGroup {
    case item(ChatSession.Item)
    case tools([ChatSession.Item])

    /// Items rendered at first, and added by each "Show earlier" press.
    static let pageSize = 300

    var id: UUID {
        switch self {
        case .item(let item): return item.id
        case .tools(let items): return items[0].id
        }
    }

    /// Where the rendered window of the newest `limit` items starts. It never splits a run of tool steps.
    static func windowStart(_ items: [ChatSession.Item], limit: Int) -> Int {
        let base = max(0, items.count - limit)
        var start = base
        // Pull in the rest of a run that straddles the boundary, but never more than `limit` extra items.
        while start > 0, base - start < limit, case .tool = items[start].kind, case .tool = items[start - 1].kind { start -= 1 }
        return start
    }

    static func make(_ items: ArraySlice<ChatSession.Item>) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var run: [ChatSession.Item] = []
        for item in items {
            if case .tool = item.kind {
                run.append(item)
            } else {
                if !run.isEmpty { groups.append(.tools(run)); run = [] }
                groups.append(.item(item))
            }
        }
        if !run.isEmpty { groups.append(.tools(run)) }
        return groups
    }
}

/// Decoded attachment images, so a re-render of the transcript does not read and decode every file again.
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()
    /// How many times a file was actually decoded; tests read it.
    nonisolated(unsafe) static var decodeCount = 0

    /// Decodes at most 640 px on the long side, so a full-resolution screenshot does not stay in memory.
    private static func decode(_ path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOfFile: path) // not a bitmap ImageIO can thumbnail, such as a PDF
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func image(at path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = decode(path) else { return nil }
        decodeCount += 1
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct Thumbnail: View {
    let path: String
    let height: CGFloat

    var body: some View {
        if let image = ThumbnailCache.image(at: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                .pointerCursor()
                .help("Open screenshot")
        } else {
            // Not an image: show the file's own icon and name, like a Finder attachment.
            let url = URL(fileURLWithPath: path)
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: min(height - 12, 32), height: min(height - 12, 32))
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: min(height, 48))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            .onTapGesture { NSWorkspace.shared.open(url) }
            .pointerCursor()
            .help("Open \(url.lastPathComponent)")
        }
    }
}

/// The pet's first idle frame, cropped to the face, used as the chat avatar.
struct PetAvatar: View {
    let size: CGFloat
    @ObservedObject private var config = ConfigStore.shared
    @MainActor private static var cache: (sprite: String?, image: NSImage?)?

    @MainActor private static func image(sprite: String?) -> NSImage? {
        if let cache, cache.sprite == sprite { return cache.image }
        var image: NSImage?
        if let frame = Atlas.loadDefault(sprite: sprite)?.rows.first?.first,
           let face = frame.cropping(to: CGRect(x: 34, y: 36, width: 124, height: 112)) {
            image = NSImage(cgImage: face, size: NSSize(width: 124, height: 112))
        }
        cache = (sprite, image)
        return image
    }

    var body: some View {
        Group {
            if let image = Self.image(sprite: config.config.pet.sprite) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "pawprint.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.06), in: Circle())
        .clipShape(Circle())
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// One row of the project picker: tinted icon tile, title, optional path, chevron, hover highlight.
private struct PickerRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering = $0 }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    let last: Bool
    let content: Content

    init(_ title: String, last: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.last = last
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer(minLength: 12)
                content
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            if !last { Hairline().padding(.horizontal, 12) }
        }
    }
}

private extension View {
    /// A menu that reads as the row's value: secondary text with a small chevron, aligned right.
    func settingsValueMenu() -> some View {
        self.menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
}

/// The command list above the input while the input starts with `/`.
private struct SlashPopup: View {
    let commands: [SlashCommand]
    let selection: Int
    let pick: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        Button { pick(command) } label: {
                            HStack(spacing: 8) {
                                Text("/\(command.name)").font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                if let hint = command.hint {
                                    Text(hint).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                                }
                                Text(command.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == selection ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .id(command.id)
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, new in
                if commands.indices.contains(new) { proxy.scrollTo(commands[new].id) }
            }
        }
        .padding(6)
        .chromeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
