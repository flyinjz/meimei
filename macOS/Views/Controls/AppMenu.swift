import AppKit
import SwiftUI

// MARK: - Model

/// One row in an app menu: an action or a submenu.
struct MenuEntry: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu(MenuContent)
    }

    let id = UUID()
    var title: String
    var glyph: String?
    /// Right-aligned hint: a shortcut, a count, the current value.
    var detail: String?
    var checked = false
    var destructive = false
    var enabled = true
    var kind: Kind

    static func action(_ title: String, glyph: String? = nil, detail: String? = nil, checked: Bool = false,
                       destructive: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, glyph: glyph, detail: detail, checked: checked,
                  destructive: destructive, enabled: enabled, kind: .action(action))
    }

    static func submenu(_ title: String, glyph: String? = nil, detail: String? = nil,
                        enabled: Bool = true, _ content: MenuContent) -> MenuEntry {
        MenuEntry(title: title, glyph: glyph, detail: detail, enabled: enabled, kind: .submenu(content))
    }

    var isSubmenu: Bool { if case .submenu = kind { return true } else { return false } }
}

/// Entries that belong together. Groups are set apart by space and an
/// optional `// label`, never by a rule.
struct MenuGroup: Identifiable {
    let id = UUID()
    var label: String?
    var entries: [MenuEntry]

    init(_ label: String? = nil, _ entries: [MenuEntry]) {
        self.label = label
        self.entries = entries
    }
}

/// What a menu shows: an optional header naming what it acts on, then groups.
struct MenuContent {
    var title: String?
    var subtitle: String?
    var groups: [MenuGroup]

    init(title: String? = nil, subtitle: String? = nil, _ groups: [MenuGroup]) {
        self.title = title
        self.subtitle = subtitle
        self.groups = groups.filter { !$0.entries.isEmpty }
    }

    /// A single unlabeled group.
    init(title: String? = nil, subtitle: String? = nil, entries: [MenuEntry]) {
        self.init(title: title, subtitle: subtitle, [MenuGroup(nil, entries)])
    }

    var isEmpty: Bool { groups.isEmpty }
    fileprivate var selectable: [MenuEntry] { groups.flatMap(\.entries).filter(\.enabled) }
}

// MARK: - Presenter

/// Shows i2s's own menus in place of the platform's: a borderless panel per
/// level (root, then one per open submenu), driven from the keyboard and mouse
/// like a native menu. Built on plain SwiftUI plus a panel, so it ports.
@MainActor
final class AppMenu {
    static let shared = AppMenu()

    private var levels: [MenuLevel] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    var isOpen: Bool { !levels.isEmpty }

    /// Test runs never put a window on screen.
    private static var headless: Bool {
        #if DEBUG
        return DebugHooks.isHeadless
        #else
        return false
        #endif
    }

    /// Opens `content` with its top-left corner at `point` (screen coordinates),
    /// flipping to stay on screen.
    func present(_ content: MenuContent, at point: NSPoint, minWidth: CGFloat = 0) {
        close()
        guard !content.isEmpty, !Self.headless else { return }
        open(content, depth: 0, minWidth: minWidth) { size, screen in
            var origin = NSPoint(x: point.x, y: point.y - size.height)
            if origin.x + size.width > screen.maxX { origin.x = point.x - size.width }
            if origin.y < screen.minY { origin.y = point.y }
            return Self.clamp(origin, size, screen)
        }
        installMonitors()
    }

    /// Opens `content` under `rect` (screen coordinates), as a dropdown.
    func present(_ content: MenuContent, below rect: NSRect) {
        close()
        guard !content.isEmpty, !Self.headless else { return }
        open(content, depth: 0, minWidth: rect.width) { size, screen in
            var origin = NSPoint(x: rect.minX, y: rect.minY - 4 - size.height)
            if origin.y < screen.minY { origin.y = rect.maxY + 4 }
            return Self.clamp(origin, size, screen)
        }
        installMonitors()
    }

