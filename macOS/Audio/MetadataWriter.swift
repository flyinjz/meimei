import Foundation
import AVFoundation
import ImageIO

/// Writes tags back into audio files. Only the fields Meimei edits are
/// replaced; every other frame, comment, and block already in the file
/// (lyrics, ReplayGain, comments, other taggers' data) is carried over.
enum MetadataWriter {
    enum WriteError: LocalizedError {
        case unsupported(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let format): return "\(format) files can't be tagged in place; the change was saved to the library only."
            case .malformed(let detail): return "The file's existing tags couldn't be read safely (\(detail)); it was left untouched."
            }
        }
    }

    /// The editable fields, as they should end up in the file.
    struct Fields: Sendable {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var genre: String
        var composer: String
        var year: Int?
        var trackNumber: Int?
        var discNumber: Int?
        /// nil leaves the file's lyrics alone; "" removes them.
        var lyrics: String?

        init(_ t: Track, lyrics: String? = nil) {
            self.lyrics = lyrics
            title = t.title
            artist = t.artist
            album = t.album
            albumArtist = t.albumArtist
            genre = t.genre
            composer = t.composer
            year = t.year
            trackNumber = t.trackNumber
            discNumber = t.discNumber
        }
    }

    static func canWrite(_ url: URL) -> Bool {
        ["mp3", "flac", "m4a", "m4b", "aac", "alac"].contains(url.pathExtension.lowercased())
    }

    /// Writes `fields`, and `artworkJPEG` when the cover changed (nil keeps
    /// whatever cover the file already has).
    static func write(_ fields: Fields, artworkJPEG: Data?, to url: URL) async throws {
        switch url.pathExtension.lowercased() {
        case "mp3":
            try ID3Writer.write(fields, artwork: artworkJPEG, to: url)
        case "flac":
            try FLACWriter.write(fields, artwork: artworkJPEG, to: url)
        case "m4a", "m4b", "aac", "alac":
            try await MP4Writer.write(fields, artwork: artworkJPEG, to: url)
        default:
            throw WriteError.unsupported(url.pathExtension.uppercased())
        }
    }
}

// MARK: - ID3v2.4 (MP3)

/// Rewrites the ID3v2 tag at the head of an MP3 as v2.4 with UTF-8 text.
enum ID3Writer {
    private static let owned: Set<String> = ["TIT2", "TPE1", "TALB", "TPE2", "TCON", "TCOM", "TDRC", "TYER", "TDAT", "TRCK", "TPOS"]

    static func write(_ f: MetadataWriter.Fields, artwork: Data?, to url: URL) throws {
        let file = try Data(contentsOf: url)
        let (existing, audioStart) = try parse(file)

        var frames: [(id: String, body: Data)] = []
        func text(_ id: String, _ value: String) {
            guard !value.isEmpty else { return }
            frames.append((id, Data([0x03]) + Data(value.utf8)))
        }
        text("TIT2", f.title)
        text("TPE1", f.artist)
        text("TALB", f.album)
        text("TPE2", f.albumArtist)
        text("TCON", f.genre == "Unknown" ? "" : f.genre)
        text("TCOM", f.composer)
        if let y = f.year { text("TDRC", String(y)) }
        if let n = f.trackNumber { text("TRCK", String(n)) }
        if let n = f.discNumber { text("TPOS", String(n)) }
        if let artwork {
            var body = Data([0x00]) + Data("image/jpeg".utf8) + Data([0x00, 0x03, 0x00])
            body.append(artwork)
            frames.append(("APIC", body))
        }
        // USLT: UTF-8, language "eng", empty description, then the text.
        if let lyrics = f.lyrics, !lyrics.isEmpty {
            frames.append(("USLT", Data([0x03]) + Data("eng".utf8) + Data([0x00]) + Data(lyrics.utf8)))
        }
        for frame in existing where !owned.contains(frame.id) && !(artwork != nil && frame.id == "APIC")
            && !(f.lyrics != nil && frame.id == "USLT") {
            frames.append(frame)
        }

        var tagBody = Data()
        for frame in frames {
            tagBody.append(Data(frame.id.utf8))
            tagBody.append(contentsOf: synchsafe(UInt32(frame.body.count)))
            tagBody.append(contentsOf: [0x00, 0x00])
            tagBody.append(frame.body)
        }
        tagBody.append(Data(count: 1024)) // padding, so later edits by other taggers can be in place

        var output = Data("ID3".utf8) + Data([0x04, 0x00, 0x00]) + Data(synchsafe(UInt32(tagBody.count)))
        output.append(tagBody)
        output.append(file[audioStart...])
        try output.write(to: url, options: .atomic)
    }

