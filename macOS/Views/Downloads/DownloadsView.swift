import SwiftUI
import AppKit

/// The Downloads window: Soulseek search, transfers, messages, sharing, and
/// the network. Shows the setup walkthrough until setup is finished.
struct DownloadsWindowView: View {
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings

    var body: some View {
        let skin = settings.styled(theme.skin)
        DownloadsView(store: AppSession.shared.soulseek, skin: skin)
            .font(TypeScale.body)
            .foregroundStyle(skin.textPrimary)
            .frame(minWidth: 900, minHeight: 580)
            .glassWindow(skin, minSize: NSSize(width: 900, height: 580))
            .navigationTitle("Downloads")
            .preferredColorScheme(.dark)
    }

}

extension View {
    /// A Downloads pane: a light dark tint and a hairline over the frosted
    /// window, whatever the skin, so the desktop shows through every pane.
    func frostedPane(_ skin: Skin, tint: Double = 0.26) -> some View {
        background(Color.black.opacity(tint))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
            .fuiCorners(skin)
    }
}

struct DownloadsView: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    /// Off only for offscreen snapshots, whose renderer can't draw scroll views.
    var scrolls = true

    enum Section: Hashable {
        case search, transfers, messages, shares, network
        case browse(String)
    }

    @State var section: Section = .search
    @State var logOpen = false
    /// Snapshots only: the search field's text and whether its key is open.
    var searchQuery: String? = nil
    var searchKey = false
    var searchAssist = false
    var searchCorrection: (String, String)? = nil

    var body: some View {
        VStack(spacing: Corners.inset) {
            HStack(spacing: Corners.inset) {
                if store.settings.enabled && store.settings.setupComplete {
                    rail
                        .frame(width: 196)
                        .frostedPane(skin, tint: 0.08)
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipShape(Rectangle())
                        .frostedPane(skin, tint: 0.14)
                } else {
                    // Setup brings its own rail and content panes.
                    SoulseekSetupView(store: store, skin: skin, onFinish: { section = .search }, scrolls: scrolls)
                }
            }
            .frame(maxHeight: .infinity)
            if logOpen && store.settings.enabled && store.settings.setupComplete {
                LogConsole(store: store, skin: skin, scrolls: scrolls, onClose: toggleLog)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Corners.inset)
        .padding(.bottom, Corners.inset)
        .padding(.top, TitleBand.height)
        .clipped()
        .overlay(alignment: .top) { WindowDragArea().frame(height: TitleBand.height) }
        .overlay(alignment: .top) {
            ZStack {
                HStack(spacing: 16) {
                    if !AppSession.shared.settings.data.systemWindowFrame { WindowControls(skin: skin, closeOnly: true) }
                    Spacer()
                    if store.settings.enabled && store.settings.setupComplete {
                        NetworkStats(store: store, skin: skin)
                    }
                }
            }
            .frame(height: TitleBand.height)
            .padding(.leading, TitleBand.controlsLeading)
            .padding(.trailing, TitleBand.controlsLeading)
        }
        .background {
            Button("", action: toggleLog)
                .keyboardShortcut("j", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func toggleLog() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { logOpen.toggle() }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsNavRow(icon: "magnifyingglass", title: "Search", isSelected: section == .search,
                           trailingText: store.searches.isEmpty ? nil : "\(store.searches.count)", skin: skin) { section = .search }
            SettingsNavRow(icon: "downloads", title: "Transfers", isSelected: section == .transfers,
                           trailingText: activeCount == 0 ? nil : "\(activeCount)", trailingIsOn: failedCount > 0,
                           skin: skin) { section = .transfers }
            SettingsNavRow(icon: "messages", title: "Messages", isSelected: section == .messages,
                           trailingText: store.unreadMessages == 0 ? nil : "\(store.unreadMessages)",
                           trailingIsOn: store.unreadMessages > 0, skin: skin) { section = .messages }
            SettingsNavRow(icon: "folder.badge.plus", title: "Sharing", isSelected: section == .shares,
                           trailingText: store.settings.sharesNothing ? "none" : Self.count(store.sharedFiles),
                           trailingIsOn: store.settings.sharesNothing, skin: skin) { section = .shares }
            SettingsNavRow(icon: "network", title: "Network", isSelected: section == .network,
                           skin: skin) { section = .network }
            if !browsedUsers.isEmpty {
                Text("browsing").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    .padding(.top, 12).padding(.leading, 8).padding(.bottom, 2)
                ForEach(browsedUsers, id: \.self) { user in
                    SettingsNavRow(icon: "person.fill", title: user, isSelected: section == .browse(user), skin: skin) {
                        section = .browse(user)
                    }
                }
            }
            if !store.settings.starredUsers.isEmpty {
                Text("starred").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    .padding(.top, 12).padding(.leading, 8).padding(.bottom, 2)
                ForEach(store.settings.starredUsers.prefix(12), id: \.self) { user in
                    SettingsNavRow(icon: "star.fill", title: user, isSelected: section == .browse(user), skin: skin) {
                        store.browse(user)
                        section = .browse(user)
                    }
                    .appContextMenu {
                        MenuContent(title: user, entries: [
                            .action("Browse Their Files", glyph: "folder.badge.plus") { store.browse(user); section = .browse(user) },
                            .action("Message", glyph: "messages") { store.startConversation(with: user); section = .messages },
                            .action("Unstar User", glyph: "star") { store.toggleStar(user) },
                        ])
                    }
                }
            }
            Spacer()
            RailNotice(store: store, skin: skin) { section = .messages }
            ConnectionStatus(store: store, skin: skin, logOpen: logOpen, onToggle: toggleLog)
        }
        .padding(10)
    }

    private var browsedUsers: [String] { store.browsing.keys.filter { !store.isStarred($0) }.sorted() }
    private var activeCount: Int { store.downloads.filter { !$0.state.isFinished }.count }
    private var failedCount: Int { store.downloads.filter { if case .failed = $0.state { return true } else { return false } }.count }

    static func count(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.0fk", Double(n) / 1000) : NumberFormatter.localizedString(from: n as NSNumber, number: .decimal)
    }

    private func browse(_ user: String) {
        store.browse(user)
        section = .browse(user)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .search:
            SearchPage(store: store, skin: skin, scrolls: scrolls, query: searchQuery, keyOpen: searchKey,
                       showsAssist: searchAssist, correction: searchCorrection, onBrowse: browse)
        case .transfers: TransfersPage(store: store, skin: skin, scrolls: scrolls) { section = .shares }
        case .messages: MessagesPage(store: store, skin: skin, scrolls: scrolls, onBrowse: browse)
        case .shares: scroll { SharingPage(store: store, skin: skin) }
        case .network: scroll { NetworkPage(store: store, skin: skin) }
        case .browse(let user):
            BrowsePage(store: store, user: user, skin: skin, scrolls: scrolls) {
                store.startConversation(with: user)
                section = .messages
            }
        }
    }

    @ViewBuilder
    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let body = content().padding(20).frame(maxWidth: .infinity, alignment: .leading)
        if scrolls { ScrollView { body } } else { body.frame(maxHeight: .infinity, alignment: .top) }
    }
}

