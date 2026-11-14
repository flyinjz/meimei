import SwiftUI
import AppKit

/// An image from the web, fetched through the lookups' private session
/// (not the shared one, so no cookies or cache), decoded off the main thread.
struct RemoteThumbnail: View {
    var url: URL
    var skin: Skin
    var onFailure: () -> Void = {}
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(skin.textPrimary.opacity(0.05))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if !failed {
                CapsuleProgress(fraction: nil, skin: skin).frame(width: 36, height: 2)
            }
        }
        .clipped()
        .task(id: url) {
            image = nil
            failed = false
            if let data = await OnlineMetadata.image(url), let decoded = NSImage(data: data) {
                image = decoded
            } else {
                failed = true
                onFailure()
            }
        }
    }
}

/// Source tags under results: which service, and the size when known.
private func sourceTag(_ source: OnlineSource, _ pixels: Int?) -> String {
    "[\(source.tag)\(pixels.map { " · \($0) px" } ?? "")]"
}

// MARK: - Cover search

/// Covers for an album from every enabled source; picking one downloads
/// the full-size image and hands it back as JPEG.
struct CoverSearchSheet: View {
    var skin: Skin
    @State var artist: String
    @State var album: String
    var sources: [OnlineSource]
    var onPick: (Data) -> Void
    var onCancel: () -> Void

    @State private var results: [CoverCandidate] = []
    @State private var broken: Set<String> = []
    @State private var selected: CoverCandidate?
    @State private var searching = false
    @State private var downloading = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "Find a cover", subtitle: "Searched from this Mac, straight to \(sources.map(\.label).joined(separator: ", ")).", skin: skin)
            HStack(spacing: 8) {
                DialogTextField(placeholder: "Artist", text: $artist, skin: skin).onSubmit(search)
                DialogTextField(placeholder: "Album", text: $album, skin: skin).onSubmit(search)
                DialogButton(title: searching ? "Searching…" : "Search", enabled: !searching, skin: skin, action: search)
            }
            .padding(.horizontal, 18)
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(128), spacing: 10), count: 3), spacing: 12) {
                        ForEach(results.filter { !broken.contains($0.id) }) { c in
                            Button { selected = c } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    RemoteThumbnail(url: c.thumbnail, skin: skin) { broken.insert(c.id) }
                                        .frame(width: 128, height: 128)
                                        .overlay(Rectangle().strokeBorder(selected == c ? skin.accent : skin.textPrimary.opacity(0.14),
                                                                          lineWidth: selected == c ? 2 : 1))
                                    Text(c.title).font(AppFont.ui(10.5)).foregroundStyle(skin.textPrimary).lineLimit(1)
                                    Text(sourceTag(c.source, c.maxPixels)).font(AppFont.ui(9.5)).foregroundStyle(skin.textTertiary)
                                }
                                .frame(width: 128, alignment: .leading)
                            }
                            .buttonStyle(PressDipStyle())
                        }
                    }
                    .padding(2)
                }
                .frame(width: 424, height: 380)
                VStack(alignment: .leading, spacing: 8) {
                    if let selected {
                        RemoteThumbnail(url: selected.thumbnail, skin: skin)
                            .frame(width: 220, height: 220)
                            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
                        Text(selected.title).font(AppFont.ui(12, weight: .semibold)).lineLimit(2)
                        Text(selected.artist + (selected.year.map { " · \($0)" } ?? "")).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary)
                        Text(sourceTag(selected.source, selected.maxPixels)).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                    } else {
                        Text(results.isEmpty && !searching ? "No covers yet. Adjust the names and search again." : "Pick a cover to preview it.")
                            .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                            .frame(width: 220, height: 220)
                            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    Spacer()
                }
                .frame(width: 220)
            }
            .padding(18)
            HStack {
                if let message { Text(message).font(AppFont.ui(11)).foregroundStyle(skin.accent) }
                Spacer()
                DialogButton(title: "Cancel", skin: skin, action: onCancel)
                DialogButton(title: downloading ? "Downloading…" : "Use This Cover", prominent: true,
                             enabled: selected != nil && !downloading, skin: skin, action: use)
            }
            .padding([.horizontal, .bottom], 18)
        }
        .frame(width: 700)
        .glassSheet(skin)
        .task { search() }
    }

    private func search() {
        guard !searching else { return }
        searching = true
        message = nil
        selected = nil
        broken = []
        Task {
            results = await OnlineMetadata.covers(artist: artist, album: album, sources: sources)
            searching = false
            if results.isEmpty { message = "Nothing found." }
        }
    }

    private func use() {
        guard let selected else { return }
        downloading = true
        Task {
            // The full image, falling back to the preview size if the original won't load.
            var data = await OnlineMetadata.image(selected.full)
            if data == nil { data = await OnlineMetadata.image(selected.thumbnail) }
            downloading = false
            if let data, let jpeg = ArtworkStore.normalizedJPEG(from: data) {
                onPick(jpeg)
            } else {
                message = "That cover couldn't be downloaded."
            }
        }
    }
}

