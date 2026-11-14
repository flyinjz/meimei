import SwiftUI

/// Title row above the library content: what's shown and how much of it,
/// a live filter, and the actions that apply to the whole list.
struct LibraryHeaderView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var settings: AppSettings
    var skin: Skin
    var onPlay: () -> Void
    var onShuffle: () -> Void
    var onEditRules: (UUID) -> Void

    var body: some View {
        // One row when it fits; otherwise the controls wrap under the title
        // instead of crushing it. The title is built once for all three tries.
        let titleBlock = self.titleBlock(summary: summary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                titleBlock
                Spacer(minLength: 16)
                controls
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                HStack(spacing: 10) { controls }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Narrowest: the buttons drop their titles (tooltips keep them).
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                HStack(spacing: 6) { controls }
                    .environment(\.buttonContentOverride, .icon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .labelStyle(TightLabelStyle())
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func titleBlock(summary: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if case .artist(let name) = library.source {
                ArtistAvatar(name: name, path: library.artistGroups.first { $0.name == name }?.artworkFilePath, size: 46, skin: skin)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(AppFont.ui(11, weight: .medium))
                        .foregroundStyle(skin.accent)
                }
                Text(library.sourceTitle)
                    .textRole(.libraryTitle, size: 22, weight: .bold, color: skin.textPrimary)
                    .lineLimit(1)
                Text(summary)
                    .textRole(.librarySummary, size: 11, color: skin.textTertiary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
            if settings.data.showSearchField, !library.source.isGrid {
                FilterField(text: $library.filterText, skin: skin)
                    .frame(minWidth: 90, idealWidth: CGFloat(settings.data.searchFieldWidth), maxWidth: CGFloat(settings.data.searchFieldWidth))
            }
            if case .playlist(let id) = library.source, library.playlist(id: id)?.isSmart == true {
                Button { onEditRules(id) } label: { Label("Rules", glyph: "slider.horizontal.3") }
                    .buttonStyle(PillButtonStyle(skin: skin))
                    .fixedSize()
            }
            if !library.source.isGrid { groupMenu }
            Button(action: onShuffle) { Label("Shuffle", glyph: "shuffle") }
                .buttonStyle(PillButtonStyle(skin: skin))
                .help("Shuffle")
                .disabled(library.visibleTracks.isEmpty)
                .fixedSize()
            Button(action: onPlay) { Label("Play", glyph: "play.fill") }
                .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                .help("Play")
                .disabled(library.visibleTracks.isEmpty)
                .fixedSize()
    }

    private var eyebrow: String? {
        switch library.source {
        case .artist: return "Artist"
        case .genre: return "Genre"
        case .playlist(let id): return library.playlist(id: id)?.isSmart == true ? "Smart Playlist" : "Playlist"
        case .recentlyAdded, .recentlyPlayed, .mostPlayed: return "Collection"
        default: return nil
        }
    }

    private var summary: String {
        switch library.source {
        case .albums:
            let n = library.albumGroups.count
            return n == 1 ? "1 album" : "\(n) albums"
        case .artists:
            let n = library.artistGroups.count
            return n == 1 ? "1 artist" : "\(n) artists"
        default:
            let tracks = library.visibleTracks
            if tracks.isEmpty { return library.filterText.isEmpty ? "No tracks" : "No matches" }
            let count = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
            var parts = [count, Self.longDuration(library.visibleDuration)]
            if case .artist = library.source {
                let albums = Set(tracks.map(\.albumKey)).count
                parts.insert(albums == 1 ? "1 album" : "\(albums) albums", at: 0)
            }
            if !library.filterText.isEmpty { parts.append("filtered") }
            return parts.joined(separator: " · ")
        }
    }

    static func longDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// A Meimei button that opens the grouping menu. (A SwiftUI `Menu`
    /// ignores custom button styles on macOS and draws as plain text.)
    private var groupMenu: some View {
        PopUpMenuButton(items: TableGroupMode.allCases.map { mode in
            PopUpMenuButton.Item(title: mode.label, checked: settings.data.groupBy == mode) { settings.data.groupBy = mode }
        }) {
            Label(settings.data.groupBy == .none ? "Group" : settings.data.groupBy.label, glyph: "rectangle.3.group")
        }
        .buttonStyle(PillButtonStyle(skin: skin, isActive: settings.data.groupBy != .none))
        .fixedSize()
        .help("Group the table")
    }
}

/// A labeled pill action used in headers and sheets.
struct HeaderButton: View {
    var title: String
    var icon: String
    var prominent = false
    var skin: Skin
    var action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, glyph: icon) }
            .labelStyle(TightLabelStyle())
            .buttonStyle(PillButtonStyle(skin: skin, prominent: prominent))
    }
}

