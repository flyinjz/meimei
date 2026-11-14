import Foundation

/// What a track has: synced (timed) lyrics, plain text, or none.
enum LyricsState: String, Codable {
    case synced, plain, none

    /// Timed lines like "[01:23.45]".
    nonisolated static func of(_ raw: String?) -> LyricsState {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        return raw.range(of: #"\[\d{1,3}:\d{1,2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil ? .synced : .plain
    }
}

/// Finds lyrics online for many tracks at once (lrclib.net, on request,
/// straight from this Mac), saves them as the settings say, and keeps an
/// index of which tracks have lyrics so coverage is instant.
@MainActor
final class LyricsFinder: ObservableObject {
    enum Outcome: Equatable {
        case synced, plain, notFound, kept, failed(String), unavailable(String)
    }

    struct Report: Equatable {
        var synced = 0, plain = 0, notFound = 0, kept = 0, failed = 0, unavailable = 0
        /// Why the sources didn't answer, when they didn't.
        var problem: String?
        var total: Int { synced + plain + notFound + kept + failed + unavailable }
        var summary: String {
            var parts = ["\(synced + plain) found (\(synced) synced)", "\(notFound) not found"]
            if kept > 0 { parts.append("\(kept) already had lyrics") }
            if unavailable > 0 { parts.append("\(unavailable) not searched: \(problem ?? "sources unavailable")") }
            if failed > 0 { parts.append("\(failed) couldn't be saved") }
            return parts.joined(separator: " · ")
        }
    }

    /// Known lyrics per track (absent: not checked yet).
    @Published private(set) var states: [UUID: LyricsState] = [:]
    @Published private(set) var checking: (done: Int, total: Int)?
    @Published private(set) var searching: (done: Int, total: Int)?
    @Published private(set) var report: Report?
    /// Each track's outcome in the latest search.
    @Published private(set) var outcomes: [UUID: Outcome] = [:]

    var isBusy: Bool { searching != nil }

    private let library: LibraryStore
    private let indexURL: URL
    private struct Entry: Codable { var modified: Double; var state: LyricsState }
    private var index: [String: Entry] = [:]
    private var cancelled = false

    init(library: LibraryStore) {
        self.library = library
        indexURL = library.supportDirectory.appendingPathComponent("lyrics-index.json")
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = saved
        }
        refreshStatesFromIndex()
    }

    func cancel() { cancelled = true }

    // MARK: Coverage

    private func refreshStatesFromIndex() {
        var s: [UUID: LyricsState] = [:]
        for t in library.tracks { if let e = index[t.filePath] { s[t.id] = e.state } }
        states = s
    }

    /// Looks at every track's .lrc and tags (only files that changed since
    /// last time), in the background.
    func checkCoverage() {
        guard checking == nil else { return }
        let tracks = library.tracks
        let known = index
        checking = (0, tracks.count)
        Task.detached(priority: .utility) { [weak self] in
            var updated = known
            for (i, t) in tracks.enumerated() {
                let modified = Self.modified(t)
                if let e = known[t.filePath], e.modified == modified { continue }
                updated[t.filePath] = Entry(modified: modified, state: await Self.state(of: t))
                if i % 200 == 0 { await MainActor.run { self?.checking = (i, tracks.count) } }
            }
            await MainActor.run {
                guard let self else { return }
                self.index = updated
                self.checking = nil
                self.refreshStatesFromIndex()
                self.saveIndex()
            }
        }
    }

    /// Newest of the audio file's and its .lrc's modification dates.
    nonisolated private static func modified(_ t: Track) -> Double {
        let fm = FileManager.default
        func date(_ path: String) -> Double {
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        }
        return max(date(t.filePath), date(t.url.deletingPathExtension().appendingPathExtension("lrc").path))
    }

    nonisolated private static func state(of t: Track) async -> LyricsState {
        let lrc = t.url.deletingPathExtension().appendingPathExtension("lrc")
        if let raw = try? String(contentsOf: lrc, encoding: .utf8), LyricsState.of(raw) != .none { return LyricsState.of(raw) }
        return LyricsState.of(await EmbeddedLyrics.read(t.url))
    }