    func close() {
        closeLevels(from: 0)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: Levels

    private func open(_ content: MenuContent, depth: Int, minWidth: CGFloat,
                      place: (CGSize, NSRect) -> NSPoint) {
        let model = MenuModel(content: content, depth: depth)
        let skin = AppSession.shared.settings.styled(AppSession.shared.theme.skin)
        let view = MenuPanelView(model: model, skin: skin, minWidth: minWidth, menu: self)
        let host = NSHostingView(rootView: view.scrollIndicators(.never))
        let size = host.fittingSize
        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = host
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The view pads itself for its shadow; place the visible box, not the window.
        let inset = MenuPanelView.shadowInset
        let box = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        let origin = place(box, screen)
        levels.append(MenuLevel(panel: panel, model: model))
        panel.setFrameOrigin(NSPoint(x: origin.x - inset, y: origin.y - inset))
        panel.orderFrontRegardless()
    }

    private func closeLevels(from depth: Int) {
        while levels.count > depth {
            levels.removeLast().panel.orderOut(nil)
        }
    }

    fileprivate func hover(_ entry: MenuEntry?, in model: MenuModel, rowFrame: CGRect?) {
        model.highlighted = entry?.id
        guard let entry, case .submenu(let content) = entry.kind, entry.enabled else {
            // Pointing at a plain row closes any submenu opened from this level.
            if levels.count > model.depth + 1 { closeLevels(from: model.depth + 1) }
            return
        }
        if levels.indices.contains(model.depth + 1), levels[model.depth + 1].model.source == entry.id { return }
        closeLevels(from: model.depth + 1)
        guard let rowFrame, let panel = levels[safe: model.depth]?.panel else { return }
        // Row frames are top-left based (SwiftUI); the window is bottom-left based.
        let row = panel.convertToScreen(CGRect(x: rowFrame.minX, y: panel.frame.height - rowFrame.maxY,
                                               width: rowFrame.width, height: rowFrame.height))
        let parent = panel.frame.insetBy(dx: MenuPanelView.shadowInset, dy: MenuPanelView.shadowInset)
        open(content, depth: model.depth + 1, minWidth: 0) { size, screen in
            var origin = NSPoint(x: parent.maxX - 1, y: row.maxY + 4 - size.height)
            if origin.x + size.width > screen.maxX { origin.x = parent.minX - size.width + 1 }
            return Self.clamp(origin, size, screen)
        }
        levels.last?.model.source = entry.id
    }

    fileprivate func activate(_ entry: MenuEntry, in model: MenuModel, rowFrame: CGRect?) {
        guard entry.enabled else { return }
        switch entry.kind {
        case .action(let action):
            close()
            // After the menu is gone, so sheets and windows the action opens present cleanly.
            DispatchQueue.main.async(execute: action)
        case .submenu:
            hover(entry, in: model, rowFrame: rowFrame)
            if let next = levels[safe: model.depth + 1]?.model {
                next.highlighted = next.content.selectable.first?.id
            }
        }
    }

    // MARK: Events

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.levels.contains(where: { $0.panel === event.window }) { return event }
            let passThrough = event.type == .rightMouseDown
            self.close()
            // A left click outside only dismisses, like a native menu, so it can't
            // also press whatever is underneath. A right click opens the next menu.
            return passThrough ? event : nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, !self.levels.contains(where: { $0.panel === event.window }) { self.close() }
            return event
        } as Any)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close()
        }) { monitors.append(global) }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Placing a submenu moves its panel before it's registered as a level;
                    // that must never read as the app window moving.
                    if note.object is MenuPanel { return }
                    self.close()
                }
            })
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let level = levels.last else { return false }
        let model = level.model
        let items = model.content.selectable
        let index = items.firstIndex { $0.id == model.highlighted }
        switch event.keyCode {
        case 53: // escape
            if levels.count > 1 { closeLevels(from: levels.count - 1) } else { close() }
        case 125: // down
            guard !items.isEmpty else { return true }
            model.highlighted = items[index.map { ($0 + 1) % items.count } ?? 0].id
        case 126: // up
            guard !items.isEmpty else { return true }
            model.highlighted = items[index.map { ($0 - 1 + items.count) % items.count } ?? items.count - 1].id
        case 124: // right
            if let index, items[index].isSubmenu { activate(items[index], in: model, rowFrame: model.rowFrames[items[index].id]) }
        case 123: // left
            if levels.count > 1 { closeLevels(from: levels.count - 1) }
        case 36, 76, 49: // return, enter, space
            if let index { activate(items[index], in: model, rowFrame: model.rowFrames[items[index].id]) }
        default:
            // Type-to-select: jump to the next entry starting with the typed letter.
            guard let ch = event.charactersIgnoringModifiers?.lowercased().first, ch.isLetter || ch.isNumber else {
                // Swallow other keys too, as a native menu does, except command shortcuts.
                return !event.modifierFlags.contains(.command)
            }
            let start = (index ?? -1) + 1
            let ordered = Array(items[min(start, items.count)...]) + Array(items[..<min(start, items.count)])
            if let match = ordered.first(where: { $0.title.lowercased().first == ch }) { model.highlighted = match.id }
        }
        return true
    }

    private static func clamp(_ origin: NSPoint, _ size: CGSize, _ screen: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4),
                y: min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4))
    }
}

