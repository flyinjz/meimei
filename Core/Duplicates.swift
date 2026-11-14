import Foundation

// MARK: - Duplicate detection

struct DuplicateGroup: Identifiable {
    enum Kind { case songs, albums }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    var tracks: [Track]
}

enum DuplicateIdentity {
    private static let punctuation = try! NSRegularExpression(pattern: #"[\p{Punct}]+"#)
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

    /// The ignored-duplicates list is keyed on this; changing it re-surfaces
    /// groups the user already dismissed.
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        s = punctuation.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = whitespace.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}

enum DuplicateFinder {
    static func groups(in tracks: [Track]) -> [DuplicateGroup] {
        var songBuckets: [String: [Track]] = [:]
        var albumBuckets: [String: [Track]] = [:]
        for track in tracks {
            songBuckets[track.duplicateSongKey, default: []].append(track)
            albumBuckets[track.looseAlbumKey, default: []].append(track)
        }

        var groups: [DuplicateGroup] = songBuckets.compactMap { key, members in
            guard members.count > 1, let sample = members.first,
                  !DuplicateIdentity.normalize(sample.title).isEmpty else { return nil }
            return DuplicateGroup(
                id: "song:" + key,
                kind: .songs,
                title: sample.title,
                subtitle: "\(sample.artist) · \(members.count) copies",
                tracks: members.sorted { $0.dateAdded > $1.dateAdded }
            )
        }

        for (key, members) in albumBuckets {
            let albumKeys = Set(members.map(\.albumKey))
            guard albumKeys.count > 1, let sample = members.first,
                  !DuplicateIdentity.normalize(sample.album).isEmpty else { continue }
            groups.append(DuplicateGroup(
                id: "album:" + key,
                kind: .albums,
                title: sample.album,
                subtitle: "\(sample.albumArtist) · \(albumKeys.count) matching albums",
                tracks: members.sorted(by: Track.albumOrder)
            ))
        }
        return groups.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
