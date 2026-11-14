import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Library → Metadata: album-by-album editing with covers from disk or the
/// web, artist spellings, library-wide cleanup, and where lookups go.
struct MetadataPage: View {
    @ObservedObject var library: LibraryStore
    var skin: Skin

    enum Mode: String, CaseIterable, Identifiable {
        case albums, artists, cleanup, lyrics, sources
        var id: String { rawValue }
        var label: String {
            switch self {
            case .albums: return "Albums"
            case .artists: return "Artist Names"
            case .cleanup: return "Clean Up"
            case .lyrics: return "Lyrics"
            case .sources: return "Sources & Saving"
            }
        }
    }

    @State private var mode: Mode

    init(library: LibraryStore, skin: Skin, mode: Mode = .albums) {
        self.library = library
        self.skin = skin
        _mode = State(initialValue: mode)
    }
    @ObservedObject private var navigator = LibraryNavigator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LibraryHeader(title: "Metadata", skin: skin)
            SettingsSegmented(options: Mode.allCases, selection: $mode, label: \.label, skin: skin)
            SaveStatus(saver: AppSession.shared.metadataSaver, skin: skin)
            switch mode {
            case .albums: AlbumsMode(library: library, skin: skin)
            case .artists: ScrollIfLive { ArtistNamesMode(library: library, skin: skin).padding(.trailing, 4) }
            case .cleanup: CleanupMode(library: library, skin: skin)
            case .lyrics: ScrollIfLive { LyricsMode(library: library, finder: AppSession.shared.lyricsFinder, skin: skin).padding(.trailing, 4) }
            case .sources: ScrollIfLive { SourcesMode(skin: skin).padding(.trailing, 4) }
            }
        }
        .onAppear(perform: navigate)
        .onChange(of: navigator.request) { _ in navigate() }
    }
}

extension MetadataPage {
    /// Follows a request to open a mode (the lyrics panel's search button).
    private func navigate() {
        guard let r = navigator.request, let target = r.metadataMode.flatMap(Mode.init(rawValue:)), target != mode else { return }
        mode = target
    }
}

/// Writing progress and the last save's outcome, shared by every mode.
private struct SaveStatus: View {
    @ObservedObject var saver: MetadataSaver
    var skin: Skin
    @State private var showFailures = false

    var body: some View {
        if let p = saver.progress {
            HStack(spacing: 10) {
                Text("Writing tags \(p.done) of \(p.total)…").font(AppFont.ui(11))
                CapsuleProgress(fraction: p.total > 0 ? Double(p.done) / Double(p.total) : nil, skin: skin).frame(height: 3)
                Button("Stop") { saver.cancel() }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
        } else if let message = saver.lastMessage {
            HStack(spacing: 8) {
                Text(message).font(AppFont.ui(11)).foregroundStyle(saver.failures.isEmpty ? skin.textSecondary : skin.accent)
                if !saver.failures.isEmpty {
                    Button(showFailures ? "Hide" : "Show failures") { showFailures.toggle() }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                }
            }
            if showFailures {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(saver.failures) { f in
                        Text("\(f.title): \(f.reason)").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).lineLimit(2)
                    }
                }
            }
        }
    }
}

// MARK: - Albums

private struct AlbumRowModel: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var title: String
    var artist: String
    var artwork: String?
    var issues: AlbumIssues
}