private struct MenuLevel {
    let panel: MenuPanel
    let model: MenuModel
}

@MainActor
final class MenuModel: ObservableObject {
    let content: MenuContent
    let depth: Int
    /// The submenu entry in the parent level that opened this one.
    var source: UUID?
    @Published var highlighted: UUID?
    /// Row frames in the panel's window coordinates, for placing submenus.
    var rowFrames: [UUID: CGRect] = [:]

    init(content: MenuContent, depth: Int) {
        self.content = content
        self.depth = depth
    }
}

private final class MenuPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        // The view draws its own shadow, so it can fade in with the menu.
        hasShadow = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    // Keys stay with the window the menu was opened from; the presenter reads them.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - View

private struct MenuPanelView: View {
    static let shadowInset: CGFloat = 24

    @ObservedObject var model: MenuModel
    var skin: Skin
    var minWidth: CGFloat
    let menu: AppMenu
    /// Starts visible for offscreen renders, where onAppear animations never run.
    @State var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = model.content.title { header(title) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.content.groups.enumerated()), id: \.element.id) { i, group in
                    if let label = group.label {
                        Text(label.lowercased())
                            .font(AppFont.ui(9.5))
                            .foregroundStyle(skin.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, i == 0 ? 4 : 10)
                            .padding(.bottom, 3)
                    } else if i > 0 {
                        Color.clear.frame(height: 6)
                    }
                    ForEach(group.entries) { entry in
                        MenuRow(entry: entry, skin: skin, highlighted: model.highlighted == entry.id,
                                open: model.highlighted == entry.id && entry.isSubmenu)
                            .background(GeometryReader { g in
                                Color.clear.onAppear { model.rowFrames[entry.id] = g.frame(in: .global) }
                            })
                            .onHover { inside in
                                if inside { menu.hover(entry, in: model, rowFrame: model.rowFrames[entry.id]) }
                                else if model.highlighted == entry.id && !entry.isSubmenu { model.highlighted = nil }
                            }
                            .onTapGesture { menu.activate(entry, in: model, rowFrame: model.rowFrames[entry.id]) }
                    }
                }
            }
            .padding(4)
        }
        .frame(minWidth: max(188, minWidth), maxWidth: 320, alignment: .leading)
        .fixedSize()
        .modifier(MenuSurface(skin: skin))
        .shadow(color: .black.opacity(shown ? 0.5 : 0), radius: 16, y: 8)
        .scaleEffect(shown ? 1 : 0.97, anchor: .topLeading)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -3)
        .padding(Self.shadowInset)
        .onAppear { withAnimation(.easeOut(duration: 0.13)) { shown = true } }
    }

    private func header(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.ui(11.5, weight: .semibold))
                .foregroundStyle(skin.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle = model.content.subtitle {
                Text(subtitle)
                    .font(AppFont.ui(10))
                    .foregroundStyle(skin.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.textPrimary.opacity(0.04))
    }
}

