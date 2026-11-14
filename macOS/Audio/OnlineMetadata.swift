import Foundation
import AppKit

/// A cover found online.
struct CoverCandidate: Identifiable, Hashable, Sendable {
    var id: String
    var source: OnlineSource
    var title: String
    var artist: String
    var year: Int?
    var thumbnail: URL
    var full: URL
    /// Known size of `full`, when the provider says.
    var maxPixels: Int?
}

/// An album's details found online, for filling in or correcting tags.
struct AlbumMatch: Identifiable, Hashable, Sendable {
    struct Song: Hashable, Sendable {
        var disc: Int
        var number: Int
        var title: String
        var artist: String
    }

    var id: String
    var source: OnlineSource
    var title: String
    var artist: String
    var year: Int?
    var genre: String?
    var trackCount: Int
    /// Release details shown to tell editions apart (country, format, label).
    var note: String?
    var cover: CoverCandidate?
    /// The provider's id for the tracklist request.
    var lookupID: String
}

enum OnlineMetadata {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // MusicBrainz asks every client to identify itself.
        config.httpAdditionalHeaders = ["User-Agent": "i2s/0.2 ( desktop music player; lookups made on the user's request )",
                                        "Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    // MARK: Covers

    /// Covers from every enabled source, in parallel; a source that fails
    /// just contributes nothing.
    static func covers(artist: String, album: String, sources: [OnlineSource]) async -> [CoverCandidate] {
        await withTaskGroup(of: [CoverCandidate].self) { group in
            for source in sources {
                group.addTask { (try? await covers(from: source, artist: artist, album: album)) ?? [] }
            }
            var all: [CoverCandidate] = []
            for await batch in group { all.append(contentsOf: batch) }
            let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
            return all.sorted { (order[$0.source] ?? 0) < (order[$1.source] ?? 0) }
        }
    }

    private static func covers(from source: OnlineSource, artist: String, album: String) async throws -> [CoverCandidate] {
        try await albums(from: source, artist: artist, album: album).compactMap(\.cover)
            .reduce(into: [CoverCandidate]()) { list, c in if !list.contains(where: { $0.full == c.full }) { list.append(c) } }
    }

    // MARK: Albums

    static func albums(artist: String, album: String, sources: [OnlineSource]) async -> [AlbumMatch] {
        await withTaskGroup(of: [AlbumMatch].self) { group in
            for source in sources {
                group.addTask { (try? await albums(from: source, artist: artist, album: album)) ?? [] }
            }
            var all: [AlbumMatch] = []
            for await batch in group { all.append(contentsOf: batch) }
            // Closest names first; ties keep the source order.
            let wantAlbum = fold(album), wantArtist = fold(artist)
            func score(_ m: AlbumMatch) -> Int {
                let t = fold(m.title), a = fold(m.artist)
                return (t == wantAlbum ? 4 : t.contains(wantAlbum) || wantAlbum.contains(t) ? 2 : 0)
                    + (a == wantArtist ? 3 : a.contains(wantArtist) || wantArtist.contains(a) ? 1 : 0)
            }
            let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
            return all.enumerated().sorted { l, r in
                let (sl, sr) = (score(l.element), score(r.element))
                if sl != sr { return sl > sr }
                let (ol, or) = (order[l.element.source] ?? 0, order[r.element.source] ?? 0)
                return ol != or ? ol < or : l.offset < r.offset
            }.map(\.element)
        }
    }

    private static func albums(from source: OnlineSource, artist: String, album: String) async throws -> [AlbumMatch] {
        switch source {
        case .appleMusic: return try await AppleMusicSource.albums(artist: artist, album: album)
        case .musicBrainz: return try await MusicBrainzSource.albums(artist: artist, album: album)
        case .deezer: return try await DeezerSource.albums(artist: artist, album: album)
        }
    }

    /// The tracklist of a match.
    static func songs(of match: AlbumMatch) async throws -> [AlbumMatch.Song] {
        switch match.source {
        case .appleMusic: return try await AppleMusicSource.songs(match.lookupID)
        case .musicBrainz: return try await MusicBrainzSource.songs(match.lookupID)
        case .deezer: return try await DeezerSource.songs(match.lookupID)
        }
    }

    /// Downloads an image, checking it really is one.
    static func image(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              NSImage(data: data) != nil else { return nil }
        return data
    }

    // MARK: Helpers

    static func json(_ url: URL) async throws -> Any {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// A URL with properly escaped query items ("&" and "+" in names included).
    static func url(_ base: String, _ params: [String: String]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func year(_ date: String?) -> Int? { date.flatMap { Int($0.prefix(4)) } }
}

// MARK: - Apple Music (iTunes Search)

private enum AppleMusicSource {
    static func albums(artist: String, album: String) async throws -> [AlbumMatch] {
        guard let url = OnlineMetadata.url("https://itunes.apple.com/search",
                                           ["term": "\(artist) \(album)", "media": "music", "entity": "album", "limit": "12"]) else { return [] }
        let rows = (try await OnlineMetadata.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let id = r["collectionId"] as? Int, let title = r["collectionName"] as? String else { return nil }
            let artistName = r["artistName"] as? String ?? ""
            let year = OnlineMetadata.year(r["releaseDate"] as? String)
            var cover: CoverCandidate?
            if let art = r["artworkUrl100"] as? String,
               let thumb = URL(string: art.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
               let full = URL(string: art.replacingOccurrences(of: "100x100bb", with: "3000x3000bb")) {
                cover = CoverCandidate(id: "apple:\(id)", source: .appleMusic, title: title, artist: artistName, year: year,
                                       thumbnail: thumb, full: full, maxPixels: 3000)
            }
            let explicit = (r["collectionExplicitness"] as? String) == "explicit" ? "explicit" : nil
            let note = [r["country"] as? String, explicit].compactMap { $0 }.joined(separator: " · ")
            return AlbumMatch(id: "apple:\(id)", source: .appleMusic, title: title, artist: artistName, year: year,
                              genre: r["primaryGenreName"] as? String, trackCount: r["trackCount"] as? Int ?? 0,
                              note: note.isEmpty ? nil : note, cover: cover, lookupID: String(id))
        }
    }

    static func songs(_ id: String) async throws -> [AlbumMatch.Song] {
        guard let url = OnlineMetadata.url("https://itunes.apple.com/lookup", ["id": id, "entity": "song", "limit": "200"]) else { return [] }
        let rows = (try await OnlineMetadata.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard (r["wrapperType"] as? String) == "track", let title = r["trackName"] as? String else { return nil }
            return AlbumMatch.Song(disc: r["discNumber"] as? Int ?? 1, number: r["trackNumber"] as? Int ?? 0,
                                   title: title, artist: r["artistName"] as? String ?? "")
        }
        .sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
    }
}

// MARK: - MusicBrainz + Cover Art Archive

private enum MusicBrainzSource {
    /// Lucene phrase, with its own quotes and backslashes escaped.
    private static func phrase(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func albums(artist: String, album: String) async throws -> [AlbumMatch] {
        var query = "release:\(phrase(album))"
        if !artist.isEmpty { query += " AND artist:\(phrase(artist))" }
        guard let url = OnlineMetadata.url("https://musicbrainz.org/ws/2/release/", ["query": query, "fmt": "json", "limit": "12"]) else { return [] }
        let rows = (try await OnlineMetadata.json(url) as? [String: Any])?["releases"] as? [[String: Any]] ?? []
        var seenGroups = Set<String>()
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
            let credit = (r["artist-credit"] as? [[String: Any]])?.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined() ?? ""
            let year = OnlineMetadata.year(r["date"] as? String)
            let group = (r["release-group"] as? [String: Any])?["id"] as? String
            let media = (r["media"] as? [[String: Any]])?.compactMap { $0["format"] as? String }.joined(separator: " + ")
            let label = ((r["label-info"] as? [[String: Any]])?.first?["label"] as? [String: Any])?["name"] as? String
            let note = [r["country"] as? String, media, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            // One cover per release group: editions mostly share art.
            var cover: CoverCandidate?
            if let group, seenGroups.insert(group).inserted,
               let thumb = URL(string: "https://coverartarchive.org/release-group/\(group)/front-250"),
               let full = URL(string: "https://coverartarchive.org/release-group/\(group)/front") {
                cover = CoverCandidate(id: "mb:\(group)", source: .musicBrainz, title: title, artist: credit, year: year,
                                       thumbnail: thumb, full: full, maxPixels: nil)
            }
            return AlbumMatch(id: "mb:\(id)", source: .musicBrainz, title: title, artist: credit, year: year, genre: nil,
                              trackCount: r["track-count"] as? Int ?? 0, note: note.isEmpty ? nil : note, cover: cover, lookupID: id)
        }
    }

    static func songs(_ id: String) async throws -> [AlbumMatch.Song] {
        guard let url = OnlineMetadata.url("https://musicbrainz.org/ws/2/release/\(id)", ["inc": "recordings artist-credits", "fmt": "json"]) else { return [] }
        let media = (try await OnlineMetadata.json(url) as? [String: Any])?["media"] as? [[String: Any]] ?? []
        return media.flatMap { m -> [AlbumMatch.Song] in
            let disc = m["position"] as? Int ?? 1
            return (m["tracks"] as? [[String: Any]] ?? []).compactMap { t in
                guard let title = t["title"] as? String else { return nil }
                let credit = (t["artist-credit"] as? [[String: Any]])?.map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined() ?? ""
                return AlbumMatch.Song(disc: disc, number: t["position"] as? Int ?? 0, title: title, artist: credit)
            }
        }
    }
}

// MARK: - Deezer

private enum DeezerSource {
    static func albums(artist: String, album: String) async throws -> [AlbumMatch] {
        // Deezer's album search ignores field syntax; plain words work.
        let q = "\(artist) \(album)".trimmingCharacters(in: .whitespaces)
        guard let url = OnlineMetadata.url("https://api.deezer.com/search/album", ["q": q, "limit": "12"]) else { return [] }
        let rows = (try await OnlineMetadata.json(url) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let id = r["id"] as? Int, let title = r["title"] as? String else { return nil }
            let artistName = (r["artist"] as? [String: Any])?["name"] as? String ?? ""
            var cover: CoverCandidate?
            if let thumb = (r["cover_medium"] as? String).flatMap(URL.init(string:)),
               let full = (r["cover_xl"] as? String).flatMap(URL.init(string:)) {
                cover = CoverCandidate(id: "deezer:\(id)", source: .deezer, title: title, artist: artistName, year: nil,
                                       thumbnail: thumb, full: full, maxPixels: 1000)
            }
            let type = (r["record_type"] as? String).map { $0 == "ep" ? "EP" : $0.capitalized }
            return AlbumMatch(id: "deezer:\(id)", source: .deezer, title: title, artist: artistName, year: nil, genre: nil,
                              trackCount: r["nb_tracks"] as? Int ?? 0, note: type, cover: cover, lookupID: String(id))
        }
    }

    static func songs(_ id: String) async throws -> [AlbumMatch.Song] {
        guard let url = URL(string: "https://api.deezer.com/album/\(id)/tracks?limit=200") else { return [] }
        let rows = (try await OnlineMetadata.json(url) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { i, r in
            guard let title = r["title"] as? String else { return nil }
            return AlbumMatch.Song(disc: r["disk_number"] as? Int ?? 1, number: r["track_position"] as? Int ?? i + 1,
                                   title: title, artist: (r["artist"] as? [String: Any])?["name"] as? String ?? "")
        }
    }
}

// MARK: - Lyrics

/// One lookup's result: lyrics, a clean miss, or a source that didn't work.
enum LyricsFetch: Sendable {
    case found(String, LyricsSource)
    case notFound
    /// Every source that was asked failed (down, timed out); the message says which.
    case unavailable(String)
}

enum LyricsLookup {
    /// Asks each source in order until one has lyrics. When `syncedOnly`,
    /// plain results don't count and plain-only sources are skipped.
    static func fetch(_ track: Track, sources: [LyricsSource], syncedOnly: Bool) async -> LyricsFetch {
        var failures: [String] = []
        var answered = false
        for source in sources where !(syncedOnly && source == .lyricsOvh) {
            switch await attempt(source, track) {
            case .success(let text?):
                if syncedOnly, LyricsState.of(text) != .synced { answered = true; continue }
                return .found(text, source)
            case .success(nil):
                answered = true
            case .failure(let message):
                failures.append("\(source.label) \(message)")
            }
        }
        if !answered, !failures.isEmpty { return .unavailable(failures.joined(separator: "; ")) }
        return .notFound
    }

    private enum Attempt { case success(String?), failure(String) }

    /// One source, retried once if it errors.
    private static func attempt(_ source: LyricsSource, _ track: Track) async -> Attempt {
        var last = Attempt.failure("didn't respond")
        for tryNumber in 0..<2 {
            if tryNumber > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            do {
                switch source {
                case .lrclib: return .success(try await lrclib(track))
                case .lyricsOvh: return .success(try await lyricsOvh(track))
                }
            } catch let error as HTTPStatus {
                last = .failure("is unavailable (\(error.code))")
            } catch {
                last = .failure("didn't respond")
            }
        }
        return last
    }

    private struct HTTPStatus: Error { var code: Int }

    /// The body for 200, nil for 404 (a clean miss), an error otherwise.
    private static func get(_ url: URL) async throws -> Data? {
        let (data, response) = try await OnlineMetadata.session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw HTTPStatus(code: code) }
        return data
    }

    private static func lrclib(_ t: Track) async throws -> String? {
        var params = ["artist_name": t.artist, "track_name": t.title]
        if !t.album.isEmpty { params["album_name"] = t.album }
        if t.duration > 0 { params["duration"] = String(Int(t.duration.rounded())) }
        if let url = OnlineMetadata.url("https://lrclib.net/api/get", params), let data = try await get(url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = pick(json) {
            return text
        }
        guard let url = OnlineMetadata.url("https://lrclib.net/api/search", ["artist_name": t.artist, "track_name": t.title]),
              let data = try await get(url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        // Prefer a synced result, then any.
        return rows.lazy.compactMap { row in (row["syncedLyrics"] as? String).flatMap { $0.contains("[") ? $0 : nil } }.first
            ?? rows.lazy.compactMap(pick).first
    }

    private static func pick(_ json: [String: Any]) -> String? {
        if let synced = json["syncedLyrics"] as? String, synced.contains("[") { return synced }
        if let plain = json["plainLyrics"] as? String, !plain.isEmpty { return plain }
        return nil
    }

    private static func lyricsOvh(_ t: Track) async throws -> String? {
        let artist = t.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
        let title = t.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
        guard !artist.isEmpty, !title.isEmpty, let url = URL(string: "https://api.lyrics.ovh/v1/\(artist)/\(title)"),
              let data = try await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var text = json["lyrics"] as? String else { return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Some entries start with a "Paroles de la chanson … par …" credit line.
        if let first = text.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("Paroles de la chanson") {
            text = String(text.dropFirst(first.count)).trimmingCharacters(in: .newlines)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
