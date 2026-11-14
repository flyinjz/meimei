import SwiftUI

// The Albums and Artists pages of the main window's library pane.

// MARK: - Derived data

/// What the Albums and Artists pages show, worked out once per change of
/// the library (comparing the track list is instant when it hasn't changed).
@MainActor
final class LibraryPagesModel {
    static let shared = LibraryPagesModel()

    struct Album: Identifiable {
        var id: String { group.key }
        let group: AlbumGroup
        let tracks: [Track]
        let genre: String
        let added: Date
        let plays: Int
        /// "FLAC 24/96", "MP3 320".
        let quality: String
    }

    struct Artist: Identifiable {
        var id: String { name }
        let name: String
        /// Newest first.
        let albums: [Album]
        let trackCount: Int
        let duration: TimeInterval
        let genre: String
        let topTracks: [Track]
        let allTracks: [Track]
    }

    private var builtFrom: [Track]?
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []

    func update(_ library: LibraryStore) {
        if let builtFrom, builtFrom == library.tracks { return }
        builtFrom = library.tracks
        albums = library.albumGroups.map { g in
            let tracks = library.tracks(inAlbum: g.key)
            let best = tracks.max { ($0.isLossless ? 1 : 0, $0.bitDepth, $0.sampleRate, $0.estimatedBitrateKbps)
                < ($1.isLossless ? 1 : 0, $1.bitDepth, $1.sampleRate, $1.estimatedBitrateKbps) }
            let quality = best.map { t in
                t.isLossless ? "\(t.fileFormat) \(t.bitDepth)/\(Self.khz(t.sampleRate))" : "\(t.fileFormat) \(t.estimatedBitrateKbps)"
            } ?? ""
            let genre = tracks.first?.genre ?? ""
            return Album(group: g, tracks: tracks, genre: genre == "Unknown" ? "" : genre,
                         added: tracks.map(\.dateAdded).max() ?? .distantPast,
                         plays: tracks.reduce(0) { $0 + $1.playCount }, quality: quality)
        }
        let byArtist = Dictionary(grouping: albums) { $0.group.artist }
        var tracksByArtist: [String: [Track]] = [:]
        for t in library.tracks { tracksByArtist[t.displayArtist, default: []].append(t) }
        artists = library.artistGroups.map { a in
            let list = (byArtist[a.name] ?? []).sorted { ($0.group.year ?? 0) > ($1.group.year ?? 0) }
            let tracks = tracksByArtist[a.name] ?? list.flatMap(\.tracks)
            let genre = Dictionary(grouping: tracks, by: \.genre).filter { $0.key != "Unknown" }
                .max { $0.value.count < $1.value.count }?.key ?? ""
            return Artist(name: a.name, albums: list, trackCount: tracks.count,
                          duration: tracks.reduce(0) { $0 + $1.duration }, genre: genre,
                          topTracks: Array(tracks.sorted { $0.playCount > $1.playCount }.prefix(3)), allTracks: tracks)
        }
    }

    static func khz(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? "\(Int(k))" : String(format: "%.1f", k)
    }

    static func runtime(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }
}

// MARK: - Albums

