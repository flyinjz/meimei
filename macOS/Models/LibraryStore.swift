import Foundation
import Combine

/// One artist in the library, by album artist (or track artist when unset).
struct ArtistGroup: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let albumCount: Int
    let trackCount: Int
    let artworkFilePath: String?
}

/// Progress of a running import.
struct ScanProgress: Equatable {
    var completed: Int
    var total: Int
    var label: String
}

/// All known tracks and playlists, the current browse selection, and
/// persistence. Derived collections (visible tracks, albums, genres, counts)
/// are rebuilt when their inputs change rather than recomputed in view bodies.
@MainActor
final class LibraryStore: ObservableObject {

    // MARK: Stored state

    /// Every track, kept in library order (album artist, album, disc, track).
    @Published private(set) var tracks: [Track] = [] {
        didSet { tracksDidChange() }
    }
    /// Bumped whenever tracks change in more than play counts, play dates,
    /// or likes, for caches of text and order (sort ranks).
    private(set) var tracksVersion = 0
    /// User playlists, manual and smart, in the order the user sees them.
    @Published private(set) var playlists: [Playlist] = [] {
        didSet { playlistsDidChange() }
    }

    @Published var source: LibrarySource = .all {
        didSet {
            guard source != oldValue else { return }
            albumKey = nil
            rebuildVisible()
            noteNavigation()
        }
    }
    /// When set, the center column shows this album instead of `source`.
    @Published var albumKey: String? {
        didSet { noteNavigation() }
    }

    // MARK: Back and forward

    /// Where the library pane is: a page, and the album open over it.
    struct Place: Equatable {
        var source: LibrarySource
        var albumKey: String?
    }

    /// The last back or forward move, for the pane's slide: -1 back, 1 forward.
    struct NavigationMove: Equatable {
        var direction: Int
        var serial: Int
    }

    private var place = Place(source: .all, albumKey: nil)
    private var backPlaces: [Place] = []
    private var forwardPlaces: [Place] = []
    private var movingThroughHistory = false
    @Published private(set) var navigationMove = NavigationMove(direction: 0, serial: 0)
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private static let historyLimit = 100

    /// Every visit lands on the back list, as in a browser; a new visit
    /// clears what was ahead.
    private func noteNavigation() {
        let now = Place(source: source, albumKey: albumKey)
        guard now != place else { return }
        if !movingThroughHistory {
            backPlaces.append(place)
            if backPlaces.count > Self.historyLimit { backPlaces.removeFirst() }
            forwardPlaces.removeAll()
        }
        place = now
        updateHistoryFlags()
    }

    func goBack() { move(-1) }
    func goForward() { move(1) }

    /// Starts the history afresh from where the pane is (after restoring the last view at launch).
    func resetNavigationHistory() {
        place = Place(source: source, albumKey: albumKey)
        backPlaces.removeAll()
        forwardPlaces.removeAll()
        updateHistoryFlags()
    }

    private func move(_ direction: Int) {
        while var next = direction < 0 ? backPlaces.popLast() : forwardPlaces.popLast() {
            // A removed album leaves its page; a deleted playlist is skipped.
            if let key = next.albumKey, albumGroup(for: key) == nil { next.albumKey = nil }
            if case .playlist(let id) = next.source, playlist(id: id) == nil { continue }
            guard next != place else { continue }
            if direction < 0 { forwardPlaces.append(place) } else { backPlaces.append(place) }
            movingThroughHistory = true
            source = next.source
            albumKey = next.albumKey
            movingThroughHistory = false
            navigationMove = NavigationMove(direction: direction, serial: navigationMove.serial + 1)
            break
        }
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        if canGoBack != !backPlaces.isEmpty { canGoBack = !backPlaces.isEmpty }
        if canGoForward != !forwardPlaces.isEmpty { canGoForward = !forwardPlaces.isEmpty }
    }
    /// Narrows the visible list as you type: every word must match the
    /// title, artist, album, album artist, genre, or composer.
    @Published var filterText = "" {
        didSet { if filterText != oldValue { rebuildVisible() } }
    }

