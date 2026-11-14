import Foundation

// MARK: - Enumerated customization options

/// Row height, bar heights, and type size app-wide.
enum LayoutDensity: String, CaseIterable, Codable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 18
        case .comfortable: return 21
        case .spacious: return 26
        }
    }
    var statusBarHeight: CGFloat {
        switch self {
        case .compact: return 18
        case .comfortable: return 20
        case .spacious: return 25
        }
    }
    var rowFontSize: CGFloat {
        switch self {
        case .compact: return 10.5
        case .comfortable: return 11.5
        case .spacious: return 13
        }
    }
}

enum SidebarWidthMode: String, Codable, CaseIterable, Identifiable {
    case proportional, fixed
    var id: String { rawValue }
    var label: String { self == .proportional ? "Proportional (scales with window)" : "Fixed width" }
}

/// Optional library table columns. Title is always shown.
enum TrackColumnKind: String, Codable, CaseIterable, Identifiable {
    case track, artist, album, year, time, genre, plays, format, quality
    var id: String { rawValue }

    var label: String {
        switch self {
        case .track: return "Track #"
        case .artist: return "Artist"
        case .album: return "Album"
        case .year: return "Year"
        case .time: return "Time"
        case .genre: return "Genre"
        case .plays: return "Plays"
        case .format: return "Format"
        case .quality: return "Quality"
        }
    }

    static let defaults: [TrackColumnKind] = [.track, .artist, .album, .time, .genre, .format]
}

enum SliderStyleOption: String, Codable, CaseIterable, Identifiable {
    case line, knob
    var id: String { rawValue }

    /// Styles from older builds (e.g. "diamond") read as `.line`.
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .line
    }
    var label: String {
        switch self {
        case .line: return "Line (knob on hover)"
        case .knob: return "Line with knob"
        }
    }
}

/// How buttons are drawn, app-wide.
/// The close / minimize / full-screen buttons in i2s's own window frame.
enum WindowControlStyle: String, Codable, CaseIterable, Identifiable {
    case outline, filled, bare
    var id: String { rawValue }
    var label: String {
        switch self {
        case .outline: return "Outline"
        case .filled: return "Filled"
        case .bare: return "Icon only"
        }
    }
}

enum WindowControlShape: String, Codable, CaseIterable, Identifiable {
    case square, rounded, circle
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// What color the window buttons are at rest.
enum WindowControlColoring: String, Codable, CaseIterable, Identifiable {
    case theme, accent, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theme: return "Theme"
        case .accent: return "Accent"
        case .custom: return "Per button"
        }
    }
}

/// What a window button turns under the pointer.
enum WindowControlHover: String, Codable, CaseIterable, Identifiable {
    case accent, own, brighten
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accent: return "Accent"
        case .own: return "Its color"
        case .brighten: return "Brighten"
        }
    }
}

enum WindowControlGlyphs: String, Codable, CaseIterable, Identifiable {
    case hover, always, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hover: return "On hover"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

enum WindowControlSize: String, Codable, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var side: CGFloat {
        switch self {
        case .small: return 11
        case .regular: return 13
        case .large: return 16
        }
    }
}

enum ButtonFill: String, Codable, CaseIterable, Identifiable {
    case solid, outline, text
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "Solid"
        case .outline: return "Outline"
        case .text: return "Text only"
        }
    }
}

/// What a labeled button shows.
enum ButtonContent: String, Codable, CaseIterable, Identifiable {
    case iconAndText, text, icon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .iconAndText: return "Icon + text"
        case .text: return "Text"
        case .icon: return "Icon"
        }
    }
}

enum ButtonSize: String, Codable, CaseIterable, Identifiable {
    case compact, regular, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Added to the base height; the font steps with it.
    var delta: CGFloat {
        switch self {
        case .compact: return -3
        case .regular: return 0
        case .large: return 5
        }
    }
}

/// How panes and bars are drawn.
enum SurfaceStyle: String, Codable, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var label: String { self == .glass ? "Glass" : "Solid" }
}