private struct AlbumsMode: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var settings = AppSession.shared.settings
    var skin: Skin

    @State private var query = ""
    @State private var attentionOnly = false
    @State private var rows: [AlbumRowModel] = []
    @State private var selected: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                DialogTextField(placeholder: "Find an album or artist", text: $query, skin: skin)
                HStack {
                    Button(attentionOnly ? "Needs attention (\(visible.count))" : "All albums (\(visible.count))") { attentionOnly.toggle() }
                        .buttonStyle(PillButtonStyle(skin: skin, isActive: attentionOnly, compact: true))
                        .help("Show only albums with no cover, odd formatting, mixed or misspelled artists, or missing numbers")
                    Spacer()
                }
                ScrollIfLive {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { row in
                            AlbumListRow(row: row, selected: row.key == selected, skin: skin) { selected = row.key }
                        }
                    }
                }
                .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
            }
            .frame(width: 230)
            Group {
                if let selected = selected ?? (GlassRendering.forceFallback ? visible.first?.key : nil),
                   !library.tracks(inAlbum: selected).isEmpty {
                    AlbumEditor(library: library, albumKey: selected, skin: skin) { newKey in self.selected = newKey }
                        .id(selected)
                } else {
                    Text(rows.isEmpty ? "No albums yet." : "Pick an album to edit its details and cover.")
                        .font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: library.tracksVersion) { await rebuild() }
        .onChange(of: settings.data.cleanupRules) { _ in Task { await rebuild() } }
    }

    private var visible: [AlbumRowModel] {
        let q = OnlineMetadata.fold(query)
        // The offscreen snapshot can't wait for the background pass.
        let rows = self.rows.isEmpty && GlassRendering.forceFallback ? Self.rows(library, settings.data.cleanupRules) : self.rows
        return rows.filter { row in
            (!attentionOnly || !row.issues.isEmpty)
                && (q.isEmpty || OnlineMetadata.fold(row.title).contains(q) || OnlineMetadata.fold(row.artist).contains(q))
        }
    }

    private static func rows(_ library: LibraryStore, _ rules: CleanupRules) -> [AlbumRowModel] {
        let keys = Set(ArtistSpellings.find(in: library.tracks).map(\.key))
        return library.albumGroups.map { g in
            AlbumRowModel(key: g.key, title: g.title, artist: g.artist, artwork: g.artworkFilePath,
                          issues: AlbumIssues.of(library.tracks(inAlbum: g.key), rules: rules, spellingKeys: keys))
        }
    }

    /// Album rows with their issues, worked out off the main thread.
    private func rebuild() async {
        let groups = library.albumGroups.map { ($0, library.tracks(inAlbum: $0.key)) }
        let rules = settings.data.cleanupRules
        let all = library.tracks
        let lyrics = AppSession.shared.lyricsFinder.states
        rows = await Task.detached(priority: .userInitiated) {
            let keys = Set(ArtistSpellings.find(in: all).map(\.key))
            return groups.map { g, tracks in
                // Flagged only once checked: every track known, none with lyrics.
                let noLyrics = tracks.allSatisfy { lyrics[$0.id] == LyricsState.none }
                return AlbumRowModel(key: g.key, title: g.title, artist: g.artist, artwork: g.artworkFilePath,
                                     issues: AlbumIssues.of(tracks, rules: rules, spellingKeys: keys, lyricsMissing: noLyrics))
            }
        }.value
        if selected == nil { selected = rows.first(where: { !$0.issues.isEmpty })?.key ?? rows.first?.key }
    }
}

