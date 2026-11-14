import SwiftUI
import AppKit

/// Commands the palette hands back to the window to perform.
enum PaletteCommand {
    case settings, equalizer, addMusic, miniPlayer, getInfo, newPlaylist, goToCurrent, library
}

/// Spotlight-style search over songs, albums, artists, and commands.
struct CommandPaletteView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: PlayerController
    var skin: Skin
    var onDismiss: () -> Void
    var onOpenAlbum: (AlbumGroup) -> Void
    var onCommand: (PaletteCommand) -> Void

    @State private var query = ""
    @State private var results: [PaletteItem] = []
    @State private var highlight = 0
    @State private var index: PaletteIndex?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // The window recedes behind the palette.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                searchField
                resultList
                footer
            }
            .frame(width: 580)
            .clipShape(Rectangle())
            .modifier(PaletteSurface(skin: skin))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
            .padding(.top, 72)
        }
        .onAppear {
            index = PaletteIndex(library: library)
            refresh()
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _ in refresh() }
        .background(PaletteKeyCatcher(
            onUp: { move(-1) },
            onDown: { move(1) },
            onReturn: { run(highlight) },
            onEscape: onDismiss
        ))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Glyph("magnifyingglass", size: 13)
                .foregroundStyle(skin.accent)
            TextField("Songs, albums, artists, commands", text: $query)
                .textFieldStyle(.plain)
                .font(AppFont.ui(14))
                .foregroundStyle(skin.textPrimary)
                .focused($fieldFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Glyph("xmark.circle.fill", size: 12)
                        .foregroundStyle(skin.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(skin.textPrimary.opacity(0.05))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            hint("↩", "open")
            hint("esc", "close")
            Spacer()
            Text("\(results.count) results")
                .font(AppFont.ui(10))
                .foregroundStyle(skin.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(skin.textPrimary.opacity(0.04))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(AppFont.ui(9.5, weight: .semibold))
                .foregroundStyle(skin.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Rectangle().fill(Color.white.opacity(0.08)))
            Text(label)
                .font(AppFont.ui(10))
                .foregroundStyle(skin.textTertiary)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { offset, item in
                        if offset == 0 || results[offset - 1].section != item.section {
                            Text(item.section.rawValue)
                                .font(AppFont.ui(9, weight: .bold))
                                .foregroundStyle(skin.textTertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, offset == 0 ? 6 : 12)
                                .padding(.bottom, 3)
                        }
                        row(item, lit: offset == highlight)
                            .id(item.id)
                            .onTapGesture { run(offset) }
                            .onHover { if $0 { highlight = offset } }
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: highlight) { value in
                guard results.indices.contains(value) else { return }
                proxy.scrollTo(results[value].id)
            }
        }
        .frame(height: results.isEmpty ? 90 : min(400, CGFloat(results.count) * 40 + 40))
        .overlay {
            if results.isEmpty {
                Text("No matches for \u{201C}\(query)\u{201D}")
                    .font(AppFont.ui(12))
                    .foregroundStyle(skin.textTertiary)
            }
        }
    }

    private func row(_ item: PaletteItem, lit: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                switch item.thumbnail {
                case .symbol(let name):
                    Glyph(name, size: 11)
                        .foregroundStyle(lit ? skin.accent : skin.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Rectangle().fill(skin.bgVoid.opacity(0.6)))
                case .cover(let path, let round):
                    ArtworkView(path: path, size: 26, skin: skin, placeholder: round ? "person.fill" : "music.note")
                        .clipShape(Rectangle())
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(AppFont.ui(12.5, weight: lit ? .semibold : .regular))
                    .foregroundStyle(skin.textPrimary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(AppFont.ui(10, weight: .medium))
                    .foregroundStyle(skin.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Rectangle()
                .fill(lit ? skin.selection.opacity(0.55) : .clear)
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func refresh() {
        guard let index else { return }
        results = index.search(query, player: player, library: library, onOpenAlbum: onOpenAlbum, onCommand: onCommand)
        highlight = 0
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlight = min(results.count - 1, max(0, highlight + delta))
    }

    private func run(_ offset: Int) {
        guard results.indices.contains(offset) else { return }
        let item = results[offset]
        onDismiss()
        item.run()
    }
}

/// The palette's surface: frosted glass, whatever the window's skin.
private struct PaletteSurface: ViewModifier {
    var skin: Skin

    /// The glass windows' frosted glass over the window behind it, dark
    /// enough that results read clearly over anything, with a hairline.
    func body(content: Content) -> some View {
        content
            .background(InWindowGlass(tint: 0.42))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 1) }
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .fuiCorners(skin)
    }
}

// MARK: - Search model

struct PaletteItem: Identifiable {
    enum Section: String { case commands = "Commands", artists = "Artists", albums = "Albums", songs = "Songs" }
    enum Thumbnail { case symbol(String), cover(String?, round: Bool) }

    let id: String
    let section: Section
    let title: String
    let subtitle: String?
    var shortcut: String? = nil
    let thumbnail: Thumbnail
    let run: () -> Void
}

/// Normalized search keys, built once when the palette opens.
@MainActor
private struct PaletteIndex {
    struct Artist { let name: String; let key: String; let tracks: [Track]; let albumCount: Int; let cover: String? }
    struct Album { let album: AlbumGroup; let title: String; let artist: String }
    struct Song { let track: Track; let title: String; let artist: String; let album: String }

    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]

    init(library: LibraryStore) {
        var byArtist: [String: (name: String, tracks: [Track], albums: Set<String>)] = [:]
        var songs: [Song] = []
        songs.reserveCapacity(library.tracks.count)
        for t in library.tracks {
            let key = Self.normalize(t.artist)
            songs.append(Song(track: t, title: Self.normalize(t.title), artist: key, album: Self.normalize(t.album)))
            guard !key.isEmpty else { continue }
            byArtist[key, default: (t.artist, [], [])].tracks.append(t)
            byArtist[key]?.albums.insert(t.albumKey)
        }
        artists = byArtist.map { key, value in
            Artist(name: value.name, key: key, tracks: value.tracks, albumCount: value.albums.count,
                   cover: value.tracks.first { $0.artworkFilePath != nil }?.artworkFilePath)
        }
        albums = library.albumGroups.map { Album(album: $0, title: Self.normalize($0.title), artist: Self.normalize($0.artist)) }
        self.songs = songs
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// 100 exact, 88 prefix, 74 word prefix, 48 substring, 0 no match.
    static func score(_ haystack: String, _ needle: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        if haystack == needle { return 100 }
        if haystack.hasPrefix(needle) { return 88 }
        if haystack.range(of: " " + needle) != nil { return 74 }
        if haystack.contains(needle) { return 48 }
        return 0
    }

    func search(_ raw: String, player: PlayerController, library: LibraryStore,
                onOpenAlbum: @escaping (AlbumGroup) -> Void, onCommand: @escaping (PaletteCommand) -> Void) -> [PaletteItem] {
        let q = Self.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let commands = Self.commands(player: player, onCommand: onCommand)
        guard !q.isEmpty else { return commands }

        let matchedCommands = commands.filter { Self.score(Self.normalize($0.title), q) > 0 }

        let artistHits = artists
            .map { ($0, Self.score($0.key, q)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.tracks.count > $1.0.tracks.count }
            .prefix(5)
        let rankedArtists = artistHits.map { artist, _ in
                PaletteItem(
                    id: "artist:" + artist.key, section: .artists, title: artist.name,
                    subtitle: "Artist · \(artist.albumCount) albums · \(artist.tracks.count) songs",
                    thumbnail: .cover(artist.cover, round: true),
                    run: { player.play(artist.tracks.sorted(by: Track.libraryOrder)) }
                )
            }

        let albumHits = albums
            .map { ($0, max(Self.score($0.title, q), Self.score($0.artist, q) / 2)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
        let rankedAlbums = albumHits.map { entry, _ in
                PaletteItem(
                    id: "album:" + entry.album.key, section: .albums, title: entry.album.title,
                    subtitle: "Album · \(entry.album.artist)" + (entry.album.year.map { " · \($0)" } ?? ""),
                    thumbnail: .cover(entry.album.artworkFilePath, round: false),
                    run: { onOpenAlbum(entry.album) }
                )
            }

        let songHits = songs
            .map { ($0, max(Self.score($0.title, q), Self.score($0.artist, q) / 2, Self.score($0.album, q) / 2)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
        let rankedSongs = songHits.map { song, _ in
                PaletteItem(
                    id: "song:" + song.track.id.uuidString, section: .songs, title: song.track.title,
                    subtitle: "\(song.track.artist) · \(song.track.album) · \(song.track.formattedDuration)",
                    thumbnail: .cover(song.track.artworkFilePath, round: false),
                    run: { player.play(track: song.track, within: library.tracks(inAlbum: song.track.albumKey)) }
                )
            }

        // Whichever kind matched best leads; artists win ties ("radiohead"
        // should surface the artist before one of their songs).
        let groups: [(score: Int, items: [PaletteItem])] = [
            ((artistHits.first?.1 ?? 0) + 1, rankedArtists),
            (albumHits.first?.1 ?? 0, rankedAlbums),
            (songHits.first?.1 ?? 0, rankedSongs)
        ]
        return groups.sorted { $0.score > $1.score }.flatMap(\.items) + matchedCommands
    }

    static func commands(player: PlayerController, onCommand: @escaping (PaletteCommand) -> Void) -> [PaletteItem] {
        func item(_ id: String, _ icon: String, _ title: String, _ shortcut: String? = nil, _ run: @escaping () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:" + id, section: .commands, title: title, subtitle: nil, shortcut: shortcut, thumbnail: .symbol(icon), run: run)
        }
        let playing = player.engine.isPlaying
        return [
            item("play", playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play", "Space") { player.togglePlayPause() },
            item("next", "forward.fill", "Next Track", "⌘→") { player.next() },
            item("previous", "backward.fill", "Previous Track", "⌘←") { player.previous() },
            item("shuffle", "shuffle", player.shuffle ? "Turn Shuffle Off" : "Turn Shuffle On", "⌥⌘S") { player.shuffle.toggle() },
            item("repeat", "repeat", "Repeat: \(player.repeatMode.next.rawValue.capitalized)", "⌥⌘R") { player.repeatMode = player.repeatMode.next },
            item("current", "scope", "Go to Current Track") { onCommand(.goToCurrent) },
            item("info", "info.circle", "Get Info for Selection") { onCommand(.getInfo) },
            item("playlist", "music.note.list", "New Playlist…", "⌘N") { onCommand(.newPlaylist) },
            item("add", "folder.badge.plus", "Add Music…", "⌘O") { onCommand(.addMusic) },
            item("eq", "slider.vertical.3", "Equalizer", "⌥⌘E") { onCommand(.equalizer) },
            item("mini", "pip", "Mini Player", "⇧⌘M") { onCommand(.miniPlayer) },
            item("library", "music.note.house", "Library: folders and scanning", "⇧⌘L") { onCommand(.library) },
            item("settings", "gearshape", "Settings", "⌘,") { onCommand(.settings) }
        ]
    }
}

/// Arrow keys, Return, and Escape while the palette is open, even with the
/// search field focused.
private struct PaletteKeyCatcher: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handlers = (onUp, onDown, onReturn, onEscape)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(handlers: (onUp, onDown, onReturn, onEscape)) }

    final class Coordinator {
        var handlers: (up: () -> Void, down: () -> Void, enter: () -> Void, escape: () -> Void)
        private var monitor: Any?

        init(handlers: (() -> Void, () -> Void, () -> Void, () -> Void)) {
            self.handlers = handlers
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 126: self.handlers.up(); return nil
                case 125: self.handlers.down(); return nil
                case 36, 76: self.handlers.enter(); return nil
                case 53: self.handlers.escape(); return nil
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
