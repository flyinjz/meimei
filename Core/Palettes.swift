import Foundation

/// A built-in palette: every theme colour as 24-bit sRGB. The starter
/// themes are made from these, and each platform's skins are drawn from them,
/// so the Mac and the Qt app show exactly the same colours.
struct Palette: Equatable {
    let key: String
    let name: String
    let bgVoid, bgPanel, bgRow, bgRowAlt, bgRaised, hairline: UInt32
    let textPrimary, textSecondary, textTertiary, textOnAccent: UInt32
    let accent, accentDim, accentGlow: UInt32
    let lcdOn, lcdOff, lcdBackground: UInt32
    let selection, hover: UInt32
    /// Panels and the table stay translucent so a blurred cover shows through (the live cover theme).
    let bleed: Bool

    init(_ key: String, _ name: String,
         void: UInt32, panel: UInt32, row: UInt32, alt: UInt32, raised: UInt32, line: UInt32,
         text: UInt32, text2: UInt32, text3: UInt32, onAcc: UInt32,
         acc: UInt32, dim: UInt32, glow: UInt32,
         lcd: UInt32, lcdOff: UInt32, lcdBg: UInt32,
         sel: UInt32, hov: UInt32, bleed: Bool = false) {
        self.key = key; self.name = name
        bgVoid = void; bgPanel = panel; bgRow = row; bgRowAlt = alt; bgRaised = raised; hairline = line
        textPrimary = text; textSecondary = text2; textTertiary = text3; textOnAccent = onAcc
        accent = acc; accentDim = dim; accentGlow = glow
        lcdOn = lcd; self.lcdOff = lcdOff; lcdBackground = lcdBg
        selection = sel; hover = hov
        self.bleed = bleed
    }
}

extension Palette {
    static let voidBlack = Palette(
        "void", "Void // Amethyst",
        void: 0x0A0A0D, panel: 0x101014, row: 0x121216, alt: 0x17171C, raised: 0x191920, line: 0x28282F,
        text: 0xE7E5F0, text2: 0x9C9AAC, text3: 0x63616F, onAcc: 0xF5F3FF,
        acc: 0x8B6BFF, dim: 0x4E3F8C, glow: 0xB79CFF,
        lcd: 0xB79CFF, lcdOff: 0x2B2440, lcdBg: 0x090711,
        sel: 0x4E3F8C, hov: 0x22222A
    )

    static let terminalAmber = Palette(
        "amber", "Amber // CRT",
        void: 0x0B0A08, panel: 0x131109, row: 0x14120A, alt: 0x1A170D, raised: 0x1C1810, line: 0x332B18,
        text: 0xF3E7C9, text2: 0xB79E6E, text3: 0x6E5F42, onAcc: 0x1A1204,
        acc: 0xFFB020, dim: 0x7A5518, glow: 0xFFD680,
        lcd: 0xFFB020, lcdOff: 0x3A2A0E, lcdBg: 0x0A0700,
        sel: 0x7A5518, hov: 0x241E10
    )

    static let coldSteelCyan = Palette(
        "cyan", "Cold Steel // Cyan",
        void: 0x07090B, panel: 0x0D1114, row: 0x0F1417, alt: 0x131A1E, raised: 0x151C20, line: 0x223037,
        text: 0xDCEFF2, text2: 0x84A6AE, text3: 0x4E6B71, onAcc: 0x03151A,
        acc: 0x33D6E8, dim: 0x1B6E78, glow: 0x9CF3FB,
        lcd: 0x33D6E8, lcdOff: 0x123338, lcdBg: 0x050B0D,
        sel: 0x1B6E78, hov: 0x1A262C
    )

    static let bloodChrome = Palette(
        "blood", "Blood // Chrome",
        void: 0x0A0808, panel: 0x110D0D, row: 0x130E0E, alt: 0x191212, raised: 0x1B1414, line: 0x2E1F1F,
        text: 0xF0E4E4, text2: 0xAD8686, text3: 0x6B4B4B, onAcc: 0x1A0505,
        acc: 0xFF3B4E, dim: 0x7A1E28, glow: 0xFF8C97,
        lcd: 0xFF5064, lcdOff: 0x3A1418, lcdBg: 0x0A0505,
        sel: 0x7A1E28, hov: 0x241414
    )