// MARK: - Transfers

private struct TransfersPage: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var scrolls: Bool
    var onShowSharing: () -> Void
    @State private var showUploads = false
    /// Folders whose open/closed state the user flipped from the default
    /// (open while anything in them is unfinished, closed once all are done).
    @State private var flipped: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryHeader(title: "Transfers", subtitle: subtitle, skin: skin) {
                HStack(spacing: 6) {
                    Button("Retry Failed") { store.retryAllFailed() }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        .disabled(!hasFailed)
                    Button("Clear Finished") { store.clearFinished() }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    Button("Open Folder") {
                        let url = URL(fileURLWithPath: store.settings.downloadFolder, isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
            }
            ChoiceChips(options: [("Downloads", store.downloads.count), ("Uploads", store.uploads.count)],
                        selected: showUploads ? 1 : 0, skin: skin) { showUploads = $0 == 1 }
            let groups = TransferGroup.make(showUploads ? store.uploads : store.downloads)
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Glyph(showUploads ? "transfer.up" : "transfer.down", size: 22).foregroundStyle(skin.textTertiary.opacity(0.6))
                    Text(showUploads ? "Nothing sent yet" : "Nothing downloaded yet")
                        .font(TypeScale.strong).foregroundStyle(skin.textSecondary)
                    Text(showUploads ? "Files other users take from your shares appear here."
                                     : "Pick files or folders in Search or a user's files to download them.")
                        .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    TransferColumnsHeader(skin: skin)
                    let rows = LazyVStack(spacing: 3) {
                        ForEach(groups.prefix(scrolls ? 1000 : 6)) { group in
                            TransferGroupView(group: group, upload: showUploads, expanded: isExpanded(group),
                                              skin: skin, store: store, scrolls: scrolls, onShowSharing: onShowSharing) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                    if flipped.contains(group.id) { flipped.remove(group.id) } else { flipped.insert(group.id) }
                                }
                            }
                        }
                    }
                    if scrolls { ScrollView { rows.padding(.bottom, 8) } } else { rows.frame(maxHeight: .infinity, alignment: .top).clipped() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isExpanded(_ group: TransferGroup) -> Bool {
        group.allFinished == flipped.contains(group.id)
    }

    private var hasFailed: Bool { store.downloads.contains { if case .failed = $0.state { return true } else { return false } } }

    private var subtitle: String {
        let active = store.downloads.filter { !$0.state.isFinished }
        let speed = active.reduce(0) { $0 + $1.speed }
        if active.isEmpty { return "Saving to " + (store.settings.downloadFolder as NSString).abbreviatingWithTildeInPath }
        return "\(active.count) in progress · \(Format.speed(speed))"
    }
}

/// The files of one remote folder, from one user.
struct TransferGroup: Identifiable {
    let user: String
    /// The remote folder's full path.
    let path: String
    var transfers: [SoulseekStore.Transfer]

    var id: String { user + "|" + path }
    var name: String { path.split(separator: "\\").last.map(String.init) ?? path }
    /// Where the folder sits on their side, without the folder itself.
    var parent: String { path.split(separator: "\\").dropLast().joined(separator: "\\") }

    var size: UInt64 { transfers.reduce(0) { $0 + $1.size } }
    var bytes: UInt64 { transfers.reduce(0) { $0 + ($1.localURL != nil ? $1.size : $1.bytes) } }
    var progress: Double { size == 0 ? 0 : min(1, Double(bytes) / Double(size)) }
    var speed: Double { transfers.reduce(0) { $0 + ($1.state == .downloading ? $1.speed : 0) } }
    var done: Int { transfers.filter { $0.localURL != nil }.count }
    var failed: [SoulseekStore.Transfer] { transfers.filter { if case .failed = $0.state { return true } else { return false } } }
    var moving: Bool { transfers.contains { $0.state == .downloading } }
    var allFinished: Bool { transfers.allSatisfy(\.state.isFinished) }
    var allDone: Bool { done == transfers.count }
    var unfinished: [SoulseekStore.Transfer] { transfers.filter { !$0.state.isFinished } }

    /// Groups a transfer list by user and folder, newest folder first, files in name order.
    static func make(_ list: [SoulseekStore.Transfer]) -> [TransferGroup] {
        var order: [String] = []
        var groups: [String: TransferGroup] = [:]
        for t in list {
            let folder = t.path.split(separator: "\\").dropLast().joined(separator: "\\")
            let key = t.user + "|" + folder
            if groups[key] == nil {
                order.append(key)
                groups[key] = TransferGroup(user: t.user, path: folder, transfers: [])
            }
            groups[key]!.transfers.append(t)
        }
        return order.map { key in
            var g = groups[key]!
            g.transfers.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return g
        }
    }
}

private enum TransferColumns {
    static let lead: CGFloat = 16
    static let files: CGFloat = 52
    static let size: CGFloat = 72
    static let speed: CGFloat = 76
    static let status: CGFloat = 96
    static let actions: CGFloat = 70
}

private struct TransferColumnsHeader: View {
    var skin: Skin

    var body: some View {
        HStack(spacing: 10) {
            Text("Folder").frame(maxWidth: .infinity, alignment: .leading)
            Text("Files").frame(width: TransferColumns.files, alignment: .trailing)
            Text("Size").frame(width: TransferColumns.size, alignment: .trailing)
            Text("Speed").frame(width: TransferColumns.speed, alignment: .trailing)
            Text("Status").frame(width: TransferColumns.status, alignment: .trailing)
            Color.clear.frame(width: TransferColumns.actions)
        }
        .font(TypeScale.caption)
        .foregroundStyle(skin.textTertiary)
        .padding(.horizontal, 13)
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A folder of transfers: one summary line with the folder's progress,
/// and its files under it while open.
private struct TransferGroupView: View {
    var group: TransferGroup
    var upload: Bool
    var expanded: Bool
    var skin: Skin
    @ObservedObject var store: SoulseekStore
    var scrolls: Bool
    var onShowSharing: () -> Void
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.transfers.prefix(scrolls ? 5000 : 5)) { t in
                        TransferFileRow(transfer: t, upload: upload, skin: skin, store: store, onShowSharing: onShowSharing)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let first = group.failed.first, case .failed(let why) = first.state {
                FailureLine(text: group.failed.count == 1 ? why : "\(group.failed.count) failed. \(why)",
                            sharing: why == SlskReasons.requiresSharing, skin: skin, onShowSharing: onShowSharing)
                    .padding(.leading, 12 + TransferColumns.lead * 2 + 20)
                    .padding(.trailing, 12)
                    .padding(.bottom, 9)
            }
        }
        .background(Rectangle().fill(Color.white.opacity(expanded ? 0.035 : hovering ? 0.03 : 0.015)))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(expanded ? 0.12 : 0.07), lineWidth: 1))
        .clipped()
        .onHover { hovering = $0 }
        .appContextMenu { menu }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Glyph("chevron.right", size: 8)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(hovering ? skin.textSecondary : skin.textTertiary)
                    .frame(width: TransferColumns.lead)
                Glyph(stateGlyph, size: 12)
                    .foregroundStyle(stateColor)
                    .frame(width: TransferColumns.lead)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name.isEmpty ? "Top level" : group.name)
                        .font(TypeScale.strong).foregroundStyle(skin.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 0) {
                        Text((upload ? "to " : "from ") + group.user).foregroundStyle(skin.textSecondary)
                            .fixedSize().layoutPriority(1)
                        if !group.parent.isEmpty {
                            Text("  " + group.parent.replacingOccurrences(of: "\\", with: " / "))
                                .foregroundStyle(skin.textTertiary).truncationMode(.head)
                        }
                    }
                    .font(TypeScale.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(group.done)/\(group.transfers.count)")
                    .frame(width: TransferColumns.files, alignment: .trailing)
                    .foregroundStyle(skin.textSecondary)
                Text(Format.bytes(group.size))
                    .frame(width: TransferColumns.size, alignment: .trailing)
                    .foregroundStyle(skin.textSecondary)
                Text(group.speed > 0 ? Format.speed(group.speed) : "")
                    .frame(width: TransferColumns.speed, alignment: .trailing)
                    .foregroundStyle(skin.textSecondary)
                StatusLogButton(text: status, strong: group.moving, color: group.moving ? skin.textPrimary : statusColor,
                                title: group.name, subtitle: (upload ? "to " : "from ") + group.user,
                                ids: group.transfers.map(\.id), upload: upload, store: store, skin: skin)
                    .frame(width: TransferColumns.status, alignment: .trailing)
                actions.frame(width: TransferColumns.actions, alignment: .trailing)
            }
            .font(TypeScale.caption.monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)
            CapsuleProgress(fraction: group.progress, skin: skin)
                .frame(height: 2)
                .padding(.leading, 12 + TransferColumns.lead * 2 + 20)
                .padding(.trailing, 12 + TransferColumns.actions + 10)
                .padding(.bottom, 7)
                .opacity(showsBar ? 1 : 0)
                .frame(height: showsBar ? 10 : 2, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// Only while the folder is underway: a full bar on a finished folder would read as a rule.
    private var showsBar: Bool { !group.allFinished && group.bytes > 0 }

    private var stateGlyph: String {
        if group.moving { return upload ? "transfer.up" : "transfer.down" }
        if group.allDone { return "transfer.done" }
        if group.allFinished { return "transfer.failed" }
        return "transfer.queued"
    }

    private var stateColor: Color {
        if group.moving { return skin.accent }
        if group.allFinished && !group.failed.isEmpty { return skin.accent.opacity(0.85) }
        return skin.textTertiary
    }

    private var statusColor: Color { group.allFinished && !group.failed.isEmpty ? skin.accent.opacity(0.9) : skin.textSecondary }

    private var status: String {
        if group.moving { return upload ? "sending" : "\(Int(group.progress * 100))%" }
        if group.allDone { return "done" }
        if group.allFinished { return group.failed.count == group.transfers.count ? "failed" : "\(group.failed.count) failed" }
        let places = group.unfinished.compactMap { t -> Int? in if case .remoteQueued(let p) = t.state { return p } else { return nil } }
        if let first = places.filter({ $0 > 0 }).min() { return "their queue #\(first)" }
        if !places.isEmpty { return "their queue" }
        if group.unfinished.contains(where: { $0.state == .connecting }) { return "connecting" }
        if group.unfinished.contains(where: { $0.state == .requesting }) { return "requested" }
        return "waiting"
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if !upload && !group.failed.isEmpty {
                RowAction(glyph: "arrow.counterclockwise", help: "Retry the failed files", skin: skin) {
                    store.retry(Set(group.failed.map(\.id)))
                }
            }
            if group.done > 0 {
                RowAction(glyph: "folder.open", help: "Show in Finder", skin: skin) { store.reveal(group.transfers) }
            }
            if !upload {
                RowAction(glyph: group.allFinished ? "trash" : "xmark.circle.fill",
                          help: group.allFinished ? "Remove from the list" : "Cancel the remaining files", skin: skin) {
                    store.cancel(Set((group.allFinished ? group.transfers : group.unfinished).map(\.id)))
                }
            }
        }
        .opacity(hovering ? 1 : 0.5)
    }

    private var menu: MenuContent {
        var entries: [MenuEntry] = []
        if !upload && !group.failed.isEmpty {
            entries.append(.action("Retry Failed", glyph: "arrow.counterclockwise") { store.retry(Set(group.failed.map(\.id))) })
        }
        if group.done > 0 {
            entries.append(.action("Show in Finder", glyph: "folder.open") { store.reveal(group.transfers) })
        }
        entries.append(.action(expanded ? "Fold Up" : "Show Files", glyph: expanded ? "chevron.up" : "chevron.down", onToggle))
        var removal: [MenuEntry] = []
        if !upload {
            if !group.unfinished.isEmpty {
                removal.append(.action("Cancel Remaining", glyph: "xmark.circle.fill", destructive: true) {
                    store.cancel(Set(group.unfinished.map(\.id)))
                })
            }
            removal.append(.action("Remove from List", glyph: "trash", destructive: !group.allFinished) {
                store.cancel(Set(group.transfers.map(\.id)))
            })
        }
        return MenuContent(title: group.name, subtitle: (upload ? "to " : "from ") + group.user, [
            MenuGroup(nil, entries),
            MenuGroup(group.user, [
                .action("Browse Their Files", glyph: "folder.badge.plus") { store.browse(group.user) },
            ]),
            MenuGroup(nil, removal),
        ])
    }
}