private struct AlbumListRow: View {
    var row: AlbumRowModel
    var selected: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ArtworkView(path: row.artwork, size: 34, skin: skin, placeholder: "opticaldisc")
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(AppFont.ui(11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Text(row.artist).font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary).lineLimit(1)
                    if !row.issues.isEmpty {
                        Text(row.issues.labels.prefix(2).map { "[\($0)]" }.joined(separator: " "))
                            .font(AppFont.ui(9.5)).foregroundStyle(skin.accent).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(selected ? skin.selection.opacity(0.6) : hovering ? skin.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Album editor

private struct AlbumEditor: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var saver = AppSession.shared.metadataSaver
    var albumKey: String
    var skin: Skin
    /// The album's key after a save that renamed it, so the list follows.
    var onRenamed: (String) -> Void

    @State private var original: [Track]
    @State private var draft: [Track]
    @State private var newCover: Data?
    @State private var removeCover = false
    @State private var showingCoverSearch = false
    @State private var showingMatch = false
    @State private var note: String?

    init(library: LibraryStore, albumKey: String, skin: Skin, onRenamed: @escaping (String) -> Void) {
        self.library = library
        self.albumKey = albumKey
        self.skin = skin
        self.onRenamed = onRenamed
        // Loaded up front so the first frame already shows the album.
        let tracks = library.tracks(inAlbum: albumKey).sorted(by: Track.albumOrder)
        _original = State(initialValue: tracks)
        _draft = State(initialValue: tracks)
    }

    private var changeCount: Int {
        zip(original, draft).filter { $0 != $1 }.count + (newCover != nil || removeCover ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollIfLive {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 20) {
                        coverPanel
                        albumFields
                    }
                    toolbar
                    trackTable
                }
                .padding(.trailing, 4)
                .padding(.bottom, 16)
            }
            saveBar
        }
        .sheet(isPresented: $showingCoverSearch) {
            CoverSearchSheet(skin: skin, artist: albumArtist.wrappedValue, album: albumTitle.wrappedValue, sources: sources) { jpeg in
                newCover = jpeg
                removeCover = false
                showingCoverSearch = false
            } onCancel: { showingCoverSearch = false }
        }
        .sheet(isPresented: $showingMatch) {
            AlbumMatchSheet(skin: skin, artist: albumArtist.wrappedValue, album: albumTitle.wrappedValue, local: draft, sources: sources) { updated, cover in
                draft = draft.map { t in updated.first { $0.id == t.id } ?? t }
                showingMatch = false
                if let cover {
                    note = "Downloading cover…"
                    Task {
                        if let data = await OnlineMetadata.image(cover.full), let jpeg = ArtworkStore.normalizedJPEG(from: data) {
                            newCover = jpeg
                            note = nil
                        } else {
                            note = "The cover couldn't be downloaded."
                        }
                    }
                }
            } onCancel: { showingMatch = false }
        }
    }

    private var sources: [OnlineSource] { settings.data.metadataSources }
    private var online: Bool { settings.data.onlineLookups && !sources.isEmpty }

    private func load() {
        original = library.tracks(inAlbum: albumKey).sorted(by: Track.albumOrder)
        draft = original
        newCover = nil
        removeCover = false
    }

    // MARK: Cover

    private var coverPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let newCover, let image = NSImage(data: newCover) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if removeCover {
                    Rectangle().fill(skin.textPrimary.opacity(0.04))
                    Glyph("photo", size: 26).foregroundStyle(skin.textTertiary)
                } else {
                    ArtworkView(path: draft.first?.artworkFilePath, size: 168, skin: skin, placeholder: "photo")
                }
            }
            .frame(width: 168, height: 168)
            .clipped()
            .overlay(Rectangle().strokeBorder(newCover != nil ? skin.accent : skin.textPrimary.opacity(0.14), lineWidth: 1))
            .onDrop(of: [.fileURL, .image], isTargeted: nil, perform: dropCover)
            .help("Drop an image to replace the cover")
            Text(coverCaption)
                .font(AppFont.ui(10.5))
                .foregroundStyle(newCover != nil || removeCover ? skin.accent : skin.textTertiary)
            SegmentBar(skin: skin, items: [
                .init(glyph: "folder.badge.plus", help: "Choose an image file…", action: chooseCover),
                .init(glyph: "magnifyingglass", enabled: online, help: "Search for covers online…", action: { showingCoverSearch = true }),
                .init(glyph: "doc.on.doc", help: "Paste an image", action: pasteCover),
                .init(glyph: "trash", enabled: draft.first?.artworkFilePath != nil || newCover != nil, help: "Remove the cover",
                      action: { newCover = nil; removeCover = true }),
            ])
            .frame(width: 168)
        }
        .frame(width: 168)
    }

    private var coverCaption: String {
        if let newCover { return "New cover · " + Self.pixelSize(newCover) }
        if removeCover { return "Cover will be removed" }
        guard let path = draft.first?.artworkFilePath, let data = FileManager.default.contents(atPath: path) else { return "No cover" }
        return Self.pixelSize(data)
    }

    private static func pixelSize(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return "image" }
        return "\(w) × \(h)"
    }

    private func setCover(_ data: Data) {
        guard let jpeg = ArtworkStore.normalizedJPEG(from: data) else { note = "That image couldn't be read."; return }
        newCover = jpeg
        removeCover = false
        note = nil
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover for “\(albumTitle.wrappedValue)”."
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) { setCover(data) }
    }

    private func pasteCover() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            setCover(data)
        } else if let url = pb.readObjects(forClasses: [NSURL.self])?.first as? URL, let data = try? Data(contentsOf: url) {
            setCover(data)
        } else {
            note = "There's no image on the clipboard."
        }
    }

    private func dropCover(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                Task { @MainActor in setCover(data) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in setCover(data) }
        }
        return true
    }

    // MARK: Album fields

    /// A field that's the same on every track; editing it sets them all.
    /// Mixed values show empty with a "mixed" placeholder.
    private func shared(_ key: WritableKeyPath<Track, String>) -> Binding<String> {
        Binding(get: { Set(draft.map { $0[keyPath: key] }).count == 1 ? draft.first?[keyPath: key] ?? "" : "" },
                set: { v in for i in draft.indices { draft[i][keyPath: key] = v } })
    }

    private var albumTitle: Binding<String> { shared(\.album) }
    private var albumArtist: Binding<String> { shared(\.albumArtist) }

    private var year: Binding<String> {
        Binding(get: { Set(draft.map(\.year)).count == 1 ? draft.first?.year.map(String.init) ?? "" : "" },
                set: { v in let y = Int(v.filter(\.isNumber).prefix(4)); for i in draft.indices { draft[i].year = y } })
    }

    private var albumFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormField(title: "Album", text: albumTitle, placeholder: mixed(\.album) ? "Multiple values" : "", skin: skin)
            VStack(alignment: .leading, spacing: 6) {
                FormField(title: "Album Artist", text: albumArtist, placeholder: mixed(\.albumArtist) ? "Multiple values" : "", skin: skin)
                SpellingHint(library: library, name: albumArtist.wrappedValue, skin: skin) { albumArtist.wrappedValue = $0 }
            }
            HStack(alignment: .bottom, spacing: 12) {
                FormField(title: "Year", text: year, placeholder: Set(draft.map(\.year)).count > 1 ? "Multiple" : "", skin: skin)
                    .frame(width: 96)
                FormField(title: "Genre", text: shared(\.genre), placeholder: mixed(\.genre) ? "Multiple values" : "", skin: skin) {
                    PopUpMenuButton(items: library.genres.prefix(40).map { g in
                        PopUpMenuButton.Item(title: g.name, checked: g.name == shared(\.genre).wrappedValue) { shared(\.genre).wrappedValue = g.name }
                    }) {
                        Glyph("chevron.down", size: 9)
                            .foregroundStyle(skin.textSecondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Genres in your library")
                }
            }
            Text(summary).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mixed(_ key: KeyPath<Track, String>) -> Bool { Set(draft.map { $0[keyPath: key] }).count > 1 }

    private var summary: String {
        let discs = Set(draft.map { $0.discNumber ?? 1 }).count
        let formats = Set(draft.map(\.fileFormat)).sorted().joined(separator: ", ")
        let length = LibraryHeaderView.longDuration(draft.reduce(0) { $0 + $1.duration })
        return [LibraryFormat.count(draft.count, "track"), discs > 1 ? "\(discs) discs" : nil, length, formats]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Toolbar

    /// One bar when there's room; otherwise editing tools and online
    /// lookups on two bars.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                editTools
                Spacer(minLength: 0)
                ToolbarDivider(skin: skin)
                onlineTools
            }
            .toolbarBox(skin)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) { editTools; Spacer(minLength: 0) }.toolbarBox(skin)
                HStack(spacing: 0) { onlineTools; ToolbarDivider(skin: skin); Spacer(minLength: 0) }.toolbarBox(skin)
            }
        }
    }

    @ViewBuilder
    private var editTools: some View {
        let rules = settings.data.cleanupRules
        ToolbarMenu(title: "Case", skin: skin, items: [
            .init(title: "Title Case") { transform { $0.title = TitleCaser.apply($0.title, style: .title); $0.album = TitleCaser.apply($0.album, style: .title) } },
            .init(title: "Sentence case") { transform { $0.title = TitleCaser.apply($0.title, style: .sentence); $0.album = TitleCaser.apply($0.album, style: .sentence) } },
        ])
        ToolbarDivider(skin: skin)
        ToolbarAction(title: "Clean Up", skin: skin) {
            transform {
                $0.title = MetadataCleanup.title($0.title, rules)
                $0.album = MetadataCleanup.title($0.album, rules)
                $0.artist = MetadataCleanup.name($0.artist, rules)
                $0.albumArtist = MetadataCleanup.name($0.albumArtist, rules)
            }
        }
        .help("Apply the rules from Clean Up to this album")
        ToolbarDivider(skin: skin)
        ToolbarMenu(title: "Numbers", skin: skin, items: [
            .init(title: "Number Tracks in Order") { renumber() },
            .init(title: "Set Every Track to Disc 1") { transform { $0.discNumber = 1 }; renumber() },
            .init(title: "Clear Track Numbers") { transform { $0.trackNumber = nil } },
        ])
        ToolbarDivider(skin: skin)
        ToolbarMenu(title: "Artist", skin: skin, items: [
            .init(title: "Use Album Artist for Every Track") {
                let a = albumArtist.wrappedValue
                if !a.isEmpty { transform { $0.artist = a } }
            },
            .init(title: "Use First Track's Artist as Album Artist") {
                if let a = draft.first?.artist, !a.isEmpty { transform { $0.albumArtist = a } }
            },
        ])
        ToolbarDivider(skin: skin)
    }

    @ViewBuilder
    private var onlineTools: some View {
        let finder = AppSession.shared.lyricsFinder
        ToolbarAction(title: finder.isBusy ? "Lyrics…" : "Lyrics", skin: skin) {
            let tracks = library.tracks(inAlbum: albumKey)
            Task {
                await finder.find(tracks)
                note = finder.report.map { "Lyrics: \($0.synced + $0.plain) of \($0.total) found" }
            }
        }
        .disabled(!online || finder.isBusy)
        .help("Find lyrics for every track")
        ToolbarDivider(skin: skin)
        ToolbarAction(title: "Look Up…", skin: skin) { showingMatch = true }
            .help("Compare with album details online")
            .disabled(!online)
    }

    private func transform(_ body: (inout Track) -> Void) {
        for i in draft.indices { body(&draft[i]) }
    }

    private func renumber() {
        var counters: [Int: Int] = [:]
        for i in draft.indices {
            let disc = draft[i].discNumber ?? 1
            counters[disc, default: 0] += 1
            draft[i].trackNumber = counters[disc]
        }
    }

    // MARK: Tracks

    private var trackTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TrackColumnHeader(title: "Disc", width: 44, trailing: true, skin: skin)
                TrackColumnHeader(title: "#", width: 44, trailing: true, skin: skin)
                TrackColumnHeader(title: "Title", skin: skin)
                TrackColumnHeader(title: "Artist", skin: skin)
                TrackColumnHeader(title: "Time", width: 56, trailing: true, skin: skin)
            }
            .frame(height: 28)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.04)))
            .overlay(alignment: .bottom) { Rectangle().fill(skin.textPrimary.opacity(0.12)).frame(height: 1) }
            ForEach(draft.indices, id: \.self) { i in
                TrackEditRow(track: $draft[i], changed: i < original.count && draft[i] != original[i], striped: i % 2 == 1, skin: skin)
            }
        }
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
    }

    // MARK: Save bar

    private var saveBar: some View {
        HStack(spacing: 12) {
            Text(changeCount == 0 ? "No changes" : "\(changeCount) change\(changeCount == 1 ? "" : "s")")
                .font(AppFont.ui(11.5)).foregroundStyle(changeCount == 0 ? skin.textTertiary : skin.textPrimary)
            if let note { Text(note).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1) }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                SettingsToggleSwitch(isOn: $settings.data.writeTagsToFiles, skin: skin)
                Text("Write tags").font(AppFont.ui(11.5)).foregroundStyle(skin.textSecondary).fixedSize()
            }
            .help("Save changes into the audio files (FLAC, MP3, M4A/ALAC) as well as the library")
            DialogButton(title: "Revert", enabled: changeCount > 0, skin: skin, action: load)
            DialogButton(title: "Save", prominent: true, enabled: changeCount > 0 && !saver.isSaving, skin: skin, action: save)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Rectangle().fill(skin.bgVoid.opacity(0.92)))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
    }

    private func save() {
        let edited = draft
        let cover = newCover
        let remove = removeCover
        let newKey = edited.first?.albumKey
        Task {
            await saver.save(edited, cover: cover, removeCover: remove, writeFiles: settings.data.writeTagsToFiles)
            if let newKey, newKey != albumKey { onRenamed(newKey) } else { load() }
        }
    }
}