// MARK: - Album lookup

/// Which of a match's details to take.
struct MatchFields: OptionSet, Hashable {
    let rawValue: Int
    static let titles = MatchFields(rawValue: 1 << 0)
    static let numbers = MatchFields(rawValue: 1 << 1)
    static let album = MatchFields(rawValue: 1 << 2)
    static let albumArtist = MatchFields(rawValue: 1 << 3)
    static let year = MatchFields(rawValue: 1 << 4)
    static let genre = MatchFields(rawValue: 1 << 5)
    static let trackArtists = MatchFields(rawValue: 1 << 6)
    static let cover = MatchFields(rawValue: 1 << 7)
}

enum AlbumMatcher {
    /// Pairs local tracks with a tracklist: by disc and number when the
    /// local ones are numbered, otherwise in order.
    static func pair(_ local: [Track], with songs: [AlbumMatch.Song]) -> [(Track, AlbumMatch.Song?)] {
        let numbered = local.allSatisfy { $0.trackNumber != nil }
        if numbered {
            let byKey = Dictionary(songs.map { ("\($0.disc)-\($0.number)", $0) }, uniquingKeysWith: { a, _ in a })
            let pairs = local.map { ($0, byKey["\($0.discNumber ?? 1)-\($0.trackNumber ?? 0)"]) }
            if pairs.filter({ $0.1 != nil }).count >= max(1, local.count / 2) { return pairs }
        }
        let ordered = local.sorted(by: Track.albumOrder)
        return ordered.enumerated().map { i, t in (t, i < songs.count ? songs[i] : nil) }
    }

    /// `local` with the chosen details from `match` and its `songs`.
    static func apply(_ match: AlbumMatch, songs: [AlbumMatch.Song], to local: [Track], fields: MatchFields) -> [Track] {
        pair(local, with: songs).map { t, song in
            var t = t
            if fields.contains(.album) { t.album = match.title }
            if fields.contains(.albumArtist), !match.artist.isEmpty { t.albumArtist = match.artist }
            if fields.contains(.year), let y = match.year { t.year = y }
            if fields.contains(.genre), let g = match.genre { t.genre = g }
            if let song {
                if fields.contains(.titles) { t.title = song.title }
                if fields.contains(.numbers) { t.trackNumber = song.number; t.discNumber = song.disc }
                if fields.contains(.trackArtists), !song.artist.isEmpty { t.artist = song.artist }
            }
            return t
        }
    }
}

/// Look an album up online, compare, and take what's right.
struct AlbumMatchSheet: View {
    var skin: Skin
    @State var artist: String
    @State var album: String
    var local: [Track]
    var sources: [OnlineSource]
    /// The updated tracks, plus a cover to download if one was asked for.
    var onApply: ([Track], CoverCandidate?) -> Void
    var onCancel: () -> Void