    /// Y2K lime/magenta clash on a dead-CRT black — late-90s tracker aesthetic.
    static let acidStatic = Palette(
        "acid", "Acid Static",
        void: 0x08080A, panel: 0x0E0E10, row: 0x101012, alt: 0x161618, raised: 0x1A1A1C, line: 0x2C2C18,
        text: 0xEEFFE4, text2: 0x8AA878, text3: 0x556048, onAcc: 0x0A0C00,
        acc: 0xC6FF3A, dim: 0x5A7A12, glow: 0xE8FF8C,
        lcd: 0xC6FF3A, lcdOff: 0x1A2208, lcdBg: 0x050600,
        sel: 0x5A7A12, hov: 0x1C1C12
    )

    /// Dusty orange + harbor teal over warm brown — vinyl, rain, a cheap sampler.
    static let lofiHarbor = Palette(
        "harbor", "Lofi Harbor",
        void: 0x120E0C, panel: 0x1A1512, row: 0x1C1714, alt: 0x241E19, raised: 0x261F1A, line: 0x3A322C,
        text: 0xF0E6D8, text2: 0xB89A82, text3: 0x7A6558, onAcc: 0x1A1008,
        acc: 0xD4894A, dim: 0x8A5A32, glow: 0xE8B88A,
        lcd: 0x4A8B86, lcdOff: 0x1A2826, lcdBg: 0x0C0A08,
        sel: 0x8A5A32, hov: 0x2A221C
    )

    /// Steamed matcha and paper — quiet Japanese indie, late afternoon studio.
    static let matchaHour = Palette(
        "matcha", "Matcha Hour",
        void: 0x10140F, panel: 0x161C14, row: 0x181E16, alt: 0x1E261C, raised: 0x20281E, line: 0x3A4A34,
        text: 0xE8EDE0, text2: 0x9AAB88, text3: 0x657056, onAcc: 0x12180C,
        acc: 0x8FA86B, dim: 0x4A5C38, glow: 0xC4D4A0,
        lcd: 0xC4B48A, lcdOff: 0x2A2E20, lcdBg: 0x0A0C09,
        sel: 0x4A5C38, hov: 0x22281E
    )

    /// Indigo booth, brass riff, a little wine in the glass.
    static let loopStation = Palette(
        "loop", "Loop Station",
        void: 0x0C0A14, panel: 0x14121C, row: 0x16141E, alt: 0x1C1A28, raised: 0x1E1C2A, line: 0x3A3450,
        text: 0xEDE8F5, text2: 0xA090B8, text3: 0x6A6080, onAcc: 0x120E08,
        acc: 0xC4A35A, dim: 0x6A5828, glow: 0xE8D090,
        lcd: 0xC4A35A, lcdOff: 0x2A2410, lcdBg: 0x0A0810,
        sel: 0x4A3A70, hov: 0x222030
    )

    /// Graphite sheets and a single hot accent — the current Apple Music chrome.
    static let pulseRed = Palette(
        "pulse", "Pulse",
        void: 0x000000, panel: 0x1C1C1E, row: 0x1C1C1E, alt: 0x2C2C2E, raised: 0x2C2C2E, line: 0x3A3A3C,
        text: 0xF5F5F7, text2: 0xA1A1A6, text3: 0x6E6E73, onAcc: 0xF5F5F7,
        acc: 0xFA2D48, dim: 0x8A1828, glow: 0xFF6B80,
        lcd: 0xFA2D48, lcdOff: 0x3A1018, lcdBg: 0x000000,
        sel: 0x8A1828, hov: 0x2A2A2C
    )

    /// Frosted navy and system blue — iOS music player at night.
    static let pacificGlass = Palette(
        "pacific", "Pacific Glass",
        void: 0x070B12, panel: 0x0C121C, row: 0x0E141E, alt: 0x141C28, raised: 0x161E2A, line: 0x2A3A50,
        text: 0xE8F0FA, text2: 0x8AA0B8, text3: 0x5A7088, onAcc: 0xF5FAFF,
        acc: 0x0A84FF, dim: 0x0A3A78, glow: 0x64B0FF,
        lcd: 0x64B0FF, lcdOff: 0x102038, lcdBg: 0x05080C,
        sel: 0x0A3A78, hov: 0x1A2430
    )