/// What fills the window behind the panes (after Cider's background types).
enum BackdropStyle: String, Codable, CaseIterable, Identifiable {
    case translucent, themeColor, ambient, artwork
    var id: String { rawValue }
    var label: String {
        switch self {
        case .translucent: return "Wallpaper"
        case .themeColor: return "Solid"
        case .ambient: return "Grid"
        case .artwork: return "Album Art"
        }
    }
}

/// Where the player bar sits.
enum PlayerBarPosition: String, Codable, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How much room the player bar takes (after Cider's player types).
enum PlayerBarStyle: String, Codable, CaseIterable, Identifiable {
    case comfy, compact
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var height: CGFloat { self == .comfy ? 58 : 42 }
}

enum SpectrumStyleOption: String, Codable, CaseIterable, Identifiable {
    case gradient, solid, segmented, mirrored
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gradient: return "Gradient"
        case .solid: return "Solid"
        case .segmented: return "LED"
        case .mirrored: return "Mirrored"
        }
    }
}

/// The configurable pieces of window chrome listed under Settings → Panels.
enum PanelKind: String, CaseIterable, Identifiable {
    case nowPlayingRail, albumGrid, lyrics, statusBar, spectrum, transportButtons, eqToggle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nowPlayingRail: return "Now Playing Rail"
        case .albumGrid: return "Collection Rail"
        case .lyrics: return "Lyrics"
        case .statusBar: return "Status Bar"
        case .spectrum: return "Spectrum Analyzer"
        case .transportButtons: return "Player Bar"
        case .eqToggle: return "Equalizer"
        }
    }

    var icon: String {
        switch self {
        case .nowPlayingRail: return "rectangle.leftthird.inset.filled"
        case .albumGrid: return "music.note.list"
        case .lyrics: return "text.alignleft"
        case .statusBar: return "rectangle.bottomthird.inset.filled"
        case .spectrum: return "waveform"
        case .transportButtons: return "playpause.fill"
        case .eqToggle: return "slider.horizontal.3"
        }
    }

    var summary: String {
        switch self {
        case .nowPlayingRail: return "Artwork, title, and format info"
        case .albumGrid: return "Playlists and liked songs on the right"
        case .lyrics: return "Synced .lrc words beside the table"
        case .statusBar: return "Bottom info strip"
        case .spectrum: return "Live audio-reactive bars"
        case .transportButtons: return "Position, size, and which controls appear"
        case .eqToggle: return "Opens the EQ rack from the transport bar"
        }
    }
}

// MARK: - Persisted settings

/// Every user preference, stored as one blob. Defaults reproduce the stock
/// look; keys missing from an older payload fall back to them.
struct AppSettingsData: LenientDecodable, Equatable {
    // Panels
    var showSidebar = true
    var showAlbumGrid = true
    var showStatusBar = true
    /// The platform's own window frame (macOS: traffic lights, rounded
    /// corners) instead of Meimei's square one.
    var systemWindowFrame = false

    // Metadata
    /// Online lookups (covers, album details) on request; off hides them.
    var onlineLookups = true
    /// Sources to ask, in order.
    var metadataSources: [OnlineSource] = OnlineSource.allCases
    /// Edits go into the audio files' tags, not just the library.
    var writeTagsToFiles = true
    var cleanupRules = CleanupRules()
    // Lyrics
    var lyricsSaveMode: LyricsSaveMode = .lrcFile
    /// Lyrics sources to ask, in order.
    var lyricsSources: [LyricsSource] = LyricsSource.allCases
    /// Take only timed lyrics; plain text counts as not found.
    var lyricsSyncedOnly = false
    var lyricsReplaceExisting = false

    // Icons
    var iconPack: IconPack = .material
    /// Drawn size within each icon's box (0.8…1.25).
    var iconScale: Double = 1
    /// Icon role → a glyph chosen by hand.
    var iconOverrides: [String: UInt32] = [:]

