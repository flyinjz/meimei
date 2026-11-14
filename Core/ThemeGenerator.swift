import Foundation

/// Builds a full theme from a handful of colors (at least 8): the darkest
/// become the backgrounds, the lightest the text, and the most vivid one
/// that reads against the background the accent. Everything else (dims,
/// hover, selection, dividers) is mixed from those, with contrast floors so
/// any input gives a legible theme. `light` swaps the ends.
enum ThemeGenerator {
    static let minimumColors = 8

    enum Mode: String, CaseIterable, Identifiable {
        case dark, light
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static func generate(name: String, colors input: [UInt32], mode: Mode = .dark) -> CustomTheme? {
        var seen = Set<UInt32>()
        let colors = input.map { $0 & 0xFFFFFF }.filter { seen.insert($0).inserted }
        guard colors.count >= minimumColors else { return nil }
        let dark = mode == .dark
        let byLum = colors.sorted { luminance($0) < luminance($1) }
        let paperEnd = dark ? byLum : byLum.reversed()
        let white: UInt32 = 0xFFFFFF, black: UInt32 = 0x000000
        let away = dark ? white : black      // toward the text end
        let deeper = dark ? black : white     // toward the background end

        // Backgrounds: the extreme color, pushed far enough to sit behind text.
        var void = paperEnd[0]
        for _ in 0..<40 where dark ? luminance(void) > 0.03 : luminance(void) < 0.85 { void = mix(void, deeper, 0.15) }
        let panelCandidate = paperEnd[1]
        let panel = (1.03...1.5).contains(contrast(void, panelCandidate)) ? panelCandidate : mix(void, away, 0.045)
        let row = mix(void, panel, 0.6)
        let rowAlt = mix(row, away, 0.025)
        let raisedCandidate = paperEnd[2]
        let raised = (1.08...1.9).contains(contrast(void, raisedCandidate)) ? raisedCandidate : mix(panel, away, 0.07)

        // Text: the other extreme, with a high contrast floor.
        var text = paperEnd[paperEnd.count - 1]
        // Capped: rounding can stall a channel just short of the end.
        for _ in 0..<40 where contrast(text, void) < 11 { text = mix(text, away, 0.2) }
        if contrast(text, void) < 11 { text = away }
        let used: Set<UInt32> = [paperEnd[0], paperEnd[1], paperEnd[2], paperEnd[paperEnd.count - 1]]
        let rest = colors.filter { !used.contains($0) }
        let secondary = rest.filter { (5.5...10).contains(contrast($0, void)) && saturation($0) < 0.25 }
            .min { abs(contrast($0, void) - 7.5) < abs(contrast($1, void) - 7.5) } ?? mix(text, void, 0.3)
        let tertiary = mix(text, void, 0.55)

        // Accent: vivid and readable on the background.
        var accent = rest.filter { contrast($0, void) >= 3 }.max { saturation($0) < saturation($1) }
            ?? rest.max { saturation($0) < saturation($1) } ?? text
        for _ in 0..<40 where contrast(accent, void) < 3 { accent = mix(accent, away, 0.15) }
        let onAccent: UInt32 = contrast(accent, 0x0A0A0A) >= contrast(accent, white) ? 0x0A0A0A : white

        var theme = CustomTheme.starterThemes[0]
        theme.id = UUID()
        theme.name = name
        theme.category = "Custom"
        theme.isAlbumReactive = false
        theme.bgVoid = void
        theme.bgPanel = panel
        theme.bgRow = row
        theme.bgRowAlt = rowAlt
        theme.bgRaised = raised
        theme.hairline = mix(void, text, 0.16)
        theme.textPrimary = text
        theme.textSecondary = secondary
        theme.textTertiary = tertiary
        theme.textOnAccent = onAccent
        theme.accent = accent
        theme.accentDim = mix(accent, void, 0.45)
        theme.accentGlow = mix(accent, away, 0.25)
        theme.selection = mix(row, accent, 0.28)
        theme.hover = mix(row, text, 0.06)
        theme.lcdOn = accent
        theme.lcdOff = mix(void, accent, 0.12)
        theme.lcdBackground = void
        return theme
    }

    /// Every 6-digit hex code in `text` (#RRGGBB, RRGGBB, 0xRRGGBB).
    static func parseHexList(_ text: String) -> [UInt32] {
        let pattern = try? NSRegularExpression(pattern: "(?<![0-9A-Fa-f])([0-9A-Fa-f]{6})(?![0-9A-Fa-f])")
        let ns = text as NSString
        return pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            UInt32(ns.substring(with: $0.range(at: 1)), radix: 16)
        } ?? []
    }

    // MARK: Color math (sRGB)

    private static func channels(_ c: UInt32) -> (Double, Double, Double) {
        (Double((c >> 16) & 0xFF) / 255, Double((c >> 8) & 0xFF) / 255, Double(c & 0xFF) / 255)
    }

    static func luminance(_ c: UInt32) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = channels(c)
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1…21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func saturation(_ c: UInt32) -> Double {
        let (r, g, b) = channels(c)
        let hi = max(r, g, b), lo = min(r, g, b)
        return hi == 0 ? 0 : (hi - lo) / hi
    }

    /// `a` moved toward `b` by `t` (0…1).
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        func ch(_ x: Double, _ y: Double) -> UInt32 { UInt32(((x + (y - x) * t) * 255).rounded().clamped(0, 255)) }
        return (ch(ar, br) << 16) | (ch(ag, bg) << 8) | ch(ab, bb)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
