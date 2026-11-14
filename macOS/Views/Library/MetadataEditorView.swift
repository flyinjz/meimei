import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Get Info: edit tags, replace the cover, fetch art or lyrics, and save to
/// the library and (optionally) into the file itself.
struct MetadataEditorView: View {
    @ObservedObject var library: LibraryStore
    var lyrics: LyricsStore
    var skin: Skin
    var trackID: UUID
    var onDismiss: () -> Void

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var genre = ""
    @State private var composer = ""
    @State private var year = ""
    @State private var trackNumber = ""
    @State private var discNumber = ""
    @State private var newArtwork: (image: NSImage, jpeg: Data)?
    @State private var lyricsDraft = ""
    @State private var originalLyrics = ""
    @State private var status = ""
    @State private var isWorking = false
    @State private var writeToFile = true

    private var track: Track? { library.track(id: trackID) }
    private var canWriteFile: Bool { track.map { MetadataWriter.canWrite($0.url) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: track?.title ?? "Get Info", subtitle: track.map(technicalLine), skin: skin)
            Hairline(color: skin.hairline)
            HStack(alignment: .top, spacing: 20) {
                artworkColumn
                fieldsColumn
            }
            .padding(18)
            Hairline(color: skin.hairline)
            footer
        }
        .frame(width: 660)
        .glassSheet(skin)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func technicalLine(_ t: Track) -> String {
        "\(t.fileFormat) · \(t.qualitySummary) · \(t.formattedDuration) · \(t.playCount) plays"
    }

    // MARK: Artwork