    // MARK: Finding

    /// Searches lyrics for `tracks` and saves what it finds.
    func find(_ tracks: [Track]) async {
        guard searching == nil, !tracks.isEmpty else { return }
        let settings = AppSession.shared.settings.data
        let mode = settings.lyricsSaveMode
        let syncedOnly = settings.lyricsSyncedOnly
        let replace = settings.lyricsReplaceExisting
        let sources = settings.lyricsSources
        cancelled = false
        searching = (0, tracks.count)
        var report = Report()
        for t in tracks { outcomes[t.id] = nil }

        await withTaskGroup(of: (Track, Outcome, LyricsState?).self) { group in
            var queue = tracks.makeIterator()
            for _ in 0..<4 {
                guard let t = queue.next() else { break }
                group.addTask { await Self.process(t, mode: mode, syncedOnly: syncedOnly, replace: replace, sources: sources) }
            }
            var done = 0
            while let (track, outcome, state) = await group.next() {
                done += 1
                outcomes[track.id] = outcome
                switch outcome {
                case .synced: report.synced += 1
                case .plain: report.plain += 1
                case .notFound: report.notFound += 1
                case .kept: report.kept += 1
                case .failed: report.failed += 1
                case .unavailable(let why): report.unavailable += 1; report.problem = why
                }
                if let state {
                    index[track.filePath] = Entry(modified: Self.modified(track), state: state)
                    states[track.id] = state
                }
                searching = (done, tracks.count)
                if !cancelled, let t = queue.next() {
                    group.addTask { await Self.process(t, mode: mode, syncedOnly: syncedOnly, replace: replace, sources: sources) }
                }
            }
        }
        searching = nil
        self.report = report
        saveIndex()
        // The panel shows what was just found for the playing track.
        let player = AppSession.shared.player
        if let current = player.currentTrack, tracks.contains(where: { $0.id == current.id }) {
            AppSession.shared.lyrics.reload(current)
        }
    }

    nonisolated private static func process(_ t: Track, mode: LyricsSaveMode, syncedOnly: Bool,
                                            replace: Bool, sources: [LyricsSource]) async -> (Track, Outcome, LyricsState?) {
        let existing = await state(of: t)
        if existing != .none, !replace { return (t, .kept, existing) }
        let raw: String
        switch await LyricsLookup.fetch(t, sources: sources, syncedOnly: syncedOnly) {
        case .found(let text, _): raw = text
        case .notFound: return (t, .notFound, existing)
        case .unavailable(let why): return (t, .unavailable(why), existing)
        }
        let found = LyricsState.of(raw)
        if found == .none { return (t, .notFound, existing) }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let embed = (mode == .embedded || mode == .both) && MetadataWriter.canWrite(t.url)
        let lrc = mode == .lrcFile || mode == .both || !embed
        do {
            if lrc {
                try text.write(to: t.url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
            }
            if embed {
                try await MetadataWriter.write(MetadataWriter.Fields(t, lyrics: text), artworkJPEG: nil, to: t.url)
            }
        } catch {
            return (t, .failed(error.localizedDescription), existing)
        }
        return (t, found == .synced ? .synced : .plain, found)
    }

    private func saveIndex() {
        let snapshot = index
        let url = indexURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Opens the Library window at a place, from anywhere (the lyrics panel's
/// search button). Views pick the request up when they appear.
@MainActor
final class LibraryNavigator: ObservableObject {
    static let shared = LibraryNavigator()

    struct Request: Equatable {
        var id = UUID()
        var section: String
        var metadataMode: String?
        /// A track to act on there (look up its lyrics).
        var trackID: UUID?
    }

    @Published var request: Request?

    func open(section: String, metadataMode: String? = nil, trackID: UUID? = nil) {
        request = Request(section: section, metadataMode: metadataMode, trackID: trackID)
        WindowRequest.library.post()
    }
}
