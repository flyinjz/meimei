#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// MARK: - Listens

/// One listen: what played, when, and how long it was actually heard.
/// Play counts, last-played dates and every statistic are worked out from
/// these; no count is ever stored where it could be edited.
struct Listen: Codable, Equatable, Identifiable {
    var id: UUID
    var trackID: UUID
    /// Identity that survives the file being moved, renamed or re-imported.
    var trackKey: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackDuration: Double
    var startedAt: Date
    var endedAt: Date
    /// Seconds the track was audible (playing, volume above zero), timed by
    /// the system's monotonic clock, so changing the date doesn't add any.
    var heardSeconds: Double
    /// The installation that heard it.
    var device: UUID

    static func key(for track: Track) -> String {
        [track.displayArtist, track.title, track.album].map { $0.lowercased() }.joined(separator: "\u{1F}")
    }
}

/// What counts as a listen, and what can't be real. Checked when a listen is
/// recorded and again every time the history is read back.
enum ListenRules {
    /// Tracks shorter than this never count (as on last.fm).
    static let minimumTrackLength: Double = 30
    /// Slack for crossfades, timer granularity and file-system dates.
    static let tolerance: Double = 15

    /// Half the track or four minutes, whichever comes first.
    static func required(for duration: Double) -> Double { min(duration / 2, 240) }

    static func counts(heard: Double, duration: Double) -> Bool {
        duration >= minimumTrackLength && heard >= required(for: duration)
    }

    /// Why `listen` can't have happened, or nil. `previousEnd` is when the
    /// same device's previous listen ended: one device plays one thing at a time.
    static func problem(_ listen: Listen, previousEnd: Date?, accountCreated: Date, now: Date) -> String? {
        let span = listen.endedAt.timeIntervalSince(listen.startedAt)
        if !listen.heardSeconds.isFinite || !listen.trackDuration.isFinite || !span.isFinite { return "not a number" }
        if listen.trackDuration < minimumTrackLength { return "track too short" }
        if listen.heardSeconds < required(for: listen.trackDuration) - 1 { return "not heard long enough" }
        if span < -1 { return "ends before it starts" }
        if listen.heardSeconds > span + tolerance { return "heard longer than it lasted" }
        if listen.startedAt.timeIntervalSince(accountCreated) < -tolerance { return "before the account existed" }
        if listen.endedAt.timeIntervalSince(now) > tolerance { return "in the future" }
        if let previousEnd, listen.startedAt.timeIntervalSince(previousEnd) < -tolerance { return "overlaps the previous listen" }
        return nil
    }
}

// MARK: - Keys

/// Where the history's keys are kept.
/// Platform piece: macOS Keychain here; the ports use their own secret stores.
protocol HistorySecrets: Sendable {
    func read(_ name: String) -> Data?
    func write(_ data: Data, _ name: String)
}

/// Keys kept as files beside the history: test runs, and ports until
/// their platform secret store is wired in.
struct FileHistorySecrets: HistorySecrets {
    var dir: URL
    func read(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("secret-" + name)) }
    func write(_ data: Data, _ name: String) {
        // The identity is written once and must never be half-written. The
        // anchor changes with every listen and is only a shortcut (a damaged
        // one just means a full check), so it's overwritten in place: an
        // atomic replace per listen is the slowest part on NTFS.
        let url = dir.appendingPathComponent("secret-" + name)
        try? data.write(to: url, options: name == "identity" ? .atomic : [])
    }
}

/// Signs history records. Platform piece: the Mac keeps the key inside the
/// Secure Enclave, ports use the TPM where there is one; this core only knows
/// the software key.
protocol HistorySigning {
    /// What's stored to get the key back: the raw key, or a handle only the hardware can use.
    var stored: Data { get }
    var isHardware: Bool { get }
    var publicKey: P256.Signing.PublicKey { get }
    func sign(_ data: Data) throws -> Data
}

/// Makes and restores signing keys; the app sets its platform's maker at launch.
protocol HistoryKeyMaker {
    func make(hardware: Bool) throws -> HistorySigning
    func restore(_ data: Data, hardware: Bool) throws -> HistorySigning
}

struct SoftwareHistorySigner: HistorySigning {
    let key: P256.Signing.PrivateKey
    var stored: Data { key.rawRepresentation }
    var isHardware: Bool { false }
    var publicKey: P256.Signing.PublicKey { key.publicKey }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
}

struct SoftwareKeyMaker: HistoryKeyMaker {
    func make(hardware: Bool) throws -> HistorySigning { SoftwareHistorySigner(key: P256.Signing.PrivateKey()) }
    func restore(_ data: Data, hardware: Bool) throws -> HistorySigning {
        guard !hardware else { throw ListenLog.Failure.keyUnavailable }
        return SoftwareHistorySigner(key: try P256.Signing.PrivateKey(rawRepresentation: data))
    }
}