    /// Existing frames (as v2.4-compatible bodies) and where the audio begins.
    static func parse(_ data: Data) throws -> (frames: [(id: String, body: Data)], audioStart: Int) {
        guard data.count >= 10, data.starts(with: Data("ID3".utf8)) else { return ([], 0) }
        let base = data.startIndex
        let version = data[base + 3]
        let flags = data[base + 5]
        let tagSize = readSynchsafe(data, base + 6)
        let end = min(data.count, 10 + tagSize + ((flags & 0x10) != 0 ? 10 : 0))
        guard version == 3 || version == 4 else {
            // v2.2 frames are a different format; replace the tag entirely.
            return ([], end)
        }
        guard flags & 0x80 == 0 else { throw MetadataWriter.WriteError.malformed("unsynchronised ID3 tag") }

        var pos = 10
        if flags & 0x40 != 0 {
            let extSize = version == 4 ? readSynchsafe(data, base + 10) : readUInt32(data, base + 10) + 4
            pos += extSize
        }

        var frames: [(String, Data)] = []
        while pos + 10 <= 10 + tagSize, pos + 10 <= data.count {
            let idBytes = data[(base + pos)..<(base + pos + 4)]
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }),
                  let id = String(data: idBytes, encoding: .ascii) else { break }
            let size = version == 4 ? readSynchsafe(data, base + pos + 4) : readUInt32(data, base + pos + 4)
            let frameFlags = data[base + pos + 9]
            let bodyStart = pos + 10
            guard size > 0, bodyStart + size <= data.count else { break }
            let body = data[(base + bodyStart)..<(base + bodyStart + size)]
            // Compressed, encrypted, or per-frame unsynchronised frames can't
            // be carried over byte-for-byte; drop just those.
            let unsafeFlags: UInt8 = version == 4 ? 0x0F : 0xE0
            if frameFlags & unsafeFlags == 0 {
                frames.append((id, Data(body)))
            }
            pos = bodyStart + size
        }
        return (frames, end)
    }

    private static func synchsafe(_ n: UInt32) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    private static func readSynchsafe(_ d: Data, _ i: Int) -> Int {
        Int(d[i]) << 21 | Int(d[i + 1]) << 14 | Int(d[i + 2]) << 7 | Int(d[i + 3])
    }

    private static func readUInt32(_ d: Data, _ i: Int) -> Int {
        Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
    }
}

// MARK: - FLAC