private struct TrackEditRow: View {
    @Binding var track: Track
    var changed: Bool
    var striped: Bool
    var skin: Skin

    var body: some View {
        HStack(spacing: 0) {
            InlineField(text: Binding(get: { track.discNumber.map(String.init) ?? "" },
                                      set: { track.discNumber = Int($0.filter(\.isNumber)) }), trailing: true, inset: 6, skin: skin)
                .frame(width: 44)
            InlineField(text: Binding(get: { track.trackNumber.map(String.init) ?? "" },
                                      set: { track.trackNumber = Int($0.filter(\.isNumber)) }), trailing: true, inset: 6, skin: skin)
                .frame(width: 44)
            InlineField(text: $track.title, skin: skin)
            InlineField(text: $track.artist, skin: skin)
            Text(track.formattedDuration)
                .font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                .frame(width: 56, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 30)
        .background(Rectangle().fill(striped ? skin.textPrimary.opacity(0.025) : .clear))
        .overlay(alignment: .leading) { Rectangle().fill(changed ? skin.accent : .clear).frame(width: 2) }
    }
}

private extension View {
    func toolbarBox(_ skin: Skin) -> some View {
        frame(height: 32)
            .background(Rectangle().fill(skin.textPrimary.opacity(0.03)))
            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
    }
}

/// Other spellings of a name found in the library, with buttons to use one.
private struct SpellingHint: View {
    @ObservedObject var library: LibraryStore
    var name: String
    var skin: Skin
    var use: (String) -> Void