enum HistoryKeys {
    /// The platform's key maker. Software until the app sets its own.
    nonisolated(unsafe) static var maker: HistoryKeyMaker = SoftwareKeyMaker()
}

// MARK: - The sealed log

/// The listening history on disk: one append-only file of records, each
/// encrypted, chained to the one before it, and signed.
///
/// File: "I2SH", version byte, the account's UUID; then records, each a
/// little-endian u32 length and a body: u64 index · 32-byte hash of the
/// previous record · u32 length + ChaCha20-Poly1305 box (the listen, sealed
/// with the record's index and previous hash as associated data) · u8 length
/// + P-256 signature over everything before it. Changing a byte breaks the
/// box and the signature; removing or reordering records breaks the chain;
/// adding one needs the signing key.
///
/// The anchor (record count, last hash, latest listen end, signed) lives with
/// the keys. It lets a launch skip re-checking signatures already checked,
/// and shows when records were cut off the end or the clock was turned back.
final class ListenLog: @unchecked Sendable {  // used only on ListenHistory's queue
    struct Identity: Codable {
        var account: UUID
        var device: UUID
        var created: Date
        var enclave: Bool
        var signingKey: Data
        var sealKey: Data
    }

    struct Anchor: Codable {
        var count: Int
        var head: Data
        var lastEnd: Date?
        var signature: Data = Data()

        var signedBytes: Data {
            var d = Data("i2s-anchor".utf8)
            d.append(contentsOf: withUnsafeBytes(of: UInt64(count).littleEndian, Array.init))
            d.append(head)
            d.append(contentsOf: withUnsafeBytes(of: (lastEnd?.timeIntervalSinceReferenceDate ?? 0).bitPattern.littleEndian, Array.init))
            return d
        }
    }

    /// What reading the history found.
    struct Report: Equatable {
        var accepted = 0
        /// Records whose seal or signature failed, or that copy another record.
        var rejected = 0
        /// Listens that decrypted fine but can't have happened.
        var implausible = 0
        /// Places where records are missing (removed, or cut off the end).
        var gaps = 0
        /// The file's records had been checked before, so their signatures weren't checked again.
        var trustedPrefix = 0

        var isClean: Bool { rejected == 0 && implausible == 0 && gaps == 0 }
    }

    enum Failure: Error, Equatable { case implausible(String), clockMovedBack, write, keyUnavailable }

    let fileURL: URL
    private let secrets: HistorySecrets
    let identity: Identity
    private let signer: HistorySigning
    private let sealKey: SymmetricKey
    private var anchor: Anchor
    private(set) var listens: [Listen] = []
    private(set) var report = Report()
    private var nextIndex: UInt64 = 0
    private var head: Data
    private var lastEnd: Date?
    /// Records in the file, good or not.
    private var recordCount = 0
    /// Kept open between appends on Apple platforms; closed after each on Windows.
    private var writer: FileHandle?