    @Published private(set) var scan: ScanProgress?
    @Published private(set) var pendingDuplicates: [DuplicateGroup] = []

    // MARK: Derived state

    @Published private(set) var visibleTracks: [Track] = []
    /// Total length of `visibleTracks`, kept with it so views needn't sum.
    private(set) var visibleDuration: TimeInterval = 0
    @Published private(set) var albumGroups: [AlbumGroup] = []
    @Published private(set) var genres: [GenreNode] = []
    @Published private(set) var artistGroups: [ArtistGroup] = []
    @Published private(set) var likedCount = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    private(set) var playlistCounts: [UUID: Int] = [:]
    private(set) var playlistCovers: [UUID: String] = [:]

    private var indexByID: [UUID: Int] = [:]
    private var tracksByAlbum: [String: [Track]] = [:]
    /// Each track's folded search text, built on first use of the filter.
    private var searchText: [UUID: String] = [:]
    /// The last filter's input and result, so typing more narrows that
    /// result instead of searching everything again.
    private var lastFilter: (source: LibrarySource, text: String, base: [Track], result: [Track])?
    /// Set by `update` when only play counts, play dates, or likes changed:
    /// nothing the album, artist, and genre lists or the search depend on.
    private var lightChange: Set<UUID>?

    // MARK: Storage

