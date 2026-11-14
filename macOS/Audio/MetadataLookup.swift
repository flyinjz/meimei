import Foundation
import AppKit

/// Looks up covers (iTunes Search) and lyrics (lrclib) on request from Get Info.
enum MetadataLookup {
    struct Hit {
        var artworkURL: URL?
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: Int?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = [
            "User-Agent": "i2s/0.2 (macOS music player)"
        ]
        return URLSession(configuration: config)
    }()

    static func fetchArtwork(for track: Track) async -> Data? {
        if let url = try? await searchITunesAlbum(track), let data = await downloadImage(url) { return data }
        if let hit = try? await searchITunesSong(track), let url = hit.artworkURL, let data = await downloadImage(url) {
            return data
        }
        return nil
    }

    static func fetchLyrics(for track: Track) async -> String? {
        if let lrc = try? await lrclibGet(track), !lrc.isEmpty { return lrc }
        if let lrc = try? await lrclibSearch(track), !lrc.isEmpty { return lrc }
        return nil
    }

    private static func downloadImage(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              NSImage(data: data) != nil else { return nil }
        return data
    }

    // MARK: iTunes Search

    private static func searchITunesAlbum(_ track: Track) async throws -> URL? {
        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        let album = track.album.isEmpty ? track.title : track.album
        guard let url = query("https://itunes.apple.com/search",
                              ["term": "\(artist) \(album)", "media": "music", "entity": "album", "limit": "8"]) else {
            return nil
        }
        let (data, _) = try await session.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else {
            return nil
        }
        let needleAlbum = normalize(album)
        let needleArtist = normalize(artist)
        let best = results.max { a, b in
            albumScore(a, album: needleAlbum, artist: needleArtist) < albumScore(b, album: needleAlbum, artist: needleArtist)
        }
        guard let best, albumScore(best, album: needleAlbum, artist: needleArtist) >= 3,
              let raw = best["artworkUrl100"] as? String else { return nil }
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    private static func searchITunesSong(_ track: Track) async throws -> Hit? {
        guard let url = query("https://itunes.apple.com/search",
                              ["term": "\(track.artist) \(track.title)", "media": "music", "entity": "song", "limit": "8"]) else {
            return nil
        }
        let (data, _) = try await session.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else {
            return nil
        }
        let needleTitle = normalize(track.title)
        let needleArtist = normalize(track.artist)
        let best = results.max { a, b in
            score(a, title: needleTitle, artist: needleArtist) < score(b, title: needleTitle, artist: needleArtist)
        }
        guard let best, score(best, title: needleTitle, artist: needleArtist) >= 5 else { return nil }

        var artwork: URL?
        if let raw = best["artworkUrl100"] as? String {
            artwork = URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
        }
        var year: Int?
        if let date = best["releaseDate"] as? String { year = Int(date.prefix(4)) }
        return Hit(
            artworkURL: artwork,
            title: best["trackName"] as? String,
            artist: best["artistName"] as? String,
            album: best["collectionName"] as? String,
            genre: best["primaryGenreName"] as? String,
            year: year
        )
    }

    private static func albumScore(_ row: [String: Any], album: String, artist: String) -> Int {
        let t = normalize(row["collectionName"] as? String ?? "")
        let a = normalize(row["artistName"] as? String ?? "")
        var s = 0
        if t == album { s += 4 }
        else if t.contains(album) || album.contains(t) { s += 2 }
        if a == artist { s += 3 }
        else if a.contains(artist) || artist.contains(a) { s += 1 }
        return s
    }

    private static func score(_ row: [String: Any], title: String, artist: String) -> Int {
        let t = normalize(row["trackName"] as? String ?? "")
        let a = normalize(row["artistName"] as? String ?? "")
        var s = 0
        if t == title { s += 4 }
        else if t.contains(title) || title.contains(t) { s += 2 }
        if a == artist { s += 3 }
        else if a.contains(artist) || artist.contains(a) { s += 1 }
        return s
    }

    // MARK: lrclib

    private static func lrclibGet(_ track: Track) async throws -> String? {
        var params = ["artist_name": track.artist, "track_name": track.title]
        if !track.album.isEmpty { params["album_name"] = track.album }
        if track.duration > 0 { params["duration"] = String(Int(track.duration.rounded())) }
        guard let url = query("https://lrclib.net/api/get", params) else { return nil }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return lyrics(from: data)
    }

    private static func lrclibSearch(_ track: Track) async throws -> String? {
        guard let url = query("https://lrclib.net/api/search", ["artist_name": track.artist, "track_name": track.title]) else {
            return nil
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first else { return nil }
        if let synced = first["syncedLyrics"] as? String, synced.contains("[") { return synced }
        return first["plainLyrics"] as? String
    }

    private static func lyrics(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let synced = json["syncedLyrics"] as? String, synced.contains("[") { return synced }
        return json["plainLyrics"] as? String
    }

    /// Builds a URL with properly escaped query items ("&" and "+" in names included).
    private static func query(_ base: String, _ params: [String: String]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encoded
        return components.url
    }

    private static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
    }
}
