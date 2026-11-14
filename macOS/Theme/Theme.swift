import SwiftUI
import AppKit

/// The resolved colors (and corner scale) every view draws with.
struct Skin: Identifiable, Equatable {
    var id: String
    var name: String

    // Surfaces, darkest to lightest
    var bgVoid: Color        // window background
    var bgPanel: Color       // side panels
    var bgRow: Color         // table rows
    var bgRowAlt: Color      // alternating rows
    var bgRaised: Color      // bars, headers, cards
    var hairline: Color      // 1px dividers

    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var textOnAccent: Color

    var accent: Color
    var accentDim: Color
    var accentGlow: Color

    var lcdOn: Color
    var lcdOff: Color
    var lcdBackground: Color

    var selection: Color
    var hover: Color

    /// Panels and the table stay translucent so a blurred cover can show
    /// through (the live "From Cover" theme).
    var allowsBackdropBleed: Bool = false

    /// Surfaces are glass panes over the backdrop rather than flat fills.
    var isGlass: Bool = false
    /// Color the glass is tinted with (the theme's panel color); nil for clear glass.
    var glassTint: Color? = nil

    // Design tokens (see `DesignTokens`), filled in by `AppSettings.styled`.
    var panelOpacity: Double = 0.46
    var borderWidth: CGFloat = 1
    var showTicks = true
    var tickLength: CGFloat = 7
    /// The content layer's veil in glass mode; nil means `panelOpacity` + 0.16.
    var contentOpacity: Double? = nil


    /// A surface color, or clear when the cover backdrop should show through.
    func surface(_ color: Color) -> Color { allowsBackdropBleed ? .clear : color }

    static let voidBlack = Skin(palette: .voidBlack)

    static let terminalAmber = Skin(palette: .terminalAmber)

    static let coldSteelCyan = Skin(palette: .coldSteelCyan)

    static let bloodChrome = Skin(palette: .bloodChrome)

}

extension CustomTheme {
    /// The runtime colors for this theme.
    func makeSkin() -> Skin {
        Skin(
            id: id.uuidString, name: name,
            bgVoid: Color(hex: bgVoid), bgPanel: Color(hex: bgPanel),
            bgRow: Color(hex: bgRow), bgRowAlt: Color(hex: bgRowAlt),
            bgRaised: Color(hex: bgRaised), hairline: Color(hex: hairline),
            textPrimary: Color(hex: textPrimary), textSecondary: Color(hex: textSecondary),
            textTertiary: Color(hex: textTertiary), textOnAccent: Color(hex: textOnAccent),
            accent: Color(hex: accent), accentDim: Color(hex: accentDim), accentGlow: Color(hex: accentGlow),
            lcdOn: Color(hex: lcdOn), lcdOff: Color(hex: lcdOff), lcdBackground: Color(hex: lcdBackground),
            selection: Color(hex: selection), hover: Color(hex: hover),
            allowsBackdropBleed: isAlbumReactive
        )
    }

    init(id: UUID, name: String, from skin: Skin) {
        self.id = id
        self.name = name
        self.bgVoid = skin.bgVoid.toHex()
        self.bgPanel = skin.bgPanel.toHex()
        self.bgRow = skin.bgRow.toHex()
        self.bgRowAlt = skin.bgRowAlt.toHex()
        self.bgRaised = skin.bgRaised.toHex()
        self.hairline = skin.hairline.toHex()
        self.textPrimary = skin.textPrimary.toHex()
        self.textSecondary = skin.textSecondary.toHex()
        self.textTertiary = skin.textTertiary.toHex()
        self.textOnAccent = skin.textOnAccent.toHex()
        self.accent = skin.accent.toHex()
        self.accentDim = skin.accentDim.toHex()
        self.accentGlow = skin.accentGlow.toHex()
        self.selection = skin.selection.toHex()
        self.hover = skin.hover.toHex()
        self.lcdOn = skin.lcdOn.toHex()
        self.lcdOff = skin.lcdOff.toHex()
        self.lcdBackground = skin.lcdBackground.toHex()
        self.category = "Custom"
        self.isAlbumReactive = skin.allowsBackdropBleed
    }

}

/// The user's theme library (create, duplicate, rename, recolor, delete),
/// the active theme, and the live palette for the "From Cover" theme.
@MainActor
final class ThemeManager: ObservableObject {
    @Published private(set) var themes: [CustomTheme] {
        didSet {
            DefaultsStore.save(themes, key: Self.themesKey)
            resolveSkin()
        }
    }
    @Published private(set) var activeThemeID: UUID {
        didSet {
            UserDefaults.standard.set(activeThemeID.uuidString, forKey: Self.activeThemeKey)
            resolveSkin()
            ingestArtwork(at: artworkPath, force: true)
        }
    }

    /// The colors every view renders with. Resolved once per change.
    @Published private(set) var skin: Skin = Skin.voidBlack

    /// The blurred cover for the Album Art backdrop, rendered once per
    /// track; nil when no backdrop needs it.
    @Published private(set) var artworkImage: NSImage?
    private var derivedSkin: Skin? {
        didSet { resolveSkin() }
    }
    private var artworkPath: String?
    private var ingestGeneration = 0