    /// Where append time goes, per phase in milliseconds (benchmarks only; nil = off).
    struct AppendTiming {
        var encode = 0.0, seal = 0.0, sign = 0.0, write = 0.0, sync = 0.0, bookkeeping = 0.0, anchor = 0.0
        var count = 0
    }
    var timing: AppendTiming?
    private static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Brings the check-point up to date and closes the file (it reopens on
    /// the next append). The app calls this when it quits.
    func close() {
        if clean && anchorBehind > 0 { saveAnchor() }
        try? writer?.close()
        writer = nil
    }

    deinit { close() }

    /// The check-point is rewritten every this many listens, and on close.
    /// It's only a shortcut (and a check that nothing was cut off the end),
    /// so a stale one costs a fuller check at the next launch, nothing more;
    /// rewriting it on every listen was the slowest part on Windows.
    static let anchorEvery = 32
    /// Listens sealed since the check-point was last written.
    private var anchorBehind = 0
    /// The last read found nothing wrong, so the anchor can move on.
    private var clean = true

    var publicKey: P256.Signing.PublicKey { signer.publicKey }
    var usesEnclave: Bool { signer.isHardware }

    private static let magic = Data("I2SH".utf8)
    private static let version: UInt8 = 1

    /// Opens (or starts) the history in `dir`. A history file whose keys are
    /// gone can't be verified; it's moved aside, never deleted, and a new one begins.
    init(dir: URL, secrets: HistorySecrets, enclave: Bool = true, created: Date = Date()) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("listens.i2s")
        self.secrets = secrets
        let decoder = JSONDecoder()
        if let data = secrets.read("identity"), let id = try? decoder.decode(Identity.self, from: data),
           let s = try? HistoryKeys.maker.restore(id.signingKey, hardware: id.enclave) {
            identity = id
            signer = s
        } else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let aside = dir.appendingPathComponent("listens-unverifiable-\(Int(Date().timeIntervalSince1970)).i2s")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
            }
            let s = try HistoryKeys.maker.make(hardware: enclave)
            let id = Identity(account: UUID(), device: UUID(), created: created, enclave: s.isHardware,
                              signingKey: s.stored, sealKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
            secrets.write(try JSONEncoder().encode(id), "identity")
            identity = id
            signer = s
        }
        sealKey = SymmetricKey(data: identity.sealKey)
        head = Self.genesis(identity.account)
        anchor = (secrets.read("anchor").flatMap { try? decoder.decode(Anchor.self, from: $0) })
            ?? Anchor(count: 0, head: head, lastEnd: nil)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            var header = Self.magic
            header.append(Self.version)
            header.append(contentsOf: withUnsafeBytes(of: identity.account.uuid, Array.init))
            try header.write(to: fileURL, options: .atomic)
        }
        verify()
    }

    private static func genesis(_ account: UUID) -> Data {
        var d = Data("i2s history".utf8)
        d.append(contentsOf: withUnsafeBytes(of: account.uuid, Array.init))
        return Data(SHA256.hash(data: d))
    }

    // MARK: Reading back

    private struct Record {
        var index: UInt64
        var previous: Data
        var box: Data
        var signed: Data
        var signature: Data
        var hash: Data
    }

    private static func parse(_ data: Data) -> (records: [Record], damagedTail: Bool) {
        var records: [Record] = []
        var at = 21
        guard data.count >= at, data.prefix(4) == magic else { return ([], data.count > 0) }
        func u32(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24 }
        while at < data.count {
            guard at + 4 <= data.count else { return (records, true) }
            let length = u32(at)
            let start = at + 4, end = start + length
            guard length >= 8 + 32 + 4 + 1, end <= data.count else { return (records, true) }
            let body = data.subdata(in: start..<end)
            var p = 0
            let index = body.subdata(in: 0..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
            p = 8
            let previous = body.subdata(in: p..<p + 32); p += 32
            let boxLength = Int(body[p]) | Int(body[p + 1]) << 8 | Int(body[p + 2]) << 16 | Int(body[p + 3]) << 24
            p += 4
            guard p + boxLength + 1 <= body.count else { at = end; continue }
            let box = body.subdata(in: p..<p + boxLength); p += boxLength
            let signedEnd = p
            let sigLength = Int(body[p]); p += 1
            guard p + sigLength == body.count else { at = end; continue }
            records.append(Record(index: index, previous: previous, box: box, signed: body.prefix(signedEnd),
                                  signature: body.subdata(in: p..<body.count), hash: Data(SHA256.hash(data: body))))
            at = end
        }
        return (records, false)
    }

    private func associated(_ index: UInt64, _ previous: Data) -> Data {
        var d = Data(withUnsafeBytes(of: index.littleEndian, Array.init))
        d.append(previous)
        return d
    }

    /// Reads the whole file and keeps the listens that pass every check.
    func verify(now: Date = Date()) {
        var report = Report()
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        let (records, damagedTail) = Self.parse(data)
        if damagedTail { report.gaps += 1 }

        // Signatures already checked at the last launch needn't be checked
        // again, if the chain up to the anchor is exactly what it was.
        var trusted = 0
        if anchor.count > 0, anchor.count <= records.count,
           (try? P256.Signing.ECDSASignature(derRepresentation: anchor.signature)).map({ publicKey.isValidSignature($0, for: anchor.signedBytes) }) == true {
            var chain = Self.genesis(identity.account)
            var intact = true
            for r in records.prefix(anchor.count) {
                if r.previous != chain { intact = false; break }
                chain = r.hash
            }
            if intact && chain == anchor.head { trusted = anchor.count }
        }
        report.trustedPrefix = trusted
        if records.count < anchor.count { report.gaps += 1 }

        var accepted: [Listen] = []
        var seenIndex = Set<UInt64>()
        var seenListen = Set<UUID>()
        var chain = Self.genesis(identity.account)
        var lastEndByDevice: [UUID: Date] = [:]
        var newestHead = chain
        var maxIndex: UInt64? = nil
        for (i, r) in records.enumerated() {
            if r.previous != chain { report.gaps += 1 }
            chain = r.hash
            if i >= trusted {
                guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: r.signature),
                      publicKey.isValidSignature(sig, for: r.signed) else { report.rejected += 1; continue }
            }
            guard !seenIndex.contains(r.index),
                  let sealed = try? ChaChaPoly.SealedBox(combined: r.box),
                  let plain = try? ChaChaPoly.open(sealed, using: sealKey, authenticating: associated(r.index, r.previous)),
                  let listen = try? JSONDecoder().decode(Listen.self, from: plain),
                  !seenListen.contains(listen.id) else { report.rejected += 1; continue }
            seenIndex.insert(r.index)
            seenListen.insert(listen.id)
            newestHead = r.hash
            maxIndex = max(maxIndex ?? 0, r.index)
            if ListenRules.problem(listen, previousEnd: lastEndByDevice[listen.device], accountCreated: identity.created, now: now) != nil {
                report.implausible += 1
                continue
            }
            lastEndByDevice[listen.device] = max(lastEndByDevice[listen.device] ?? listen.endedAt, listen.endedAt)
            accepted.append(listen)
        }
        report.accepted = accepted.count
        listens = accepted
        self.report = report
        // New records chain on from the last good one.
        head = newestHead
        nextIndex = maxIndex.map { $0 + 1 } ?? 0
        lastEnd = [anchor.lastEnd, accepted.last?.endedAt].compactMap { $0 }.max()
        recordCount = records.count
        clean = report.isClean
        if clean { saveAnchor() }
    }

    private func saveAnchor() {
        anchorBehind = 0
        var a = Anchor(count: recordCount, head: head, lastEnd: lastEnd)
        a.signature = (try? signer.sign(a.signedBytes)) ?? Data()
        anchor = a
        if let data = try? JSONEncoder().encode(a) { secrets.write(data, "anchor") }
    }

    // MARK: Writing

    /// Seals and appends one listen. Refuses listens that can't be real, and
    /// any listen at all while the clock reads earlier than the latest one.
    @discardableResult
    func append(_ listen: Listen, now: Date = Date()) throws -> Listen {
        if let lastEnd, now.timeIntervalSince(lastEnd) < -ListenRules.tolerance { throw Failure.clockMovedBack }
        let previousEnd = listens.last { $0.device == listen.device }?.endedAt
        if let problem = ListenRules.problem(listen, previousEnd: previousEnd, accountCreated: identity.created, now: now) {
            throw Failure.implausible(problem)
        }
        var mark = timing == nil ? 0 : Self.now()
        func lap(_ phase: WritableKeyPath<AppendTiming, Double>) {
            guard timing != nil else { return }
            let t = Self.now()
            timing![keyPath: phase] += t - mark
            mark = t
        }
        let index = nextIndex
        let plain = try JSONEncoder().encode(listen)
        lap(\.encode)
        let box = try ChaChaPoly.seal(plain, using: sealKey, authenticating: associated(index, head)).combined
        lap(\.seal)
        var body = Data(withUnsafeBytes(of: index.littleEndian, Array.init))
        body.append(head)
        body.append(contentsOf: withUnsafeBytes(of: UInt32(box.count).littleEndian, Array.init))
        body.append(box)
        let signature = try signer.sign(body)
        lap(\.sign)
        body.append(UInt8(signature.count))
        body.append(signature)
        var record = Data(withUnsafeBytes(of: UInt32(body.count).littleEndian, Array.init))
        record.append(body)

        if writer == nil { writer = try? FileHandle(forWritingTo: fileURL) }
        guard let handle = writer else { throw Failure.write }
        try handle.seekToEnd()
        try handle.write(contentsOf: record)
        lap(\.write)
        try handle.synchronize()
        lap(\.sync)
        #if os(Windows)
        // Windows opens files without write sharing: closing after each
        // listen keeps the history open to backup tools (and to the checks).
        try? handle.close()
        writer = nil
        #endif

        head = Data(SHA256.hash(data: body))
        nextIndex = index + 1
        lastEnd = max(lastEnd ?? listen.endedAt, listen.endedAt)
        listens.append(listen)
        report.accepted += 1
        recordCount += 1
        anchorBehind += 1
        lap(\.bookkeeping)
        if clean && anchorBehind >= Self.anchorEvery { saveAnchor() }
        lap(\.anchor)
        if timing != nil { timing!.count += 1 }
        return listen
    }
}