/// One file inside an open folder.
private struct TransferFileRow: View {
    var transfer: SoulseekStore.Transfer
    var upload: Bool
    var skin: Skin
    @ObservedObject var store: SoulseekStore
    var onShowSharing: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Color.clear.frame(width: TransferColumns.lead, height: 1)
                Glyph(glyph, size: 10)
                    .foregroundStyle(glyphColor)
                    .frame(width: TransferColumns.lead)
                Text(transfer.name)
                    .foregroundStyle(transfer.localURL != nil ? skin.textSecondary : skin.textPrimary)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(transfer.name)
                Text(Format.bytes(transfer.size))
                    .frame(width: TransferColumns.size, alignment: .trailing)
                    .foregroundStyle(skin.textTertiary)
                    .help(isMoving ? "\(Format.bytes(transfer.bytes)) of \(Format.bytes(transfer.size))" : "")
                Text(isMoving ? Format.speed(transfer.speed) : "")
                    .frame(width: TransferColumns.speed, alignment: .trailing)
                    .foregroundStyle(skin.textTertiary)
                StatusLogButton(text: tag, strong: false,
                                color: isFailed ? skin.accent.opacity(0.9) : isMoving ? skin.textPrimary : skin.textTertiary,
                                title: transfer.name, subtitle: (upload ? "to " : "from ") + transfer.user,
                                ids: [transfer.id], upload: upload, store: store, skin: skin)
                    .frame(width: TransferColumns.status, alignment: .trailing)
                actions.frame(width: TransferColumns.actions, alignment: .trailing)
            }
            .font(TypeScale.caption.monospacedDigit())
            .lineLimit(1)
            if isMoving || (transfer.bytes > 0 && !transfer.state.isFinished) {
                CapsuleProgress(fraction: transfer.progress, skin: skin)
                    .frame(height: 1.5)
                    .padding(.leading, TransferColumns.lead * 2 + 20)
                    .padding(.trailing, TransferColumns.actions + 10)
            }
            if case .failed(let why) = transfer.state {
                FailureLine(text: why, sharing: why == SlskReasons.requiresSharing, skin: skin, onShowSharing: onShowSharing)
                    .padding(.leading, TransferColumns.lead * 2 + 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Rectangle().fill(Color.white.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
        .appContextMenu { menu }
    }

    private var isMoving: Bool { transfer.state == .downloading }
    private var isFailed: Bool { if case .failed = transfer.state { return true } else { return false } }

    private var glyph: String {
        switch transfer.state {
        case .downloading: return upload ? "transfer.up" : "transfer.down"
        case .done: return "transfer.done"
        case .failed: return "transfer.failed"
        default: return "transfer.queued"
        }
    }

    private var glyphColor: Color {
        switch transfer.state {
        case .downloading: return skin.accent
        case .failed: return skin.accent.opacity(0.85)
        default: return skin.textTertiary
        }
    }

    private var tag: String {
        switch transfer.state {
        case .queued: return "waiting"
        case .requesting: return "requested"
        case .remoteQueued(let place): return place > 0 ? "their queue #\(place)" : "their queue"
        case .connecting: return "connecting"
        case .downloading: return upload ? "sending" : "\(Int(transfer.progress * 100))%"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if !upload, isFailed {
                RowAction(glyph: "arrow.counterclockwise", help: "Retry", skin: skin) { store.retry(transfer.id) }
            }
            if transfer.localURL != nil {
                RowAction(glyph: "folder.open", help: "Show in Finder", skin: skin) { store.reveal(transfer) }
            }
            if !upload {
                RowAction(glyph: transfer.state.isFinished ? "trash" : "xmark.circle.fill",
                          help: transfer.state.isFinished ? "Remove from the list" : "Cancel", skin: skin) { store.cancel(transfer.id) }
            }
        }
        .opacity(hovering ? 1 : 0)
    }

    private var menu: MenuContent {
        var entries: [MenuEntry] = []
        if !upload, isFailed {
            entries.append(.action("Retry", glyph: "arrow.counterclockwise") { store.retry(transfer.id) })
        }
        if transfer.localURL != nil {
            entries.append(.action("Show in Finder", glyph: "folder.open") { store.reveal(transfer) })
        }
        return MenuContent(title: transfer.name, subtitle: (upload ? "to " : "from ") + transfer.user, [
            MenuGroup(nil, entries),
            MenuGroup(transfer.user, [
                .action("Browse Their Files", glyph: "folder.badge.plus") { store.browse(transfer.user) },
            ]),
            MenuGroup(nil, upload ? [] : [
                .action(transfer.state.isFinished ? "Remove from List" : "Cancel Download", glyph: "trash",
                        destructive: !transfer.state.isFinished) { store.cancel(transfer.id) },
            ]),
        ])
    }
}

/// A transfer's status; click it for the history of that bar.
private struct StatusLogButton: View {
    var text: String
    var strong: Bool
    var color: Color
    var title: String
    var subtitle: String
    var ids: [UUID]
    var upload: Bool
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text(text)
                .font(strong ? TypeScale.strong.monospacedDigit() : TypeScale.caption.monospacedDigit())
                .foregroundStyle(hovering || showing ? skin.textPrimary : color)
                .underline(hovering || showing, pattern: .dot, color: skin.textTertiary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show every update for this " + (ids.count > 1 ? "folder" : "file"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TransferHistory(title: title, subtitle: subtitle, ids: ids, upload: upload, store: store, skin: skin)
                .scrollIndicators(.never)
        }
    }
}