/// Glass skins get the panes' frosted look over a live blur of what's under
/// the menu; solid skins get an opaque layer like the command palette.
private struct MenuSurface: ViewModifier {
    var skin: Skin

    func body(content: Content) -> some View {
        if skin.isGlass && !GlassRendering.forceFallback {
            content
                .background(Color.black.opacity(min(0.85, skin.panelOpacity + 0.1)))
                .background(MenuBlur())
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 1) }
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .fuiCorners(skin)
        } else {
            content
                .background(Rectangle().fill(skin.bgVoid.opacity(0.97)))
                .background(Rectangle().fill(.black))
                .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.2), lineWidth: 1))
                .fuiCorners(skin)
        }
    }
}

/// Blur of whatever sits behind the menu panel (the app window, usually).
private struct MenuBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct MenuRow: View {
    var entry: MenuEntry
    var skin: Skin
    var highlighted: Bool
    var open: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if entry.checked {
                    Rectangle().fill(skin.accent).frame(width: 6, height: 6)
                } else if let glyph = entry.glyph {
                    Glyph(glyph, size: 11)
                }
            }
            .frame(width: 14)
            .foregroundStyle(iconColor)
            Text(entry.title)
                .font(AppFont.ui(11.5))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 18)
            if let detail = entry.detail {
                Text(detail)
                    .font(AppFont.ui(10))
                    .foregroundStyle(skin.textTertiary)
                    .lineLimit(1)
            }
            if entry.isSubmenu {
                Glyph("chevron.right", size: 8)
                    .foregroundStyle(highlighted ? skin.textPrimary : skin.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(Rectangle().fill(highlighted && entry.enabled ? skin.textPrimary.opacity(0.09) : .clear))
        .contentShape(Rectangle())
        .opacity(entry.enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.08), value: highlighted)
    }

    private var textColor: Color {
        if entry.destructive { return highlighted ? skin.accent : skin.accent.opacity(0.85) }
        return highlighted ? skin.textPrimary : skin.textSecondary
    }

    private var iconColor: Color {
        if entry.checked { return skin.accent }
        if entry.destructive { return skin.accent.opacity(0.85) }
        return highlighted ? skin.textPrimary : skin.textTertiary
    }
}

// MARK: - SwiftUI hook

extension View {
    /// Opens an app menu on right-click (or control-click). `content` is built
    /// at click time, so it can depend on where the pointer is.
    func appContextMenu(_ content: @escaping () -> MenuContent) -> some View {
        // Offscreen snapshots can't draw AppKit views; menus aren't needed there.
        overlay { if !GlassRendering.forceFallback { RightClickCatcher(content: content) } }
    }
}

/// An overlay that takes only secondary clicks; every other event falls through
/// to the SwiftUI content underneath.
private struct RightClickCatcher: NSViewRepresentable {
    var content: () -> MenuContent

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.content = content }

    final class CatcherView: NSView {
        var content: (() -> MenuContent)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { show() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show() } else { super.mouseDown(with: event) }
        }

        private func show() {
            guard let content else { return }
            AppMenu.shared.present(content(), at: NSEvent.mouseLocation)
        }
    }
}

// MARK: - Shared menus