/// Icon and title close together, as pill buttons want.
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(AppFont.ui(10, weight: .semibold))
            configuration.title
        }
    }
}

/// The library's live filter: a capsule field with a clear button. ⌘F
/// focuses it; Escape clears it.
struct FilterField: View {
    @Binding var text: String
    var skin: Skin
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Glyph("line.3.horizontal.decrease", size: 10.5)
                .foregroundStyle(focused || !text.isEmpty ? skin.accent : skin.textTertiary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(AppFont.ui(12))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Glyph("xmark.circle.fill", size: 11)
                }
                .buttonStyle(GlyphButtonStyle(skin: skin, restColor: skin.textTertiary))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Rectangle().fill(skin.textPrimary.opacity(focused ? 0.12 : 0.07)))
        .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.6) : Color.white.opacity(0.06), lineWidth: focused ? 1 : 0.5))
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
        .onReceive(NotificationCenter.default.publisher(for: FilterField.focusRequest)) { _ in focused = true }
    }

    static let focusRequest = Notification.Name("meimei.focusFilter")
}

/// Shown instead of an empty table.
struct EmptyLibraryView: View {
    @ObservedObject var library: LibraryStore
    var skin: Skin
    var onAddMusic: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Glyph(icon, size: 30)
                .foregroundStyle(skin.accent.opacity(0.8))
            Text(title)
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(skin.textPrimary)
            Text(message)
                .font(AppFont.ui(11.5))
                .foregroundStyle(skin.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if library.tracks.isEmpty {
                HeaderButton(title: "Add Music…", icon: "plus", prominent: true, skin: skin, action: onAddMusic)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(skin.surface(skin.bgRow))
    }

    private var icon: String {
        if library.tracks.isEmpty { return "music.note.house" }
        if !library.filterText.isEmpty { return "magnifyingglass" }
        switch library.source {
        case .liked: return "heart"
        case .playlist: return "music.note.list"
        default: return "music.note"
        }
    }

    private var title: String {
        if library.tracks.isEmpty { return "Your library is empty" }
        if !library.filterText.isEmpty { return "No results for “\(library.filterText)”" }
        switch library.source {
        case .liked: return "No liked songs yet"
        case .recentlyPlayed, .mostPlayed: return "Nothing played yet"
        case .playlist(let id): return library.playlist(id: id)?.isSmart == true ? "Nothing matches these rules" : "This playlist is empty"
        default: return "Nothing here"
        }
    }

    private var message: String {
        if library.tracks.isEmpty { return "Drop folders or audio files anywhere in this window, or choose them with Add Music (⌘O)." }
        if !library.filterText.isEmpty { return "Try fewer words, or clear the filter (Esc)." }
        switch library.source {
        case .liked: return "Right-click a track and choose Like."
        case .recentlyPlayed, .mostPlayed: return "Songs you listen to will collect here."
        case .playlist(let id):
            return library.playlist(id: id)?.isSmart == true
                ? "Edit the rules to widen what this playlist matches."
                : "Drag tracks onto the playlist in the sidebar, or right-click → Add to Playlist."
        default: return ""
        }
    }
}