    /// Warm dark with a rose spotlight — Now Playing, lights down.
    static let softSpotlight = Palette(
        "spotlight", "Soft Spotlight",
        void: 0x121014, panel: 0x1A171C, row: 0x1C191E, alt: 0x242026, raised: 0x262228, line: 0x3A343C,
        text: 0xF4EEF2, text2: 0xB8A8B0, text3: 0x786870, onAcc: 0x1A1014,
        acc: 0xE8A0B8, dim: 0x7A4A5A, glow: 0xF4C8D4,
        lcd: 0xE8A0B8, lcdOff: 0x2A1820, lcdBg: 0x0C0A0C,
        sel: 0x7A4A5A, hov: 0x282228
    )

    /// Midnight navy and cigarette mustard. A session, not a costume.
    static let nightSession = Palette(
        "night", "Night Session",
        void: 0x0A0C12, panel: 0x10141C, row: 0x12161E, alt: 0x181C28, raised: 0x1A1E2A, line: 0x2C3448,
        text: 0xE8E4D8, text2: 0xA8A090, text3: 0x686860, onAcc: 0x12100A,
        acc: 0xE0B43A, dim: 0x7A6220, glow: 0xF0D878,
        lcd: 0xE0B43A, lcdOff: 0x2A2410, lcdBg: 0x080A10,
        sel: 0x3A4868, hov: 0x1C2230
    )

    /// Phosphor on cheap CRT glass. Something is listening back.
    static let phosphor = Palette(
        "phosphor", "Phosphor",
        void: 0x050806, panel: 0x0A100C, row: 0x0C140E, alt: 0x121A14, raised: 0x141C16, line: 0x1E3A24,
        text: 0xC8F0CC, text2: 0x6A9A70, text3: 0x3A5A40, onAcc: 0x041006,
        acc: 0x5CFF78, dim: 0x1A5A28, glow: 0xA0FFB0,
        lcd: 0x5CFF78, lcdOff: 0x0E2814, lcdBg: 0x030504,
        sel: 0x1A5A28, hov: 0x101810
    )

    /// Moss, rain-sky, a clay roof in the distance.
    static let gardenRain = Palette(
        "garden", "Garden Rain",
        void: 0x0E120E, panel: 0x161C16, row: 0x181E18, alt: 0x1E261E, raised: 0x202820, line: 0x3A4A40,
        text: 0xE8EDE8, text2: 0x9AB0A8, text3: 0x687870, onAcc: 0x1A120C,
        acc: 0x7BA7C9, dim: 0x3A5A70, glow: 0xB0C8DC,
        lcd: 0xC4846A, lcdOff: 0x2A1C16, lcdBg: 0x0A0C0A,
        sel: 0x4A6A58, hov: 0x1C241C
    )

    /// Placeholder the live cover theme uses before the first artwork lands.
    static let fromCoverPlaceholder = Palette(
        "from-cover", "From Cover",
        void: 0x0A0A0D, panel: 0x101014, row: 0x121216, alt: 0x17171C, raised: 0x191920, line: 0x28282F,
        text: 0xE7E5F0, text2: 0x9C9AAC, text3: 0x63616F, onAcc: 0xF5F3FF,
        acc: 0x8B6BFF, dim: 0x4E3F8C, glow: 0xB79CFF,
        lcd: 0xB79CFF, lcdOff: 0x2B2440, lcdBg: 0x090711,
        sel: 0x4E3F8C, hov: 0x22222A,
        bleed: true
    )

    static let all: [Palette] = [.voidBlack, .terminalAmber, .coldSteelCyan, .bloodChrome, .acidStatic, .lofiHarbor, .matchaHour, .loopStation, .pulseRed, .pacificGlass, .softSpotlight, .nightSession, .phosphor, .gardenRain, .fromCoverPlaceholder]
}
