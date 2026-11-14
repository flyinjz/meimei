import Foundation

/// A single audio file in the library, with metadata pulled from tags at import time.
struct Track: Identifiable, Codable, Hashable {
    /// The fields, kept in one shared box: copying a track (into a filtered
    /// list, a table row, an album group) is a single reference, not twenty-odd
    /// fields and their strings, and two copies of an unchanged track compare
    /// equal without reading a field. Writing to a copy gives it its own box
    /// first, so a track still behaves exactly like a plain value.
    private struct Fields: Codable, Hashable {
        var id: UUID
        var filePath: String
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var genre: String
        var composer: String
        var year: Int?
        var trackNumber: Int?
        var discNumber: Int?
        var duration: TimeInterval
        var sampleRate: Double
        var bitDepth: Int
        var channelCount: Int
        var estimatedBitrateKbps: Int
        var fileFormat: String
        var artworkFilePath: String?
        var dateAdded: Date
        var playCount: Int
        var lastPlayedAt: Date?
        var liked: Bool
    }

    private final class Storage: @unchecked Sendable {
        var fields: Fields
        init(_ fields: Fields) { self.fields = fields }
    }

    private var storage: Storage

    private mutating func edit(_ change: (inout Fields) -> Void) {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(storage.fields) }
        change(&storage.fields)
    }

    var id: UUID { storage.fields.id }
    var filePath: String {
        get { storage.fields.filePath }
        set { edit { $0.filePath = newValue } }
    }
    var title: String {
        get { storage.fields.title }
        set { edit { $0.title = newValue } }
    }
    var artist: String {
        get { storage.fields.artist }
        set { edit { $0.artist = newValue } }
    }
    var album: String {
        get { storage.fields.album }
        set { edit { $0.album = newValue } }
    }
    var albumArtist: String {
        get { storage.fields.albumArtist }
        set { edit { $0.albumArtist = newValue } }
    }
    var genre: String {
        get { storage.fields.genre }
        set { edit { $0.genre = newValue } }
    }
    var composer: String {
        get { storage.fields.composer }
        set { edit { $0.composer = newValue } }
    }
    var year: Int? {
        get { storage.fields.year }
        set { edit { $0.year = newValue } }
    }
    var trackNumber: Int? {
        get { storage.fields.trackNumber }
        set { edit { $0.trackNumber = newValue } }
    }
    var discNumber: Int? {
        get { storage.fields.discNumber }
        set { edit { $0.discNumber = newValue } }
    }
    var duration: TimeInterval {
        get { storage.fields.duration }
        set { edit { $0.duration = newValue } }
    }
    var sampleRate: Double {
        get { storage.fields.sampleRate }
        set { edit { $0.sampleRate = newValue } }
    }
    var bitDepth: Int {
        get { storage.fields.bitDepth }
        set { edit { $0.bitDepth = newValue } }
    }
    var channelCount: Int {
        get { storage.fields.channelCount }
        set { edit { $0.channelCount = newValue } }
    }
    var estimatedBitrateKbps: Int {
        get { storage.fields.estimatedBitrateKbps }
        set { edit { $0.estimatedBitrateKbps = newValue } }
    }
    var fileFormat: String {
        get { storage.fields.fileFormat }
        set { edit { $0.fileFormat = newValue } }
    }
    var artworkFilePath: String? {
        get { storage.fields.artworkFilePath }
        set { edit { $0.artworkFilePath = newValue } }
    }
    var dateAdded: Date {
        get { storage.fields.dateAdded }
        set { edit { $0.dateAdded = newValue } }
    }
    var playCount: Int {
        get { storage.fields.playCount }
        set { edit { $0.playCount = newValue } }
    }
    var lastPlayedAt: Date? {
        get { storage.fields.lastPlayedAt }
        set { edit { $0.lastPlayedAt = newValue } }
    }
    var liked: Bool {
        get { storage.fields.liked }
        set { edit { $0.liked = newValue } }
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.fields == rhs.storage.fields
    }

    func hash(into hasher: inout Hasher) { hasher.combine(storage.fields) }

    /// Written exactly as before: the same keys, nil values left out.
    func encode(to encoder: Encoder) throws { try storage.fields.encode(to: encoder) }

    init(
        id: UUID = UUID(),
        filePath: String,
        title: String,
        artist: String,
        album: String,
        albumArtist: String = "",
        genre: String = "Unknown",
        composer: String = "",
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval,
        sampleRate: Double,
        bitDepth: Int,
        channelCount: Int,
        estimatedBitrateKbps: Int,
        fileFormat: String,
        artworkFilePath: String? = nil,
        dateAdded: Date = Date(),
        playCount: Int = 0,
        lastPlayedAt: Date? = nil,
        liked: Bool = false
    ) {
        storage = Storage(Fields(
            id: id,
            filePath: filePath,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist.isEmpty ? artist : albumArtist,
            genre: genre,
            composer: composer,
            year: year,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channelCount: channelCount,
            estimatedBitrateKbps: estimatedBitrateKbps,
            fileFormat: fileFormat,
            artworkFilePath: artworkFilePath,
            dateAdded: dateAdded,
            playCount: playCount,
            lastPlayedAt: lastPlayedAt,
            liked: liked
        ))
    }

    private enum CodingKeys: String, CodingKey {
        case id, filePath, title, artist, album, albumArtist, genre, composer
        case year, trackNumber, discNumber, duration, sampleRate, bitDepth
        case channelCount, estimatedBitrateKbps, fileFormat, artworkFilePath, dateAdded
        case playCount, lastPlayedAt, liked
    }

    /// Fields added after the first release decode with defaults so older
    /// library files keep loading. Encoding is synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storage = Storage(Fields(
            id: try c.decode(UUID.self, forKey: .id),
            filePath: try c.decode(String.self, forKey: .filePath),
            title: try c.decode(String.self, forKey: .title),
            artist: try c.decode(String.self, forKey: .artist),
            album: try c.decode(String.self, forKey: .album),
            albumArtist: try c.decode(String.self, forKey: .albumArtist),
            genre: try c.decode(String.self, forKey: .genre),
            composer: try c.decodeIfPresent(String.self, forKey: .composer) ?? "",
            year: try c.decodeIfPresent(Int.self, forKey: .year),
            trackNumber: try c.decodeIfPresent(Int.self, forKey: .trackNumber),
            discNumber: try c.decodeIfPresent(Int.self, forKey: .discNumber),
            duration: try c.decode(TimeInterval.self, forKey: .duration),
            sampleRate: try c.decode(Double.self, forKey: .sampleRate),
            bitDepth: try c.decode(Int.self, forKey: .bitDepth),
            channelCount: try c.decode(Int.self, forKey: .channelCount),
            estimatedBitrateKbps: try c.decode(Int.self, forKey: .estimatedBitrateKbps),
            fileFormat: try c.decode(String.self, forKey: .fileFormat),
            artworkFilePath: try c.decodeIfPresent(String.self, forKey: .artworkFilePath),
            dateAdded: try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date(),
            playCount: try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0,
            lastPlayedAt: try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt),
            liked: try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        ))
    }

    var url: URL { URL(fileURLWithPath: filePath) }

    /// More than CD resolution in either sample rate or word length.
    var isHiRes: Bool { sampleRate > 44_100 || bitDepth > 16 }

    var isLossless: Bool {
        switch fileFormat.uppercased() {
        case "FLAC", "ALAC", "WAV", "AIFF", "PCM": return true
        default: return false
        }
    }

    /// Who the artist views file this track under.
    var displayArtist: String {
        let a = albumArtist.isEmpty ? artist : albumArtist
        return a.isEmpty ? "Unknown Artist" : a
    }

    var albumKey: String { "\(albumArtist.lowercased())::\(album.lowercased())" }

    var looseAlbumKey: String {
        DuplicateIdentity.normalize(albumArtist) + "::" + DuplicateIdentity.normalize(album)
    }

    /// Same song regardless of file: artist, title, and length to the nearest two seconds.
    var duplicateSongKey: String {
        let seconds = Int((duration / 2).rounded()) * 2
        return DuplicateIdentity.normalize(artist) + "|" + DuplicateIdentity.normalize(title) + "|\(seconds)"
    }

    var formattedDuration: String { Track.format(seconds: duration) }

    /// "44.1 kHz · 24-bit" for lossless, "320 kbps" for lossy.
    var qualitySummary: String {
        let rate = Track.format(sampleRate: sampleRate)
        if isLossless { return "\(rate) · \(bitDepth)-bit" }
        if estimatedBitrateKbps > 0 { return "\(estimatedBitrateKbps) kbps · \(rate)" }
        return rate
    }

    static func format(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func format(sampleRate: Double) -> String {
        let khz = sampleRate / 1000
        return khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    /// Disc, then track number, then title — the order a record plays in.
    static func albumOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let ld = lhs.discNumber ?? 0, rd = rhs.discNumber ?? 0
        if ld != rd { return ld < rd }
        let lt = lhs.trackNumber ?? Int.max, rt = rhs.trackNumber ?? Int.max
        if lt != rt { return lt < rt }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// Album artist, album, then album order — the library's natural order.
    static func libraryOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        if lhs.albumArtist != rhs.albumArtist {
            return lhs.albumArtist.localizedStandardCompare(rhs.albumArtist) == .orderedAscending
        }
        if lhs.album != rhs.album {
            return lhs.album.localizedStandardCompare(rhs.album) == .orderedAscending
        }
        return albumOrder(lhs, rhs)
    }
}