/// The latest addition as a spread, a shelf of what's new, then every album
/// as a row with its tracklist showing, sorted from a menu; clicking a row
/// folds its tracklist away (and back).
struct AlbumsPage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var player = AppSession.shared.player
    @ObservedObject private var settings = AppSession.shared.settings
    var skin: Skin
    @State private var sort: Sort = .added
    /// Albums whose tracklist is folded away; every other one shows its tracks.
    @State private var closed: Set<String> = []

    enum Sort: String, CaseIterable {
        case added = "Recently added", year = "Year", artist = "Artist", title = "Title", length = "Length"
    }

    var body: some View {
        let model = LibraryPagesModel.shared
        let _ = model.update(library)
        let byAdded = model.albums.sorted { $0.added > $1.added }
        GeometryReader { geo in
            // The pane can be narrow or wide; sections lay themselves out for the room there is.
            let width = max(0, geo.size.width - 44)
            PageScroll {
                VStack(alignment: .leading, spacing: 30) {
                    if let latest = byAdded.first { LatestAddition(album: latest, width: width, skin: skin, library: library) }
                    AlbumShelf(title: "Recently added", albums: Array(byAdded.dropFirst().prefix(16)), skin: skin, library: library)
                    albumList(model.albums, compact: width < 640)
                }
                .padding(22)
            }
        }
        .background(skin.surface(skin.bgRow))
    }

    private func sorted(_ albums: [LibraryPagesModel.Album]) -> [LibraryPagesModel.Album] {
        switch sort {
        case .added: return albums.sorted { $0.added > $1.added }
        case .year: return albums.sorted { ($0.group.year ?? 0) > ($1.group.year ?? 0) }
        case .artist: return albums.sorted {
            $0.group.artist == $1.group.artist ? ($0.group.year ?? 0) < ($1.group.year ?? 0)
                : $0.group.artist.localizedStandardCompare($1.group.artist) == .orderedAscending
        }
        case .title: return albums.sorted { $0.group.title.localizedStandardCompare($1.group.title) == .orderedAscending }
        case .length: return albums.sorted { $0.group.duration > $1.group.duration }
        }
    }

    /// Every album, laid out like the shelf above it: a heading with the
    /// sort under it, then the rows. The first cover sits as far below the
    /// heading as the shelf's covers do below theirs.
    private func albumList(_ albums: [LibraryPagesModel.Album], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10 - AlbumRow.verticalPadding) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Albums").font(AppFont.ui(15, weight: .semibold)).foregroundStyle(skin.textPrimary)
                    Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(LibraryPagesModel.runtime(albums.reduce(0) { $0 + $1.group.duration }))")
                        .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1)
                }
                sortMenu
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sorted(albums)) { a in
                    AlbumRow(album: a, open: !closed.contains(a.id), compact: compact,
                             striped: settings.data.tableAlternatingRows, skin: skin, library: library) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            if closed.contains(a.id) { closed.remove(a.id) } else { closed.insert(a.id) }
                        }
                    }
                }
            }
        }
    }

    /// The sort menu as a line of small text under the heading.
    private var sortMenu: some View {
        PopUpMenuButton(items: Sort.allCases.map { s in
            PopUpMenuButton.Item(title: s.rawValue, checked: sort == s) { withAnimation(.easeOut(duration: 0.2)) { sort = s } }
        }) {
            SortLabel(value: sort.rawValue, skin: skin)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Sort albums")
    }
}