/// Every update a transfer's bar showed: added, requested, their queue,
/// connecting, progress every tenth, finished or failed. For a folder, all
/// of its files' updates in order, each with the file it was about.
struct TransferHistory: View {
    var title: String
    var subtitle: String
    var ids: [UUID]
    var upload: Bool
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    /// Off only for offscreen snapshots.
    var scrolls = true

    private struct Line: Identifiable {
        let id: UUID
        let time: Date
        let event: String
        let detail: String
        let file: String?
        let bad: Bool
    }

    private var lines: [Line] {
        let wanted = Set(ids)
        let list = (upload ? store.uploads : store.downloads).filter { wanted.contains($0.id) }
        let folder = ids.count > 1
        return list.flatMap { t in
            t.history.map { Line(id: $0.id, time: $0.time, event: $0.event, detail: $0.detail, file: folder ? t.name : nil, bad: $0.bad) }
        }
        .sorted { $0.time < $1.time }
    }

    private func grid(_ lines: [Line]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(lines) { line in
                GridRow {
                    Text(traceTime.string(from: line.time)).foregroundStyle(skin.textTertiary)
                    Text(line.event).foregroundStyle(line.bad ? skin.accent : skin.textPrimary)
                    VStack(alignment: .leading, spacing: 1) {
                        if let file = line.file {
                            Text(file).foregroundStyle(skin.textSecondary).lineLimit(1).truncationMode(.middle)
                        }
                        if !line.detail.isEmpty {
                            Text(line.detail).foregroundStyle(line.file == nil ? skin.textSecondary : skin.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .id(line.id)
            }
        }
        .font(AppFont.mono(11))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        let lines = self.lines
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.strong).foregroundStyle(skin.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(subtitle + "  ·  \(lines.count) update" + (lines.count == 1 ? "" : "s"))
                    .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if lines.isEmpty {
                Text("No updates yet.").font(AppFont.mono(11)).foregroundStyle(skin.textTertiary).padding(14)
            } else {
                if !scrolls {
                    grid(lines)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            grid(lines)
                        }
                        .onAppear { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                        .onChange(of: lines.count) { _ in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                        }
                    }
                    // A scroll view has no height of its own here: size it to the lines, up to a limit.
                    .frame(height: min(300, lines.reduce(28) { $0 + ($1.file == nil ? 18 : 32) }))
                }
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.35))
        .preferredColorScheme(.dark)
    }
}

/// Why a transfer failed, with a way to the Sharing settings when that's the reason.
private struct FailureLine: View {
    var text: String
    var sharing: Bool
    var skin: Skin
    var onShowSharing: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text).font(TypeScale.caption).foregroundStyle(skin.accent.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            if sharing {
                TextAction(title: "Sharing Settings", skin: skin, action: onShowSharing)
            }
        }
    }
}

