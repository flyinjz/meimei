import Foundation

/// Lyrics for the playing track: a `.lrc` next to the audio file
/// (`Song.flac` → `Song.lrc`), or plain unsynced text.
@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    /// False for plain lyrics with no timestamps — shown, but not followed.
    @Published private(set) var isSynced = false
    @Published private(set) var sourceLabel = ""
    @Published var offset: Double = 0

    private var loadedPath: String?

    static func lrcURL(for track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    func load(for track: Track?) {
        guard track?.filePath != loadedPath else { return }
        loadedPath = track?.filePath
        lines = []
        isSynced = false
        sourceLabel = ""
        guard let track else { return }
        let url = Self.lrcURL(for: track)
        if let raw = Self.readText(url) {
            apply(raw, label: url.lastPathComponent)
            return
        }
        // No .lrc: lyrics embedded in the file's tags, read off the main thread.
        let path = track.filePath
        let audio = track.url
        Task {
            let embedded = await Task.detached(priority: .userInitiated) { await EmbeddedLyrics.read(audio) }.value
            guard let embedded, self.loadedPath == path else { return }
            self.apply(embedded, label: "in the file's tags")
        }
    }

    /// Re-reads the current track's lyrics (after they were found or saved).
    func reload(_ track: Track?) {
        loadedPath = nil
        load(for: track)
    }

    func apply(_ raw: String, label: String) {
        let read = Lyrics.read(raw)
        lines = read.lines
        isSynced = read.synced
        sourceLabel = lines.isEmpty ? "" : label
    }

    /// Writes `raw` as the track's `.lrc`, or deletes it when `raw` is empty.
    @discardableResult
    func save(_ raw: String, for track: Track) -> Bool {
        let url = Self.lrcURL(for: track)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                try trimmed.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            return false
        }
        if track.filePath == loadedPath {
            loadedPath = nil
            load(for: track)
        }
        return true
    }

    /// Index of the line being sung at `playbackTime`, or nil before the first.
    func currentIndex(at playbackTime: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        return Lyrics.currentIndex(in: lines, at: playbackTime + offset)
    }

    static func readText(_ url: URL) -> String? { Lyrics.readText(url) }

    static func parse(_ raw: String) -> [LyricLine] { Lyrics.parse(raw) }
}