/// "Sort  Recently added ⌄", brightening under the pointer.
private struct SortLabel: View {
    var value: String
    var skin: Skin
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text("Sort").foregroundStyle(skin.textTertiary)
            Text(value).fontWeight(.medium).foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
            Glyph("chevron.down", size: 7).foregroundStyle(hovering ? skin.textSecondary : skin.textTertiary)
        }
        .font(AppFont.ui(11))
        .lineLimit(1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// The most recently added album, laid out like a record sleeve's back:
/// cover, what it is, how to play it, and its first tracks as striped
/// lines (no box, no scrolling), with a link to the whole album.
private struct LatestAddition: View {
    let album: LibraryPagesModel.Album
    /// The room the page has.
    var width: CGFloat
    var skin: Skin
    @ObservedObject var library: LibraryStore
    @ObservedObject private var settings = AppSession.shared.settings

    private static let date: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; return f }()

    /// Wide: cover, details, tracklist side by side. Otherwise the tracklist
    /// goes under, and in a narrow pane the cover shrinks.
    private var sideTracks: Bool { width >= 860 }
    private var cover: CGFloat { width >= 560 ? 200 : 132 }

    var body: some View {
        let g = album.group
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: width >= 560 ? 24 : 16) {
                PageCover(path: g.artworkFilePath, size: cover, skin: skin,
                          onOpen: { library.albumKey = g.key }, onPlay: { AppSession.shared.player.play(album.tracks) })
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                info
                    .frame(minHeight: cover, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if sideTracks {
                    tracklist.frame(width: min(360, width * 0.34))
                }
            }
            if !sideTracks {
                tracklist
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var info: some View {
        let g = album.group
        return VStack(alignment: .leading, spacing: 0) {
            Text("Latest addition · " + Self.date.string(from: album.added))
                .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1)
                .padding(.bottom, 6)
            Text(g.title).font(AppFont.ui(width >= 560 ? 28 : 20, weight: .semibold)).foregroundStyle(skin.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            Button { library.source = .artist(g.artist) } label: {
                Text(g.artist).font(AppFont.ui(14, weight: .medium)).foregroundStyle(skin.textSecondary).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Show \(g.artist)")
            Text(details).font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 14)
            // Full labels when they fit, icons alone when they don't.
            ViewThatFits(in: .horizontal) {
                buttons(labels: true)
                buttons(labels: false)
            }
        }
    }

    private func buttons(labels: Bool) -> some View {
        let g = album.group
        return HStack(spacing: 8) {
            Button { AppSession.shared.player.play(album.tracks) } label: {
                if labels { Label("Play", glyph: "play.fill") } else { Glyph("play.fill", size: 11) }
            }
            .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
            .help("Play")
            Button { AppSession.shared.player.play(album.tracks.shuffled()) } label: {
                if labels { Label("Shuffle", glyph: "shuffle") } else { Glyph("shuffle", size: 11) }
            }
            .buttonStyle(PillButtonStyle(skin: skin))
            .help("Shuffle")
            Button { library.albumKey = g.key } label: {
                if labels { Label("Open Album", glyph: "chevron.right") } else { Glyph("chevron.right", size: 11) }
            }
            .buttonStyle(PillButtonStyle(skin: skin))
            .help("Open the album")
        }
        .fixedSize()
    }

    private var details: String {
        let g = album.group
        var parts: [String] = []
        if let year = g.year { parts.append(String(year)) }
        if !album.genre.isEmpty { parts.append(album.genre) }
        parts.append("\(g.trackCount) track\(g.trackCount == 1 ? "" : "s"), \(LibraryPagesModel.runtime(g.duration))")
        if !album.quality.isEmpty { parts.append(album.quality) }
        return parts.joined(separator: " · ")
    }

    /// Beside the cover: as many lines as the cover is tall (eight), the
    /// last one the link when the album is longer. Under it: eight tracks,
    /// in two columns where there's room, then the link.
    private var tracklist: some View {
        let count = album.tracks.count
        let limit = sideTracks ? (count > 8 ? 7 : 8) : 8
        return StripedTracklist(tracks: album.tracks, columns: sideTracks || width < 640 ? 1 : 2, limit: limit,
                                striped: settings.data.tableAlternatingRows, skin: skin) {
            library.albumKey = album.group.key
        }
    }
}

/// A row of album covers that scrolls sideways.
private struct AlbumShelf: View {
    var title: String
    var albums: [LibraryPagesModel.Album]
    var skin: Skin
    @ObservedObject var library: LibraryStore

    private static let size: CGFloat = 140

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(AppFont.ui(15, weight: .semibold)).foregroundStyle(skin.textPrimary)
                PageScroll(axis: .horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(albums.prefix(GlassRendering.forceFallback ? 6 : albums.count)) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                PageCover(path: a.group.artworkFilePath, size: Self.size, skin: skin,
                                          onOpen: { library.albumKey = a.group.key },
                                          onPlay: { AppSession.shared.player.play(a.tracks) })
                                ShelfLink(text: a.group.title, font: AppFont.ui(12, weight: .medium), color: skin.textPrimary,
                                          hoverColor: skin.textPrimary, help: "Open \(a.group.title)") { library.albumKey = a.group.key }
                                ShelfLink(text: a.group.artist, font: AppFont.ui(10.5), color: skin.textSecondary,
                                          hoverColor: skin.textPrimary, help: "Show \(a.group.artist)") { library.source = .artist(a.group.artist) }
                            }
                            .frame(width: Self.size, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

/// A shelf card's title or artist: a click anywhere along its line follows
/// it, and it underlines under the pointer.
private struct ShelfLink: View {
    var text: String
    var font: Font
    var color: Color
    var hoverColor: Color
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(text).font(font).foregroundStyle(hovering ? hoverColor : color)
            .underline(hovering, color: hoverColor.opacity(0.6))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
    }
}

/// One album in the list: its tracklist, which lines up with the cover,
/// shows under it unless folded away.
private struct AlbumRow: View {
    let album: LibraryPagesModel.Album
    var open: Bool
    /// A narrow pane: the details go under the title instead of in columns.
    var compact = false
    /// Alternate tracklist lines shaded, as in the track table.
    var striped = true
    var skin: Skin
    @ObservedObject var library: LibraryStore
    var onToggle: () -> Void
    @State private var hovering = false

    /// Above and below the row's cover.
    static let verticalPadding: CGFloat = 9

    var body: some View {
        let g = album.group
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                PageCover(path: g.artworkFilePath, size: 56, skin: skin,
                          onOpen: { library.albumKey = g.key }, onPlay: { AppSession.shared.player.play(album.tracks) })
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(g.title).font(AppFont.ui(14.5, weight: .semibold)).foregroundStyle(skin.textPrimary).lineLimit(1)
                        if let year = g.year {
                            Text(String(year)).font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                        }
                    }
                    Text([g.artist, album.genre.isEmpty ? nil : album.genre].compactMap { $0 }.joined(separator: " · "))
                        .font(AppFont.ui(12)).foregroundStyle(skin.textSecondary).lineLimit(1)
                    if compact {
                        Text([album.quality, length].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    Text(album.quality).font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                        .frame(width: 100, alignment: .trailing)
                    Text(length).font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                        .frame(width: 130, alignment: .trailing)
                }
                Glyph("chevron.down", size: 9)
                    .foregroundStyle(hovering || open ? skin.textSecondary : skin.textTertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.vertical, Self.verticalPadding)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .onHover { hovering = $0 }
            if open {
                StripedTracklist(tracks: album.tracks, columns: compact ? 1 : 2, striped: striped, skin: skin)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            Rectangle().fill(skin.textPrimary.opacity(0.07)).frame(height: 1)
        }
    }
}

extension AlbumRow {
    fileprivate var length: String {
        "\(album.group.trackCount) track\(album.group.trackCount == 1 ? "" : "s") · \(LibraryPagesModel.runtime(album.group.duration))"
    }
}

/// Tracks in one or two columns, read across. Each line is a table row:
/// every other one shaded with the skin's alternating-row color, the same
/// as the track table's stripes. With a limit, the first tracks show and a
/// last line links to the whole album.
private struct StripedTracklist: View {
    let tracks: [Track]
    var columns: Int
    var limit: Int?
    var striped: Bool
    var skin: Skin
    var onMore: (() -> Void)?

    var body: some View {
        let shown = limit.map { tracks.count > $0 ? Array(tracks.prefix($0)) : tracks } ?? tracks
        let lines = (shown.count + columns - 1) / columns
        VStack(spacing: 0) {
            ForEach(0..<lines, id: \.self) { line in
                HStack(spacing: 28) {
                    ForEach(0..<columns, id: \.self) { c in
                        let i = line * columns + c
                        if i < shown.count {
                            let t = shown[i]
                            TrackLine(track: t, number: t.trackNumber ?? i + 1, skin: skin) {
                                AppSession.shared.player.play(track: t, within: tracks)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                        } else {
                            Color.clear.frame(minWidth: 0, maxWidth: .infinity, maxHeight: 24)
                        }
                    }
                }
                .background(Rectangle().fill(striped && line % 2 == 1 ? skin.bgRowAlt : .clear).padding(.horizontal, 1))
            }
            if shown.count < tracks.count, let onMore {
                MoreTracksLine(count: tracks.count, skin: skin, action: onMore)
            }
        }
    }
}

/// "All 21 tracks ›", lined up with the track titles; opens the album.
private struct MoreTracksLine: View {
    var count: Int
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("All \(count) tracks").font(AppFont.ui(11.5, weight: .medium))
            Glyph("chevron.right", size: 8)
        }
        .foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
        .padding(.leading, 36)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(perform: action)
        .help("Open the album")
    }
}

/// A track as a line: number, title, length. Double-click plays it.
private struct TrackLine: View {
    let track: Track
    var number: Int
    var skin: Skin
    var onPlay: () -> Void
    @ObservedObject private var player = AppSession.shared.player
    @State private var hovering = false

    var body: some View {
        let playing = player.currentTrack?.id == track.id
        HStack(spacing: 10) {
            Group {
                if playing { Glyph("speaker.wave.2.fill", size: 9).foregroundStyle(skin.accent) }
                else { Text("\(number)").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary) }
            }
            .frame(width: 20, alignment: .trailing)
            Text(track.title).font(AppFont.ui(12)).foregroundStyle(playing ? skin.accent : skin.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
            Text(track.formattedDuration).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Rectangle().fill(skin.textPrimary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
    }
}

// MARK: - Artists

/// Every artist as a card: their records fanned out, what they're about,
/// and their three most played tracks to start from. Click a card for the
/// artist's page.
struct ArtistsPage: View {
    @ObservedObject var library: LibraryStore
    var skin: Skin

    var body: some View {
        let model = LibraryPagesModel.shared
        let _ = model.update(library)
        PageScroll {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 520), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(model.artists) { a in ArtistCard(artist: a, skin: skin, library: library) }
            }
            .padding(18)
        }
        .background(skin.surface(skin.bgRow))
    }
}

private struct ArtistCard: View {
    let artist: LibraryPagesModel.Artist
    var skin: Skin
    @ObservedObject var library: LibraryStore
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            CoverStack(paths: artist.albums.map(\.group.artworkFilePath), skin: skin, size: 104)
                .frame(width: 118, height: 112, alignment: .leading)
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        Button { AppSession.shared.player.play(artist.allTracks) } label: {
                            Glyph("play.fill", size: 11).foregroundStyle(skin.textOnAccent)
                                .frame(width: 28, height: 28).background(Rectangle().fill(skin.accent))
                        }
                        .buttonStyle(.plain)
                        .help("Play \(artist.name)")
                        .padding(6)
                        .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(artist.name).font(AppFont.ui(17, weight: .semibold)).foregroundStyle(skin.textPrimary).lineLimit(1)
                Text(facts).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1)
                if !artist.genre.isEmpty {
                    Text(artist.genre).font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary)
                        .padding(.horizontal, 6).frame(height: 18)
                        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(artist.topTracks.enumerated()), id: \.element.id) { i, t in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).frame(width: 10, alignment: .trailing)
                            Text(t.title).font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).lineLimit(1)
                            Spacer(minLength: 6)
                            if t.playCount > 0 {
                                Text("\(t.playCount) play\(t.playCount == 1 ? "" : "s")").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                            }
                        }
                        .frame(height: 20)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { AppSession.shared.player.play(track: t, within: artist.topTracks) }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(skin.textPrimary.opacity(hovering ? 0.05 : 0.025)))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(hovering ? 0.16 : 0.08), lineWidth: 1))
        .fuiCorners(skin)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { library.source = .artist(artist.name) }
        .help("Show \(artist.name)")
    }

    private var facts: String {
        let n = artist.albums.count
        return "\(n) album\(n == 1 ? "" : "s") · \(artist.trackCount) track\(artist.trackCount == 1 ? "" : "s") · \(LibraryPagesModel.runtime(artist.duration))"
    }
}