/// A bare glyph button for a row: dim at rest, bright under the pointer.
private struct RowAction: View {
    var glyph: String
    var help: String
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(glyph, size: 10.5)
                .foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Browse

private struct BrowsePage: View {
    @ObservedObject var store: SoulseekStore
    var user: String
    var skin: Skin
    var scrolls: Bool
    var onMessage: () -> Void
    @State private var expanded: Set<String> = []
    @State private var filter = ""
    /// The filter as applied: follows the field a moment after typing stops,
    /// so a long list isn't searched on every keystroke.
    @State private var applied = ""
    @State private var pending: Task<Void, Never>?

    /// Rows drawn at most; the filter narrows the rest.
    private static let rowLimit = 5000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryHeader(title: user, subtitle: subtitle, skin: skin) {
                HStack(spacing: 6) {
                    Button("Message") { onMessage() }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    Button(store.isStarred(user) ? "Unstar" : "Star") { store.toggleStar(user) }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    Button("Refresh") { store.browse(user) }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
            }
            switch store.browsing[user] {
            case .loading?, nil:
                FileListRequest(store: store, user: user, failed: false, skin: skin)
            case .failed?:
                NoFileList(store: store, user: user, skin: skin, onMessage: onMessage)
            case .loaded(let list)?:
                let shown = store.browseMatches(user, list, applied)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    FormField(title: "Filter", text: $filter, placeholder: "", skin: skin)
                        .frame(maxWidth: 360)
                        .onChange(of: filter) { value in
                            pending?.cancel()
                            pending = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 140_000_000)
                                guard !Task.isCancelled else { return }
                                applied = value
                            }
                        }
                    if !applied.isEmpty {
                        Text("\(shown.count) of \(list.groups.count) folders").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    }
                    if shown.count > Self.rowLimit {
                        Text("Showing the first \(Self.rowLimit.formatted()); filter to narrow")
                            .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    }
                }
                let queued = store.transferKeys
                let rows = LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(shown.prefix(scrolls ? Self.rowLimit : 10)) { group in
                        ResultGroupRow(group: group, expanded: expanded.contains(group.id), skin: skin,
                                       queued: queued, showsPeer: false,
                                       onToggle: { if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) } },
                                       onDownload: { store.download($0, from: user) },
                                       onBrowse: {})
                    }
                }
                if scrolls { ScrollView { rows } } else { rows }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        if case .loaded(let list)? = store.browsing[user] {
            return "\(list.groups.count.formatted()) folders · \(list.fileCount.formatted()) files"
        }
        return "Shared files"
    }
}

