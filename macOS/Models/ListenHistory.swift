import Foundation
import CryptoKit
import Combine

// MARK: - Keys

struct KeychainHistorySecrets: HistorySecrets {
    #if DEBUG
    private let service = "i2s.history.debug"
    #else
    private let service = "i2s.history"
    #endif

    func read(_ name: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func write(_ data: Data, _ name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// The Mac's signing keys: inside the Secure Enclave where the Mac has one.
/// What's stored is a handle only this Mac's Enclave can use.
struct EnclaveHistorySigner: HistorySigning {
    let key: SecureEnclave.P256.Signing.PrivateKey
    var stored: Data { key.dataRepresentation }
    var isHardware: Bool { true }
    var publicKey: P256.Signing.PublicKey { key.publicKey }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
}

struct EnclaveKeyMaker: HistoryKeyMaker {
    func make(hardware: Bool) throws -> HistorySigning {
        if hardware && SecureEnclave.isAvailable { return EnclaveHistorySigner(key: try SecureEnclave.P256.Signing.PrivateKey()) }
        return try SoftwareKeyMaker().make(hardware: false)
    }
    func restore(_ data: Data, hardware: Bool) throws -> HistorySigning {
        hardware ? EnclaveHistorySigner(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
                 : try SoftwareKeyMaker().restore(data, hardware: false)
    }
}

// MARK: - App side

/// The history as the app sees it: opened off the main thread at launch,
/// then appended to as listens finish.
@MainActor
final class ListenHistory: ObservableObject {
    @Published private(set) var listens: [Listen] = []
    @Published private(set) var report = ListenLog.Report()
    @Published private(set) var isReady = false
    /// Why the history couldn't be opened, if it couldn't.
    @Published private(set) var failure: String?
    /// Called with each listen once it's sealed on disk.
    var onListen: ((Listen) -> Void)?
    /// Called once the history has been read back and checked.
    var onReady: (() -> Void)?

    private var log: ListenLog?
    private let queue = DispatchQueue(label: "i2s.history", qos: .utility)

    var device: UUID? { log?.identity.device }
    var stats: ListenStats { ListenStats(listens) }

    /// Opens the history kept under `support`.
    /// `seed` (DEBUG, scratch libraries only): tracks to build a made-up past from.
    func open(support: URL, seed: [Track] = []) {
        var dir = support.appendingPathComponent("History", isDirectory: true)
        var secrets: HistorySecrets = KeychainHistorySecrets()
        #if DEBUG
        if ProcessInfo.processInfo.environment["MEIMEI_SUPPORT_DIR"] != nil {
            // Scratch libraries keep their keys beside them.
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            secrets = FileHistorySecrets(dir: dir)
        } else if DebugHooks.isHeadless {
            // Test runs without a scratch library never touch the real history.
            isReady = true
            return
        } else {
            // Debug builds keep a history of their own, apart from the release app's.
            dir = support.appendingPathComponent("History-debug", isDirectory: true)
        }
        #endif
        #if DEBUG
        let seedCount = ProcessInfo.processInfo.environment["MEIMEI_SUPPORT_DIR"] == nil ? 0
            : Int(ProcessInfo.processInfo.environment["MEIMEI_SEED_LISTENS"] ?? "") ?? 0
        #endif
        queue.async { [secrets, dir] in
            #if DEBUG
            if seedCount > 0 { ListenSeeder.seed(dir: dir, secrets: secrets, tracks: seed, count: seedCount) }
            #endif
            let result = Result { try ListenLog(dir: dir, secrets: secrets) }
            DispatchQueue.main.async {
                switch result {
                case .success(let log):
                    self.log = log
                    self.listens = log.listens
                    self.report = log.report
                    if !log.report.isClean {
                        NSLog("i2s: history check: %d accepted, %d rejected, %d implausible, %d gaps",
                              log.report.accepted, log.report.rejected, log.report.implausible, log.report.gaps)
                    }
                case .failure(let error):
                    self.failure = String(describing: error)
                    NSLog("i2s: history could not be opened: %@", String(describing: error))
                }
                self.isReady = true
                self.onReady?()
            }
        }
    }

    func record(_ listen: Listen) {
        guard let log else { return }
        queue.async {
            let result = Result { try log.append(listen) }
            DispatchQueue.main.async {
                switch result {
                case .success(let l):
                    self.listens.append(l)
                    self.onListen?(l)
                case .failure(let error):
                    NSLog("i2s: listen not recorded: %@", String(describing: error))
                }
            }
        }
    }

    /// Waits for writes in flight and brings the check-point up to date. Called on quit.
    func flush() {
        let log = self.log
        queue.sync { log?.close() }
    }
}

/// Times how long the current track is actually heard and hands finished
/// listens to the history. Time counts only while playing with the volume
/// above zero, by the monotonic clock: seeking ahead or changing the date
/// adds nothing. Every full play counts, repeat-one included.
@MainActor
final class ListenTracker {
    private let player: PlayerController
    private let history: ListenHistory
    private var track: Track?
    private var startedAt: Date?
    private var heard: TimeInterval = 0
    private var audibleSince: TimeInterval?
    private var subscriptions: Set<AnyCancellable> = []

    init(player: PlayerController, history: ListenHistory) {
        self.player = player
        self.history = history
        player.$currentTrack
            .sink { [weak self] t in self?.trackChanged(t) }
            .store(in: &subscriptions)
        player.engine.$isPlaying
            .sink { [weak self] playing in self?.audibleChanged(playing: playing, volume: nil) }
            .store(in: &subscriptions)
        player.engine.$volume
            .sink { [weak self] volume in self?.audibleChanged(playing: nil, volume: volume) }
            .store(in: &subscriptions)
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func trackChanged(_ new: Track?) {
        guard new?.id != track?.id else { return }
        finish()
        begin(new)
    }

    /// The engine finished `finished` (and may already be on the next, or the same one again).
    func completed(_ finished: Track) {
        if track?.id == finished.id { finish() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.track == nil else { return }
            self.begin(self.player.currentTrack)
        }
    }

    private func begin(_ t: Track?) {
        track = t
        startedAt = nil
        heard = 0
        audibleSince = nil
        audibleChanged(playing: nil, volume: nil)
    }

    // `@Published` delivers before the property changes, so take the new value from the event.
    private func audibleChanged(playing: Bool?, volume: Float?) {
        let audible = track != nil && (playing ?? player.engine.isPlaying) && (volume ?? player.engine.volume) > 0
        if audible, audibleSince == nil {
            audibleSince = Self.uptime
            if startedAt == nil { startedAt = Date() }
        } else if !audible, let since = audibleSince {
            heard += Self.uptime - since
            audibleSince = nil
        }
    }

    /// Ends the current listen; records it if it was heard long enough.
    func finish() {
        if let since = audibleSince { heard += Self.uptime - since }
        defer {
            track = nil
            startedAt = nil
            heard = 0
            audibleSince = nil
        }
        guard let t = track, let startedAt, let device = history.device,
              ListenRules.counts(heard: heard, duration: t.duration) else { return }
        history.record(Listen(id: UUID(), trackID: t.id, trackKey: Listen.key(for: t), title: t.title,
                              artist: t.displayArtist, album: t.album, albumArtist: t.albumArtist,
                              trackDuration: t.duration, startedAt: startedAt, endedAt: Date(),
                              heardSeconds: heard, device: device))
    }
}