    var body: some View {
        let key = ArtistSpellings.key(name)
        let variants = key.isEmpty ? [] : variantsFor(key)
        if variants.count > 1 {
            HStack(spacing: 8) {
                Text("Other spellings:").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                ForEach(variants.filter { $0.name != name }, id: \.name) { v in
                    Button("\(v.name) (\(v.count))") { use(v.name) }
                        .buttonStyle(.plain)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(skin.accent)
                        .help("Use this spelling for the album artist")
                }
            }
        }
    }

    private func variantsFor(_ key: String) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for t in library.tracks {
            for n in Set([t.artist, t.albumArtist]) where ArtistSpellings.key(n) == key { counts[n, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
}

// MARK: - Artist names

private struct ArtistNamesMode: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var saver = AppSession.shared.metadataSaver
    var skin: Skin

    @State private var groups: [ArtistSpellings] = []
    @State private var loaded = false
    @State private var chosen: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Artists with more than one spelling. Choose the spelling to keep.")
                .font(AppFont.ui(11)).foregroundStyle(skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if groups.isEmpty {
                LibrarySection(skin: skin) {
                    Text(loaded ? "Every artist is written one way. Nothing to merge." : "Checking spellings…")
                        .font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                }
            } else {
                HStack {
                    Text("\(LibraryFormat.count(groups.count, "artist")) with more than one spelling").font(AppFont.ui(11))
                    Spacer()
                    Button("Merge All with Suggested Spellings") { merge(groups) }
                        .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                        .disabled(saver.isSaving)
                }
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        row(group)
                        SettingsRowDivider(skin: skin)
                    }
                }
                .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
            }
        }
        .task(id: library.tracksVersion) {
            let tracks = library.tracks
            groups = await Task.detached(priority: .userInitiated) { ArtistSpellings.find(in: tracks) }.value
            loaded = true
        }
    }

    private func row(_ group: ArtistSpellings) -> some View {
        let pick = chosen[group.key] ?? group.suggested
        return HStack(spacing: 8) {
            FlowChips(items: group.variants.map(\.name), skin: skin, selected: pick,
                      label: { name in "\(name)  \(group.variants.first { $0.name == name }?.count ?? 0)" }) { chosen[group.key] = $0 }
            Spacer(minLength: 8)
            Button("Merge into “\(pick)”") { merge([group]) }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .disabled(saver.isSaving)
        }
        .padding(10)
    }

