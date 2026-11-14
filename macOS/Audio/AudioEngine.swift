import Foundation
import AVFoundation

/// The playhead, published ~20×/s. Separate from `AudioEngine` so only the
/// handful of views that show time redraw on every tick.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var currentTime: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0
}

/// Gapless, crossfading playback on AVAudioEngine.
///
/// Two player "decks" feed one bus mixer → EQ → main mixer. The active deck
/// plays the current file; the controller hands over the next file with
/// `setNext`, and near the end of the current one the idle deck either
/// starts sample-accurately at the boundary (gapless) or fades in over the
/// tail (crossfade). Repeat-one is just "next is the same file".
@MainActor
final class AudioEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published var volume: Float = 0.85 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    let clock = PlaybackClock()
    let spectrum = SpectrumFeed()

    /// Seconds of overlap between consecutive tracks. 0 is gapless.
    var crossfadeDuration: TimeInterval = 0

    /// The engine moved on to the prepared next item by itself; the argument
    /// is its id. Fires when the next track becomes audible.
    var onAdvance: ((UUID) -> Void)?
    /// The current item played to its end with nothing prepared after it.
    var onEnded: (() -> Void)?

    private(set) var currentID: UUID?

    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: eqEngineSlots)
    private let decks = [Deck(), Deck()]
    private var active: Deck
    private var idle: Deck { decks[0] === active ? decks[1] : decks[0] }

    private var next: (url: URL, id: UUID)?
    private var transition: Transition?
    private var pausedPosition: TimeInterval = 0

    private var displayTimer: Timer?
    private var fadeTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private let analyzer = SpectrumAnalyzer()

    /// How early the idle deck is armed for a gapless start. Long enough to
    /// open the file; the start itself is sample-scheduled.
    private let gaplessLead: TimeInterval = 2.0

    private enum Transition {
        /// Idle deck is scheduled to start exactly when the active one ends.
        case gapless(incoming: Deck, id: UUID)
        /// `outgoing` is fading out under the (already active) incoming deck.
        case crossfade(outgoing: Deck, started: Date, length: TimeInterval)
    }

    init() {
        active = decks[0]
        engine.attach(bus)
        engine.attach(eq)
        for deck in decks {
            engine.attach(deck.node)
            engine.connect(deck.node, to: bus, fromBus: 0, toBus: bus.nextAvailableInputBus, format: nil)
        }
        engine.connect(bus, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume

        for band in eq.bands { band.bypass = true }
        eq.bypass = true

        // Post-EQ, pre-volume: the analyzer shows what the EQ is doing at any listening level.
        let analyzer = self.analyzer
        let feed = spectrum
        eq.installTap(onBus: 0, bufferSize: 2048, format: eq.outputFormat(forBus: 0)) { buffer, _ in
            guard let frame = analyzer.process(buffer) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { feed.receive(frame) } }
        }

        // A route change (headphones, AirPlay, default device) stops the
        // engine; restart it and carry on from the same spot.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // MARK: - Public transport

    var currentTime: TimeInterval { isPlaying ? position(of: active) : pausedPosition }
    var duration: TimeInterval { active.duration }

    /// Loads `url` on the active deck, discarding whatever was playing.
    func start(url: URL, id: UUID, at time: TimeInterval = 0, autoplay: Bool = true) throws {
        cancelTransition()
        for deck in decks { deck.reset() }
        try active.open(url)
        currentID = id
        pausedPosition = min(max(0, time), active.duration)
        clock.duration = active.duration
        clock.currentTime = pausedPosition
        if autoplay {
            play()
        } else {
            isPlaying = false
            stopDisplayTimer()
        }
    }

    /// What should play after the current item, or nil to end there.
    func setNext(url: URL?, id: UUID?) {
        let newNext = url.flatMap { u in id.map { (u, $0) } }
        if newNext?.0 == next?.url && newNext?.1 == next?.id { return }
        next = newNext
        if case .gapless = transition { cancelTransition() }
    }

    func play() {
        guard active.file != nil else { return }
        ensureEngineRunning()
        if !active.node.isPlaying {
            guard active.schedule(from: pausedPosition, onFinish: segmentFinished) else {
                // Already at the very end — treat as finished.
                endOfActive()
                return
            }
            active.node.volume = 1
            active.node.play()
        }
        isPlaying = true
        startDisplayTimer()
    }

    func pause() {
        guard isPlaying else { return }
        cancelTransition()
        pausedPosition = position(of: active)
        active.halt()
        isPlaying = false
        stopDisplayTimer()
        clock.currentTime = pausedPosition
        spectrum.silence()
    }

    func stop() {
        cancelTransition()
        for deck in decks { deck.reset() }
        currentID = nil
        next = nil
        isPlaying = false
        pausedPosition = 0
        stopDisplayTimer()
        clock.currentTime = 0
        clock.duration = 0
        spectrum.silence()
    }

    func seek(to time: TimeInterval) {
        guard active.file != nil else { return }
        cancelTransition()
        let target = min(max(0, time), max(0, active.duration - 0.05))
        pausedPosition = target
        clock.currentTime = target
        guard isPlaying else { return }
        active.halt()
        if active.schedule(from: target, onFinish: segmentFinished) {
            active.node.play()
        } else {
            endOfActive()
        }
    }

    // MARK: - Equalizer

    /// Maps the EQ's bands onto the unit's fixed pool of filters. Cuts
    /// cascade one 12 dB/oct filter per slope step; a soloed band replaces
    /// the whole curve with a band-pass at its frequency.
    func applyEqualizer(_ data: EqualizerSettingsData, solo: UUID?) {
        eq.bypass = !data.enabled
        var slot = 0
        func use(_ type: AVAudioUnitEQFilterType, _ frequency: Double, gain: Double = 0, octaves: Double = 1) {
            guard slot < eq.bands.count else { return }
            let band = eq.bands[slot]
            band.filterType = type
            band.frequency = Float(min(frequency, 20_000))
            band.gain = Float(gain)
            band.bandwidth = Float(min(5, max(0.05, octaves)))
            band.bypass = false
            slot += 1
        }
        if let solo, let band = data.bands.first(where: { $0.id == solo }) {
            eq.globalGain = 0
            use(.bandPass, band.frequency, octaves: band.type.hasQ ? band.octaves : 1)
        } else {
            eq.globalGain = Float(data.preampGain)
            for band in data.bands where band.enabled {
                switch band.type {
                case .bell: use(.parametric, band.frequency, gain: band.gain, octaves: band.octaves)
                case .lowShelf: use(.lowShelf, band.frequency, gain: band.gain)
                case .highShelf: use(.highShelf, band.frequency, gain: band.gain)
                case .lowCut: for _ in 0..<band.slotCount { use(.highPass, band.frequency) }
                case .highCut: for _ in 0..<band.slotCount { use(.lowPass, band.frequency) }
                case .notch: use(.bandStop, band.frequency, octaves: band.octaves)
                case .bandPass: use(.bandPass, band.frequency, octaves: band.octaves)
                }
            }
        }
        for band in eq.bands[slot...] { band.bypass = true }
    }

    // MARK: - Transitions

    private func checkForTransition() {
        guard isPlaying, transition == nil, let next else { return }
        let remaining = active.duration - position(of: active)
        let fade = min(crossfadeDuration, active.duration / 2)
        if fade >= 0.1 {
            if remaining <= fade { beginCrossfade(to: next, length: max(0.1, remaining)) }
        } else if remaining <= gaplessLead {
            armGapless(next)
        }
    }

    private func armGapless(_ item: (url: URL, id: UUID)) {
        let incoming = idle
        guard let when = endTime(of: active) else { return }
        do {
            try incoming.open(item.url)
        } catch {
            NSLog("i2s: couldn't open next track %@: %@", item.url.path, String(describing: error))
            next = nil
            return
        }
        guard incoming.schedule(from: 0, onFinish: segmentFinished) else { return }
        incoming.node.volume = 1
        incoming.node.play(at: when)
        transition = .gapless(incoming: incoming, id: item.id)
    }

    /// The node time at which the active deck's scheduled audio runs out.
    private func endTime(of deck: Deck) -> AVAudioTime? {
        guard let file = deck.file,
              let nodeTime = deck.node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = deck.node.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid else {
            return nil
        }
        let outRate = playerTime.sampleRate
        let segmentFrames = Double(file.length - deck.startFrame) * outRate / deck.fileRate
        let remaining = segmentFrames - Double(playerTime.sampleTime)
        guard remaining > 0 else { return nil }
        return AVAudioTime(sampleTime: nodeTime.sampleTime + AVAudioFramePosition(remaining.rounded()), atRate: nodeTime.sampleRate)
    }

    private func beginCrossfade(to item: (url: URL, id: UUID), length: TimeInterval) {
        let incoming = idle
        do {
            try incoming.open(item.url)
        } catch {
            NSLog("i2s: couldn't open next track %@: %@", item.url.path, String(describing: error))
            next = nil
            return
        }
        guard incoming.schedule(from: 0, onFinish: segmentFinished) else { return }
        let outgoing = active
        incoming.node.volume = 0
        incoming.node.play()
        becomeActive(incoming, id: item.id)
        transition = .crossfade(outgoing: outgoing, started: Date(), length: length)
        startFadeTimer()
        onAdvance?(item.id)
    }

    private func stepFade() {
        guard case .crossfade(let outgoing, let started, let length) = transition else {
            stopFadeTimer()
            return
        }
        let t = min(1, Date().timeIntervalSince(started) / length)
        // Equal-power curves keep perceived loudness flat through the overlap.
        active.node.volume = Float(sin(t * .pi / 2))
        outgoing.node.volume = Float(cos(t * .pi / 2))
        if t >= 1 {
            outgoing.reset()
            active.node.volume = 1
            transition = nil
            stopFadeTimer()
        }
    }

    private func completeGapless(incoming: Deck, id: UUID) {
        let outgoing = active
        becomeActive(incoming, id: id)
        transition = nil
        outgoing.reset()
        onAdvance?(id)
    }

    /// Drops an armed gapless start, or snaps a running crossfade to its end
    /// (the incoming track keeps playing at full volume).
    private func cancelTransition() {
        switch transition {
        case .gapless(let incoming, _):
            incoming.reset()
        case .crossfade(let outgoing, _, _):
            outgoing.reset()
            active.node.volume = 1
        case nil:
            break
        }
        transition = nil
        stopFadeTimer()
    }

    private func becomeActive(_ deck: Deck, id: UUID) {
        active = deck
        currentID = id
        next = nil
        pausedPosition = 0
        clock.duration = deck.duration
        clock.currentTime = 0
    }

    // MARK: - Completion

    private func segmentFinished(_ deck: Deck, generation: Int) {
        guard generation == deck.generation else { return }
        if case .gapless(let incoming, let id) = transition, deck === active {
            completeGapless(incoming: incoming, id: id)
            return
        }
        if deck === active, isPlaying {
            endOfActive()
        }
    }

    private func endOfActive() {
        isPlaying = false
        pausedPosition = active.duration
        clock.currentTime = active.duration
        stopDisplayTimer()
        spectrum.silence()
        onEnded?()
    }

    // MARK: - Position & timers

    private func position(of deck: Deck) -> TimeInterval {
        let base = Double(deck.startFrame) / deck.fileRate
        guard deck.node.isPlaying,
              let nodeTime = deck.node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = deck.node.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid,
              playerTime.sampleTime >= 0 else {
            return deck === active ? pausedPosition : base
        }
        return min(deck.duration, base + Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    private func tick() {
        guard isPlaying else { return }
        if case .gapless(let incoming, let id) = transition,
           incoming.node.isPlaying, position(of: incoming) > 0.02 {
            // The completion callback is late; the next track is already audible.
            completeGapless(incoming: incoming, id: id)
        }
        clock.currentTime = position(of: active)
        checkForTransition()
    }

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A little slack lets the system batch wakeups; invisible at 20 Hz.
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func startFadeTimer() {
        stopFadeTimer()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    // MARK: - Engine lifecycle

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("i2s: audio engine failed to start: %@", String(describing: error))
        }
    }

    private func recoverFromConfigurationChange() {
        let wasPlaying = isPlaying
        let resumeAt = wasPlaying ? position(of: active) : pausedPosition
        cancelTransition()
        active.halt()
        isPlaying = false
        pausedPosition = resumeAt
        ensureEngineRunning()
        if wasPlaying { play() }
    }

    #if DEBUG
    /// Self-test access to the rendered output.
    var outputNode: AVAudioMixerNode { engine.mainMixerNode }
    #endif
}

/// One player node and the file it's playing.
@MainActor
private final class Deck {
    let node = AVAudioPlayerNode()
    private(set) var file: AVAudioFile?
    /// File frame the currently scheduled segment starts at.
    private(set) var startFrame: AVAudioFramePosition = 0
    /// Bumped whenever scheduled audio is discarded, so its late completion
    /// callback can be recognized and ignored.
    private(set) var generation = 0

    var fileRate: Double { file?.fileFormat.sampleRate ?? 44_100 }
    var duration: TimeInterval { file.map { Double($0.length) / fileRate } ?? 0 }

    func open(_ url: URL) throws {
        halt()
        file = try AVAudioFile(forReading: url)
        startFrame = 0
    }

    /// Schedules from `time` to the end of the file.
    func schedule(from time: TimeInterval, onFinish: @escaping @MainActor (Deck, Int) -> Void) -> Bool {
        guard let file else { return false }
        let frame = min(file.length, AVAudioFramePosition(max(0, time) * fileRate))
        let count = file.length - frame
        guard count > 0 else { return false }
        startFrame = frame
        generation += 1
        let generation = self.generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(count), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { onFinish(self, generation) }
            }
        }
        return true
    }

    /// Stops and discards scheduled audio, keeping the file open.
    func halt() {
        generation += 1
        node.stop()
    }

    func reset() {
        halt()
        node.volume = 1
        file = nil
        startFrame = 0
    }
}