    private var artworkColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let newArtwork {
                    Image(nsImage: newArtwork.image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ArtworkView(path: track?.artworkFilePath, size: 190, skin: skin, placeholder: "photo")
                }
            }
            .frame(width: 190, height: 190)
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
            .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: loadDroppedArtwork)
            .help("Drop an image to replace the cover")

            HStack(spacing: 6) {
                HeaderButton(title: "Choose…", icon: "photo", skin: skin, action: pickArtwork)
                HeaderButton(title: "Find Online", icon: "magnifyingglass", skin: skin) {
                    Task { await fetchArtwork() }
                }
                .disabled(isWorking || !AppSession.shared.settings.data.onlineLookups)
                .help(AppSession.shared.settings.data.onlineLookups ? "The best match from your sources (Library → Metadata has the full search)"
                      : "Online lookups are off (Library → Metadata)")
            }
            if newArtwork != nil {
                Text("The new cover applies to every track on this album.")
                    .font(AppFont.ui(10))
                    .foregroundStyle(skin.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let track {
                Text(track.filePath)
                    .font(AppFont.ui(9.5))
                    .foregroundStyle(skin.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                    .help("Double-click to show in Finder")
            }
        }
        .frame(width: 190)
    }

    // MARK: Fields

    private var fieldsColumn: some View {
        VStack(spacing: 8) {
            field("Title", $title)
            HStack(spacing: 8) {
                field("Artist", $artist)
                field("Album Artist", $albumArtist)
            }
            field("Album", $album)
            HStack(spacing: 8) {
                field("Genre", $genre)
                field("Composer", $composer)
            }
            HStack(spacing: 8) {
                field("Year", $year).frame(width: 80)
                field("Track", $trackNumber).frame(width: 64)
                field("Disc", $discNumber).frame(width: 64)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label("Lyrics")
                    Spacer()
                    Button("Find Online") { Task { await fetchLyrics() } }
                        .disabled(!AppSession.shared.settings.data.onlineLookups)
                        .buttonStyle(.plain)
                        .font(AppFont.ui(10.5, weight: .semibold))
                        .foregroundStyle(skin.accent)
                        .disabled(isWorking)
                }
                TextEditor(text: $lyricsDraft)
                    .font(AppFont.ui(11))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(skin.textPrimary)
                    .padding(6)
                    .frame(height: 120)
                    .background(Rectangle().fill(skin.bgVoid.opacity(0.7)))
                    .overlay(Rectangle().strokeBorder(skin.hairline, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(AppFont.ui(9, weight: .bold))
            .foregroundStyle(skin.textTertiary)
    }

    private func field(_ name: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(name)
            DialogTextField(text: text, skin: skin)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            SettingsToggleSwitch(isOn: $writeToFile, skin: skin)
                .disabled(!canWriteFile)
                .opacity(canWriteFile ? 1 : 0.4)
            Text(canWriteFile ? "Also write tags to the file" : "Tags for this format are saved to the library only")
                .font(AppFont.ui(11.5))
                .foregroundStyle(skin.textSecondary)
            if isWorking { ProgressView().controlSize(.small) }
            if !status.isEmpty {
                Text(status)
                    .font(AppFont.ui(10.5))
                    .foregroundStyle(skin.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            DialogButton(title: "Cancel", skin: skin, action: onDismiss)
                .keyboardShortcut(.cancelAction)
            DialogButton(title: "Save", prominent: true, enabled: !isWorking, skin: skin, action: save)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(skin.bgRaised)
    }

    // MARK: Load / save

    private func load() {
        guard let track else { return }
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist
        genre = track.genre
        composer = track.composer
        year = track.year.map(String.init) ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        discNumber = track.discNumber.map(String.init) ?? ""
        originalLyrics = LyricsStore.readText(LyricsStore.lrcURL(for: track)) ?? ""
        lyricsDraft = originalLyrics
        writeToFile = canWriteFile
    }

    private func edited(_ base: Track) -> Track {
        var t = base
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        t.title = clean(title).isEmpty ? base.title : clean(title)
        t.artist = clean(artist)
        t.album = clean(album)
        t.albumArtist = clean(albumArtist).isEmpty ? t.artist : clean(albumArtist)
        t.genre = clean(genre).isEmpty ? "Unknown" : clean(genre)
        t.composer = clean(composer)
        t.year = Int(clean(year))
        t.trackNumber = Int(clean(trackNumber))
        t.discNumber = Int(clean(discNumber))
        return t
    }

    private func save() {
        guard let original = track else { return }
        var updated = edited(original)
        if let newArtwork, let path = library.storeArtwork(newArtwork.jpeg) {
            updated.artworkFilePath = path
        }
        library.replaceTrack(updated)
        if let path = updated.artworkFilePath, newArtwork != nil {
            library.applyArtworkToAlbum(updated.albumKey, path: path)
        }
        if lyricsDraft != originalLyrics {
            lyrics.save(lyricsDraft, for: updated)
        }

        guard writeToFile, canWriteFile else {
            onDismiss()
            return
        }
        isWorking = true
        status = "Writing tags…"
        let fields = MetadataWriter.Fields(updated)
        let artwork = newArtwork?.jpeg
        let url = updated.url
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await MetadataWriter.write(fields, artworkJPEG: artwork, to: url)
                }.value
                isWorking = false
                onDismiss()
            } catch {
                isWorking = false
                status = "Saved to the library. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Artwork sources

    private func setArtwork(from data: Data) {
        guard let jpeg = ArtworkStore.normalizedJPEG(from: data), let image = NSImage(data: jpeg) else {
            status = "That image couldn't be read."
            return
        }
        newArtwork = (image, jpeg)
        status = ""
    }

    private func fetchArtwork() async {
        guard let track else { return }
        isWorking = true
        status = "Looking up the cover…"
        defer { isWorking = false }
        // The closest album from the enabled sources, then the old song search.
        let e = edited(track)
        let sources = AppSession.shared.settings.data.metadataSources
        let best = await OnlineMetadata.albums(artist: e.albumArtist.isEmpty ? e.artist : e.albumArtist,
                                               album: e.album.isEmpty ? e.title : e.album, sources: sources).first?.cover
        var found: Data?
        if let best { found = await OnlineMetadata.image(best.full) }
        if found == nil, sources.contains(.appleMusic) { found = await MetadataLookup.fetchArtwork(for: e) }
        if let data = found {
            setArtwork(from: data)
            status = "Found a cover. Save to apply it."
        } else {
            status = "No matching cover found."
        }
    }

    private func fetchLyrics() async {
        guard let track else { return }
        isWorking = true
        status = "Looking up lyrics…"
        defer { isWorking = false }
        let settings = AppSession.shared.settings.data
        switch await LyricsLookup.fetch(edited(track), sources: settings.lyricsSources, syncedOnly: settings.lyricsSyncedOnly) {
        case .found(let text, let source):
            lyricsDraft = text
            status = (LyricsState.of(text) == .synced ? "Found synced lyrics" : "Found lyrics (not synced)") + " on \(source.label)."
        case .notFound:
            status = "No lyrics found."
        case .unavailable(let why):
            status = "Couldn't search: \(why)."
        }
    }

    private func pickArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            setArtwork(from: data)
        }
    }

    private func loadDroppedArtwork(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                DispatchQueue.main.async { setArtwork(from: data) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            DispatchQueue.main.async { setArtwork(from: data) }
        }
        return true
    }
}
