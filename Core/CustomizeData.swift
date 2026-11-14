import Foundation

// MARK: - Elements

/// Everything the customize mode can pick: the panels of the window and the
/// text roles inside them.
enum CustomElement: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable {
    // Panels
    case playerBar, nowPlayingPanel, browsePanel, libraryPanel, collectionRail, lyricsPanel, statusBar
    case eqGraph, eqPanels, tableHeader
    // Text
    case playerTitle, playerSubtitle, playerTimes
    case miniTitle, miniArtist, eqLabels, tableHeaderText
    case nowPlayingTitle, nowPlayingArtist, nowPlayingDetails
    case libraryTitle, librarySummary, sectionLabels, sidebarRows, railRows, tableText, statusText, lyricsText
    // Controls
    case windowControls

    var id: String { rawValue }

    enum Kind { case panel, text, controls }

    var kind: Kind {
        switch self {
        case .windowControls: return .controls
        case .playerBar, .nowPlayingPanel, .browsePanel, .libraryPanel, .collectionRail, .lyricsPanel, .statusBar,
             .eqGraph, .eqPanels, .tableHeader: return .panel
        default: return .text
        }
    }

    var label: String {
        switch self {
        case .playerBar: return "player bar"
        case .nowPlayingPanel: return "now playing"
        case .browsePanel: return "browse"
        case .libraryPanel: return "library"
        case .collectionRail: return "playlists"
        case .lyricsPanel: return "lyrics panel"
        case .statusBar: return "status bar"
        case .playerTitle: return "player title"
        case .playerSubtitle: return "player artist"
        case .playerTimes: return "player times"
        case .nowPlayingTitle: return "track title"
        case .nowPlayingArtist: return "track artist"
        case .nowPlayingDetails: return "track details"
        case .libraryTitle: return "library title"
        case .librarySummary: return "library summary"
        case .sectionLabels: return "section labels"
        case .sidebarRows: return "browse rows"
        case .railRows: return "playlist rows"
        case .tableText: return "track list"
        case .statusText: return "status text"
        case .lyricsText: return "lyrics"
        case .eqGraph: return "eq graph"
        case .eqPanels: return "eq panels"
        case .miniTitle: return "mini title"
        case .miniArtist: return "mini artist"
        case .eqLabels: return "eq labels"
        case .tableHeader: return "table header"
        case .tableHeaderText: return "table header labels"
        case .windowControls: return "window buttons"
        }
    }

    /// The movable pane this panel is, if it is one.
    var pane: PaneID? {
        switch self {
        case .nowPlayingPanel: return .nowPlaying
        case .browsePanel: return .browse
        case .libraryPanel: return .library
        case .collectionRail: return .playlists
        case .lyricsPanel: return .lyrics
        default: return nil
        }
    }

    /// Single-line titles, where alignment and line count make sense.
    var isTitle: Bool {
        [.playerTitle, .playerSubtitle, .nowPlayingTitle, .nowPlayingArtist, .libraryTitle, .librarySummary,
         .miniTitle, .miniArtist].contains(self)
    }
}

// MARK: - Styles

enum TextWeight: String, Codable, CaseIterable, Identifiable {
    case light, regular, bold
    var id: String { rawValue }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
}

/// Which sides of a panel a custom border draws.
struct BorderSides: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let top = BorderSides(rawValue: 1), bottom = BorderSides(rawValue: 2)
    static let leading = BorderSides(rawValue: 4), trailing = BorderSides(rawValue: 8)
    static let all: BorderSides = [.top, .bottom, .leading, .trailing]
}

/// One element's overrides. Nil means "as designed".
struct ElementStyle: Codable, Equatable {
    // Type
    var font: AppFontFamily?
    var sizeScale: Double?
    var weight: TextWeight?
    var color: UInt32?
    var opacity: Double?
    var tracking: Double?
    var align: TextAlign?
    var lines: Int?
    var shadow: Bool?
    // Surface
    var fill: UInt32?
    var fillOpacity: Double?
    var border: UInt32?
    var borderWidth: Double?
    var borderSides: BorderSides?
    var ticks: Bool?
    var padding: Double?
    var depth: Int?
    // Layout
    var height: Double?

    var isEmpty: Bool { self == ElementStyle() }

    /// This style with every property `other` sets (for `kind`) taking over:
    /// how a copied style pastes onto another element.
    func merging(_ other: ElementStyle, kind: CustomElement.Kind) -> ElementStyle {
        var s = self
        switch kind {
        case .text:
            s.font = other.font ?? s.font; s.sizeScale = other.sizeScale ?? s.sizeScale
            s.weight = other.weight ?? s.weight; s.color = other.color ?? s.color
            s.opacity = other.opacity ?? s.opacity; s.tracking = other.tracking ?? s.tracking
            s.align = other.align ?? s.align; s.lines = other.lines ?? s.lines; s.shadow = other.shadow ?? s.shadow
        case .panel:
            s.fill = other.fill ?? s.fill; s.fillOpacity = other.fillOpacity ?? s.fillOpacity
            s.border = other.border ?? s.border; s.borderWidth = other.borderWidth ?? s.borderWidth
            s.borderSides = other.borderSides ?? s.borderSides; s.ticks = other.ticks ?? s.ticks
            s.padding = other.padding ?? s.padding; s.depth = other.depth ?? s.depth
        case .controls:
            // Window buttons keep their own settings, not element styles.
            break
        }
        return s
    }
}