    private func merge(_ list: [ArtistSpellings]) {
        var rename: [String: String] = [:]
        for g in list {
            let target = chosen[g.key] ?? g.suggested
            for v in g.variants where v.name != target { rename[v.name] = target }
        }
        let edited = library.tracks.compactMap { t -> Track? in
            var t = t
            var touched = false
            if let a = rename[t.artist] { t.artist = a; touched = true }
            if let a = rename[t.albumArtist] { t.albumArtist = a; touched = true }
            return touched ? t : nil
        }
        Task { await saver.save(edited, writeFiles: settings.data.writeTagsToFiles) }
    }
}

/// Pills that wrap; one is selected.
private struct FlowChips: View {
    var items: [String]
    var skin: Skin
    var selected: String
    var label: (String) -> String
    var pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(label(item)) { pick(item) }
                    .buttonStyle(PillButtonStyle(skin: skin, isActive: item == selected, compact: true))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Clean up

private struct CleanupChange: Identifiable {
    var id: UUID { track.id }
    var track: Track
    var updated: Track
}

private struct CleanupMode: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var saver = AppSession.shared.metadataSaver
    var skin: Skin

    @State private var titles = true
    @State private var albums = true
    @State private var names = true
    @State private var changes: [CleanupChange] = []
    @State private var excluded: Set<UUID> = []
    @State private var previewed = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollIfLive {
                VStack(alignment: .leading, spacing: 12) {
                    CleanupRulesEditor(rules: $settings.data.cleanupRules, skin: skin)
                    LibrarySection(title: "Apply to", skin: skin) {
                        SettingsToggleRow(title: "Track titles", isOn: $titles, skin: skin)
                        SettingsToggleRow(title: "Album titles", isOn: $albums, skin: skin)
                        SettingsToggleRow(title: "Artist names", subtitle: "Spacing and quotes only.", isOn: $names, skin: skin)
                    }
                    Button("Preview Changes", action: preview)
                        .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                }
                .padding(.trailing, 4)
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 8) {
                if !previewed {
                    Text("No preview yet.")
                        .font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                } else if changes.isEmpty {
                    Text("Everything already follows these rules.").font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
                } else {
                    HStack {
                        Text("\(changes.count - excluded.count) of \(LibraryFormat.count(changes.count, "track")) will change")
                            .font(AppFont.ui(11.5))
                        Spacer()
                        Button("Apply") { apply() }
                            .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                            .disabled(saver.isSaving || excluded.count == changes.count)
                    }
                    ScrollIfLive {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(changes) { change in changeRow(change) }
                        }
                    }
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func changeRow(_ change: CleanupChange) -> some View {
        let on = !excluded.contains(change.id)
        return Button {
            if on { excluded.insert(change.id) } else { excluded.remove(change.id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(on ? skin.accent : .clear)
                    .frame(width: 10, height: 10)
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.4), lineWidth: 1))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    diff(change.track.title, change.updated.title)
                    diff(change.track.album, change.updated.album)
                    diff(change.track.artist, change.updated.artist)
                    diff(change.track.albumArtist, change.updated.albumArtist)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .opacity(on ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func diff(_ before: String, _ after: String) -> some View {
        if before != after {
            HStack(spacing: 6) {
                Text(before).strikethrough().foregroundStyle(skin.textTertiary).lineLimit(1)
                Text("→").foregroundStyle(skin.textTertiary)
                Text(after).foregroundStyle(skin.textPrimary).lineLimit(1)
            }
            .font(AppFont.ui(11))
        }
    }

    private func preview() {
        let rules = settings.data.cleanupRules
        changes = library.tracks.compactMap { t in
            var u = t
            if titles { u.title = MetadataCleanup.title(t.title, rules) }
            if albums { u.album = MetadataCleanup.title(t.album, rules) }
            if names {
                u.artist = MetadataCleanup.name(t.artist, rules)
                u.albumArtist = MetadataCleanup.name(t.albumArtist, rules)
            }
            return u == t ? nil : CleanupChange(track: t, updated: u)
        }
        excluded = []
        previewed = true
    }

    private func apply() {
        let edited = changes.filter { !excluded.contains($0.id) }.map(\.updated)
        Task {
            await saver.save(edited, writeFiles: settings.data.writeTagsToFiles)
            preview()
        }
    }
}

/// The cleanup rules, also used by the album editor's Clean Up tool.
struct CleanupRulesEditor: View {
    @Binding var rules: CleanupRules
    var skin: Skin

    var body: some View {
        LibrarySection(title: "Rules", skin: skin) {
            Text("Capitalization").font(AppFont.ui(12)).padding(.bottom, 2)
            SettingsSegmented(options: ["title", "sentence", "keep"],
                              selection: Binding(get: { rules.caseStyle?.rawValue ?? "keep" },
                                                 set: { rules.caseStyle = CaseStyle(rawValue: $0) }),
                              label: { $0 == "title" ? "Title Case" : $0 == "sentence" ? "Sentence" : "Keep" }, skin: skin)
            Text("Featured artists").font(AppFont.ui(12)).padding(.top, 6).padding(.bottom, 2)
            SettingsSegmented(options: FeatStyle.allCases, selection: $rules.feat, label: \.label, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Tidy spacing", subtitle: "Trims and collapses spaces.", isOn: $rules.tidySpaces, skin: skin)
            SettingsToggleRow(title: "Straight quotes", subtitle: "’ “ ” → ' \"", isOn: $rules.straightQuotes, skin: skin)
            SettingsToggleRow(title: "Remove edition tags", subtitle: "(Remastered 2011), [Explicit], (Deluxe Edition)…", isOn: $rules.removeEditionTags, skin: skin)
        }
    }
}

// MARK: - Sources & saving

private struct SourcesMode: View {
    @ObservedObject private var settings = AppSession.shared.settings
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySection(title: "Online lookups", skin: skin) {
                SettingsToggleRow(title: "Allow online lookups", 
                                  isOn: $settings.data.onlineLookups, skin: skin)
                Text("Requests go directly from this Mac to the sources below and include only the names you search for.")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LibrarySection(title: "Sources, in order", skin: skin) {
                ForEach(OnlineSource.allCases) { source in sourceRow(source) }
            }
            .disabled(!settings.data.onlineLookups)
            .opacity(settings.data.onlineLookups ? 1 : 0.5)
            LibrarySection(title: "Saving", skin: skin) {
                SettingsToggleRow(title: "Write changes into the files", subtitle: "FLAC, MP3, and M4A/ALAC files.",
                                  isOn: $settings.data.writeTagsToFiles, skin: skin)
            }
        }
    }

    private func sourceRow(_ source: OnlineSource) -> some View {
        let list = settings.data.metadataSources
        let on = list.contains(source)
        let index = list.firstIndex(of: source)
        return HStack(alignment: .top, spacing: 10) {
            SettingsToggleSwitch(isOn: Binding(get: { on }, set: { v in
                if v { settings.data.metadataSources.append(source) } else { settings.data.metadataSources.removeAll { $0 == source } }
            }), skin: skin)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label + (index.map { "  [\($0 + 1)]" } ?? "")).font(AppFont.ui(12))
                Text(source.detail).font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary)
                Text("contacts " + source.hosts).font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
            }
            Spacer()
            if let index {
                IconButton(icon: "chevron.up", size: 22, help: "Ask this source earlier", skin: skin) {
                    guard index > 0 else { return }
                    settings.data.metadataSources.swapAt(index, index - 1)
                }
                .disabled(index == 0)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A scroll view, except while the debug snapshot renders offscreen (its
/// renderer leaves scroll views blank).
struct ScrollIfLive<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if GlassRendering.forceFallback {
            VStack(alignment: .leading, spacing: 0) { content }
        } else {
            ScrollView { content }
        }
    }
}

// MARK: - Lyrics

private struct LyricsMode: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var finder: LyricsFinder
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var navigator = LibraryNavigator.shared
    var skin: Skin
    @State private var focus: UUID?

    var body: some View {
        let tracks = library.tracks
        let known = tracks.filter { finder.states[$0.id] != nil }
        let have = known.filter { finder.states[$0.id] != LyricsState.none }
        let synced = have.filter { finder.states[$0.id] == .synced }.count
        let missing = known.filter { finder.states[$0.id] == LyricsState.none }
        let online = settings.data.onlineLookups
        VStack(alignment: .leading, spacing: 14) {
            if let focus, let track = library.track(id: focus) { focusCard(track) }

            LibrarySection(title: "Coverage", skin: skin) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    stat("\(have.count)", "with lyrics")
                    stat("\(synced)", "synced")
                    stat("\(missing.count)", "without", accent: !missing.isEmpty)
                    stat("\(tracks.count - known.count)", "not checked")
                    Spacer()
                    if let c = finder.checking {
                        Text("checking \(c.done) of \(c.total)").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                    } else {
                        Button("Check Again") { finder.checkCoverage() }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    }
                }
            }

            LibrarySection(title: "Find", skin: skin) {
                if let s = finder.searching {
                    HStack(spacing: 10) {
                        Text("Searching \(s.done) of \(s.total)…").font(AppFont.ui(11.5))
                        CapsuleProgress(fraction: s.total > 0 ? Double(s.done) / Double(s.total) : nil, skin: skin).frame(height: 3)
                        Button("Stop") { finder.cancel() }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Find Missing Lyrics") { Task { await finder.find(missing + tracks.filter { finder.states[$0.id] == nil }) } }
                            .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                            .disabled(!online || (missing.isEmpty && known.count == tracks.count))
                        Text("\(missing.count + tracks.count - known.count) tracks without lyrics.")
                            .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let report = finder.report {
                        Text("Last search: " + report.summary).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary).padding(.top, 4)
                    }
                }
                if !online {
                    Text("Online lookups are off (Sources & Saving).").font(AppFont.ui(10.5)).foregroundStyle(skin.accent)
                }
            }

            LibrarySection(title: "Saving", skin: skin) {
                Text("Keep found lyrics as").font(AppFont.ui(12)).padding(.bottom, 2)
                SettingsSegmented(options: LyricsSaveMode.allCases, selection: $settings.data.lyricsSaveMode, label: \.label, skin: skin)
                SettingsRowDivider(skin: skin)
                SettingsToggleRow(title: "Synced lyrics only", subtitle: "Plain lyrics are skipped.", isOn: $settings.data.lyricsSyncedOnly, skin: skin)
                SettingsToggleRow(title: "Replace lyrics tracks already have", isOn: $settings.data.lyricsReplaceExisting, skin: skin)
            }

            LibrarySection(title: "Sources, in order", skin: skin) {
                ForEach(LyricsSource.allCases) { source in lyricsSourceRow(source) }
                if let problem = finder.report?.problem {
                    Text("Last search: " + problem).font(AppFont.ui(10.5)).foregroundStyle(skin.accent).padding(.top, 4)
                }
            }

            if !missing.isEmpty { albumsMissing(missing) }
        }
        .onAppear {
            finder.checkCoverage()
            takeRequest()
        }
        .onChange(of: navigator.request) { _ in takeRequest() }
    }

