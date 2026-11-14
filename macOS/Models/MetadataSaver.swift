import Foundation

/// Saves metadata edits: the library first (instantly), then, if asked,
/// each changed file's tags in the background, with progress and a list
/// of files that couldn't be written. A save can be cancelled between files.
@MainActor
final class MetadataSaver: ObservableObject {
    struct Failure: Identifiable, Hashable {
        var id: UUID
        var title: String
        var reason: String
    }

    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var failures: [Failure] = []
    @Published private(set) var lastMessage: String?

    var isSaving: Bool { progress != nil }

    private let library: LibraryStore
    private var cancelled = false

    init(library: LibraryStore) {
        self.library = library
    }

    func cancel() { cancelled = true }

    /// Saves `edited` (only tracks that differ from the library are
    /// touched). `cover` replaces the cover of every edited track; `removeCover`
    /// clears it in the library (files keep theirs).
    func save(_ edited: [Track], cover: Data? = nil, removeCover: Bool = false, writeFiles: Bool) async {
        var updated = edited
        var coverPath: String?
        if let cover, let path = library.storeArtwork(cover) {
            coverPath = path
            for i in updated.indices { updated[i].artworkFilePath = path }
            ArtworkCache.shared.invalidate(path)
        } else if removeCover {
            for i in updated.indices { updated[i].artworkFilePath = nil }
        }
        let changed = updated.filter { library.track(id: $0.id) != $0 }
        guard !changed.isEmpty else {
            lastMessage = "Nothing to save."
            return
        }
        library.replaceTracks(changed)
        failures = []
        guard writeFiles else {
            lastMessage = "Saved \(LibraryFormat.count(changed.count, "track")) to the library."
            return
        }

        let writable = changed.filter { MetadataWriter.canWrite($0.url) }
        let jpeg = coverPath.flatMap { FileManager.default.contents(atPath: $0) }
        cancelled = false
        progress = (0, writable.count)
        var written = 0
        for track in writable {
            if cancelled { break }
            let fields = MetadataWriter.Fields(track)
            let url = track.url
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await MetadataWriter.write(fields, artworkJPEG: jpeg, to: url)
                }.value
                written += 1
            } catch {
                failures.append(Failure(id: track.id, title: track.title, reason: error.localizedDescription))
            }
            progress = (written + failures.count, writable.count)
        }
        progress = nil
        let skipped = changed.count - writable.count
        var parts = ["Saved \(LibraryFormat.count(changed.count, "track"))", "tags written to \(LibraryFormat.count(written, "file"))"]
        if skipped > 0 { parts.append("\(skipped) library-only (format can't be tagged)") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if cancelled { parts.append("stopped early") }
        lastMessage = parts.joined(separator: " · ") + "."
    }
}
