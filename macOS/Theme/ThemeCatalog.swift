import SwiftUI

/// A platform skin from a shared palette (`Palette` in the core). Alpha is
/// always opaque here; the live cover theme is the only one that bleeds.
extension Skin {
    init(palette p: Palette) {
        self.init(
            id: p.key, name: p.name,
            bgVoid: Color(hex: p.bgVoid), bgPanel: Color(hex: p.bgPanel),
            bgRow: Color(hex: p.bgRow), bgRowAlt: Color(hex: p.bgRowAlt),
            bgRaised: Color(hex: p.bgRaised), hairline: Color(hex: p.hairline),
            textPrimary: Color(hex: p.textPrimary), textSecondary: Color(hex: p.textSecondary),
            textTertiary: Color(hex: p.textTertiary), textOnAccent: Color(hex: p.textOnAccent),
            accent: Color(hex: p.accent), accentDim: Color(hex: p.accentDim), accentGlow: Color(hex: p.accentGlow),
            lcdOn: Color(hex: p.lcdOn), lcdOff: Color(hex: p.lcdOff), lcdBackground: Color(hex: p.lcdBackground),
            selection: Color(hex: p.selection), hover: Color(hex: p.hover),
            allowsBackdropBleed: p.bleed
        )
    }
}

extension Skin {
    /// Y2K lime/magenta clash on a dead-CRT black — late-90s tracker aesthetic.
    static let acidStatic = Skin(palette: .acidStatic)

    /// Dusty orange + harbor teal over warm brown — vinyl, rain, a cheap sampler.
    static let lofiHarbor = Skin(palette: .lofiHarbor)

    /// Steamed matcha and paper — quiet Japanese indie, late afternoon studio.
    static let matchaHour = Skin(palette: .matchaHour)

    /// Indigo booth, brass riff, a little wine in the glass.
    static let loopStation = Skin(palette: .loopStation)

    /// Graphite sheets and a single hot accent — the current Apple Music chrome.
    static let pulseRed = Skin(palette: .pulseRed)

    /// Frosted navy and system blue — iOS music player at night.
    static let pacificGlass = Skin(palette: .pacificGlass)

    /// Warm dark with a rose spotlight — Now Playing, lights down.
    static let softSpotlight = Skin(palette: .softSpotlight)

    /// Midnight navy and cigarette mustard. A session, not a costume.
    static let nightSession = Skin(palette: .nightSession)

    /// Phosphor on cheap CRT glass. Something is listening back.
    static let phosphor = Skin(palette: .phosphor)

    /// Moss, rain-sky, a clay roof in the distance.
    static let gardenRain = Skin(palette: .gardenRain)

    /// Placeholder the live cover theme uses before the first artwork lands.
    static let fromCoverPlaceholder = Skin(palette: .fromCoverPlaceholder)
}
