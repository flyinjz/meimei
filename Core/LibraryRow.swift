import Foundation

enum TableGroupMode: String, Codable, CaseIterable, Identifiable {
    case none, album, albumArtist, genre, year
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No grouping"
        case .album: return "Album"
        case .albumArtist: return "Album Artist"
        case .genre: return "Genre"
        case .year: return "Year"
        }
    }
}

/// One row of the library table: a group header or a track.
enum LibraryRow {
    case header(title: String, detail: String)
    case track(Track, stripe: Bool)

    var track: Track? {
        if case .track(let t, _) = self { return t }
        return nil
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    /// Tracks keep their incoming order within each group; groups are sorted
    /// by title. `stripe` alternates per track and restarts in each group.
    static func build(from tracks: [Track], groupBy: TableGroupMode) -> [LibraryRow] {
        guard groupBy != .none else {
            return tracks.enumerated().map { .track($1, stripe: $0 % 2 == 1) }
        }

        func key(_ t: Track) -> String {
            switch groupBy {
            case .none: return ""
            case .album: return t.album.isEmpty ? "Unknown Album" : t.album
            case .albumArtist: return t.albumArtist.isEmpty ? "Unknown Artist" : t.albumArtist
            case .genre: return t.genre.isEmpty ? "Unknown" : t.genre
            case .year: return t.year.map(String.init) ?? "Unknown Year"
            }
        }

        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for track in tracks {
            let k = key(track)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(track)
        }
        if groupBy == .year {
            order.sort { $0.localizedStandardCompare($1) == .orderedDescending }
        } else {
            order.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        var rows: [LibraryRow] = []
        rows.reserveCapacity(tracks.count + order.count)
        for k in order {
            let members = groups[k] ?? []
            let total = members.reduce(0) { $0 + $1.duration }
            let count = members.count == 1 ? "1 track" : "\(members.count) tracks"
            rows.append(.header(title: k, detail: "\(count) · \(Track.format(seconds: total))"))
            rows.append(contentsOf: members.enumerated().map { .track($1, stripe: $0 % 2 == 1) })
        }
        return rows
    }
}
