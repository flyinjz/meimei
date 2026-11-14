import Foundation
import AVFoundation

/// Reads tags, embedded artwork, and technical stats from an audio file.
enum MetadataReader {

    static func readTrack(url: URL, artwork: ArtworkStore) async -> Track? {
        let asset = AVURLAsset(url: url)
        var tags = Tags(fallbackTitle: url.deletingPathExtension().lastPathComponent)

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        // Common metadata covers ID3 and MP4; FLAC's Vorbis comments only
        // appear through the format-specific lists, read second so they win.
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                await tags.apply(key: key, item: item)
            }
        }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    let tail = item.identifier?.rawValue.split(separator: "/").last.map(String.init)
                    let key = (tail?.removingPercentEncoding ?? tail) ?? (item.key as? String) ?? ""
                    await tags.apply(key: key, item: item)
                }
            }
        }

        let tech = await technicalInfo(asset: asset, url: url, duration: duration)
        let artworkPath = tags.artworkData.flatMap { artwork.store($0) }

        return Track(
            filePath: url.path,
            title: tags.title,
            artist: tags.artist,
            album: tags.album,
            albumArtist: tags.albumArtist,
            genre: tags.genre,
            composer: tags.composer,
            year: tags.year,
            trackNumber: tags.trackNumber,
            discNumber: tags.discNumber,
            duration: duration.isFinite ? duration : 0,
            sampleRate: tech.sampleRate,
            bitDepth: tech.bitDepth,
            channelCount: tech.channels,
            estimatedBitrateKbps: tech.bitrateKbps,
            fileFormat: tech.format,
            artworkFilePath: artworkPath
        )
    }

    // MARK: - Tags

    private struct Tags {
        var title: String
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var albumArtist = ""
        var genre = "Unknown"
        var composer = ""
        var year: Int?
        var trackNumber: Int?
        var discNumber: Int?
        var artworkData: Data?

        init(fallbackTitle: String) {
            title = fallbackTitle
        }

        mutating func apply(key rawKey: String, item: AVMetadataItem) async {
            switch rawKey.uppercased() {
            case "TITLE", "TIT2", "TT2", "©NAM":
                if let v = await string(item) { title = v }
            case "ARTIST", "TPE1", "TP1", "©ART":
                if let v = await string(item) { artist = v }
            case "ALBUMNAME", "ALBUM", "TALB", "TAL", "©ALB":
                if let v = await string(item) { album = v }
            case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST", "TPE2", "TP2", "AART":
                if let v = await string(item) { albumArtist = v }
            case "GENRE", "TCON", "TCO", "©GEN", "GNRE":
                if let v = await string(item) { genre = Self.cleanGenre(v) }
            case "COMPOSER", "TCOM", "TCM", "©WRT":
                if let v = await string(item) { composer = v }
            case "TRACKNUMBER", "TRACK", "TRCK", "TRK", "TRKN":
                if let n = await number(item) { trackNumber = n }
            case "DISCNUMBER", "DISC", "TPOS", "TPA", "DISK":
                if let n = await number(item) { discNumber = n }
            case "CREATIONDATE", "DATE", "YEAR", "TYER", "TDRC", "TYE", "©DAY":
                if let v = await string(item), let y = Int(v.prefix(4)), y > 0 { year = y }
            case "ARTWORK", "APIC", "PIC", "COVR", "PICTURE", "METADATA_BLOCK_PICTURE":
                if artworkData == nil, let v = try? await item.load(.dataValue), !v.isEmpty { artworkData = v }
            default:
                break
            }
        }

        private func string(_ item: AVMetadataItem) async -> String? {
            guard let v = try? await item.load(.stringValue) else { return nil }
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// "3", "3/12", or MP4's binary `trkn`/`disk` atom (big-endian
        /// position at bytes 2...3).
        private func number(_ item: AVMetadataItem) async -> Int? {
            if let v = try? await item.load(.stringValue),
               let n = Int(v.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""), n > 0 {
                return n
            }
            if let v = try? await item.load(.numberValue), v.intValue > 0 { return v.intValue }
            if let d = try? await item.load(.dataValue), d.count >= 4 {
                let n = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                return n > 0 ? n : nil
            }
            return nil
        }

        /// ID3v1-style numeric genres like "(17)" read as the genre name.
        private static func cleanGenre(_ raw: String) -> String {
            let numeric = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if let n = Int(numeric), id3Genres.indices.contains(n) { return id3Genres[n] }
            return raw
        }

        private static let id3Genres = [
            "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
            "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
            "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
            "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game",
            "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative",
            "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
            "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
            "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
            "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka",
            "Retro", "Musical", "Rock & Roll", "Hard Rock"
        ]
    }

    // MARK: - Technical info

    struct TechnicalInfo {
        var sampleRate: Double = 44_100
        var bitDepth = 16
        var channels = 2
        var bitrateKbps = 0
        var format = ""
    }

    private static func technicalInfo(asset: AVURLAsset, url: URL, duration: Double) async -> TechnicalInfo {
        var info = TechnicalInfo()
        var formatID: AudioFormatID?
        var formatFlags: AudioFormatFlags = 0

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            if let desc = try? await audio.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                info.sampleRate = asbd.mSampleRate
                info.channels = Int(asbd.mChannelsPerFrame)
                formatID = asbd.mFormatID
                formatFlags = asbd.mFormatFlags
                if asbd.mBitsPerChannel > 0 { info.bitDepth = Int(asbd.mBitsPerChannel) }
            }
            if let rate = try? await audio.load(.estimatedDataRate), rate > 0 {
                info.bitrateKbps = Int(rate / 1000)
            }
        }

        let ext = url.pathExtension.lowercased()
        info.format = formatLabel(ext: ext, formatID: formatID)
        if let depth = losslessBitDepth(url: url, format: info.format, flags: formatFlags) {
            info.bitDepth = depth
        }
        if info.bitrateKbps == 0, duration > 0,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            info.bitrateKbps = Int(Double(size) * 8 / duration / 1000)
        }
        return info
    }

    /// Core Audio reports 0 bits per channel for FLAC and ALAC, so read the
    /// real source word length: FLAC's STREAMINFO block, or ALAC's flags.
    static func losslessBitDepth(url: URL, format: String, flags: AudioFormatFlags = 0) -> Int? {
        switch format {
        case "FLAC":
            return flacBitDepth(url: url)
        case "ALAC":
            switch flags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func flacBitDepth(url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: 64), head.count >= 10 else { return nil }

        // Skip a leading ID3v2 tag, which some taggers wrongly put on FLACs.
        if head.starts(with: Data("ID3".utf8)) {
            let size = (Int(head[6]) << 21) | (Int(head[7]) << 14) | (Int(head[8]) << 7) | Int(head[9])
            try? handle.seek(toOffset: UInt64(10 + size))
            guard let next = try? handle.read(upToCount: 64) else { return nil }
            head = next
        }
        // "fLaC", a 4-byte block header, then STREAMINFO: bits-per-sample − 1
        // is the 5 bits straddling bytes 12 and 13 of the block body.
        guard head.count >= 22, head.starts(with: Data("fLaC".utf8)), head[4] & 0x7F == 0 else { return nil }
        let body = head.startIndex + 8
        let bps = ((Int(head[body + 12]) & 0x01) << 4 | Int(head[body + 13]) >> 4) + 1
        return (4...32).contains(bps) ? bps : nil
    }

    /// Codec first, extension second: `.m4a` can be AAC or ALAC.
    private static func formatLabel(ext: String, formatID: AudioFormatID?) -> String {
        switch formatID {
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return ext.hasPrefix("aif") ? "AIFF" : "WAV"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_ELD_V2:
            return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        default: break
        }
        switch ext {
        case "mp3": return "MP3"
        case "m4a", "m4b", "aac": return "AAC"
        case "flac": return "FLAC"
        case "wav": return "WAV"
        case "aiff", "aif", "aifc": return "AIFF"
        case "alac": return "ALAC"
        default: return ext.uppercased()
        }
    }
}
