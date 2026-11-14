import Foundation
import Combine

/// The process-wide model graph, shared by the main window and the mini
/// player, plus the wiring between its parts.
@MainActor
final class AppSession {
    static let shared = AppSession()

    let library = LibraryStore()
    let player = PlayerController()
    let theme = ThemeManager()
    let settings = AppSettings()
    let lyrics = LyricsStore()
    let customize = CustomizeStore()
    /// Library folders, scanning, and watching.
    lazy var scanner = LibraryScanner(library: library)
    /// Saves metadata edits to the library and the files.
    lazy var metadataSaver = MetadataSaver(library: library)
    /// Batch lyrics lookups and the index of which tracks have lyrics.
    lazy var lyricsFinder = LyricsFinder(library: library)
    /// Soulseek downloads; inert until the user enables and sets it up.
    lazy var soulseek = SoulseekStore()

    /// The sealed listening history; every play count comes from it.
    let history = ListenHistory()
    private var listenTracker: ListenTracker!

    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        // History keys live in the Secure Enclave on Macs that have one.
        HistoryKeys.maker = EnclaveKeyMaker()
        listenTracker = ListenTracker(player: player, history: history)
        player.onTrackCompleted = { [listenTracker] track in
            listenTracker?.completed(track)
        }
        history.onListen = { [library] listen in
            library.recordPlay(listen.trackID, at: listen.endedAt)
        }
        history.onReady = { [library, history] in
            library.applyListenStats(history.stats)
        }
        history.open(support: library.supportDirectory, seed: library.tracks)

        // Edited or removed tracks update the queue.
        library.$tracks
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // `$tracks` fires before the store's lookup tables rebuild; read them next turn.
                DispatchQueue.main.async {
                    self.player.refreshTracks { self.library.track(id: $0) }
                }
            }
            .store(in: &subscriptions)

        settings.$data
            .sink { [weak self] data in
                guard let self else { return }
                self.player.crossfadeSeconds = data.crossfadeSeconds
                self.lyrics.offset = data.lyricsOffset
                self.player.engine.spectrum.bandCount = data.spectrumBandCount
                self.theme.artworkBackdropEnabled = data.backdropStyle == .artwork
                IconTheme.shared.apply(pack: data.iconPack, scale: data.iconScale, overrides: data.iconOverrides)
            }
            .store(in: &subscriptions)

        // Cover-driven theme and lyrics follow the playing track.
        player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id && $0?.artworkFilePath == $1?.artworkFilePath }
            .sink { [weak self] track in
                self?.theme.ingestArtwork(at: track?.artworkFilePath)
                self?.lyrics.load(for: track)
            }
            .store(in: &subscriptions)

        scanner.start()

        if settings.data.resumeLastSession {
            player.restoreSession { [library] in library.track(id: $0) }
        }
    }

    /// Persists everything that's written lazily. Called on quit.
    func flush() {
        listenTracker.finish()
        history.flush()
        player.saveSession()
        library.flush()
    }
}
