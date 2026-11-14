import SwiftUI
import AppKit

// The connection's state at the foot of the Downloads rail, and the log
// panel it opens under the window's panes.

/// The network glyph for a connection state: connected, connecting (pulses),
/// disconnected.
struct NetworkGlyph: View {
    enum State { case online, connecting, offline, off }

    var state: State
    var skin: Skin
    var size: CGFloat = 18
    @SwiftUI.State private var dim = false

    var body: some View {
        Glyph(name, size: size)
            .foregroundStyle(color)
            .opacity(state == .connecting && dim ? 0.3 : 1)
            .onAppear(perform: animate)
            .onChange(of: state) { _ in animate() }
    }

    private var name: String {
        switch state {
        case .online: return "network.online"
        case .connecting: return "network.connecting"
        case .offline, .off: return "network.offline"
        }
    }

    private var color: Color {
        switch state {
        case .online: return skin.accent
        case .connecting: return skin.textSecondary
        case .offline: return skin.textPrimary
        case .off: return skin.textTertiary
        }
    }

    private func animate() {
        if state == .connecting {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dim = false }
        }
    }
}

extension SoulseekStore {
    var glyphState: NetworkGlyph.State {
        switch status {
        case .online: return .online
        case .connecting: return .connecting
        case .offline: return .offline
        case .off: return .off
        }
    }
}

/// The account and connection state; click to show or hide the log.
struct ConnectionStatus: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var logOpen: Bool
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    NetworkGlyph(state: store.glyphState, skin: skin, size: 17)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.settings.username.isEmpty ? "Not signed in" : store.settings.username)
                            .font(TypeScale.strong).foregroundStyle(skin.textPrimary).lineLimit(1)
                        Text(detail).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Glyph(logOpen ? "chevron.down" : "chevron.up", size: 8)
                        .foregroundStyle(hovering || logOpen ? skin.textSecondary : skin.textTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Rectangle().fill(skin.textPrimary.opacity(logOpen ? 0.08 : hovering ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(logOpen ? "Hide the log (⌘J)" : "Show the log (⌘J)")
            .appContextMenu {
                MenuContent(title: store.settings.username.isEmpty ? "Soulseek" : store.settings.username, entries: [
                    store.status == .online || store.status == .connecting
                        ? .action("Disconnect", glyph: "network.offline") { store.disconnect() }
                        : .action("Connect", glyph: "network.online") { store.connect() },
                    .action(logOpen ? "Hide Log" : "Show Log", glyph: "console", onToggle),
                ])
            }
            if store.status != .online && store.status != .connecting {
                TextAction(title: "Connect", skin: skin) { store.connect() }
                    .padding(.leading, 36)
                    .padding(.bottom, 4)
            }
        }
    }

    private var detail: String {
        switch store.status {
        case .online: return "Online" + (store.settings.routeMode == .direct ? "" : " · " + routeName)
        case .connecting: return "Connecting to \(store.serverAddress)"
        case .off: return "Not connected"
        case .offline(let why): return why
        }
    }

    private var routeName: String {
        switch store.settings.routeMode {
        case .direct: return "default route"
        case .tunnel: return "Raven Tunnel"
        case .socks5: return "SOCKS5"
        }
    }
}

