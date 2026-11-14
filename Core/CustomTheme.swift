import Foundation

// MARK: - User-editable themes

/// Every color a theme controls, grouped for the editor, with a key path
/// into `CustomTheme` so the editor renders them generically.
enum ThemeColorField: CaseIterable, Identifiable {
    case bgVoid, bgPanel, bgRow, bgRowAlt, bgRaised, hairline
    case textPrimary, textSecondary, textTertiary, textOnAccent
    case accent, accentDim, accentGlow
    case selection, hover
    case lcdOn, lcdOff, lcdBackground

    var id: Self { self }

    var label: String {
        switch self {
        case .bgVoid: return "Void Background"
        case .bgPanel: return "Panel Background"
        case .bgRow: return "Row Background"
        case .bgRowAlt: return "Alternating Row"
        case .bgRaised: return "Raised Surface"
        case .hairline: return "Hairline / Divider"
        case .textPrimary: return "Primary Text"
        case .textSecondary: return "Secondary Text"
        case .textTertiary: return "Tertiary Text"
        case .textOnAccent: return "Text on Accent"
        case .accent: return "Accent"
        case .accentDim: return "Accent (Dim)"
        case .accentGlow: return "Accent (Glow)"
        case .selection: return "Selection"
        case .hover: return "Hover"
        case .lcdOn: return "LCD On"
        case .lcdOff: return "LCD Off"
        case .lcdBackground: return "LCD Background"
        }
    }

    var group: String {
        switch self {
        case .bgVoid, .bgPanel, .bgRow, .bgRowAlt, .bgRaised, .hairline: return "Backgrounds"
        case .textPrimary, .textSecondary, .textTertiary, .textOnAccent: return "Text"
        case .accent, .accentDim, .accentGlow: return "Accent"
        case .selection, .hover: return "Interactive"
        case .lcdOn, .lcdOff, .lcdBackground: return "LCD Readout"
        }
    }

    /// Display order for the group headers in the theme editor.
    static let groups: [String] = ["Backgrounds", "Text", "Accent", "Interactive", "LCD Readout"]

    var keyPath: WritableKeyPath<CustomTheme, UInt32> {
        switch self {
        case .bgVoid: return \CustomTheme.bgVoid
        case .bgPanel: return \CustomTheme.bgPanel
        case .bgRow: return \CustomTheme.bgRow
        case .bgRowAlt: return \CustomTheme.bgRowAlt
        case .bgRaised: return \CustomTheme.bgRaised
        case .hairline: return \CustomTheme.hairline
        case .textPrimary: return \CustomTheme.textPrimary
        case .textSecondary: return \CustomTheme.textSecondary
        case .textTertiary: return \CustomTheme.textTertiary
        case .textOnAccent: return \CustomTheme.textOnAccent
        case .accent: return \CustomTheme.accent
        case .accentDim: return \CustomTheme.accentDim
        case .accentGlow: return \CustomTheme.accentGlow
        case .selection: return \CustomTheme.selection
        case .hover: return \CustomTheme.hover
        case .lcdOn: return \CustomTheme.lcdOn
        case .lcdOff: return \CustomTheme.lcdOff
        case .lcdBackground: return \CustomTheme.lcdBackground
        }
    }
}