// MARK: - Sharing

struct SharingPage: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryHeader(title: "Sharing", subtitle: subtitle, skin: skin) {
                if store.indexingShares { Text("indexing").font(TypeScale.caption).foregroundStyle(skin.textTertiary) }
            }
            if store.settings.sharesNothing {
                LibrarySection(title: "not sharing", skin: skin) {
                    Text("Many users upload only to peers who share files. Requests to those users will be declined.")
                        .font(TypeScale.body).foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Share Download Folder") { store.settings.shareDownloads = true }
                        .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                        .padding(.top, 6)
                }
            }
            LibrarySection(title: "shared folders", skin: skin) {
                SettingsToggleRow(title: "Download folder", subtitle: "Completed downloads.",
                                  isOn: $store.settings.shareDownloads, skin: skin)
                SettingsToggleRow(title: "Library folders", subtitle: "All folders in the i2s library.",
                                  isOn: $store.settings.shareLibrary, skin: skin)
                ForEach(store.settings.extraShares, id: \.self) { path in
                    HStack {
                        Glyph("folder.badge.plus", size: 11).foregroundStyle(skin.textTertiary)
                        Text((path as NSString).abbreviatingWithTildeInPath).font(TypeScale.body).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { store.settings.extraShares.removeAll { $0 == path } }
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    }
                    .padding(.vertical, 4)
                }
                Button("Add Folder…") {
                    if let url = Self.chooseFolder(), !store.settings.extraShares.contains(url.path) {
                        store.settings.extraShares.append(url.path)
                    }
                }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .padding(.top, 6)
            }
            LibrarySection(title: "details", skin: skin) {
                SpecRow(label: "visibility", value: "Shared files can be browsed and downloaded by any Soulseek user", skin: skin)
                SpecRow(label: "partial files", value: "Never shared", skin: skin)
                SpecRow(label: "index", value: "Rebuilt when folders change and after each completed download", skin: skin)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var subtitle: String {
        store.settings.sharesNothing ? "No folders shared" : "\(DownloadsView.count(store.sharedFiles)) files in \(DownloadsView.count(store.sharedFolders)) folders"
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Network

/// The account, the route Raven takes, transfer limits, and turning
/// Soulseek off. The session's log is in the panel under the window.
private struct NetworkPage: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryHeader(title: "Network", subtitle: statusLine, skin: skin) {
                HStack(spacing: 6) {
                    if store.status == .online || store.status == .connecting {
                        Button("Disconnect") { store.disconnect() }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    } else {
                        Button("Connect") { store.connect() }.buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                    }
                }
            }
            LibrarySection(title: "account", skin: skin) {
                HStack(spacing: 12) {
                    NetworkGlyph(state: store.glyphState, skin: skin, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.settings.username.isEmpty ? "Not signed in" : store.settings.username).font(TypeScale.strong)
                        Text(accountDetail).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Sign Out") { store.signOut(); store.settings.setupComplete = false }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
                .padding(.vertical, 4)
                SettingsToggleRow(title: "Connect at launch", subtitle: "Signs in when i2s opens, along the route below.",
                                  isOn: $store.settings.connectOnLaunch, skin: skin)
            }
            NetworkForm(store: store, skin: skin)
            HStack {
                Spacer()
                Button("Reconnect to Apply") { store.connect() }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
            LibrarySection(title: "transfers", skin: skin) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download folder").font(TypeScale.body)
                        Text((store.settings.downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .font(TypeScale.caption).foregroundStyle(skin.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { if let url = SharingPage.chooseFolder() { store.settings.downloadFolder = url.path } }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
                .padding(.vertical, 4)
                SettingsToggleRow(title: "Preserve remote folder structure", subtitle: "Each download is saved inside the folder name used by the uploader.",
                                  isOn: $store.settings.keepFolders, skin: skin)
                stepper("Concurrent requests", value: $store.settings.maxActiveDownloads, range: 1...20,
                        note: "Download requests sent at a time.")
                stepper("Upload slots", value: $store.settings.uploadSlots, range: 1...20,
                        note: "Simultaneous uploads to other users.")
            }
            LibrarySection(skin: skin) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disable Soulseek").font(TypeScale.body)
                        Text("Disconnects and closes Downloads. The account and downloaded files are kept.")
                            .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    }
                    Spacer()
                    Button("Disable") { store.turnOff() }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
            }
            LegalLink(skin: skin)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var statusLine: String {
        switch store.status {
        case .online: return store.greeting.isEmpty ? "Online" : "Online · " + store.greeting.prefix(120)
        case .connecting: return "Connecting"
        case .off: return "Not connected"
        case .offline(let why): return why
        }
    }

    private var accountDetail: String {
        var parts: [String] = []
        switch store.status {
        case .online: parts.append("Signed in to \(store.serverAddress)")
        case .connecting: parts.append("Connecting to \(store.serverAddress)")
        default: parts.append(store.serverAddress)
        }
        if let seen = store.seenAs, store.status == .online { parts.append("seen as \(seen)") }
        if let port = store.listeningPort { parts.append("listening on \(port)") }
        return parts.joined(separator: " · ")
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, note: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.body)
                Text(note).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            }
            Spacer()
            SegmentBar(skin: skin, items: [
                SegmentBar.Item(glyph: "minus.circle", enabled: value.wrappedValue > range.lowerBound) { value.wrappedValue -= 1 },
                SegmentBar.Item(title: "\(value.wrappedValue)", enabled: false) {},
                SegmentBar.Item(glyph: "plus", enabled: value.wrappedValue < range.upperBound) { value.wrappedValue += 1 },
            ])
            .frame(width: 110)
        }
        .padding(.vertical, 4)
    }
}

