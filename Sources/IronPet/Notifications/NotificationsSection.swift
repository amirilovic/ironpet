import AppKit
import Combine
import SwiftUI

/// What clicking a link in a notification does. Each kind has its own closure so the window, the tests and the previews can supply
/// their own.
struct NotificationLinkOpener {
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Reveals rather than opens: a script or agent wrote the path, and opening could launch an app or a script.
    var openFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var openThread: (String) -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    var openTask: (String) -> Void = { _ in }
    var openAlert: (String) -> Void = { _ in }

    func open(_ link: NotificationLink) {
        switch link.kind {
        case .url:
            // Stored rows passed validation, but a row from an older build or by hand might not have.
            guard let url = URL(string: link.ref), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            openURL(url)
        case .file: openFile(URL(fileURLWithPath: (link.ref as NSString).expandingTildeInPath))
        case .thread: openThread(link.ref)
        case .session: openSession(link.ref)
        case .task: openTask(link.ref)
        case .alert: openAlert(link.ref)
        }
    }
}

/// The state of the Notifications section: the list, the filters and which entry is open.
@MainActor
final class NotificationsModel: ObservableObject {
    let store: NotificationStore
    @Published var items: [NotificationItem] = []
    @Published var expanded: String?
    @Published var type: NotificationType?
    @Published var source: String?
    @Published private(set) var sources: [String] = []
    /// The unread count, mirrored from the store so the sidebar badge redraws.
    @Published private(set) var unread = 0
    var opener = NotificationLinkOpener()
    private var cancellable: AnyCancellable?

    /// Stands in where the page is not shown.
    static let empty = NotificationsModel(store: NotificationStore(database: Database.open(path: nil, migrations: NotificationStore.migrations).database))

    init(store: NotificationStore) {
        self.store = store
        unread = store.unreadCount
        cancellable = store.$unreadCount.sink { [weak self] count in self?.unread = count }
        reload()
    }

    func reload() {
        items = store.list(.init(source: source, type: type))
        sources = store.sources()
    }

    /// Opens or closes a row. Opening it marks it read.
    func toggle(_ id: String) {
        if expanded == id {
            expanded = nil
            return
        }
        select(id)
    }

    /// Opens a row and marks it read. A bubble's click and a row's click both end here.
    func select(_ id: String) {
        expanded = id
        store.markRead(id)
        reload()
    }

    func markAllRead() {
        store.markAllRead()
        reload()
    }

    /// The source filter's text: the automation id, or `System`.
    static func sourceTitle(_ source: String) -> String {
        source == NotificationItem.systemSource ? "System" : source
    }
}

/// The Notifications section: everything ironpet showed in a bubble, newest first.
struct NotificationsSection: View {
    @ObservedObject var model: NotificationsModel
    @ObservedObject var store: NotificationStore
    /// A notification a bubble asked to open. Opened, then cleared.
    @Binding var focus: String?

    var body: some View {
        content
            .pageHeader(IronPetSection.notifications.title) {
                HStack(spacing: 10) {
                    typeMenu
                    sourceMenu
                    Button("Mark all read") { model.markAllRead() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(store.unreadCount == 0)
                }
            }
            .onAppear { model.reload(); openFocus() }
            .onChange(of: focus) { _ in openFocus() }
            .onChange(of: store.revision) { _ in model.reload() }
    }

    private func openFocus() {
        guard let id = focus else { return }
        focus = nil
        model.type = nil
        model.source = nil
        model.select(id)
    }

    @ViewBuilder private var content: some View {
        if model.items.isEmpty {
            EmptyState(symbol: "tray", title: model.type == nil && model.source == nil ? "No notifications" : "Nothing matches",
                       detail: "Every bubble Ghost shows is kept here with its full text and links.")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.items) { item in
                        NotificationRow(item: item, expanded: model.expanded == item.id, onToggle: { model.toggle(item.id) },
                                        onOpen: { model.opener.open($0) })
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var typeMenu: some View {
        Menu {
            Button("All types") { model.type = nil; model.reload() }
            Divider()
            ForEach(NotificationType.allCases, id: \.self) { type in
                Button(type.title) { model.type = type; model.reload() }
            }
        } label: {
            Label(model.type?.title ?? "Type", systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .accessibilityLabel("Filter by type")
    }

    private var sourceMenu: some View {
        Menu {
            Button("All sources") { model.source = nil; model.reload() }
            Divider()
            ForEach(model.sources, id: \.self) { source in
                Button(NotificationsModel.sourceTitle(source)) { model.source = source; model.reload() }
            }
        } label: {
            Label(model.source.map(NotificationsModel.sourceTitle) ?? "Source", systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .accessibilityLabel("Filter by source")
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let expanded: Bool
    let onToggle: () -> Void
    let onOpen: (NotificationLink) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) { header }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isUnread ? "Unread: \(item.title)" : item.title)
            if expanded { details }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(expanded || hovering ? 0.08 : 0.03)))
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            Image(systemName: item.type.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.isUnread ? .semibold : .regular))
                        .lineLimit(expanded ? nil : 1)
                    Spacer(minLength: 4)
                    Text(item.created, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !item.summary.isEmpty, item.summary != item.title {
                    Text(item.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                Text(NotificationsModel.sourceTitle(item.source) + " · " + item.type.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var details: some View {
        if !item.description.isEmpty, item.description != item.summary {
            Text(Self.markdown(item.description))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 35)
        }
        if !item.links.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.links.enumerated()), id: \.offset) { _, link in
                    Button { onOpen(link) } label: {
                        Label(link.title, systemImage: Self.symbol(link.kind))
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(link.ref)
                }
            }
            .padding(.leading, 35)
        }
    }

    /// Markdown with the line breaks kept. Text that does not parse shows as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func symbol(_ kind: NotificationLink.Kind) -> String {
        switch kind {
        case .url: return "link"
        case .file: return "doc"
        case .thread: return "bubble.left"
        case .session: return "person.2"
        case .task: return "checklist"
        case .alert: return "bell"
        }
    }
}