/// One record in the library, derived from its tracks.
struct AlbumGroup: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    let artist: String
    let year: Int?
    let artworkFilePath: String?
    let trackCount: Int
    let duration: TimeInterval
}

extension AlbumGroup {
    /// One group per album key, from tracks already grouped by album (each in album order), sorted by title.
    static func groups(byAlbum: [String: [Track]]) -> [AlbumGroup] {
        byAlbum.values.compactMap { members -> AlbumGroup? in
            guard let first = members.first else { return nil }
            return AlbumGroup(
                key: first.albumKey,
                title: first.album.isEmpty ? "Unknown Album" : first.album,
                artist: first.albumArtist,
                year: members.lazy.compactMap(\.year).first,
                artworkFilePath: members.first { $0.artworkFilePath != nil }?.artworkFilePath,
                trackCount: members.count,
                duration: members.reduce(0) { $0 + $1.duration }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Groups loose tracks by album (for callers without a library store, such as the C interface).
    static func groups(from tracks: [Track]) -> [AlbumGroup] {
        var byAlbum: [String: [Track]] = [:]
        for t in tracks { byAlbum[t.albumKey, default: []].append(t) }
        for k in byAlbum.keys { byAlbum[k]?.sort(by: Track.albumOrder) }
        return groups(byAlbum: byAlbum)
    }
}