    // Buttons
    var buttonFill: ButtonFill = .solid
    var buttonContent: ButtonContent = .iconAndText
    var buttonSize: ButtonSize = .regular
    /// Primary actions (Play, Save) in the accent; otherwise like the rest.
    var buttonAccentPrimary = true

    // Window controls (own frame only)
    var windowControlStyle: WindowControlStyle = .outline
    var windowControlGlyphs: WindowControlGlyphs = .hover
    var windowControlSize: WindowControlSize = .regular
    /// Tint the controls with the accent at rest, not only on hover.
    var windowControlAccent = false
    var windowControlShape: WindowControlShape = .square
    /// Box size, in points (`windowControlSize` is the older preset).
    var windowControlSide: Double = 13
    var windowControlSpacing: Double = 6
    /// The icon's size within its box.
    var windowControlIconScale: Double = 0.62
    var windowControlBorder: Double = 1
    var windowControlColoring: WindowControlColoring = .theme
    /// Per button ("close", "minimize", "zoom") when coloring is Custom.
    var windowControlColors: [String: UInt32] = [:]
    var windowControlHover: WindowControlHover = .accent
    /// How strong the icons are before you point at them.
    var windowControlRestOpacity: Double = 0.6
    /// Close at the far end instead of first.
    var windowControlCloseLast = false
    var showSpectrum = false
    var showLyrics = false

    // Layout
    var density: LayoutDensity = .comfortable
    var sidebarWidthMode: SidebarWidthMode = .proportional
    var sidebarProportionalPercent: Double = 0.25
    var sidebarFixedWidth: Double = 280
    var lyricsPanelWidth: Double = 290
    var collectionRailWidth: Double = 250

    // Library table
    var groupBy: TableGroupMode = .none
    var visibleColumns: [TrackColumnKind] = TrackColumnKind.defaults
    var tableShowGridLines = false
    var tableAlternatingRows = true
    var showHiResBadge = true

    // Album grid
    var albumGridTileSize: Double = 150

    // Library header
    var showSearchField = true
    var searchFieldWidth: Double = 200

    // Now playing rail
    var showFormatStrip = true
    var showNowPlayingSubtitle = true

    // Status bar
    var statusBarShowSelectionCount = true
    var statusBarShowScanProgress = true

    // Spectrum analyzer
    var spectrumStyle: SpectrumStyleOption = .gradient
    var spectrumBarSpacing: Double = 2
    var spectrumWidth: Double = 90
    var spectrumBandCount: Int = 24
    var spectrumShowPeaks = true

    // Player bar
    var playerBarPosition: PlayerBarPosition = .top
    var playerBarStyle: PlayerBarStyle = .comfy
    var transportButtonScale: Double = 1.0
    var volumeSliderWidth: Double = 84
    var showShuffleRepeat = true
    var showEQToggle = true
    var showLyricsButton = true
    var showQueueButton = true
    var showMiniPlayerButton = false
    var accentProgress = false

    // Appearance
    var surfaceStyle: SurfaceStyle = .glass
    var backdropStyle: BackdropStyle = .artwork
    /// How strongly the theme tints the window glass: low shows more of
    /// what's behind the window, high more of the theme.
    var glassTintStrength: Double = 0.55
    /// How much the theme darkens the frosted Downloads and legal windows.
    var downloadsGlassTint: Double = 0.04
    var sliderStyle: SliderStyleOption = .line
    var useMonospacedNumbers = true
    var hairlineOpacity: Double = 1.0
    var fontFamily: AppFontFamily = .geistMono

    // Behavior
    var playOnSingleClick = false
    var confirmBeforeRemovingFromLibrary = true
    var rememberLastView = false
    var resumeLastSession = true
    var crossfadeSeconds: Double = 0
    var lyricsOffset: Double = 0
    /// Empty means "use the Mac account name". Never leaves the machine.
    var localAccountName = ""

    init() {}
}