extension MenuContent {
    /// The menu for a single track shown outside the library list (now
    /// playing, Up Next): what you can do with that one song.
    @MainActor
    static func track(_ track: Track, play: (() -> Void)? = nil) -> MenuContent {
        let library = AppSession.shared.library
        let player = AppSession.shared.player
        let isCurrent = player.currentTrack?.id == track.id
        var playback: [MenuEntry] = []
        if isCurrent {
            playback.append(.action(player.engine.isPlaying ? "Pause" : "Play", glyph: player.engine.isPlaying ? "pause.fill" : "play.fill",
                                    detail: "space") { player.togglePlayPause() })
            playback.append(.action("Next Track", glyph: "forward.fill") { player.next() })
        } else if let play {
            playback.append(.action("Play Now", glyph: "play.fill", play))
        }
        return MenuContent(
            title: track.title,
            subtitle: [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "),
            [
                MenuGroup(nil, playback),
                MenuGroup(nil, [
                    .action(track.liked ? "Unlike" : "Like", glyph: track.liked ? "heart.fill" : "heart") {
                        library.setLiked([track.id], !track.liked)
                    },
                    .action("Show Album", glyph: "opticaldisc") { library.albumKey = track.albumKey },
                ]),
                MenuGroup("metadata", [
                    .action("Edit Info…", glyph: "info.circle") {
                        LibraryNavigator.shared.open(section: "metadata", trackID: track.id)
                    },
                    .action("Find Lyrics…", glyph: "quote.bubble") {
                        LibraryNavigator.shared.open(section: "metadata", metadataMode: "lyrics", trackID: track.id)
                    },
                    .action("Show in Finder", glyph: "arrow.up.forward") {
                        NSWorkspace.shared.activateFileViewerSelecting([track.url])
                    },
                ]),
            ])
    }
}

#if DEBUG
extension AppMenu {
    /// A menu as a plain view, for offscreen snapshots.
    static func debugView(_ content: MenuContent, skin: Skin) -> some View {
        let model = MenuModel(content: content, depth: 0)
        model.highlighted = content.groups.first?.entries.dropFirst().first?.id
        return MenuPanelView(model: model, skin: skin, minWidth: 0, menu: .shared, shown: true)
    }
}

extension MenuContent {
    static func debugTrackMenu() -> MenuContent {
        let playlists = MenuContent(entries: [.action("New Playlist from Selection…", glyph: "plus") {}])
        return MenuContent(title: "Pleine lune", subtitle: "Artist · Album", [
            MenuGroup(nil, [
                .action("Play", glyph: "play.fill", detail: "↩") {},
                .action("Play Next", glyph: "arrow.uturn.forward") {},
                .action("Add to Queue", glyph: "list.number") {},
            ]),
            MenuGroup(nil, [
                .action("Like", glyph: "heart") {},
                .submenu("Add to Playlist", glyph: "plus.square.on.square", playlists),
                .action("Show Album", glyph: "opticaldisc") {},
                .action("Get Info…", glyph: "info.circle") {},
            ]),
            MenuGroup("file", [
                .action("Refresh from File", glyph: "arrow.counterclockwise") {},
                .action("Show in Finder", glyph: "arrow.up.forward") {},
            ]),
            MenuGroup(nil, [.action("Remove from Library…", glyph: "trash", detail: "⌫", destructive: true) {}]),
        ])
    }
}
#endif

// MARK: - Dropdown button

/// A button that opens an app menu below itself: the replacement for
/// SwiftUI's `Menu`, which always draws the platform's menu. Style it with
/// `.buttonStyle` like any button.
struct MenuButton<Label: View>: View {
    var content: () -> MenuContent
    @ViewBuilder var label: Label
    @State private var anchor = MenuButtonAnchor()

    var body: some View {
        Button { anchor.open(content()) } label: { label }
            .background { if !GlassRendering.forceFallback { MenuButtonAnchorView(anchor: anchor) } }
    }
}

final class MenuButtonAnchor {
    weak var view: NSView?

    @MainActor func open(_ content: MenuContent) {
        guard let view, let window = view.window else { return }
        AppMenu.shared.present(content, below: window.convertToScreen(view.convert(view.bounds, to: nil)))
    }
}

private struct MenuButtonAnchorView: NSViewRepresentable {
    let anchor: MenuButtonAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