    /// Set when the Album Art backdrop is chosen, so the blurred cover is
    /// prepared under any theme, not just From Cover.
    var artworkBackdropEnabled = false {
        didSet {
            if artworkBackdropEnabled != oldValue { ingestArtwork(at: artworkPath, force: true) }
        }
    }

    private var needsArtwork: Bool { isAlbumReactive || artworkBackdropEnabled }

    private static let themesKey = "com.meimei.player.themes.v1"
    private static let activeThemeKey = "com.meimei.player.activeThemeID.v1"

    var activeTheme: CustomTheme? { themes.first { $0.id == activeThemeID } }
    var isAlbumReactive: Bool { activeTheme?.isAlbumReactive == true }

    init() {
        let stored = DefaultsStore.load([CustomTheme].self, key: Self.themesKey) ?? []
        let loaded = ThemeLibrary.merged(stored)
        themes = loaded
        activeThemeID = ThemeLibrary.activeID(stored: UserDefaults.standard.string(forKey: Self.activeThemeKey), in: loaded)
        resolveSkin()
    }

    private func resolveSkin() {
        let resolved: Skin
        if isAlbumReactive {
            resolved = derivedSkin ?? AlbumColorExtractor.fallbackSkin
        } else {
            resolved = (activeTheme ?? themes.first ?? CustomTheme.fallback).makeSkin()
        }
        if resolved != skin { skin = resolved }
    }


    func setActive(_ id: UUID) {
        guard id != activeThemeID, themes.contains(where: { $0.id == id }) else { return }
        activeThemeID = id
    }

    /// Feeds the playing track's cover to the live theme. Sampling runs off
    /// the main thread; a newer cover always wins over an older one.
    func ingestArtwork(at path: String?, force: Bool = false) {
        guard force || path != artworkPath else { return }
        artworkPath = path
        guard needsArtwork else {
            artworkImage = nil
            derivedSkin = nil
            return
        }
        ingestGeneration += 1
        let generation = ingestGeneration
        guard let path else {
            artworkImage = nil
            derivedSkin = nil
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = ArtworkCache.shared.image(path, pixels: 256)
            let sampled = image.map(AlbumColorExtractor.makeSkin(from:))
            let backdrop = image.flatMap(BackdropBlur.render)
            await self?.applyIngested(image: backdrop, skin: sampled, generation: generation)
        }
    }

    private func applyIngested(image: NSImage?, skin sampled: Skin?, generation: Int) {
        guard generation == ingestGeneration, needsArtwork else { return }
        artworkImage = image
        derivedSkin = sampled
    }

    /// Creates a theme from `base` (default: the active one) and returns its
    /// id. Copying the live cover theme snapshots its current palette.
    @discardableResult
    func createTheme(named name: String, basedOn base: CustomTheme? = nil) -> UUID {
        var new = base ?? activeTheme ?? CustomTheme.starterThemes[0]
        if new.isAlbumReactive {
            if let derivedSkin { new = CustomTheme(id: UUID(), name: name, from: derivedSkin) }
            new.isAlbumReactive = false
        }
        new.category = "Custom"
        new.id = UUID()
        new.name = name
        themes.append(new)
        return new.id
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let source = themes.first(where: { $0.id == id }) else { return nil }
        return createTheme(named: source.name + " Copy", basedOn: source)
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    /// The last remaining theme can't be deleted.
    func delete(_ id: UUID) {
        guard themes.count > 1 else { return }
        if activeThemeID == id, let other = themes.first(where: { $0.id != id }) {
            activeThemeID = other.id
        }
        themes.removeAll { $0.id == id }
    }

    func update(_ id: UUID, _ transform: (inout CustomTheme) -> Void) {
        guard let i = themes.firstIndex(where: { $0.id == id }) else { return }
        var copy = themes
        transform(&copy[i])
        if copy[i] != themes[i] { themes = copy }
    }

    /// A binding to one color of one theme, for the color editor.
    func binding(for field: ThemeColorField, themeID: UUID) -> Binding<UInt32> {
        Binding(
            get: { self.themes.first { $0.id == themeID }?[keyPath: field.keyPath] ?? 0 },
            set: { value in self.update(themeID) { $0[keyPath: field.keyPath] = value } }
        )
    }
}

extension Color {
    /// A shared-core colour (sRGB with opacity).
    init(_ c: RGBA) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// The colour as sRGB components with opacity, for the shared core.
    var rgba: RGBA {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return RGBA(r: 0.5, g: 0.5, b: 0.5) }
        return RGBA(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }

    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// The color as 24-bit sRGB.
    func toHex() -> UInt32 {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = UInt32((ns.redComponent * 255).rounded().clamped(to: 0...255))
        let g = UInt32((ns.greenComponent * 255).rounded().clamped(to: 0...255))
        let b = UInt32((ns.blueComponent * 255).rounded().clamped(to: 0...255))
        return (r << 16) | (g << 8) | b
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A 1px divider — panels are separated by hairlines, not shadows.
/// A 1pt rounded divider. Horizontal ones stop short of the pane edge so
/// they never run into a rounded corner.
struct Hairline: View {
    var color: Color
    var vertical = false
    var inset: CGFloat? = nil

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .padding(vertical ? .vertical : .horizontal, inset ?? (vertical ? 0 : 12))
    }
}