/// Replaces a FLAC file's Vorbis comment (and picture, when the cover
/// changed), keeping every other metadata block and comment.
enum FLACWriter {
    private static let owned: Set<String> = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "ALBUM ARTIST", "GENRE", "COMPOSER",
                                             "DATE", "YEAR", "TRACKNUMBER", "DISCNUMBER"]

    struct Block {
        var type: UInt8
        var body: Data
    }

    static func write(_ f: MetadataWriter.Fields, artwork: Data?, to url: URL) throws {
        let file = try Data(contentsOf: url)
        let (blocks, audioStart) = try parse(file)
        guard blocks.first?.type == 0 else { throw MetadataWriter.WriteError.malformed("missing STREAMINFO") }

        var vendor = "i2s"
        var kept: [String] = []
        if let comment = blocks.first(where: { $0.type == 4 }) {
            (vendor, kept) = try parseComments(comment.body)
            kept.removeAll { comment in
                let key = comment.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? ""
                return owned.contains(key) || (f.lyrics != nil && (key == "LYRICS" || key == "UNSYNCEDLYRICS"))
            }
        }
        var comments: [String] = []
        func add(_ key: String, _ value: String) {
            if !value.isEmpty { comments.append("\(key)=\(value)") }
        }
        add("TITLE", f.title)
        add("ARTIST", f.artist)
        add("ALBUM", f.album)
        add("ALBUMARTIST", f.albumArtist)
        add("GENRE", f.genre == "Unknown" ? "" : f.genre)
        add("COMPOSER", f.composer)
        if let y = f.year { add("DATE", String(y)) }
        if let n = f.trackNumber { add("TRACKNUMBER", String(n)) }
        if let n = f.discNumber { add("DISCNUMBER", String(n)) }
        if let lyrics = f.lyrics { add("LYRICS", lyrics) }
        comments += kept

        var out: [Block] = []
        for block in blocks {
            switch block.type {
            case 1, 4: continue                           // padding, old comments
            case 6 where artwork != nil: continue         // old cover, being replaced
            default: out.append(block)
            }
        }
        out.insert(Block(type: 4, body: encodeComments(vendor: vendor, comments: comments)), at: 1)
        if let artwork { out.insert(Block(type: 6, body: pictureBlock(artwork)), at: 2) }
        out.append(Block(type: 1, body: Data(count: 4096)))

        var output = Data("fLaC".utf8)
        for (i, block) in out.enumerated() {
            guard block.body.count < 1 << 24 else { throw MetadataWriter.WriteError.malformed("metadata block too large") }
            let last: UInt8 = i == out.count - 1 ? 0x80 : 0
            let n = block.body.count
            output.append(contentsOf: [last | block.type, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            output.append(block.body)
        }
        output.append(file[(file.startIndex + audioStart)...])
        try output.write(to: url, options: .atomic)
    }

    static func parse(_ data: Data) throws -> (blocks: [Block], audioStart: Int) {
        let base = data.startIndex
        guard data.count >= 8, data.starts(with: Data("fLaC".utf8)) else {
            throw MetadataWriter.WriteError.malformed("not a native FLAC stream")
        }
        var pos = 4
        var blocks: [Block] = []
        while true {
            guard pos + 4 <= data.count else { throw MetadataWriter.WriteError.malformed("truncated metadata") }
            let header = data[base + pos]
            let length = Int(data[base + pos + 1]) << 16 | Int(data[base + pos + 2]) << 8 | Int(data[base + pos + 3])
            let start = pos + 4
            guard start + length <= data.count else { throw MetadataWriter.WriteError.malformed("truncated block") }
            blocks.append(Block(type: header & 0x7F, body: Data(data[(base + start)..<(base + start + length)])))
            pos = start + length
            if header & 0x80 != 0 { break }
        }
        return (blocks, pos)
    }

    static func parseComments(_ body: Data) throws -> (vendor: String, comments: [String]) {
        var pos = body.startIndex
        func u32() throws -> Int {
            guard pos + 4 <= body.endIndex else { throw MetadataWriter.WriteError.malformed("bad Vorbis comment") }
            defer { pos += 4 }
            return Int(body[pos]) | Int(body[pos + 1]) << 8 | Int(body[pos + 2]) << 16 | Int(body[pos + 3]) << 24
        }
        func string(_ n: Int) throws -> String {
            guard pos + n <= body.endIndex else { throw MetadataWriter.WriteError.malformed("bad Vorbis comment") }
            defer { pos += n }
            return String(decoding: body[pos..<(pos + n)], as: UTF8.self)
        }
        let vendor = try string(try u32())
        let count = try u32()
        var comments: [String] = []
        for _ in 0..<count { comments.append(try string(try u32())) }
        return (vendor, comments)
    }

    static func encodeComments(vendor: String, comments: [String]) -> Data {
        var d = Data()
        func u32(_ n: Int) { d.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]) }
        let v = Data(vendor.utf8)
        u32(v.count)
        d.append(v)
        u32(comments.count)
        for c in comments {
            let bytes = Data(c.utf8)
            u32(bytes.count)
            d.append(bytes)
        }
        return d
    }

    private static func pictureBlock(_ jpeg: Data) -> Data {
        var width = 0, height = 0
        if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        var d = Data()
        func u32(_ n: Int) { d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) }
        let mime = Data("image/jpeg".utf8)
        u32(3)                // front cover
        u32(mime.count); d.append(mime)
        u32(0)                // empty description
        u32(width); u32(height)
        u32(24)               // color depth
        u32(0)                // not indexed
        u32(jpeg.count); d.append(jpeg)
        return d
    }
}

// MARK: - MP4 (AAC / ALAC)