    private func lyricsSourceRow(_ source: LyricsSource) -> some View {
        let list = settings.data.lyricsSources
        let index = list.firstIndex(of: source)
        return HStack(alignment: .top, spacing: 10) {
            SettingsToggleSwitch(isOn: Binding(get: { index != nil }, set: { on in
                if on { settings.data.lyricsSources.append(source) } else { settings.data.lyricsSources.removeAll { $0 == source } }
            }), skin: skin)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label + (index.map { "  [\($0 + 1)]" } ?? "")).font(AppFont.ui(12))
                Text(source.detail).font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary)
            }
            Spacer()
            if let index {
                IconButton(icon: "chevron.up", size: 22, help: "Ask this source earlier", skin: skin) {
                    settings.data.lyricsSources.swapAt(index, index - 1)
                }
                .disabled(index == 0)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppFont.ui(16, weight: .semibold)).foregroundStyle(accent ? skin.accent : skin.textPrimary)
            Text(label).font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
        }
    }

    /// The track the lyrics panel asked about, and how its search went.
    private func focusCard(_ track: Track) -> some View {
        LibrarySection(title: "Now playing", skin: skin) {
            HStack(spacing: 10) {
                ArtworkView(path: track.artworkFilePath, size: 40, skin: skin, placeholder: "music.note")
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(AppFont.ui(12, weight: .semibold)).lineLimit(1)
                    Text("\(track.artist) · \(track.album)").font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary).lineLimit(1)
                }
                Spacer()
                LibraryTag(text: outcomeText(track), skin: skin, accent: true)
                Button("Search Again") { Task { await finder.find([track]) } }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    .disabled(finder.isBusy || !settings.data.onlineLookups)
            }
        }
    }

    private func outcomeText(_ track: Track) -> String {
        if finder.isBusy, finder.outcomes[track.id] == nil { return "searching…" }
        switch finder.outcomes[track.id] {
        case .synced?: return "found synced lyrics"
        case .plain?: return "found lyrics (not synced)"
        case .notFound?: return "not found"
        case .kept?: return "already has lyrics"
        case .failed(let why)?: return "couldn't save: \(why)"
        case .unavailable(let why)?: return why
        case nil: return finder.states[track.id] == LyricsState.none ? "no lyrics" : "has lyrics"
        }
    }

    private func albumsMissing(_ missing: [Track]) -> some View {
        let byAlbum = Dictionary(grouping: missing, by: \.albumKey)
            .map { (key: $0.key, tracks: $0.value) }
            .sorted { $0.tracks.count > $1.tracks.count }
        return LibrarySection(title: "Albums without lyrics", skin: skin) {
            LazyVStack(spacing: 0) {
                ForEach(byAlbum.prefix(150), id: \.key) { entry in
                    let total = library.tracks(inAlbum: entry.key).count
                    HStack(spacing: 10) {
                        ArtworkView(path: entry.tracks.first?.artworkFilePath, size: 30, skin: skin, placeholder: "opticaldisc")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.tracks.first?.album ?? "").font(AppFont.ui(11.5)).lineLimit(1)
                            Text(entry.tracks.first?.albumArtist ?? "").font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        LibraryTag(text: "\(entry.tracks.count) of \(total) missing", skin: skin)
                        Button("Find") { Task { await finder.find(entry.tracks) } }
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                            .disabled(finder.isBusy || !settings.data.onlineLookups)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }

    /// Picks up "find lyrics for this track" from the lyrics panel.
    private func takeRequest() {
        guard let r = navigator.request, r.metadataMode == "lyrics" else { return }
        navigator.request = nil
        guard let id = r.trackID, let track = library.track(id: id) else { return }
        focus = id
        if settings.data.onlineLookups { Task { await finder.find([track]) } }
    }
}
