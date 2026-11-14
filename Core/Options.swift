import Foundation

/// The bundled type families. Every one is a monospaced Nerd Font, so the
/// same file draws the text and the icons, on every platform Meimei ships to.
enum AppFontFamily: String, Codable, CaseIterable, Identifiable {
    case geistMono, jetBrainsMono, blexMono, iosevka, commitMono, monaspiceNeon
    case inter, geist, plexSans, spaceGrotesk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .geistMono: return "Geist Mono"
        case .jetBrainsMono: return "JetBrains Mono"
        case .blexMono: return "Blex Mono"
        case .iosevka: return "Iosevka"
        case .commitMono: return "Commit Mono"
        case .monaspiceNeon: return "Monaspice Neon"
        case .inter: return "Inter"
        case .geist: return "Geist"
        case .plexSans: return "IBM Plex Sans"
        case .spaceGrotesk: return "Space Grotesk"
        }
    }

    var note: String {
        switch self {
        case .geistMono: return "Calm and thin. The default."
        case .jetBrainsMono: return "Taller letters, very legible."
        case .blexMono: return "IBM Plex Mono, warm and engineered."
        case .iosevka: return "Narrow; fits the most into dense tables."
        case .commitMono: return "Neutral and quiet."
        case .monaspiceNeon: return "GitHub's Monaspace Neon, crisp and technical."
        case .inter: return "The neutral interface sans."
        case .geist: return "Geist Mono's proportional sibling."
        case .plexSans: return "IBM's sans, warm and engineered."
        case .spaceGrotesk: return "Geometric, with a technical edge."
        }
    }

    /// PostScript names of the bundled light, regular, and bold faces.
    var faces: (light: String, regular: String, bold: String) {
        switch self {
        case .geistMono: return ("GeistMonoNF-Light", "GeistMonoNF", "GeistMonoNF-Bold")
        case .jetBrainsMono: return ("JetBrainsMonoNF-Light", "JetBrainsMonoNF-Regular", "JetBrainsMonoNF-Bold")
        case .blexMono: return ("BlexMonoNF-Light", "BlexMonoNF", "BlexMonoNF-Bold")
        case .iosevka: return ("IosevkaNF-Light", "IosevkaNF", "IosevkaNF-Bold")
        case .commitMono: return ("CommitMonoNF", "CommitMonoNF", "CommitMonoNF-Bold")
        case .monaspiceNeon: return ("MonaspiceNeNF-Light", "MonaspiceNeNF", "MonaspiceNeNF-Bold")
        case .inter: return ("Inter-Light", "Inter-Regular", "Inter-Bold")
        case .geist: return ("Geist-Light", "Geist-Regular", "Geist-Bold")
        case .plexSans: return ("IBMPlexSans-Light", "IBMPlexSans", "IBMPlexSans-Bold")
        case .spaceGrotesk: return ("SpaceGrotesk-Light", "SpaceGrotesk-Regular", "SpaceGrotesk-Bold")
        }
    }

    /// Mono faces are Nerd Fonts; the sans faces are proportional and get
    /// tabular figures wherever numbers line up.
    var isMonospaced: Bool {
        switch self {
        case .inter, .geist, .plexSans, .spaceGrotesk: return false
        default: return true
        }
    }
}

enum IconPack: String, Codable, CaseIterable, Identifiable {
    case material, materialOutline, materialFilled, materialCircle, materialBox, codicons, fontAwesome, octicons
    var id: String { rawValue }
    var label: String {
        switch self {
        case .material: return "Material"
        case .materialOutline: return "Material Outline"
        case .materialFilled: return "Material Filled"
        case .materialCircle: return "Material Circle"
        case .materialBox: return "Material Box"
        case .codicons: return "Codicons"
        case .fontAwesome: return "Font Awesome"
        case .octicons: return "Octicons"
        }
    }

    var table: [String: UInt32] {
        switch self {
        case .material: return IconPackTables.material
        case .materialOutline: return IconPackTables.materialOutline
        case .materialFilled: return IconPackTables.materialFilled
        case .materialCircle: return IconPackTables.materialCircle
        case .materialBox: return IconPackTables.materialBox
        case .codicons: return IconPackTables.codicons
        case .fontAwesome: return IconPackTables.fontAwesome
        case .octicons: return IconPackTables.octicons
        }
    }
}

/// Where found lyrics are kept.
enum LyricsSaveMode: String, Codable, CaseIterable, Identifiable {
    case lrcFile, embedded, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lrcFile: return ".lrc file"
        case .embedded: return "In the file's tags"
        case .both: return "Both"
        }
    }
}

/// Where lyrics come from. Same rule as covers: only on request, straight
/// from this Mac, with nothing but the song's names and length.
enum LyricsSource: String, Codable, CaseIterable, Identifiable {
    case lrclib, lyricsOvh

    var id: String { rawValue }
    var label: String { self == .lrclib ? "lrclib.net" : "lyrics.ovh" }
    var detail: String {
        self == .lrclib ? "Community lyrics database, including synced lyrics." : "Plain lyrics (no timing)."
    }
    var host: String { self == .lrclib ? "lrclib.net" : "api.lyrics.ovh" }
}

/// Where online covers and album details come from. Every request goes
/// straight from this Mac to the provider, only when the user asks, with
/// nothing but the artist and album names: no account, no cookies, no
/// identifiers, and no Meimei server in between. A Meimei-run source would
/// be one more case here.
enum OnlineSource: String, Codable, CaseIterable, Identifiable {
    case appleMusic, musicBrainz, deezer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .musicBrainz: return "MusicBrainz"
        case .deezer: return "Deezer"
        }
    }

    var detail: String {
        switch self {
        case .appleMusic: return "iTunes Search. Large covers (up to 3000 px), tracklists, genres."
        case .musicBrainz: return "The open music encyclopedia, with the Cover Art Archive. Exact editions and originals."
        case .deezer: return "Deezer's catalog. Covers up to 1000 px, tracklists."
        }
    }

    /// The hosts a lookup contacts, shown so it's clear where requests go.
    var hosts: String {
        switch self {
        case .appleMusic: return "itunes.apple.com, is*-ssl.mzstatic.com"
        case .musicBrainz: return "musicbrainz.org, coverartarchive.org"
        case .deezer: return "api.deezer.com, cdn-images.dzcdn.net"
        }
    }

    var tag: String {
        switch self {
        case .appleMusic: return "apple"
        case .musicBrainz: return "musicbrainz"
        case .deezer: return "deezer"
        }
    }
}
