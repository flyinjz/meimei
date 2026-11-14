pragma Singleton
// The colours and tokens every view draws with: the skin the core resolves
// (the Mac's styled Skin, SkinRules.styled), read straight from Core.skin.
// Nothing here computes a colour; the helpers only apply opacities.
import QtQuick
import I2S

QtObject {
    function rgb(v, a) { return Qt.rgba(((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255, a === undefined ? 1 : a) }
    function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, c.a * a) }
    /// WCAG relative luminance, 0 black … 1 white (as the Mac's Color.luminance).
    function luminance(c) {
        const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// A labeled button's colours in the chosen fill (the Mac's ButtonLook):
    /// solid fills the accent ones, outline draws only the frame, text neither.
    function buttonLook(fill, isAccent, hovering) {
        const fg = fill === "solid" && isAccent ? textOnAccent : isAccent ? accent : hovering ? textPrimary : textSecondary
        const bg = fill === "solid" ? (isAccent ? withAlpha(accent, hovering ? 1 : 0.9) : withAlpha(textPrimary, hovering ? 0.08 : 0.02))
                 : fill === "outline" ? (hovering ? withAlpha(isAccent ? accent : textPrimary, 0.08) : "transparent")
                 : "transparent"
        const border = fill === "solid" ? (isAccent ? accent : withAlpha(textPrimary, hovering ? 0.55 : 0.22))
                     : fill === "outline" ? (isAccent ? withAlpha(accent, hovering ? 1 : 0.8) : withAlpha(textPrimary, hovering ? 0.55 : 0.28))
                     : "transparent"
        return { foreground: fg, background: bg, border: border }
    }
    /// ButtonSize.delta: added to a button's base height; the font steps a third of it.
    function buttonSizeDelta(size) { return size === "compact" ? -3 : size === "large" ? 5 : 0 }

    readonly property var s: Core.skin
    readonly property var c: s.colors || ({})

    readonly property color bgVoid: c.bgVoid || "black"
    readonly property color bgPanel: c.bgPanel || "transparent"
    readonly property color bgRow: c.bgRow || "transparent"
    readonly property color bgRowAlt: c.bgRowAlt || "transparent"
    readonly property color bgRaised: c.bgRaised || "transparent"
    readonly property color hairline: c.hairline || "transparent"
    readonly property color textPrimary: c.textPrimary || "white"
    readonly property color textSecondary: c.textSecondary || "white"
    readonly property color textTertiary: c.textTertiary || "white"
    readonly property color textOnAccent: c.textOnAccent || "white"
    readonly property color accent: c.accent || "white"
    readonly property color accentDim: c.accentDim || "white"
    readonly property color accentGlow: c.accentGlow || "white"
    readonly property color lcdOn: c.lcdOn || "white"
    readonly property color lcdOff: c.lcdOff || "transparent"
    readonly property color lcdBackground: c.lcdBackground || "transparent"
    readonly property color selection: c.selection || "transparent"
    readonly property color hover: c.hover || "transparent"

    readonly property bool isGlass: !!s.isGlass
    readonly property bool allowsBackdropBleed: !!s.allowsBackdropBleed
    readonly property real panelOpacity: s.panelOpacity === undefined ? 0.46 : s.panelOpacity
    readonly property real contentOpacity: s.contentOpacity === undefined ? 0.62 : s.contentOpacity
    readonly property real borderWidth: s.borderWidth === undefined ? 1 : s.borderWidth
    readonly property bool showTicks: s.showTicks === undefined ? true : s.showTicks
    readonly property real tickLength: s.tickLength === undefined ? 7 : s.tickLength
    readonly property string backdrop: s.backdrop || "translucent"
    readonly property real gap: s.gap === undefined ? 6 : s.gap
}