// MARK: - Tokens

enum GrayTone: String, Codable, CaseIterable, Identifiable {
    case neutral, warm, cool
    var id: String { rawValue }
    /// A gray at `white`, nudged toward the tone, as sRGB components 0…1.
    func rgb(_ white: Double) -> (red: Double, green: Double, blue: Double) {
        switch self {
        case .neutral: return (white, white, white)
        case .warm: return (min(1, white * 1.06 + 0.006), white * 1.01, white * 0.93)
        case .cool: return (white * 0.94, white * 0.99, min(1, white * 1.07 + 0.008))
        }
    }
}

/// App-wide design values every surface and text reads.
struct DesignTokens: Codable, Equatable {
    var accent: UInt32?
    var tone: GrayTone = .neutral
    var textScale: Double = 1
    var gap: Double = 6
    var borderWidth: Double = 1
    var panelOpacity: Double = 0.46
    var cornerTicks = true
    var tickLength: Double = 7

    static let gapRange: ClosedRange<Double> = 0...18
    static let textScaleRange: ClosedRange<Double> = 0.8...1.4
}

// MARK: - Layout

/// The movable panes of the main window.
enum PaneID: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable {
    case nowPlaying, browse, library, lyrics, playlists
    var id: String { rawValue }

    var element: CustomElement {
        switch self {
        case .nowPlaying: return .nowPlayingPanel
        case .browse: return .browsePanel
        case .library: return .libraryPanel
        case .lyrics: return .lyricsPanel
        case .playlists: return .collectionRail
        }
    }

    /// Takes its natural height in a stack until the user resizes it.
    var isIntrinsic: Bool { self == .nowPlaying }
}

/// A column of stacked panes. The column holding the library stretches;
/// the others have a width (nil: the pane's default).
struct PaneColumn: Codable, Equatable, Identifiable {
    var id = UUID()
    var panes: [PaneID]
    var width: Double?
    /// Share of the column's flexible height, per pane (default 1; an
    /// intrinsic pane without a weight takes its natural height).
    var weights: [PaneID: Double] = [:]

    func weight(_ pane: PaneID) -> Double { weights[pane] ?? (pane.isIntrinsic ? 0 : 1) }
}

/// Where a dragged pane lands.
enum DropTarget: Equatable {
    /// Into column `column`, before the pane at `index` (or at the end).
    case stack(column: Int, index: Int)
    /// As a new column inserted at `index`.
    case newColumn(index: Int)
}

struct PaneLayout: Codable, Equatable {
    var columns: [PaneColumn]
    var hidden: Set<PaneID> = []

    static let standard = PaneLayout(columns: [
        PaneColumn(panes: [.nowPlaying, .browse]),
        PaneColumn(panes: [.library]),
        PaneColumn(panes: [.lyrics]),
        PaneColumn(panes: [.playlists]),
    ])

    func columnIndex(of pane: PaneID) -> Int? { columns.firstIndex { $0.panes.contains(pane) } }

    mutating func move(_ pane: PaneID, to target: DropTarget) {
        guard let from = columnIndex(of: pane), let fromIndex = columns[from].panes.firstIndex(of: pane) else { return }
        let weight = columns[from].weights[pane]
        let width = columns[from].panes.count == 1 ? columns[from].width : nil
        columns[from].panes.remove(at: fromIndex)
        columns[from].weights = [:]
        switch target {
        case .stack(let column, let index):
            guard columns.indices.contains(column) else { break }
            // An index past the removed pane in the same column shifts up by one.
            let i = (column == from && index > fromIndex) ? index - 1 : index
            columns[column].panes.insert(pane, at: min(max(0, i), columns[column].panes.count))
            // Resized stacks keep weights in points; a newcomer would get a
            // sliver, so a changed stack starts from even shares again.
            if column == from { columns[column].weights[pane] = weight } else { columns[column].weights = [:] }
        case .newColumn(let index):
            columns.insert(PaneColumn(panes: [pane], width: width), at: min(max(0, index), columns.count))
        }
        normalize()
    }

    /// Keeps every pane in exactly one column and drops empty columns.
    mutating func normalize() {
        var seen = Set<PaneID>()
        for i in columns.indices {
            columns[i].panes = columns[i].panes.filter { seen.insert($0).inserted }
        }
        columns.removeAll { $0.panes.isEmpty }
        for pane in PaneID.allCases where !seen.contains(pane) {
            columns.append(PaneColumn(panes: [pane]))
        }
    }
}

// MARK: - Workspaces

/// A saved look: layout, tokens, and element styles together.
struct Workspace: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var layout: PaneLayout
    var tokens: DesignTokens
    var styles: [CustomElement: ElementStyle]
}