    let artwork: ArtworkStore
    /// Where the library, artwork, and scan index live.
    let supportDirectory: URL
    private let libraryFileURL: URL
    private let writer: CoalescingFileWriter
    private var isBatching = false
    private var pendingImports: [URL] = []
    /// Run once every queued import has finished.
    private var importCompletions: [() -> Void] = []

    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "aifc", "caf", "alac"]

    private static let ignoredDuplicatesKey = "com.meimei.player.ignoredDuplicateKeys"
    private static let starterPlaylistsKey = "com.meimei.player.smartPlaylistsSeeded.v1"

    init(supportDirectory: URL = LibraryStore.defaultSupportDirectory()) {
        let fm = FileManager.default
        self.supportDirectory = supportDirectory
        let artworkDirectory = supportDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try? fm.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        artwork = ArtworkStore(directory: artworkDirectory)
        libraryFileURL = supportDirectory.appendingPathComponent("library.json")
        writer = CoalescingFileWriter(url: libraryFileURL, label: "meimei.library-writer")

        isBatching = true
        load()
        seedStarterPlaylistsIfNeeded()
        isBatching = false
        rebuildDerived()
        rebuildVisible()
        scheduleWarmCaches()

        shareAlbumArtwork()
        detectDuplicates()
        pruneArtworkCache()
        repairLosslessBitDepthsIfNeeded()
    }

    nonisolated static func defaultSupportDirectory() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MEIMEI_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MeimeiPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Lookups

    func track(id: UUID) -> Track? {
        indexByID[id].map { tracks[$0] }
    }

    func tracks(ids: some Sequence<UUID>) -> [Track] {
        ids.compactMap { track(id: $0) }
    }

    func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func tracks(inAlbum key: String) -> [Track] {
        tracksByAlbum[key] ?? []
    }

    func albumGroup(for key: String) -> AlbumGroup? {
        albumGroups.first { $0.key == key }
    }

    /// The tracks a playlist plays, in order.
    func contents(of playlist: Playlist) -> [Track] {
        playlist.isSmart ? playlist.resolveSmart(from: tracks) : tracks(ids: playlist.trackIDs)
    }

    var manualPlaylists: [Playlist] { playlists.filter { !$0.isSmart } }

    /// True when the visible list has a meaningful hand-made order the user can rearrange.
    var visibleListIsReorderable: Bool {
        if albumKey != nil { return false }
        if case .playlist(let id) = source, let p = playlist(id: id) { return !p.isSmart }
        return false
    }

    var sourceTitle: String {
        if let albumKey, let album = albumGroup(for: albumKey) { return album.title }
        switch source {
        case .all: return "All Music"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .artist(let a): return a
        case .genre(let g): return g
        case .liked: return "Liked Songs"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .playlist(let id): return playlist(id: id)?.name ?? "Playlist"
        case .profile: return "Profile"
        }
    }

    // MARK: - Derived rebuilds

    private func tracksDidChange() {
        guard !isBatching else { return }
        if let ids = lightChange {
            lightChange = nil
            patchDerived(ids)
        } else {
            tracksVersion &+= 1
            searchText = [:]
            rebuildDerived()
            scheduleWarmCaches()
        }
        lastFilter = nil
        rebuildVisible()
        scheduleSave()
    }

    private var warmWork: DispatchWorkItem?

    /// Builds the search index and the common sort ranks off the main
    /// thread once the library settles, so the first filter keystroke or
    /// column click after launch or an import doesn't pay for them.
    private func scheduleWarmCaches() {
        warmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.tracks
            let version = self.tracksVersion
            Task.detached(priority: .utility) {
                var index: [UUID: String] = [:]
                index.reserveCapacity(snapshot.count)
                for t in snapshot { index[t.id] = LibraryStore.searchHaystack(t) }
                let ranks = ["title", "artist", "album"].map { ($0, TextRanks.compute($0, ascending: true, over: snapshot)) }
                await MainActor.run {
                    guard self.tracksVersion == version else { return }
                    if self.searchText.isEmpty { self.searchText = index }
                    for (key, r) in ranks { TextRanks.store(r, for: key, ascending: true, version: version) }
                }
            }
        }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// The cheap counterpart of `rebuildDerived` for play counts, play
    /// dates, and likes: same order, same albums, artists, and genres.
    private func patchDerived(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = indexByID[id] else { continue }
            let t = tracks[i]
            if let j = tracksByAlbum[t.albumKey]?.firstIndex(where: { $0.id == id }) { tracksByAlbum[t.albumKey]?[j] = t }
        }
        let liked = tracks.reduce(0) { $0 + ($1.liked ? 1 : 0) }
        if liked != likedCount { likedCount = liked }
        rebuildPlaylistSummaries()
    }

    private func playlistsDidChange() {
        guard !isBatching else { return }
        lastFilter = nil
        if case .playlist(let id) = source, playlist(id: id) == nil {
            source = .all
        }
        rebuildPlaylistSummaries()
        rebuildVisible()
        scheduleSave()
    }

    private func rebuildDerived() {
        var index: [UUID: Int] = [:]
        index.reserveCapacity(tracks.count)
        var byAlbum: [String: [Track]] = [:]
        var genreCounts: [String: Int] = [:]
        var liked = 0
        var total: TimeInterval = 0
        for (i, t) in tracks.enumerated() {
            index[t.id] = i
            byAlbum[t.albumKey, default: []].append(t)
            genreCounts[t.genre, default: 0] += 1
            if t.liked { liked += 1 }
            total += t.duration
        }
        for key in byAlbum.keys { byAlbum[key]?.sort(by: Track.albumOrder) }

        indexByID = index
        tracksByAlbum = byAlbum
        likedCount = liked
        totalDuration = total
        genres = genreCounts
            .map { GenreNode(name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        albumGroups = AlbumGroup.groups(byAlbum: byAlbum)

        var byArtist: [String: (albums: Set<String>, tracks: Int, art: String?)] = [:]
        for t in tracks {
            let name = t.displayArtist
            var entry = byArtist[name] ?? ([], 0, nil)
            entry.albums.insert(t.albumKey)
            entry.tracks += 1
            if entry.art == nil { entry.art = t.artworkFilePath }
            byArtist[name] = entry
        }
        artistGroups = byArtist
            .map { ArtistGroup(name: $0.key, albumCount: $0.value.albums.count, trackCount: $0.value.tracks, artworkFilePath: $0.value.art) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        rebuildPlaylistSummaries()
    }

    private func rebuildPlaylistSummaries() {
        var counts: [UUID: Int] = [:]
        var covers: [UUID: String] = [:]
        for playlist in playlists {
            let members = contents(of: playlist)
            counts[playlist.id] = members.count
            covers[playlist.id] = members.first { $0.artworkFilePath != nil }?.artworkFilePath
        }
        playlistCounts = counts
        playlistCovers = covers
    }

    private func rebuildVisible() {
        let list = LibraryRules.base(for: source, tracks: tracks, playlist: { self.playlist(id: $0) }, contents: { self.contents(of: $0) })
        let result: [Track]
        let text = filterText
        if text.split(separator: " ").isEmpty {
            result = list
            lastFilter = nil
        } else {
            // Typing more only narrows: search the last result, if it came
            // from the same list.
            let narrowing = lastFilter.flatMap { last in
                last.source == source && text.hasPrefix(last.text) && last.base.elementsEqualByIdentity(list) ? last.result : nil
            }
            result = filter(narrowing ?? list, by: text)
            lastFilter = (source, text, list, result)
        }
        visibleDuration = result.reduce(0) { $0 + $1.duration }
        visibleTracks = result
    }

    /// `Self.filter` with each track's folded text cached.
    private func filter(_ list: [Track], by text: String) -> [Track] {
        let words = Self.searchWords(text)
        guard !words.isEmpty else { return list }
        if searchText.isEmpty {
            searchText.reserveCapacity(tracks.count)
            for t in tracks { searchText[t.id] = Self.searchHaystack(t) }
        }
        return list.filter { t in
            let hay = searchText[t.id] ?? Self.searchHaystack(t)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    nonisolated static func searchWords(_ text: String) -> [String] { LibraryRules.searchWords(text) }
    nonisolated static func searchHaystack(_ t: Track) -> String { LibraryRules.searchHaystack(t) }
    nonisolated static func filter(_ list: [Track], by text: String) -> [Track] { LibraryRules.filter(list, by: text) }

    // MARK: - Track mutations

    /// Applies `body` to each listed track in one published change.
    func update(_ ids: Set<UUID>, _ body: (inout Track) -> Void) {
        guard !ids.isEmpty else { return }
        var copy = tracks
        var changed = false
        var light = true
        for id in ids {
            guard let i = indexByID[id] else { continue }
            let before = copy[i]
            body(&copy[i])
            if copy[i] != before {
                changed = true
                var stripped = copy[i]
                stripped.playCount = before.playCount
                stripped.lastPlayedAt = before.lastPlayedAt
                stripped.liked = before.liked
                if stripped != before { light = false }
            }
        }
        if changed {
            lightChange = light ? ids : nil
            tracks = copy
        }
    }

    func setLiked(_ ids: Set<UUID>, _ liked: Bool) {
        update(ids) { $0.liked = liked }
    }

    /// A listen was sealed into the history.
    func recordPlay(_ id: UUID, at date: Date = Date()) {
        update([id]) {
            $0.playCount += 1
            $0.lastPlayedAt = max($0.lastPlayedAt ?? date, date)
        }
    }

    /// Play counts and last-played dates come only from the listening
    /// history; whatever the library file says is replaced.
    func applyListenStats(_ stats: ListenStats) {
        update(Set(tracks.map(\.id))) { t in
            let e = stats.entry(for: t)
            t.playCount = e?.count ?? 0
            t.lastPlayedAt = e?.last
        }
    }

    /// Replaces a track's metadata (Get Info), re-sorting if its place in
    /// the library changed.
    func replaceTrack(_ track: Track) {
        guard let i = indexByID[track.id] else { return }
        var copy = tracks
        let moved = Track.libraryOrder(copy[i], track) || Track.libraryOrder(track, copy[i])
        copy[i] = track
        if moved { copy.sort(by: Track.libraryOrder) }
        tracks = copy
    }

    /// Replaces many tracks in one change (one re-sort, one save).
    func replaceTracks(_ updated: [Track]) {
        guard !updated.isEmpty else { return }
        var copy = tracks
        var changed = false
        for t in updated {
            if let i = indexByID[t.id], copy[i] != t { copy[i] = t; changed = true }
        }
        guard changed else { return }
        copy.sort(by: Track.libraryOrder)
        tracks = copy
    }

    func removeTracks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        isBatching = true
        playlists = playlists.map { p in
            var p = p
            p.trackIDs.removeAll { ids.contains($0) }
            return p
        }
        isBatching = false
        tracks.removeAll { ids.contains($0.id) }
    }

    // MARK: - Artwork

    func storeArtwork(_ data: Data) -> String? {
        artwork.store(data)
    }

    /// Points every track on an album at one cover.
    func applyArtworkToAlbum(_ albumKey: String, path: String) {
        let ids = Set(tracks(inAlbum: albumKey).map(\.id))
        update(ids) { $0.artworkFilePath = path }
        ArtworkCache.shared.invalidate(path)
    }

    /// Tracks without art inherit the cover of any other track on their album.
    private func shareAlbumArtwork() {
        var cover: [String: String] = [:]
        for t in tracks {
            if let path = t.artworkFilePath, cover[t.albumKey] == nil { cover[t.albumKey] = path }
        }
        let missing = Set(tracks.filter { $0.artworkFilePath == nil && cover[$0.albumKey] != nil }.map(\.id))
        update(missing) { $0.artworkFilePath = cover[$0.albumKey] }
    }

    func pruneArtworkCache() {
        let referenced = Set(tracks.compactMap(\.artworkFilePath))
        let store = artwork
        Task.detached(priority: .background) {
            store.prune(keeping: referenced)
        }
    }

    // MARK: - Importing

    /// Imports audio files and folders. Files already in the library are
    /// skipped before any metadata is read; new tracks land in batches so a
    /// large import fills in progressively.
    func importItems(_ urls: [URL], completion: (() -> Void)? = nil) {
        if let completion { importCompletions.append(completion) }
        guard !urls.isEmpty else {
            if scan == nil { runImportCompletions() }
            return
        }
        if scan != nil {
            pendingImports.append(contentsOf: urls)
            return
        }
        let known = Set(tracks.map(\.filePath))
        let store = artwork
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        scan = ScanProgress(completed: 0, total: 0, label: label)

        Task.detached(priority: .userInitiated) { [weak self] in
            var seen = Set<String>()
            let files = urls
                .flatMap(Self.audioFiles(under:))
                .filter { !known.contains($0.path) && seen.insert($0.path).inserted }
            await self?.updateScan(completed: 0, total: files.count)

            var batch: [Track] = []
            var completed = 0
            var lastFlush = Date()
            await withTaskGroup(of: Track?.self) { group in
                var iterator = files.makeIterator()
                for _ in 0..<min(8, files.count) {
                    if let url = iterator.next() {
                        group.addTask { await MetadataReader.readTrack(url: url, artwork: store) }
                    }
                }
                while let result = await group.next() {
                    completed += 1
                    if let result { batch.append(result) }
                    if let url = iterator.next() {
                        group.addTask { await MetadataReader.readTrack(url: url, artwork: store) }
                    }
                    if batch.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.75 {
                        let flushed = batch
                        batch.removeAll()
                        lastFlush = Date()
                        await self?.merge(flushed, completed: completed)
                    }
                }
            }
            await self?.merge(batch, completed: completed)
            await self?.finishImport()
        }
    }

    private func updateScan(completed: Int, total: Int) {
        scan?.completed = completed
        scan?.total = total
    }

    private func merge(_ newTracks: [Track], completed: Int) {
        scan?.completed = completed
        guard !newTracks.isEmpty else { return }
        let existing = Set(tracks.map(\.filePath))
        let fresh = newTracks.filter { !existing.contains($0.filePath) }
        guard !fresh.isEmpty else { return }
        tracks = (tracks + fresh).sorted(by: Track.libraryOrder)
    }

    private func finishImport() {
        scan = nil
        shareAlbumArtwork()
        detectDuplicates()
        if !pendingImports.isEmpty {
            let next = pendingImports
            pendingImports.removeAll()
            importItems(next)
        } else {
            runImportCompletions()
        }
    }

    private func runImportCompletions() {
        let done = importCompletions
        importCompletions.removeAll()
        done.forEach { $0() }
    }

    /// Points tracks at files that moved, keeping everything else about them.
    func relink(_ moves: [UUID: String]) {
        guard !moves.isEmpty else { return }
        var copy = tracks
        for (id, path) in moves {
            if let i = indexByID[id] { copy[i].filePath = path }
        }
        tracks = copy
    }

    /// Re-reads tags and technical info from disk, keeping library-only
    /// state (play history, likes, date added, a cover set by hand).
    func refreshFromFiles(_ ids: Set<UUID>, completion: ((Int) -> Void)? = nil) {
        let targets = tracks(ids: ids)
        guard !targets.isEmpty else { completion?(0); return }
        let store = artwork
        Task.detached(priority: .userInitiated) { [weak self] in
            var refreshed: [Track] = []
            for old in targets {
                guard var fresh = await MetadataReader.readTrack(url: old.url, artwork: store) else { continue }
                fresh = Track(
                    id: old.id, filePath: old.filePath, title: fresh.title, artist: fresh.artist, album: fresh.album,
                    albumArtist: fresh.albumArtist, genre: fresh.genre, composer: fresh.composer, year: fresh.year,
                    trackNumber: fresh.trackNumber, discNumber: fresh.discNumber, duration: fresh.duration,
                    sampleRate: fresh.sampleRate, bitDepth: fresh.bitDepth, channelCount: fresh.channelCount,
                    estimatedBitrateKbps: fresh.estimatedBitrateKbps, fileFormat: fresh.fileFormat,
                    artworkFilePath: fresh.artworkFilePath ?? old.artworkFilePath, dateAdded: old.dateAdded,
                    playCount: old.playCount, lastPlayedAt: old.lastPlayedAt, liked: old.liked
                )
                refreshed.append(fresh)
            }
            await self?.applyRefreshed(refreshed)
            await MainActor.run { completion?(refreshed.count) }
        }
    }

    private func applyRefreshed(_ refreshed: [Track]) {
        guard !refreshed.isEmpty else { return }
        var copy = tracks
        for t in refreshed {
            if let i = indexByID[t.id] { copy[i] = t }
        }
        tracks = copy.sorted(by: Track.libraryOrder)
        shareAlbumArtwork()
    }

    /// Earlier builds recorded every FLAC/ALAC as 16-bit. Reading the real
    /// depth is a header peek per file, so it runs once in the background.
    private func repairLosslessBitDepthsIfNeeded() {
        let key = "com.meimei.player.losslessBitDepthRepaired.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let candidates = tracks.filter { $0.fileFormat == "FLAC" }.map { ($0.id, $0.url, $0.bitDepth) }
        // Only a real pass counts as done; an empty library has nothing to repair yet.
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            var depths: [UUID: Int] = [:]
            for (id, url, current) in candidates {
                if let depth = MetadataReader.losslessBitDepth(url: url, format: "FLAC"), depth != current {
                    depths[id] = depth
                }
            }
            await self?.applyBitDepths(depths, markDone: key)
        }
    }

    private func applyBitDepths(_ depths: [UUID: Int], markDone key: String) {
        update(Set(depths.keys)) { $0.bitDepth = depths[$0.id] ?? $0.bitDepth }
        UserDefaults.standard.set(true, forKey: key)
    }

    nonisolated private static func audioFiles(under url: URL) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return audioExtensions.contains(url.pathExtension.lowercased()) ? [url.standardizedFileURL] : []
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var results: [URL] = []
        for case let fileURL as URL in enumerator where audioExtensions.contains(fileURL.pathExtension.lowercased()) {
            results.append(fileURL.standardizedFileURL)
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String, trackIDs: [UUID] = []) -> UUID {
        let playlist = Playlist(name: name, trackIDs: trackIDs)
        playlists.append(playlist)
        source = .playlist(playlist.id)
        return playlist.id
    }

    func createSmartPlaylist(named name: String, rules: [SmartRule], matchAll: Bool, order: SmartOrder, limit: Int?) {
        let playlist = Playlist(name: name, isSmart: true, matchAll: matchAll, rules: rules, smartOrder: order, smartLimit: limit)
        playlists.append(playlist)
        source = .playlist(playlist.id)
    }

    func updateSmartPlaylist(_ id: UUID, name: String, rules: [SmartRule], matchAll: Bool, order: SmartOrder, limit: Int?) {
        modifyPlaylist(id) {
            $0.name = name
            $0.rules = rules
            $0.matchAll = matchAll
            $0.smartOrder = order
            $0.smartLimit = limit
        }
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modifyPlaylist(id) { $0.name = trimmed }
    }

    func removePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    func movePlaylists(from offsets: IndexSet, to destination: Int) {
        var copy = playlists
        let moving = offsets.map { copy[$0] }
        for i in offsets.sorted(by: >) { copy.remove(at: i) }
        let insertAt = destination - offsets.filter { $0 < destination }.count
        copy.insert(contentsOf: moving, at: max(0, min(insertAt, copy.count)))
        playlists = copy
    }

    /// Appends tracks to a manual playlist, skipping ones already in it.
    func addTracks(_ ids: [UUID], toPlaylist playlistID: UUID) {
        modifyPlaylist(playlistID) { p in
            guard !p.isSmart else { return }
            var existing = Set(p.trackIDs)
            for id in ids where existing.insert(id).inserted {
                p.trackIDs.append(id)
            }
        }
    }

    func removeTracks(_ ids: Set<UUID>, fromPlaylist playlistID: UUID) {
        modifyPlaylist(playlistID) { $0.trackIDs.removeAll { ids.contains($0) } }
    }

    /// Moves the given tracks so they sit before `index` in the playlist.
    func moveTracks(_ ids: [UUID], inPlaylist playlistID: UUID, to index: Int) {
        modifyPlaylist(playlistID) { p in
            let moving = Set(ids)
            let before = p.trackIDs.prefix(index).filter { !moving.contains($0) }
            let after = p.trackIDs.dropFirst(index).filter { !moving.contains($0) }
            let ordered = p.trackIDs.filter { moving.contains($0) }
            p.trackIDs = Array(before) + ordered + Array(after)
        }
    }

    private func modifyPlaylist(_ id: UUID, _ body: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var copy = playlists
        body(&copy[i])
        if copy[i] != playlists[i] { playlists = copy }
    }

    private func seedStarterPlaylistsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.starterPlaylistsKey) else { return }
        let starters: [(String, [SmartRule], SmartOrder)] = [
            ("Hi-Res", [SmartRule(field: .hiRes, op: .isTrue)], .library),
            ("Recently Added", [SmartRule(field: .addedDaysAgo, op: .lte, value: "30")], .recentlyAdded),
            ("Unplayed", [SmartRule(field: .playCount, op: .equals, value: "0")], .library)
        ]
        for (name, rules, order) in starters where !playlists.contains(where: { $0.isSmart && $0.name == name }) {
            playlists.append(Playlist(name: name, isSmart: true, rules: rules, isBuiltIn: true, smartOrder: order))
        }
        UserDefaults.standard.set(true, forKey: Self.starterPlaylistsKey)
    }

    // MARK: - Duplicates

    /// Finds duplicates among tracks whose files exist. A copy whose file
    /// is gone, with a live copy of the same song (the album was deleted
    /// and downloaded again), isn't a duplicate: it's replaced by the live
    /// one, which takes over its plays, likes, date added, and playlists.
    func detectDuplicates() {
        let snapshot = tracks
        let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredDuplicatesKey) ?? [])
        Task.detached(priority: .utility) { [weak self] in
            let fm = FileManager.default
            var gone = Set<UUID>()
            var replacements: [(stale: Track, keep: UUID)] = []
            for members in Dictionary(grouping: snapshot, by: \.duplicateSongKey).values where members.count > 1 {
                let missing = members.filter { !fm.fileExists(atPath: $0.filePath) }
                let present = members.filter { fm.fileExists(atPath: $0.filePath) }
                missing.forEach { gone.insert($0.id) }
                guard let keep = present.max(by: { $0.dateAdded < $1.dateAdded }) else { continue }
                replacements += missing.map { ($0, keep.id) }
            }
            let live = snapshot.filter { !gone.contains($0.id) }
            let groups = DuplicateFinder.groups(in: live).filter { !ignored.contains($0.id) }
            await self?.replaceStaleCopies(replacements)
            await self?.setPendingDuplicates(groups)
        }
    }

    private func replaceStaleCopies(_ replacements: [(stale: Track, keep: UUID)]) {
        guard !replacements.isEmpty else { return }
        var copy = tracks
        var swap: [UUID: UUID] = [:]
        for (stale, keepID) in replacements {
            guard indexByID[stale.id] != nil, let i = indexByID[keepID] else { continue }
            copy[i].playCount += stale.playCount
            copy[i].liked = copy[i].liked || stale.liked
            copy[i].dateAdded = min(copy[i].dateAdded, stale.dateAdded)
            if let played = stale.lastPlayedAt { copy[i].lastPlayedAt = max(copy[i].lastPlayedAt ?? played, played) }
            swap[stale.id] = keepID
        }
        guard !swap.isEmpty else { return }
        isBatching = true
        playlists = playlists.map { p in
            var p = p
            var seen = Set<UUID>()
            p.trackIDs = p.trackIDs.map { swap[$0] ?? $0 }.filter { seen.insert($0).inserted }
            return p
        }
        isBatching = false
        tracks = copy.filter { swap[$0.id] == nil }
    }

    private func setPendingDuplicates(_ groups: [DuplicateGroup]) {
        pendingDuplicates = groups
    }

    func dismissDuplicatesKeepingAll() {
        ignoreDuplicateGroups(pendingDuplicates.map(\.id))
        pendingDuplicates = []
    }

    func deferDuplicates() {
        pendingDuplicates = []
    }

    func resolveDuplicates(keeping ids: Set<UUID>) {
        let groups = pendingDuplicates
        let extras = Set(groups.flatMap { $0.tracks.map(\.id) }).subtracting(ids)
        pendingDuplicates = []
        removeTracks(extras)
        ignoreDuplicateGroups(DuplicateFinder.groups(in: tracks).map(\.id))
    }

    private func ignoreDuplicateGroups(_ ids: [String]) {
        var ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredDuplicatesKey) ?? [])
        ignored.formUnion(ids)
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredDuplicatesKey)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !isBatching else { return }
        let snapshot = LibraryFile(tracks: tracks, playlists: playlists)
        writer.schedule { try snapshot.encoded() }
    }

    /// Writes any pending change to disk now.
    func flush() {
        writer.flush()
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryFileURL) else { return }
        do {
            let file = try LibraryFile.read(data)
            tracks = file.tracks
            playlists = file.playlists
        } catch {
            // Never overwrite a library file this build can't read.
            let backup = libraryFileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: libraryFileURL, to: backup)
            NSLog("i2s: library.json could not be decoded (%@); a copy was kept at %@", String(describing: error), backup.path)
        }
    }
}


private extension Array where Element == Track {
    /// Same count and the same track ids in the same order. Cheaper than
    /// `==`, and enough to tell whether a cached result still applies when
    /// the tracks themselves were replaced (which resets the cache anyway).
    func elementsEqualByIdentity(_ other: [Track]) -> Bool {
        guard count == other.count else { return false }
        return withUnsafeBufferPointer { a in other.withUnsafeBufferPointer { b in
            a.baseAddress == b.baseAddress || zip(a, b).allSatisfy { $0.id == $1.id }
        } }
    }
}