/// Two or three mutually exclusive choices, written as text; the chosen one
/// is highlighted. Counts follow in a lighter tone.
struct ChoiceChips: View {
    var options: [(title: String, count: Int?)]
    var selected: Int
    var skin: Skin
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                TextOption(title: option.count.map { "\(option.title)  \($0)" } ?? option.title, on: i == selected, skin: skin) {
                    onSelect(i)
                }
            }
        }
        .padding(.leading, -7)
    }
}

// MARK: - File list request

/// While a user's file list is on its way: what Raven is doing for this
/// request, line by line as the engine reports it, how long it has taken,
/// and how much of the list has arrived once it starts coming in.
private struct FileListRequest: View {
    @ObservedObject var store: SoulseekStore
    var user: String
    var failed: Bool
    var skin: Skin
    /// Only the trace panel (the error screen's "Show Trace").
    var traceOnly = false

    /// After this long without the list starting to arrive, say what that can mean.
    private static let patience: TimeInterval = 15

    private var started: Date { store.browseStarted[user] ?? Date() }
    private var progress: SoulseekStore.ListProgress? { store.browseProgress[user] }

    /// The engine's lines about this user since the request.
    private var steps: [(time: Date, event: String, detail: String, kind: SoulseekStore.LogLine.Kind)] {
        let prefix = user + "  "
        let since = started.addingTimeInterval(-1)
        return store.sessionLog.suffix(400).compactMap { line in
            guard line.topic == .peer, line.time >= since, line.text.hasPrefix(prefix) else { return nil }
            let parts = SessionLog.split(String(line.text.dropFirst(prefix.count)), joiner: "  ")
            let bad = parts.event == "unreachable" || parts.event == "closed" || parts.event == "no address"
            return (line.time, parts.event, parts.detail, bad ? .error : line.kind)
        }
    }

    private var tracePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trace").font(TypeScale.caption).foregroundStyle(skin.textTertiary).padding(.bottom, 6)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                let steps = self.steps
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    GridRow {
                        Text(traceTime.string(from: step.time)).foregroundStyle(skin.textTertiary)
                        Text(step.event).foregroundStyle(step.kind == .error ? skin.accent : skin.textPrimary)
                        HStack(spacing: 6) {
                            Text(step.detail).foregroundStyle(skin.textSecondary).lineLimit(1).truncationMode(.middle)
                            if i == steps.count - 1 && progress == nil && !failed { Cursor(skin: skin) }
                        }
                    }
                }
                if let progress, !failed {
                    GridRow {
                        Text(traceTime.string(from: Date())).foregroundStyle(skin.textTertiary)
                        Text("receiving").foregroundStyle(skin.textPrimary)
                        HStack(spacing: 6) {
                            Text("\(Format.bytes(UInt64(progress.received))) of \(Format.bytes(UInt64(progress.total)))")
                                .foregroundStyle(skin.textSecondary)
                            Cursor(skin: skin)
                        }
                    }
                }
                if steps.isEmpty && progress == nil && !failed {
                    GridRow {
                        Text(traceTime.string(from: started)).foregroundStyle(skin.textTertiary)
                        Text("waiting").foregroundStyle(skin.textPrimary)
                        HStack(spacing: 6) { Text("for the network").foregroundStyle(skin.textSecondary); Cursor(skin: skin) }
                    }
                }
            }
            .font(AppFont.mono(11))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    var body: some View {
        if traceOnly { tracePanel } else { request }
    }

    private var request: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(TypeScale.strong).foregroundStyle(failed ? skin.accent : skin.textPrimary)
                    Spacer(minLength: 12)
                    if !failed {
                        TimelineView(.periodic(from: started, by: 1)) { ctx in
                            Text(Self.elapsed(ctx.date.timeIntervalSince(started)))
                                .font(AppFont.mono(11)).monospacedDigit().foregroundStyle(skin.textTertiary)
                        }
                    }
                }
                if failed {
                    CapsuleProgress(fraction: 1, skin: skin, tint: skin.accent.opacity(0.5)).frame(height: 3)
                } else {
                    CapsuleProgress(fraction: progress?.fraction, skin: skin).frame(height: 3)
                }
                if !failed && progress == nil {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        let late = ctx.date.timeIntervalSince(started) > Self.patience
                        Text(late ? Self.lateNote : caption).font(TypeScale.caption)
                            .foregroundStyle(late ? skin.textSecondary : skin.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(caption).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            tracePanel

            seenInSearches
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    /// Their folders already in your search results, so there's something to
    /// take while the full list is on its way.
    @ViewBuilder
    private var seenInSearches: some View {
        let groups = knownGroups
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("In your search results").foregroundStyle(skin.textTertiary)
                    if let peer = groups.first {
                        Text("   " + [Format.speed(Double(peer.speed)), peer.freeSlot ? "free slot" : "queue \(peer.queue)"]
                            .joined(separator: " · ")).foregroundStyle(skin.textTertiary)
                    }
                    Spacer(minLength: 8)
                    if groups.count > Self.shownFolders {
                        Text("\(groups.count - Self.shownFolders) more in Search").foregroundStyle(skin.textTertiary)
                    }
                }
                .font(TypeScale.caption)
                let queued = store.transferKeys
                VStack(spacing: 3) {
                    ForEach(groups.prefix(Self.shownFolders)) { group in
                        ResultGroupRow(group: group, expanded: open.contains(group.id), skin: skin, queued: queued, showsPeer: false,
                                       onToggle: { if open.contains(group.id) { open.remove(group.id) } else { open.insert(group.id) } },
                                       onDownload: { store.download($0, from: user) }, onBrowse: {})
                    }
                }
            }
        }
    }

    @State private var open: Set<String> = []
    private static let shownFolders = 4

    private var knownGroups: [SoulseekStore.SearchGroup] {
        var seen = Set<String>()
        return store.searches.flatMap(\.groups).filter { $0.user == user && seen.insert($0.folder).inserted }
    }

    private static let lateNote = "No answer yet. Large shares take a while to send, and some users can't be reached from here at all. The request stays open; you can leave this page."

    private var title: String {
        if failed { return "File list unavailable" }
        if progress != nil { return "Receiving the file list" }
        return "Requesting the file list"
    }

    private var caption: String {
        if failed { return "\(user) didn't send a file list. They may be offline, not sharing, or unreachable from this network. Refresh asks again." }
        if let progress { return "\(Int(progress.fraction * 100))%  ·  \(Format.bytes(UInt64(progress.received))) of \(Format.bytes(UInt64(progress.total)))" }
        return "Asking \(user) for the list of everything they share."
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let n = max(0, Int(s))
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    /// A terminal block cursor, blinking on and off (no fade).
    private struct Cursor: View {
        var skin: Skin
        var body: some View {
            if GlassRendering.forceFallback {
                Rectangle().fill(skin.textPrimary.opacity(0.8)).frame(width: 6, height: 11)
            } else {
                TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
                    Rectangle().fill(skin.textPrimary.opacity(0.8))
                        .frame(width: 6, height: 11)
                        .opacity(Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0 ? 1 : 0)
                }
            }
        }
    }
}