/// Re-muxes the file with updated iTunes metadata. No re-encoding.
enum MP4Writer {
    static func write(_ f: MetadataWriter.Fields, artwork: Data?, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let existing = (try? await asset.load(.metadata)) ?? []

        var replaced: Set<AVMetadataIdentifier> = [
            .iTunesMetadataSongName, .iTunesMetadataArtist, .iTunesMetadataAlbum, .iTunesMetadataAlbumArtist,
            .iTunesMetadataUserGenre, .iTunesMetadataGenreID, .iTunesMetadataComposer, .iTunesMetadataReleaseDate,
            .iTunesMetadataTrackNumber, .iTunesMetadataDiscNumber,
            .commonIdentifierTitle, .commonIdentifierArtist, .commonIdentifierAlbumName, .commonIdentifierCreationDate
        ]
        if artwork != nil { replaced.formUnion([.iTunesMetadataCoverArt, .commonIdentifierArtwork]) }
        if f.lyrics != nil { replaced.insert(.iTunesMetadataLyrics) }

        var items = existing.filter { item in item.identifier.map { !replaced.contains($0) } ?? true }
        func add(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            items.append(item)
        }
        func text(_ s: String) -> NSString? { s.isEmpty ? nil : s as NSString }
        add(.iTunesMetadataSongName, text(f.title))
        add(.iTunesMetadataArtist, text(f.artist))
        add(.iTunesMetadataAlbum, text(f.album))
        add(.iTunesMetadataAlbumArtist, text(f.albumArtist))
        add(.iTunesMetadataUserGenre, text(f.genre == "Unknown" ? "" : f.genre))
        add(.iTunesMetadataComposer, text(f.composer))
        add(.iTunesMetadataReleaseDate, f.year.map { String($0) as NSString })
        add(.iTunesMetadataTrackNumber, f.trackNumber.map { Data([0, 0, UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF), 0, 0, 0, 0]) as NSData })
        add(.iTunesMetadataDiscNumber, f.discNumber.map { Data([0, 0, UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF), 0, 0]) as NSData })
        add(.iTunesMetadataCoverArt, artwork as NSData?)
        add(.iTunesMetadataLyrics, f.lyrics.flatMap { $0.isEmpty ? nil : $0 as NSString })

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MetadataWriter.WriteError.unsupported("This MP4")
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".meimei-\(UUID().uuidString).m4a")
        export.outputURL = temp
        export.outputFileType = .m4a
        export.metadata = items
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw export.error ?? MetadataWriter.WriteError.unsupported("This MP4")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

// MARK: - Reading embedded lyrics

/// Lyrics stored inside an audio file's tags (FLAC LYRICS, ID3 USLT, MP4
/// ©lyr). Reads only the tag, skipping past covers, so checking many files
/// stays cheap.
enum EmbeddedLyrics {
    static func read(_ url: URL) async -> String? {
        switch url.pathExtension.lowercased() {
        case "flac": return flac(url)
        case "mp3": return id3(url)
        case "m4a", "m4b", "aac", "alac":
            let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
            for item in items where item.identifier == .iTunesMetadataLyrics {
                if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
            }
            return nil
        default: return nil
        }
    }

    private static func flac(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        while let header = try? handle.read(upToCount: 4), header.count == 4 {
            let bytes = [UInt8](header)
            let last = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            if type == 4 {
                guard let body = try? handle.read(upToCount: length),
                      let (_, comments) = try? FLACWriter.parseComments(body) else { return nil }
                for c in comments {
                    let parts = c.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].uppercased()
                    if key == "LYRICS" || key == "UNSYNCEDLYRICS" { return String(parts[1]) }
                }
                return nil
            }
            guard !last, (try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))) != nil else { return nil }
        }
        return nil
    }

    private static func id3(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 10), head.count == 10, head.starts(with: Data("ID3".utf8)) else { return nil }
        let b = [UInt8](head)
        let size = Int(b[6]) << 21 | Int(b[7]) << 14 | Int(b[8]) << 7 | Int(b[9])
        guard let rest = try? handle.read(upToCount: size), let (frames, _) = try? ID3Writer.parse(head + rest) else { return nil }
        guard let body = frames.first(where: { $0.id == "USLT" })?.body, body.count > 4 else { return nil }
        let encoding = body[body.startIndex]
        var text = body.dropFirst(4) // encoding + language
        // Skip the content description (terminated by 0x00, or 0x00 0x00 in UTF-16).
        let wide = encoding == 1 || encoding == 2
        if wide {
            var i = text.startIndex
            while i + 1 < text.endIndex, !(text[i] == 0 && text[i + 1] == 0) { i += 2 }
            text = text[min(i + 2, text.endIndex)...]
        } else if let zero = text.firstIndex(of: 0) {
            text = text[text.index(after: zero)...]
        }
        let decoded: String?
        switch encoding {
        case 0: decoded = String(data: Data(text), encoding: .isoLatin1)
        case 1: decoded = String(data: Data(text), encoding: .utf16)
        case 2: decoded = String(data: Data(text), encoding: .utf16BigEndian)
        default: decoded = String(data: Data(text), encoding: .utf8)
        }
        return decoded?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