/// A user-editable theme: every `Skin` color as 24-bit RGB, so it
/// round-trips through storage exactly.
struct CustomTheme: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String

    var bgVoid: UInt32
    var bgPanel: UInt32
    var bgRow: UInt32
    var bgRowAlt: UInt32
    var bgRaised: UInt32
    var hairline: UInt32

    var textPrimary: UInt32
    var textSecondary: UInt32
    var textTertiary: UInt32
    var textOnAccent: UInt32

    var accent: UInt32
    var accentDim: UInt32
    var accentGlow: UInt32

    var selection: UInt32
    var hover: UInt32

    var lcdOn: UInt32
    var lcdOff: UInt32
    var lcdBackground: UInt32

    /// Grouping label in the Customize → Appearance list ("Y2K", "Listening Bar", …).
    var category: String
    /// When true, colors are sampled live from the playing track's artwork
    /// instead of these stored hex values, and the window backdrop becomes
    /// a blurred cover.
    var isAlbumReactive: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name
        case bgVoid, bgPanel, bgRow, bgRowAlt, bgRaised, hairline
        case textPrimary, textSecondary, textTertiary, textOnAccent
        case accent, accentDim, accentGlow, selection, hover
        case lcdOn, lcdOff, lcdBackground
        case category, isAlbumReactive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bgVoid = try c.decode(UInt32.self, forKey: .bgVoid)
        bgPanel = try c.decode(UInt32.self, forKey: .bgPanel)
        bgRow = try c.decode(UInt32.self, forKey: .bgRow)
        bgRowAlt = try c.decode(UInt32.self, forKey: .bgRowAlt)
        bgRaised = try c.decode(UInt32.self, forKey: .bgRaised)
        hairline = try c.decode(UInt32.self, forKey: .hairline)
        textPrimary = try c.decode(UInt32.self, forKey: .textPrimary)
        textSecondary = try c.decode(UInt32.self, forKey: .textSecondary)
        textTertiary = try c.decode(UInt32.self, forKey: .textTertiary)
        textOnAccent = try c.decode(UInt32.self, forKey: .textOnAccent)
        accent = try c.decode(UInt32.self, forKey: .accent)
        accentDim = try c.decode(UInt32.self, forKey: .accentDim)
        accentGlow = try c.decode(UInt32.self, forKey: .accentGlow)
        // Added later; older themes fall back to the colors these replaced.
        selection = try c.decodeIfPresent(UInt32.self, forKey: .selection) ?? accentDim
        hover = try c.decodeIfPresent(UInt32.self, forKey: .hover) ?? bgRaised
        lcdOn = try c.decode(UInt32.self, forKey: .lcdOn)
        lcdOff = try c.decode(UInt32.self, forKey: .lcdOff)
        lcdBackground = try c.decode(UInt32.self, forKey: .lcdBackground)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Custom"
        isAlbumReactive = try c.decodeIfPresent(Bool.self, forKey: .isAlbumReactive) ?? false
    }
}

extension CustomTheme {
    static let albumReactiveID = UUID(uuidString: "9E5B1000-0000-4000-8000-00000000C0DE")!

    /// A theme with a palette's colours.
    init(id: UUID, name: String, palette p: Palette) {
        self.id = id
        self.name = name
        bgVoid = p.bgVoid; bgPanel = p.bgPanel; bgRow = p.bgRow; bgRowAlt = p.bgRowAlt
        bgRaised = p.bgRaised; hairline = p.hairline
        textPrimary = p.textPrimary; textSecondary = p.textSecondary
        textTertiary = p.textTertiary; textOnAccent = p.textOnAccent
        accent = p.accent; accentDim = p.accentDim; accentGlow = p.accentGlow
        selection = p.selection; hover = p.hover
        lcdOn = p.lcdOn; lcdOff = p.lcdOff; lcdBackground = p.lcdBackground
        category = "Custom"
        isAlbumReactive = p.bleed
    }

    /// First-launch seed + catalog merge source. Stable IDs so we can add new
    /// palettes later without overwriting a user's edits to ones they already have.
    static let starterThemes: [CustomTheme] = {
        let specs: [(UUID, String, Palette, Bool)] = [
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000001")!, "Y2K", .voidBlack, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000002")!, "Y2K", .terminalAmber, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000003")!, "Y2K", .coldSteelCyan, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000004")!, "Y2K", .bloodChrome, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000005")!, "Y2K", .acidStatic, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000006")!, "Listening Bar", .lofiHarbor, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000007")!, "Listening Bar", .matchaHour, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000008")!, "Listening Bar", .loopStation, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-000000000009")!, "Studio", .pulseRed, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-00000000000A")!, "Studio", .pacificGlass, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-00000000000B")!, "Studio", .softSpotlight, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-00000000000C")!, "Afterimage", .nightSession, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-00000000000D")!, "Afterimage", .phosphor, false),
            (UUID(uuidString: "9E5B1000-0000-4000-8000-00000000000E")!, "Afterimage", .gardenRain, false),
            (albumReactiveID, "Live", .fromCoverPlaceholder, true),
        ]
        return specs.map { id, category, palette, reactive in
            var theme = CustomTheme(id: id, name: palette.name, palette: palette)
            theme.category = category
            theme.isAlbumReactive = reactive
            return theme
        }
    }()

    /// Display order of category headers in Customize → Appearance.
    static let categoryOrder = ["Live", "Y2K", "Listening Bar", "Studio", "Afterimage", "Custom"]

    /// Only used defensively if a theme list is ever (illegally) empty —
    /// `ThemeManager` never actually lets that happen.
    static let fallback = CustomTheme(id: UUID(), name: "Fallback", palette: .voidBlack)
}

extension UInt32 {
    /// 6-digit uppercase RRGGBB, no leading `#`.
    var hexString: String { String(format: "%06X", self & 0xFFFFFF) }

    /// Parses a 6-digit RRGGBB hex string, with or without a leading `#`.
    init?(hexColorString: String) {
        var cleaned = hexColorString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.removeAll { $0 == "#" }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self = value
    }
}

