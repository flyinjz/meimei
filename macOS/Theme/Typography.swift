import SwiftUI
import AppKit
import CoreText

// MARK: - Fonts

/// The app's type. Text is light by default, the way the design wants it,
/// but steps up to regular below 11 pt where thin strokes stop reading.
/// Asked-for weights collapse onto the three bundled faces.
enum AppFont {
    /// Mirrors the font preference; set by `AppSettings`.
    nonisolated(unsafe) static var family: AppFontFamily = .geistMono
    /// The global text scale design token; set by `CustomizeStore`.
    nonisolated(unsafe) static var textScale: CGFloat = 1

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let pt = size * textScale
        return .custom(face(pt, weight, in: family), fixedSize: pt).monospacedDigit()
    }

    /// Kept for call sites that want figures; `ui` already uses tabular ones.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { ui(size, weight: weight) }
    static func lcd(_ size: CGFloat) -> Font { ui(size, weight: .medium) }

    /// AppKit fonts by face and size: the track list asks for one per cell.
    private static let nsCache = LockedValue<[String: NSFont]>([:])

    static func ns(_ size: CGFloat, weight: NSFont.Weight = .regular, family: AppFontFamily = AppFont.family) -> NSFont {
        let w: Font.Weight = weight >= .bold ? .bold : weight >= .medium ? .medium : .regular
        let pt = size * textScale
        let key = "\(family.rawValue)|\(w == .bold ? 2 : w == .medium ? 1 : 0)|\(pt)"
        if let hit = nsCache.value[key] { return hit }
        let font = makeNS(pt, weight: weight, w: w, family: family)
        nsCache.mutate { $0[key] = font }
        return font
    }

    private static func makeNS(_ pt: CGFloat, weight: NSFont.Weight, w: Font.Weight, family: AppFontFamily) -> NSFont {
        guard let font = NSFont(name: face(pt, w, in: family), size: pt) else { return .monospacedSystemFont(ofSize: pt, weight: weight) }
        guard !family.isMonospaced else { return font }
        let tabular = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: tabular, size: pt) ?? font
    }

    static func face(_ size: CGFloat, _ weight: Font.Weight, in family: AppFontFamily) -> String {
        let w: FaceWeight
        switch weight {
        case .ultraLight: w = .ultraLight
        case .thin: w = .thin
        case .light: w = .light
        case .medium: w = .medium
        case .semibold: w = .semibold
        case .bold: w = .bold
        case .heavy: w = .heavy
        case .black: w = .black
        default: w = .regular
        }
        return family.face(size: Double(size), weight: w)
    }

    /// Registers the bundled fonts for this process. Looks in the app
    /// bundle's Resources/Fonts, then (for development builds) the
    /// repository's Assets/Fonts folder.
    static func registerBundledFonts(sourceFile: String = #filePath) {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
                .appendingPathComponent("../../Assets/Fonts").standardizedFileURL,
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            NSLog("i2s: bundled fonts not found")
            return
        }
        let fonts = files.filter { !$0.hasDirectoryPath }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }
}

// MARK: - Icons

/// An icon: a Nerd Font glyph's vector outline, scaled and centered in a
/// `size`-point square and filled with the foreground style. Drawing the
/// outline (rather than the character) keeps every icon exactly sized and
/// centered whatever the text font's metrics. Keys keep the descriptive
/// names the views already use.
struct Glyph: View {
    var name: String
    var size: CGFloat

    init(_ name: String, size: CGFloat = 13) {
        self.name = name
        self.size = size
    }

    @ObservedObject private var theme = IconTheme.shared

    var body: some View {
        GlyphShape(outline: theme.code(for: name).flatMap(GlyphOutlines.outline), scale: theme.scale)
            .frame(width: size, height: size)
            .accessibilityLabel(name)
    }

    /// The icon as a character, for places that can only take text (the
    /// native track table). Draw it in `IconTheme.font`.
    @MainActor
    static func glyph(_ name: String) -> String {
        guard let code = IconTheme.shared.code(for: name), let scalar = Unicode.Scalar(code) else { return "\u{25A1}" }
        return String(Character(scalar))
    }

