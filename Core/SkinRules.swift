import Foundation

// MARK: - Colours with alpha

/// An sRGB colour with opacity, components 0…1. What every surface and text
/// level resolves to, on every platform.
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// The same colour at `opacity` times its alpha.
    func opacity(_ opacity: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * opacity) }

    /// WCAG relative luminance of a 24-bit colour.
    static func luminance(_ hex: UInt32) -> Double {
        let c = RGBA(hex: hex)
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

extension GrayTone {
    /// The tone's gray at `white` as a colour.
    func color(_ white: Double) -> RGBA { let c = rgb(white); return RGBA(r: c.red, g: c.green, b: c.blue) }
}

// MARK: - The skin every view draws with

/// The theme after the design tokens and settings are applied: a monochrome
/// tonal scale for every surface and text level, hue only from the accent,
/// and the glass and corner-tick values.
struct StyledSkin: Equatable {
    var bgVoid, bgPanel, bgRow, bgRowAlt, bgRaised, hairline: RGBA
    var textPrimary, textSecondary, textTertiary, textOnAccent: RGBA
    var accent, accentDim, accentGlow: RGBA
    var lcdOn, lcdOff, lcdBackground: RGBA
    var selection, hover: RGBA
    /// Surfaces are glass panes over the backdrop rather than fills.
    var isGlass: Bool
    /// Panels and the table stay translucent so the backdrop shows through.
    var allowsBackdropBleed: Bool
    var panelOpacity: Double
    var borderWidth: Double
    var showTicks: Bool
    var tickLength: Double
    /// The window backdrop actually shown.
    var backdrop: BackdropStyle
    /// Whether the accent colours came from the design tokens rather than the theme.
    var accentOverridden: Bool
}

enum SkinRules {
    /// The live cover theme's skin id: its surfaces are always glass and its backdrop the cover.
    static let liveCoverID = "from-cover-live"

    /// The skin to draw with. `accent`, `accentDim`, `accentGlow` and
    /// `textOnAccent` are the theme's own (or the live cover's); `skinID`
    /// is `liveCoverID` for the live cover theme.
    static func styled(accent: RGBA, accentDim: RGBA, accentGlow: RGBA, textOnAccent: RGBA, skinID: String,
                       tokens: DesignTokens, settings: AppSettingsData) -> StyledSkin {
        var accent = accent, accentDim = accentDim, accentGlow = accentGlow, textOnAccent = textOnAccent
        if let hex = tokens.accent {
            accent = RGBA(hex: hex)
            accentDim = RGBA(hex: hex).opacity(0.45)
            accentGlow = RGBA(hex: hex)
            textOnAccent = RGBA.luminance(hex) > 0.55 ? RGBA.black.opacity(0.85) : .white
        }
        let tone = tokens.tone
        let ink = tone.color(0.92)
        let glass = settings.surfaceStyle == .glass || skinID == liveCoverID
        return StyledSkin(
            bgVoid: tone.color(0.04),
            bgPanel: glass ? .clear : tone.color(0.07),
            bgRow: glass ? .clear : tone.color(0.055),
            bgRowAlt: RGBA.white.opacity(0.025),
            bgRaised: RGBA.white.opacity(0.05),
            hairline: RGBA.white.opacity(0.14 * settings.hairlineOpacity),
            textPrimary: ink,
            textSecondary: ink.opacity(0.62),
            textTertiary: ink.opacity(0.4),
            textOnAccent: textOnAccent,
            accent: accent, accentDim: accentDim, accentGlow: accentGlow,
            lcdOn: ink,
            lcdOff: RGBA.white.opacity(0.12),
            lcdBackground: RGBA.black.opacity(0.3),
            selection: accent.opacity(0.18),
            hover: RGBA.white.opacity(0.05),
            isGlass: glass,
            allowsBackdropBleed: glass,
            panelOpacity: tokens.panelOpacity,
            borderWidth: tokens.borderWidth,
            showTicks: tokens.cornerTicks,
            tickLength: tokens.tickLength,
            backdrop: effectiveBackdrop(skinID: skinID, settings: settings),
            accentOverridden: tokens.accent != nil
        )
    }

    /// The live cover theme always sits on the blurred cover.
    static func effectiveBackdrop(skinID: String, settings: AppSettingsData) -> BackdropStyle {
        skinID == liveCoverID ? .artwork : settings.backdropStyle
    }
}

// MARK: - Stored themes

enum ThemeLibrary {
    /// The stored theme list as the app uses it: the starter themes when
    /// nothing is stored; otherwise the stored themes with catalog themes the
    /// user doesn't have yet added (by stable id), and catalog grouping
    /// restored on the ones they do, colours untouched.
    static func merged(_ stored: [CustomTheme]) -> [CustomTheme] {
        guard !stored.isEmpty else { return CustomTheme.starterThemes }
        let catalog = Dictionary(uniqueKeysWithValues: CustomTheme.starterThemes.map { ($0.id, $0) })
        var result = stored
        for i in result.indices {
            guard let canned = catalog[result[i].id] else { continue }
            if result[i].category == "Custom" { result[i].category = canned.category }
            result[i].isAlbumReactive = canned.isAlbumReactive
        }
        let have = Set(result.map(\.id))
        return result + CustomTheme.starterThemes.filter { !have.contains($0.id) }
    }

    /// The stored active theme if it's in the list, else the first theme.
    static func activeID(stored raw: String?, in themes: [CustomTheme]) -> UUID {
        if let raw, let id = UUID(uuidString: raw), themes.contains(where: { $0.id == id }) { return id }
        return themes.first?.id ?? CustomTheme.fallback.id
    }
}

// MARK: - Customize state

/// Everything customize mode stores, in its stored shape.
struct CustomizeState: Codable, Equatable {
    var styles: [CustomElement: ElementStyle] = [:]
    var layout: PaneLayout = .standard
    var tokens = DesignTokens()
    var workspaces: [Workspace] = []
    var activeWorkspaceID: UUID?

    /// Reads stored state; anything unreadable gives the defaults. The layout is normalised.
    static func read(_ data: Data?) -> CustomizeState {
        var state = data.flatMap { try? JSONDecoder().decode(CustomizeState.self, from: $0) } ?? CustomizeState()
        state.layout.normalize()
        return state
    }
}

// MARK: - Font faces

/// Text weights as layout asks for them, before choosing a face.
enum FaceWeight: String, CaseIterable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
}

extension AppFontFamily {
    /// Text below this size draws in the regular face, not the light one.
    static let regularBelow = 11.0

    /// The bundled face to draw `weight` at `size`: bold for bold and
    /// heavier, regular for medium and semibold (and small text), light otherwise.
    func face(size: Double, weight: FaceWeight) -> String {
        switch weight {
        case .bold, .heavy, .black: return faces.bold
        case .medium, .semibold: return faces.regular
        default: return size < Self.regularBelow ? faces.regular : faces.light
        }
    }
}
