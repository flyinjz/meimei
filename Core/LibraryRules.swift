import Foundation

/// What the library table is showing.
enum LibrarySource: Hashable, Codable {
    case all
    /// The cover grid; plays like `.all`.
    case albums
    /// The artist grid; plays like `.all`.
    case artists
    case artist(String)
    case genre(String)
    case liked
    case recentlyAdded
    case recentlyPlayed
    case mostPlayed
    case playlist(UUID)
    /// The listener's profile: stats from the listening history.
    case profile

    /// A stable string for per-view state such as the table's scroll.
    var key: String {
        switch self {
        case .all: return "all"
        case .albums: return "albums"
        case .artists: return "artists"
        case .artist(let a): return "artist:" + a
        case .genre(let g): return "genre:" + g
        case .liked: return "liked"
        case .recentlyAdded: return "recentlyAdded"
        case .recentlyPlayed: return "recentlyPlayed"
        case .mostPlayed: return "mostPlayed"
        case .playlist(let id): return "playlist:" + id.uuidString
        case .profile: return "profile"
        }
    }

    /// Views whose content is a grid rather than a track list.
    var isGrid: Bool { self == .albums || self == .artists }
}

extension LibrarySource {
    /// The source a `key` names ("all", "artist:Name", "playlist:UUID", ...), or nil.
    init?(key: String) {
        func rest(_ prefix: String) -> String? { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil }
        switch key {
        case "all": self = .all
        case "albums": self = .albums
        case "artists": self = .artists
        case "liked": self = .liked
        case "recentlyAdded": self = .recentlyAdded
        case "recentlyPlayed": self = .recentlyPlayed
        case "mostPlayed": self = .mostPlayed
        case "profile": self = .profile
        default:
            if let a = rest("artist:") { self = .artist(a) }
            else if let g = rest("genre:") { self = .genre(g) }
            else if let p = rest("playlist:"), let id = UUID(uuidString: p) { self = .playlist(id) }
            else { return nil }
        }
    }
}

/// What the library shows and how it's filtered: one set of rules for every
/// platform. Stores keep their own caches around these.
enum LibraryRules {
    /// The tracks a source shows before the filter, in the source's order.
    static func base(for source: LibrarySource, tracks: [Track], now: Date = Date(),
                     playlist: (UUID) -> Playlist?, contents: (Playlist) -> [Track]) -> [Track] {
        switch source {
        case .all, .albums, .artists, .profile:
            return tracks
        case .artist(let a):
            return tracks.filter { $0.displayArtist == a || $0.artist == a }
        case .genre(let g):
            return tracks.filter { $0.genre == g }
        case .liked:
            return tracks.filter(\.liked)
        case .recentlyAdded:
            let cutoff = now.addingTimeInterval(-60 * 86_400)
            let list = tracks.filter { $0.dateAdded > cutoff }.sorted { $0.dateAdded > $1.dateAdded }
            return list.count < 25 ? Array(tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(100)) : list
        case .recentlyPlayed:
            let list = tracks.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            return Array(list.prefix(200))
        case .mostPlayed:
            return Array(tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(100))
        case .playlist(let id):
            return playlist(id).map(contents) ?? []
        }
    }

    /// The filter's words, folded (case and accents ignored).
    static func searchWords(_ text: String) -> [String] {
        text.split(separator: " ").map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    }

    /// What a filter searches in a track, folded the same way.
    static func searchHaystack(_ t: Track) -> String {
        [t.title, t.artist, t.album, t.albumArtist, t.genre, t.composer]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Tracks whose text holds every word.
    static func filter(_ list: [Track], by text: String) -> [Track] {
        let words = searchWords(text)
        guard !words.isEmpty else { return list }
        return list.filter { t in
            let hay = searchHaystack(t)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// The library file (library.json): tracks and playlists.
struct LibraryFile: Codable {
    var tracks: [Track]
    var playlists: [Playlist]

    /// Reads the file the way the app does: play counts in it are ignored
    /// (they come from the listening history), tracks in library order,
    /// built-in views dropped from the playlists.
    static func read(_ data: Data) throws -> LibraryFile {
        var file = try JSONDecoder().decode(LibraryFile.self, from: data)
        file.tracks = file.tracks.map { t in
            guard t.playCount != 0 || t.lastPlayedAt != nil else { return t }
            var t = t
            t.playCount = 0
            t.lastPlayedAt = nil
            return t
        }.sorted(by: Track.libraryOrder)
        file.playlists = file.playlists.filter { !$0.isLibraryView }
        return file
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

/// The track table's column sort, shared so both platforms order rows the same.
enum TrackSort {
    /// Column keys: "track", "year", "time", "plays", "quality" (numbers) and
    /// "title", "artist", "album", "genre", "format" (text).
    static func textOrder(_ key: String, _ a: Track, _ b: Track, _ asc: Bool) -> Bool {
        func text(_ x: String, _ y: String) -> Bool {
            let r = x.localizedStandardCompare(y)
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        switch key {
        case "title": return text(a.title, b.title)
        case "artist": return a.artist == b.artist ? Track.libraryOrder(a, b) : text(a.artist, b.artist)
        case "album": return a.album == b.album ? Track.albumOrder(a, b) : text(a.album, b.album)
        case "genre": return text(a.genre, b.genre)
        case "format": return text(a.fileFormat, b.fileFormat)
        default: return false
        }
    }

    /// Dense ranks of `tracks` in a text column's order (cache them per library version).
    static func ranks(_ key: String, ascending: Bool, over tracks: [Track]) -> [UUID: Int] {
        let order = { (a: Track, b: Track) in textOrder(key, a, b, ascending) }
        let all = tracks.sorted(by: order)
        var ranks: [UUID: Int] = [:]
        ranks.reserveCapacity(all.count)
        var rank = 0
        for (i, t) in all.enumerated() {
            if i > 0, order(all[i - 1], t) { rank += 1 }
            ranks[t.id] = rank
        }
        return ranks
    }

    /// `tracks` sorted by a column. `ranks` (from `ranks(_:ascending:over:)`) makes text columns fast.
    static func sorted(_ tracks: [Track], key: String, ascending asc: Bool, ranks: [UUID: Int]? = nil) -> [Track] {
        func num<T: Comparable>(_ keys: [T]) -> [Track] {
            // Sorting indices by a key array, not the tracks themselves:
            // no large struct copies. Stable, like sorting the tracks.
            let order = keys.indices.sorted { asc ? keys[$0] < keys[$1] : keys[$0] > keys[$1] }
            return order.map { tracks[$0] }
        }
        switch key {
        case "track": return num(tracks.map { $0.trackNumber ?? 0 })
        case "year": return num(tracks.map { $0.year ?? 0 })
        case "time": return num(tracks.map(\.duration))
        case "plays": return num(tracks.map(\.playCount))
        case "quality": return num(tracks.map { $0.sampleRate * 100 + Double($0.bitDepth) })
        case "title", "artist", "album", "genre", "format":
            if let ranks {
                // Ranks already encode the direction; ascending by rank.
                let keys = tracks.map { ranks[$0.id] ?? 0 }
                return keys.indices.sorted { keys[$0] < keys[$1] }.map { tracks[$0] }
            }
            return tracks.sorted { textOrder(key, $0, $1, asc) }
        default: return tracks
        }
    }
}