    @State private var results: [AlbumMatch] = []
    @State private var selected: AlbumMatch?
    @State private var songs: [AlbumMatch.Song] = []
    @State private var fields: MatchFields = [.titles, .numbers, .album, .albumArtist, .year, .genre]
    @State private var searching = false
    @State private var loadingSongs = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "Look up album details", subtitle: "Compare with \(sources.map(\.label).joined(separator: ", ")) and take what's right. Searched from this Mac.", skin: skin)
            HStack(spacing: 8) {
                DialogTextField(placeholder: "Artist", text: $artist, skin: skin).onSubmit(search)
                DialogTextField(placeholder: "Album", text: $album, skin: skin).onSubmit(search)
                DialogButton(title: searching ? "Searching…" : "Search", enabled: !searching, skin: skin, action: search)
            }
            .padding(.horizontal, 18)
            HStack(alignment: .top, spacing: 14) {
                matchList.frame(width: 300, height: 400)
                comparison.frame(maxWidth: .infinity, maxHeight: 400, alignment: .topLeading)
            }
            .padding(18)
            HStack {
                if let message { Text(message).font(AppFont.ui(11)).foregroundStyle(skin.accent) }
                Spacer()
                DialogButton(title: "Cancel", skin: skin, action: onCancel)
                DialogButton(title: "Apply to Album", prominent: true, enabled: selected != nil && !loadingSongs && !fields.isEmpty, skin: skin) {
                    guard let selected else { return }
                    onApply(AlbumMatcher.apply(selected, songs: songs, to: local, fields: fields),
                            fields.contains(.cover) ? selected.cover : nil)
                }
            }
            .padding([.horizontal, .bottom], 18)
        }
        .frame(width: 900)
        .glassSheet(skin)
        .task { search() }
    }

    private var matchList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { m in
                    Button { select(m) } label: {
                        HStack(spacing: 8) {
                            if let cover = m.cover {
                                RemoteThumbnail(url: cover.thumbnail, skin: skin).frame(width: 40, height: 40)
                            } else {
                                Rectangle().fill(skin.textPrimary.opacity(0.05)).frame(width: 40, height: 40)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(AppFont.ui(11.5, weight: .semibold)).lineLimit(1)
                                Text(m.artist).font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary).lineLimit(1)
                                Text([m.year.map(String.init), "\(m.trackCount) tracks", m.note].compactMap { $0 }.joined(separator: " · ") + "  [\(m.source.tag)]")
                                    .font(AppFont.ui(9.5)).foregroundStyle(skin.textTertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(selected == m ? skin.selection.opacity(0.6) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private var comparison: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 10) {
                fieldToggles(selected)
                if loadingSongs {
                    CapsuleProgress(fraction: nil, skin: skin).frame(height: 3)
                } else {
                    let preview = AlbumMatcher.apply(selected, songs: songs, to: local, fields: fields)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(local.sorted(by: Track.albumOrder)) { before in
                                let after = preview.first { $0.id == before.id } ?? before
                                diffRow(before, after)
                            }
                        }
                    }
                    if songs.count != local.count {
                        Text("This release has \(songs.count) tracks; the album here has \(local.count). Unmatched tracks keep their details.")
                            .font(AppFont.ui(10.5)).foregroundStyle(skin.accent)
                    }
                }
            }
        } else {
            Text(searching ? "Searching…" : "Pick a result to compare it with your tracks.")
                .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
        }
    }

    private func fieldToggles(_ m: AlbumMatch) -> some View {
        let options: [(MatchFields, String)] = [(.album, "album title"), (.albumArtist, "album artist"), (.year, "year"),
                                                (.genre, "genre"), (.titles, "track titles"), (.numbers, "track numbers"),
                                                (.trackArtists, "track artists"), (.cover, "cover")]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
            ForEach(options, id: \.0.rawValue) { option, label in
                let available = option != .cover || m.cover != nil
                Button(label) {
                    if fields.contains(option) { fields.remove(option) } else { fields.insert(option) }
                }
                .buttonStyle(PillButtonStyle(skin: skin, isActive: fields.contains(option) && available, compact: true))
                .disabled(!available)
            }
        }
    }

    private func diffRow(_ before: Track, _ after: Track) -> some View {
        let numberBefore = "\(before.discNumber.map { "\($0)-" } ?? "")\(before.trackNumber.map(String.init) ?? "–")"
        let numberAfter = "\(after.discNumber.map { "\($0)-" } ?? "")\(after.trackNumber.map(String.init) ?? "–")"
        let changed = before.title != after.title || numberBefore != numberAfter || before.artist != after.artist
        return HStack(alignment: .top, spacing: 8) {
            Text(numberAfter).font(AppFont.ui(10.5)).foregroundStyle(numberBefore != numberAfter ? skin.accent : skin.textTertiary)
                .frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(after.title).font(AppFont.ui(11)).foregroundStyle(changed ? skin.textPrimary : skin.textSecondary).lineLimit(1)
                if before.title != after.title {
                    Text("was: \(before.title)").font(AppFont.ui(9.5)).foregroundStyle(skin.textTertiary).strikethrough().lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if changed { Rectangle().fill(skin.accent).frame(width: 2, height: 14) }
        }
    }

    private func search() {
        guard !searching else { return }
        searching = true
        selected = nil
        message = nil
        Task {
            results = await OnlineMetadata.albums(artist: artist, album: album, sources: sources)
            searching = false
            if results.isEmpty { message = "Nothing found." } else { select(results[0]) }
        }
    }

    private func select(_ m: AlbumMatch) {
        selected = m
        songs = []
        loadingSongs = true
        if m.cover == nil { fields.remove(.cover) }
        if m.genre == nil { fields.remove(.genre) }
        Task {
            let fetched = (try? await OnlineMetadata.songs(of: m)) ?? []
            guard selected == m else { return }
            songs = fetched
            loadingSongs = false
            if fetched.isEmpty { message = "That release's tracklist couldn't be loaded." }
        }
    }
}
