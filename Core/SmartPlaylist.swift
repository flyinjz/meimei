import Foundation

enum SmartField: String, Codable, CaseIterable, Identifiable {
    case title, artist, albumArtist, album, genre, composer, format
    case year, playCount, duration, sampleRate, bitDepth
    case addedDaysAgo, playedDaysAgo
    case liked, hiRes, lossless

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .albumArtist: return "Album artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .composer: return "Composer"
        case .format: return "Format"
        case .year: return "Year"
        case .playCount: return "Play count"
        case .duration: return "Length (min)"
        case .sampleRate: return "Sample rate (kHz)"
        case .bitDepth: return "Bit depth"
        case .addedDaysAgo: return "Days since added"
        case .playedDaysAgo: return "Days since played"
        case .liked: return "Liked"
        case .hiRes: return "Hi-Res"
        case .lossless: return "Lossless"
        }
    }

    enum Kind { case text, number, flag }

    var kind: Kind {
        switch self {
        case .title, .artist, .albumArtist, .album, .genre, .composer, .format: return .text
        case .year, .playCount, .duration, .sampleRate, .bitDepth, .addedDaysAgo, .playedDaysAgo: return .number
        case .liked, .hiRes, .lossless: return .flag
        }
    }
}

enum SmartOp: String, Codable, CaseIterable, Identifiable {
    case contains, equals, notContains, gte, lte, isTrue, isFalse
    var id: String { rawValue }

    var label: String {
        switch self {
        case .contains: return "contains"
        case .equals: return "is"
        case .notContains: return "does not contain"
        case .gte: return "at least"
        case .lte: return "at most"
        case .isTrue: return "is yes"
        case .isFalse: return "is no"
        }
    }

    static func ops(for field: SmartField) -> [SmartOp] {
        switch field.kind {
        case .flag: return [.isTrue, .isFalse]
        case .number: return [.equals, .gte, .lte]
        case .text: return [.contains, .equals, .notContains]
        }
    }
}

struct SmartRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var field: SmartField = .genre
    var op: SmartOp = .contains
    var value: String = ""

    func matches(_ track: Track, now: Date = Date()) -> Bool {
        switch field {
        case .liked: return flag(track.liked)
        case .hiRes: return flag(track.isHiRes)
        case .lossless: return flag(track.isLossless)
        case .year: return track.year.map { number(Double($0)) } ?? false
        case .playCount: return number(Double(track.playCount))
        case .duration: return number(track.duration / 60)
        case .sampleRate: return number(track.sampleRate / 1000)
        case .bitDepth: return number(Double(track.bitDepth))
        case .addedDaysAgo: return number(now.timeIntervalSince(track.dateAdded) / 86_400)
        case .playedDaysAgo:
            guard let played = track.lastPlayedAt else { return false }
            return number(now.timeIntervalSince(played) / 86_400)
        case .title: return text(track.title)
        case .artist: return text(track.artist)
        case .albumArtist: return text(track.albumArtist)
        case .album: return text(track.album)
        case .genre: return text(track.genre)
        case .composer: return text(track.composer)
        case .format: return text(track.fileFormat)
        }
    }

    private func flag(_ value: Bool) -> Bool {
        op == .isFalse ? !value : value
    }

    private func text(_ raw: String) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let found = needle.isEmpty || raw.range(of: needle, options: options) != nil
        switch op {
        case .contains: return found
        case .notContains: return !found || needle.isEmpty
        default: return raw.compare(needle, options: options) == .orderedSame
        }
    }

    private func number(_ n: Double) -> Bool {
        guard let target = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
        switch op {
        case .gte: return n >= target
        case .lte: return n <= target
        // Whole-number comparison so "length is 3" matches a 3:20 song.
        default: return n.rounded(.down) == target.rounded(.down)
        }
    }
}

enum SmartOrder: String, Codable, CaseIterable, Identifiable {
    case library, recentlyAdded, mostPlayed, recentlyPlayed, title, random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: return "Album order"
        case .recentlyAdded: return "Recently added"
        case .mostPlayed: return "Most played"
        case .recentlyPlayed: return "Recently played"
        case .title: return "Title"
        case .random: return "Random"
        }
    }

    func sort(_ tracks: inout [Track]) {
        switch self {
        case .library:
            tracks.sort(by: Track.libraryOrder)
        case .recentlyAdded:
            tracks.sort { $0.dateAdded > $1.dateAdded }
        case .mostPlayed:
            tracks.sort { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : Track.libraryOrder($0, $1) }
        case .recentlyPlayed:
            tracks.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .title:
            tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .random:
            // Stable per day, so the list doesn't reshuffle on every redraw.
            let seed = UInt64(Date().timeIntervalSince1970 / 86_400)
            tracks.sort { Self.mix($0.id, seed) < Self.mix($1.id, seed) }
        }
    }

    private static func mix(_ id: UUID, _ seed: UInt64) -> UInt64 {
        var x = seed
        withUnsafeBytes(of: id.uuid) { bytes in
            for b in bytes { x = (x ^ UInt64(b)) &* 0x100000001B3 }
        }
        return x
    }
}