/// A short notice above the account at the foot of the rail, only when
/// something happens: a message, someone browsing your files, a transfer
/// finishing, or the connection dropping. It leaves on its own after a few
/// seconds (not while the pointer is on it); nothing shows while all is
/// quiet, and never a plain "online" or "offline".
struct RailNotice: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    /// Shows the Messages page (for message notices).
    var onMessage: () -> Void
    /// Snapshots only: a notice to show from the start.
    var sample: (text: String, warning: Bool)? = nil

    private struct Notice: Equatable {
        let id = UUID()
        let glyph: String
        let text: String
        let warning: Bool
        let message: Bool
    }

    @State private var notice: Notice?
    @State private var hovering = false
    @State private var hide: Task<Void, Never>?
    @State private var lastActivity: UUID?

    private static let shown: UInt64 = 6_000_000_000

    var body: some View {
        ZStack(alignment: .bottom) {
            if let notice {
                card(notice)
                    .id(notice.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: notice)
        .onAppear {
            lastActivity = store.activity.first?.id
            if let sample { notice = Notice(glyph: sample.warning ? "network.offline" : "messages", text: sample.text,
                                            warning: sample.warning, message: !sample.warning) }
        }
        .onChange(of: store.activity.first?.id) { id in
            guard let id, id != lastActivity, let latest = store.activity.first else { return }
            lastActivity = id
            let message = latest.text.hasPrefix("Message from")
            show(Notice(glyph: message ? "messages" : latest.text.contains("browsing") ? "folder.open" : "downloads",
                        text: latest.text, warning: false, message: message))
        }
        .onChange(of: store.status) { status in
            if case .offline(let why) = status {
                show(Notice(glyph: "network.offline", text: "Disconnected. " + why, warning: true, message: false))
            }
        }
    }

    private func card(_ n: Notice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Glyph(n.glyph, size: 11)
                .foregroundStyle(n.warning ? skin.accent : skin.textSecondary)
                .padding(.top, 1)
            Text(n.text)
                .font(TypeScale.caption)
                .foregroundStyle(skin.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { withAnimation { notice = nil } } label: {
                Glyph("xmark.circle.fill", size: 9).foregroundStyle(skin.textTertiary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Rectangle().fill(Color.black.opacity(0.42)))
        .overlay(Rectangle().strokeBorder(n.warning ? skin.accent.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { hide?.cancel() } else { scheduleHide() }
        }
        .onTapGesture { if n.message { onMessage(); notice = nil } }
        .padding(.bottom, 6)
    }

    private func show(_ n: Notice) {
        notice = n
        scheduleHide()
    }

    private func scheduleHide() {
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.shown)
            guard !Task.isCancelled, !hovering else { return }
            notice = nil
        }
    }
}

// MARK: - Log panel

/// Everything Raven logged, newest last, in a terminal-style panel: the
/// server session, peers, searches, transfers, sharing and messages.
struct LogConsole: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var scrolls: Bool
    var onClose: () -> Void

    @State private var topic: SoulseekStore.LogLine.Topic?
    @State private var filter = ""
    @State private var follow = true

    /// One line of log text, and the panel's lines area: five and a half
    /// lines, so a cut-off line at the top shows there's more above.
    static let rowHeight: CGFloat = 16
    static let headerHeight: CGFloat = 30
    static let bottomInset: CGFloat = 4
    static let height = headerHeight + rowHeight * 5.5 + bottomInset

    private var shown: [SoulseekStore.LogLine] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return store.sessionLog.filter { line in
            (topic == nil || line.topic == topic) && (needle.isEmpty || line.text.lowercased().contains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            lines
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(Color.black.opacity(0.34))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .fuiCorners(skin)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Glyph("console", size: 12).foregroundStyle(skin.textSecondary)
                .help("Log")
            HStack(spacing: 1) {
                TextOption(title: "All", on: topic == nil, skin: skin) { topic = nil }
                ForEach(SoulseekStore.LogLine.Topic.allCases, id: \.self) { t in
                    TextOption(title: t.title, on: topic == t, skin: skin) { topic = topic == t ? nil : t }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Glyph("magnifyingglass", size: 9).foregroundStyle(skin.textTertiary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .font(TypeScale.caption)
                    .foregroundStyle(skin.textPrimary)
                    .frame(width: 110)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.05)))
            TextAction(title: follow ? "Following" : "Follow", skin: skin) { follow.toggle() }
                .help(follow ? "New lines scroll into view. Click to stop." : "Scroll to new lines as they arrive")
            TextAction(title: "Copy", skin: skin, action: copy)
            TextAction(title: "Clear", skin: skin) { store.clearLog() }
            Button(action: onClose) {
                Glyph("chevron.down", size: 9).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(skin.textTertiary)
            .help("Hide the log (⌘J)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Self.headerHeight)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private var lines: some View {
        let shown = self.shown
        if shown.isEmpty {
            Text(store.sessionLog.isEmpty ? "Nothing logged yet." : "No lines match.")
                .font(AppFont.mono(11)).foregroundStyle(skin.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        } else if scrolls {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { LogRow(line: $0, skin: skin).id($0.id) }
                        // Scrolling to this keeps the newest line clear of the edge,
                        // so the half line is the oldest one, at the top.
                        Color.clear.frame(height: Self.bottomInset).id("end")
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: store.sessionLog.last?.id) { _ in
                    guard follow else { return }
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: topic) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: filter) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown.suffix(6)) { LogRow(line: $0, skin: skin) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, Self.bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight * 5.5 + Self.bottomInset, alignment: .bottom)
            .clipped()
        }
    }

    private func copy() {
        let text = shown.map { LogRow.time.string(from: $0.time) + "  " + $0.topic.rawValue + "  " + $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogRow: View {
    var line: SoulseekStore.LogLine
    var skin: Skin

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let parts = SessionLog.split(line.text, joiner: "  ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time.string(from: line.time)).foregroundStyle(skin.textTertiary)
                .frame(width: 54, alignment: .leading)
            Text(line.topic.rawValue).foregroundStyle(skin.textTertiary)
                .frame(width: 54, alignment: .leading)
            (Text(parts.event).font(AppFont.mono(11, weight: .bold)).foregroundColor(color)
             + Text(parts.detail.isEmpty ? "" : " " + parts.detail).foregroundColor(skin.textSecondary))
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(AppFont.mono(11))
        .lineLimit(1)
        .frame(height: LogConsole.rowHeight)
        .textSelection(.enabled)
        .help(line.text.replacingOccurrences(of: "  ", with: " "))
    }

    private var color: Color {
        switch line.kind {
        case .info: return skin.textPrimary
        case .ok: return skin.textPrimary
        case .error: return skin.accent
        }
    }
}