/// When a user's file list doesn't come: a question mark, what probably
/// happened, and what to do next. The trace opens in a popover, so the
/// page never changes size.
private struct NoFileList: View {
    @ObservedObject var store: SoulseekStore
    var user: String
    var skin: Skin
    var onMessage: () -> Void
    @State private var showsTrace = false

    private var events: [String] {
        let prefix = user + "  "
        let since = (store.browseStarted[user] ?? .distantPast).addingTimeInterval(-1)
        return store.sessionLog.suffix(400).compactMap { line in
            guard line.topic == .peer, line.time >= since, line.text.hasPrefix(prefix) else { return nil }
            return SessionLog.split(String(line.text.dropFirst(prefix.count)), joiner: "  ").event
        }
    }

    private var reason: (headline: String, body: String, code: String) {
        let events = self.events
        let waited = store.browseStarted[user].map { Int(Date().timeIntervalSince($0)) }
        let after = waited.map { " · after \($0) s" } ?? ""
        if events.contains("no address") {
            return ("Nobody's home.",
                    "The server has no address for \(user). They're offline, or their client isn't accepting connections right now.",
                    "no address" + after)
        }
        if events.contains("unreachable") {
            return ("Can't get through.",
                    "\(user) is online, but neither side could open a connection. Their router, or this network, is turning it away.",
                    "unreachable" + after)
        }
        if events.contains("closed") {
            return ("They hung up.",
                    "\(user) closed the connection before the list arrived. They may have quit, or their client gave up on a large list.",
                    "connection closed" + after)
        }
        return ("No file list.",
                "\(user) didn't send a list of their files. They may not be sharing anything, or the list couldn't be read.",
                "nothing received" + after)
    }

    var body: some View {
        let reason = self.reason
        VStack(alignment: .center, spacing: 0) {
            Text("?")
                .font(AppFont.mono(64, weight: .light))
                .foregroundStyle(skin.textTertiary)
                .frame(width: 112, height: 112)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .fuiCorners(skin)
                .padding(.bottom, 28)
            Text(reason.headline)
                .font(AppFont.ui(30, weight: .semibold))
                .foregroundStyle(skin.textPrimary)
                .padding(.bottom, 8)
            Text(reason.body)
                .font(TypeScale.body).foregroundStyle(skin.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
                .padding(.bottom, 10)
            Text(reason.code)
                .font(AppFont.mono(11)).foregroundStyle(skin.textTertiary)
                .padding(.bottom, 20)
            HStack(spacing: 8) {
                Button("Try Again") { store.browse(user) }
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                Button("Leave a Message", action: onMessage)
                    .buttonStyle(PillButtonStyle(skin: skin))
                    .help("The server keeps messages for offline users until they sign in.")
                TextAction(title: "Show Trace", skin: skin) { showsTrace.toggle() }
                    .padding(.leading, 8)
                    .popover(isPresented: $showsTrace, arrowEdge: .bottom) {
                        FileListRequest(store: store, user: user, failed: true, skin: skin, traceOnly: true)
                            .frame(width: 520)
                            .background(Color.black.opacity(0.35))
                            .scrollIndicators(.never)
                            .preferredColorScheme(.dark)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

private let traceTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

// MARK: - Formatting

enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}


// MARK: - Title bar

/// Download and upload speed and open peer connections.
private struct NetworkStats: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin

    var body: some View {
        HStack(spacing: 14) {
            stat("↓", store.status == .online ? Format.speed(store.downloadSpeed) : "–")
            stat("↑", store.status == .online ? Format.speed(store.uploadSpeed) : "–")
            stat(store.connections == 1 ? "connection" : "connections", store.status == .online ? "\(store.connections)" : "–", valueFirst: true)
        }
        .fixedSize()
        .help("Download speed, upload speed, open peer connections")
    }

    private func stat(_ label: String, _ value: String, valueFirst: Bool = false) -> some View {
        HStack(spacing: 5) {
            if valueFirst {
                Text(value).foregroundStyle(skin.textSecondary)
                Text(label).foregroundStyle(skin.textTertiary)
            } else {
                Text(label).foregroundStyle(skin.textTertiary)
                Text(value).foregroundStyle(skin.textSecondary)
            }
        }
        .font(TypeScale.caption)
        .lineLimit(1)
    }
}