// MARK: - Pieces

/// A scroll view; offscreen snapshots (which can't draw one) get the
/// content laid out from the start instead.
struct PageScroll<Content: View>: View {
    var axis: Axis.Set = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        if GlassRendering.forceFallback {
            if axis == .horizontal {
                content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                GeometryReader { g in
                    content.fixedSize(horizontal: false, vertical: true)
                        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                        .clipped()
                }
            }
        } else {
            ScrollView(axis) { content }
        }
    }
}

/// A cover: click opens it, the play mark under the pointer plays it.
struct PageCover: View {
    var path: String?
    var size: CGFloat
    var skin: Skin
    var onOpen: () -> Void
    var onPlay: () -> Void
    @State private var hovering = false

    var body: some View {
        ArtworkView(path: path, size: size, skin: skin, placeholder: "opticaldisc")
            .frame(width: size, height: size)
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(hovering ? 0.32 : 0.1), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .overlay(alignment: .bottomTrailing) {
                if hovering && size >= 80 {
                    Button(action: onPlay) {
                        Glyph("play.fill", size: 11).foregroundStyle(skin.textOnAccent)
                            .frame(width: 28, height: 28).background(Rectangle().fill(skin.accent))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// Up to three records fanned out, newest on top.
private struct CoverStack: View {
    var paths: [String?]
    var skin: Skin
    var size: CGFloat
    /// How far the records fan out (1 is a wide fan).
    var spread: Double = 0.45

    var body: some View {
        let shown = Array(paths.prefix(3))
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.offset) { i, p in
                ArtworkView(path: p, size: size, skin: skin, placeholder: "opticaldisc")
                    .frame(width: size, height: size)
                    .clipShape(Rectangle())
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .rotationEffect(.degrees(shown.count > 1 ? Double(i) * spread * 6 - 3 * spread : 0), anchor: .bottomLeading)
                    .offset(x: CGFloat(i) * size * 0.12 * CGFloat(spread), y: CGFloat(i) * -size * 0.04 * CGFloat(spread))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
            }
        }
    }
}

extension View {
    /// A section on a page that already sits on glass: no fill at all, only
    /// the 1px line that separates it. Any veil stacks on the pane's own and goes murky.
    func pageGlass(_ skin: Skin) -> some View {
        overlay(Rectangle().strokeBorder(skin.isGlass ? Color.white.opacity(0.13) : skin.hairline, lineWidth: 1))
            .fuiCorners(skin)
    }
}