// MARK: - Statistics

/// Counts worked out from the verified listens.
struct ListenStats {
    struct Entry { var count: Int; var last: Date }
    var byTrack: [UUID: Entry] = [:]
    var byKey: [String: Entry] = [:]

    init(_ listens: [Listen]) {
        for l in listens {
            byTrack[l.trackID, default: Entry(count: 0, last: l.endedAt)].count += 1
            byTrack[l.trackID]!.last = max(byTrack[l.trackID]!.last, l.endedAt)
            byKey[l.trackKey, default: Entry(count: 0, last: l.endedAt)].count += 1
            byKey[l.trackKey]!.last = max(byKey[l.trackKey]!.last, l.endedAt)
        }
    }

    /// A track's listens: by its own id, or (moved or re-imported files) by what it is.
    func entry(for track: Track) -> Entry? {
        if let e = byTrack[track.id] { return e }
        return byKey[Listen.key(for: track)]
    }
}

#if DEBUG
/// Snapshot runs only: a believable past for a scratch library, so the
/// profile has something to show. Made once, when the scratch history has no
/// keys yet: about 400 days back, evenings and weekends busier, a few artists
/// played far more than the rest, albums played in order, never overlapping.
enum ListenSeeder {
    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func pick(_ weights: [Double]) -> Int {
            var r = unit() * weights.reduce(0, +)
            for (i, w) in weights.enumerated() { r -= w; if r <= 0 { return i } }
            return weights.count - 1
        }
    }

    static func seed(dir: URL, secrets: HistorySecrets, tracks: [Track], count: Int) {
        guard secrets.read("identity") == nil else { return }
        let pool = tracks.filter { $0.duration >= ListenRules.minimumTrackLength }
        guard !pool.isEmpty else { return }
        let now = Date()
        let cal = Calendar.current
        let created = cal.startOfDay(for: now.addingTimeInterval(-400 * 86_400))
        guard let log = try? ListenLog(dir: dir, secrets: secrets, enclave: false, created: created) else { return }
        var rng = Random(state: 42)
        var albumsByArtist: [String: [[Track]]] = [:]
        for (key, album) in Dictionary(grouping: pool, by: \.albumKey) {
            let ordered = album.sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
            albumsByArtist[ordered[0].displayArtist, default: []].append(ordered)
            _ = key
        }
        var artists = albumsByArtist.keys.sorted()
        for i in artists.indices.reversed() { artists.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        let artistWeights = artists.indices.map { 1 / pow(Double($0) + 1, 1.05) }
        let hourWeights: [Double] = [2, 1, 0.5, 0.2, 0.1, 0.1, 0.3, 1, 2, 2, 2, 2, 3, 3, 2, 2, 2, 3, 4, 6, 8, 8, 6, 4]
        let device = log.identity.device
        let perDay = Double(count) / 399
        var made = 0
        var t = created.addingTimeInterval(3_600)
        var day = cal.date(byAdding: .day, value: 1, to: created)!
        while made < count, day < now {
            let index = Double(cal.dateComponents([.day], from: created, to: day).day ?? 0)
            let weekend = cal.isDateInWeekend(day) ? 1.4 : 1
            let trend = 0.6 + 0.8 * index / 400
            var today = rng.unit() < 0.12 ? 0 : Int(perDay * weekend * trend * (0.3 + 1.4 * rng.unit()))
            while today > 0, made < count {
                let hour = rng.pick(hourWeights)
                var start = cal.date(byAdding: .hour, value: hour, to: day)!.addingTimeInterval(rng.unit() * 3_000)
                if start < t { start = t.addingTimeInterval(60 + rng.unit() * 600) }
                var album = albumsByArtist[artists[rng.pick(artistWeights)]]!.randomElement(using: &rng)!
                var position = Int(rng.next() % UInt64(album.count))
                let length = min(today, 4 + Int(rng.next() % 11))
                for _ in 0..<length {
                    if rng.unit() < 0.18 {
                        album = albumsByArtist[artists[rng.pick(artistWeights)]]!.randomElement(using: &rng)!
                        position = Int(rng.next() % UInt64(album.count))
                    }
                    let track = album[position % album.count]
                    position += 1
                    let heard = track.duration * (0.55 + 0.45 * rng.unit())
                    let end = start.addingTimeInterval(heard + 1)
                    guard end < now.addingTimeInterval(-60) else { break }
                    let listen = Listen(id: UUID(), trackID: track.id, trackKey: Listen.key(for: track), title: track.title,
                                        artist: track.displayArtist, album: track.album, albumArtist: track.albumArtist,
                                        trackDuration: track.duration, startedAt: start, endedAt: end, heardSeconds: heard, device: device)
                    if (try? log.append(listen, now: end.addingTimeInterval(5))) != nil { made += 1 }
                    start = end.addingTimeInterval(2)
                    t = start
                }
                today -= length
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        NSLog("i2s: seeded %d listens into the scratch history", made)
    }
}
#endif
