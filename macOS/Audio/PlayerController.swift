import Foundation
import AppKit
import MediaPlayer

enum RepeatMode: String, CaseIterable, Codable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbolName: String { self == .one ? "repeat.1" : "repeat" }
}

/// The play queue and transport: what plays, in what order, and what comes
/// next. Wraps `AudioEngine` and publishes to Now Playing / media keys.
@MainActor
final class PlayerController: ObservableObject {

    /// Tracks in the order they were handed over (the source list's order).
    @Published private(set) var queue: [Track] = [] { didSet { syncCurrentTrack() } }
    /// Play order as indices into `queue` — identity, or a shuffle.
    @Published private(set) var order: [Int] = [] { didSet { syncCurrentTrack() } }
    /// Index into `order` of the current track.
    @Published private(set) var position: Int? { didSet { syncCurrentTrack() } }
    /// The track at `position`. Stored (not computed) so subscribers to
    /// `$currentTrack` receive the new track itself; `@Published` fires
    /// before the change, so reading derived state from another
    /// publisher's sink would see the previous track.
    @Published private(set) var currentTrack: Track?

    @Published var shuffle = false {
        didSet {
            guard shuffle != oldValue else { return }
            rebuildOrder()
            UserDefaults.standard.set(shuffle, forKey: Keys.shuffle)
        }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            prepareNext()
            UserDefaults.standard.set(repeatMode.rawValue, forKey: Keys.repeatMode)
        }
    }

    let engine = AudioEngine()
    let equalizer = EqualizerSettings()

    /// Fired when a track plays through to its end (not on skip).
    var onTrackCompleted: ((Track) -> Void)?
    /// What the play button starts when nothing has been queued yet.
    var fallbackSource: (() -> [Track])?

    /// Pause when the current track ends, then move on to the next (paused).
    @Published var stopAfterCurrent = false {
        didSet { if stopAfterCurrent != oldValue { prepareNext() } }
    }

    /// When the sleep timer will pause playback.
    @Published private(set) var sleepDeadline: Date?
    private var sleepTimer: Timer?

    /// Pauses after `minutes`, or cancels the timer when nil.
    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes else { sleepDeadline = nil; return }
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepDeadline = deadline
        sleepTimer = Timer.scheduledTimer(withTimeInterval: deadline.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.engine.isPlaying { self.engine.pause() }
                self.sleepDeadline = nil
                self.updateNowPlaying()
            }
        }
    }

    var crossfadeSeconds: Double {
        get { engine.crossfadeDuration }
        set { engine.crossfadeDuration = max(0, newValue) }
    }

    private func syncCurrentTrack() {
        let track: Track?
        if let position, order.indices.contains(position), queue.indices.contains(order[position]) {
            track = queue[order[position]]
        } else {
            track = nil
        }
        if track != currentTrack { currentTrack = track }
    }

    /// Tracks after the current one, in play order.
    var upNext: [Track] {
        guard let position else { return [] }
        return order.dropFirst(position + 1).map { queue[$0] }
    }

    private enum Keys {
        static let shuffle = "com.meimei.player.shuffle"
        static let repeatMode = "com.meimei.player.repeatMode"
        static let volume = "com.meimei.player.volume"
        static let session = "com.meimei.player.session.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        shuffle = defaults.bool(forKey: Keys.shuffle)
        repeatMode = defaults.string(forKey: Keys.repeatMode).flatMap(RepeatMode.init) ?? .off
        if defaults.object(forKey: Keys.volume) != nil {
            engine.volume = defaults.float(forKey: Keys.volume)
        }

        engine.onAdvance = { [weak self] id in self?.engineAdvanced(to: id) }
        engine.onEnded = { [weak self] in self?.reachedEnd() }
        equalizer.onChange = { [weak self] data, solo in self?.engine.applyEqualizer(data, solo: solo) }
        engine.applyEqualizer(equalizer.data, solo: nil)
        configureRemoteCommands()
    }

    // MARK: - Starting playback

    /// Replaces the queue with `tracks` and plays from `index`.
    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        order = Array(tracks.indices)
        if shuffle {
            var rest = order.filter { $0 != index }
            rest.shuffle()
            order = [index] + rest
            position = 0
        } else {
            position = index
        }
        startCurrent()
    }

    func play(track: Track, within context: [Track]) {
        if let index = context.firstIndex(where: { $0.id == track.id }) {
            play(context, startAt: index)
        } else {
            play([track])
        }
    }

    /// Inserts tracks right after the current one.
    func playNext(_ tracks: [Track]) {
        insert(tracks, afterCurrent: true)
    }

    /// Appends tracks to the end of the play order.
    func addToQueue(_ tracks: [Track]) {
        insert(tracks, afterCurrent: false)
    }

    private func insert(_ tracks: [Track], afterCurrent: Bool) {
        guard !tracks.isEmpty else { return }
        guard position != nil else {
            play(tracks)
            return
        }
        let start = queue.count
        queue.append(contentsOf: tracks)
        let newIndices = Array(start..<queue.count)
        if afterCurrent, let position {
            order.insert(contentsOf: newIndices, at: position + 1)
        } else {
            order.append(contentsOf: newIndices)
        }
        prepareNext()
    }

    /// Jumps to a position in the play order (Up Next list).
    func jump(toOrderIndex index: Int) {
        guard order.indices.contains(index) else { return }
        position = index
        startCurrent()
    }

    // MARK: - Transport

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
        } else if currentTrack != nil {
            if engine.currentID == currentTrack?.id {
                engine.play()
            } else {
                startCurrent()
            }
        } else if let tracks = fallbackSource?(), !tracks.isEmpty {
            play(tracks)
        }
        updateNowPlaying()
    }

    func next() {
        guard let position, !order.isEmpty else { return }
        if position + 1 < order.count {
            self.position = position + 1
        } else if repeatMode != .off {
            self.position = 0
        } else {
            stop()
            return
        }
        startCurrent()
    }

    func previous() {
        guard let position, !order.isEmpty else { return }
        if engine.currentTime > 3 || (position == 0 && repeatMode == .off) {
            seek(to: 0)
            return
        }
        self.position = position > 0 ? position - 1 : order.count - 1
        startCurrent()
    }

    func seek(to time: TimeInterval) {
        engine.seek(to: time)
        updateNowPlaying()
    }

    func stop() {
        engine.stop()
        position = nil
        updateNowPlaying()
    }

    func setVolume(_ volume: Float) {
        engine.volume = max(0, min(1, volume))
        UserDefaults.standard.set(engine.volume, forKey: Keys.volume)
    }

    // MARK: - Keeping the queue in sync with the library

    /// Swaps in edited copies of queued tracks and drops removed ones.
    func refreshTracks(lookup: (UUID) -> Track?) {
        guard !queue.isEmpty else { return }
        let currentID = currentTrack?.id
        var newQueue: [Track] = []
        var remap: [Int: Int] = [:]
        for (i, t) in queue.enumerated() {
            if let fresh = lookup(t.id) {
                remap[i] = newQueue.count
                newQueue.append(fresh)
            }
        }
        guard newQueue != queue else { return }
        let newOrder = order.compactMap { remap[$0] }
        queue = newQueue
        order = newOrder
        if let currentID {
            position = order.firstIndex { queue[$0].id == currentID }
            if position == nil { stop() }
        }
        prepareNext()
    }

    // MARK: - Internals

    private func rebuildOrder() {
        guard !queue.isEmpty else { return }
        let current = position.map { order[$0] }
        if shuffle {
            var rest = Array(queue.indices).filter { $0 != current }
            rest.shuffle()
            order = (current.map { [$0] } ?? []) + rest
            position = current == nil ? nil : 0
        } else {
            order = Array(queue.indices)
            position = current
        }
        prepareNext()
    }

    /// Starts the current track, skipping forward past files that can't be
    /// opened (at most one full pass through the queue).
    private func startCurrent() {
        var attempts = 0
        while let track = currentTrack, attempts < order.count {
            do {
                try engine.start(url: track.url, id: track.id)
                prepareNext()
                updateNowPlaying()
                saveSession()
                return
            } catch {
                NSLog("i2s: couldn't play %@: %@", track.filePath, String(describing: error))
                attempts += 1
                guard let position, position + 1 < order.count || repeatMode == .all else { break }
                self.position = (position + 1) % order.count
            }
        }
        stop()
    }

    private var nextOrderIndex: Int? {
        guard let position, !order.isEmpty else { return nil }
        if repeatMode == .one { return position }
        if position + 1 < order.count { return position + 1 }
        return repeatMode == .all ? 0 : nil
    }

    private func prepareNext() {
        guard !stopAfterCurrent, let index = nextOrderIndex else {
            engine.setNext(url: nil, id: nil)
            return
        }
        let track = queue[order[index]]
        engine.setNext(url: track.url, id: track.id)
    }

    /// The engine moved to the prepared next track on its own.
    private func engineAdvanced(to id: UUID) {
        if let finished = currentTrack { onTrackCompleted?(finished) }
        if let index = nextOrderIndex, queue[order[index]].id == id {
            position = index
        } else if let index = order.firstIndex(where: { queue[$0].id == id }) {
            position = index
        }
        prepareNext()
        updateNowPlaying()
        saveSession()
    }

    /// The last track ended with nothing after it: park on the first track, paused.
    private func reachedEnd() {
        if let finished = currentTrack { onTrackCompleted?(finished) }
        guard !order.isEmpty else { return }
        if stopAfterCurrent {
            stopAfterCurrent = false
            if let index = nextOrderIndex {
                position = index
                if let track = currentTrack { try? engine.start(url: track.url, id: track.id, autoplay: false) }
                prepareNext()
                updateNowPlaying()
                saveSession()
                return
            }
        }
        position = 0
        if let first = currentTrack {
            try? engine.start(url: first.url, id: first.id, autoplay: false)
            prepareNext()
        }
        updateNowPlaying()
        saveSession()
    }

    // MARK: - Session

    private struct Session: Codable {
        var trackIDs: [UUID]
        var order: [Int]
        var position: Int
        var time: TimeInterval
    }

    func saveSession() {
        guard let position, !queue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Keys.session)
            return
        }
        let session = Session(trackIDs: queue.map(\.id), order: order, position: position, time: engine.currentTime)
        DefaultsStore.save(session, key: Keys.session)
    }

    /// Reloads the last queue, paused where it was left.
    func restoreSession(lookup: (UUID) -> Track?) {
        guard let session = DefaultsStore.load(Session.self, key: Keys.session) else { return }
        var remap: [Int: Int] = [:]
        var tracks: [Track] = []
        for (i, id) in session.trackIDs.enumerated() {
            if let t = lookup(id) {
                remap[i] = tracks.count
                tracks.append(t)
            }
        }
        let restoredOrder = session.order.compactMap { remap[$0] }
        guard session.order.indices.contains(session.position),
              let current = remap[session.order[session.position]],
              let position = restoredOrder.firstIndex(of: current) else { return }
        queue = tracks
        order = restoredOrder
        self.position = position
        guard let track = currentTrack else { return }
        do {
            try engine.start(url: track.url, id: track.id, at: session.time, autoplay: false)
            prepareNext()
            updateNowPlaying()
        } catch {
            self.position = nil
        }
    }

    // MARK: - Now Playing & media keys

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.engine.isPlaying { self.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.engine.pause()
            self?.updateNowPlaying()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private var nowPlayingArtworkPath: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0
        ]
        if track.artworkFilePath != nowPlayingArtworkPath {
            nowPlayingArtworkPath = track.artworkFilePath
            nowPlayingArtwork = track.artworkFilePath
                .flatMap { ArtworkCache.shared.image($0, pixels: 512) }
                .map { image in MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        center.nowPlayingInfo = info
        center.playbackState = engine.isPlaying ? .playing : .paused
    }
}