    /// The Material code points every icon role defaults to (the shared core table).
    static let codes = IconPackTables.material
}

extension Label where Title == Text, Icon == Glyph {
    /// A label whose icon is a font glyph.
    init(_ title: String, glyph: String, size: CGFloat = 11) {
        self.init { Text(title) } icon: { Glyph(glyph, size: size) }
    }
}

/// A glyph outline fitted into the view's square: 88% of the box on its
/// longer side, centered.
/// A specific glyph by code point, ignoring the icon theme (previews).
struct CodeGlyph: View {
    var code: UInt32
    var size: CGFloat

    var body: some View {
        GlyphShape(outline: GlyphOutlines.outline(code))
            .frame(width: size, height: size)
    }
}

private struct GlyphShape: Shape {
    let outline: CGPath?
    var scale: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        guard let outline else { return Path(rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)) }
        let b = outline.boundingBoxOfPath
        guard b.width > 0, b.height > 0 else { return Path() }
        let s = min(rect.width / b.width, rect.height / b.height) * 0.88 * scale
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: s, y: -s)
            .translatedBy(x: -b.midX, y: -b.midY)
        return Path(outline.copy(using: &t) ?? outline)
    }
}

/// Icon outlines from the bundled Nerd Fonts symbols face (every icon
/// set), read once per code point and cached.
enum GlyphOutlines {
    private static let cache = LockedValue<[UInt32: CGPath]>([:])
    private static let font: CTFont = {
        let symbols = CTFontCreateWithName("SymbolsNF" as CFString, 64, nil)
        // Before the symbols face existed, the text faces carried the icons.
        return (CTFontCopyPostScriptName(symbols) as String) == "SymbolsNF" ? symbols : CTFontCreateWithName("GeistMonoNF" as CFString, 64, nil)
    }()

    static func outline(_ code: UInt32) -> CGPath? {
        if let hit = cache.value[code] { return hit }
        guard let scalar = Unicode.Scalar(code) else { return nil }
        let units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0,
              let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { return nil }
        cache.mutate { $0[code] = path }
        return path
    }
}

// MARK: - Icon packs

/// Which glyph each icon role draws: the pack, then the user's own
/// choices per icon, with Material filling any gap. Set from settings.
@MainActor
final class IconTheme: ObservableObject {
    static let shared = IconTheme()

    @Published private(set) var pack: IconPack = .material
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var overrides: [String: UInt32] = [:]

    /// For text-drawn icons (the track list).
    static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: "SymbolsNF", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    func apply(pack: IconPack, scale: Double, overrides: [String: UInt32]) {
        if self.pack != pack { self.pack = pack }
        if self.scale != CGFloat(scale) { self.scale = CGFloat(scale) }
        if self.overrides != overrides { self.overrides = overrides }
    }

    func code(for name: String) -> UInt32? {
        overrides[name] ?? pack.table[name] ?? Glyph.codes[name]
    }

    /// Every icon role, for the icon editor.
    static var roles: [String] { Glyph.codes.keys.sorted() }

    /// Every glyph in the symbols face with its name, for choosing one by
    /// hand (built once, off the main thread).
    nonisolated static func allGlyphs() -> [(code: UInt32, name: String)] {
        let font = CTFontCreateWithName("SymbolsNF" as CFString, 32, nil)
        var out: [(UInt32, String)] = []
        for range in [0xE000...0xF8FF, 0xF0000...0xF1AF0] {
            for cp in range {
                guard let scalar = Unicode.Scalar(UInt32(cp)) else { continue }
                let units = Array(String(Character(scalar)).utf16)
                var g = [CGGlyph](repeating: 0, count: units.count)
                guard CTFontGetGlyphsForCharacters(font, units, &g, units.count), g[0] != 0,
                      let name = CTFontCopyNameForGlyph(font, g[0]) as String? else { continue }
                out.append((UInt32(cp), name))
            }
        }
        return out
    }
}

extension Color {
    /// Relative luminance (WCAG), 0 black … 1 white.
    var luminance: Double {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// WCAG contrast ratio against another color (1…21).
    func contrast(with other: Color) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
