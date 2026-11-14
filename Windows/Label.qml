// Text in the app's type (the Mac's AppFont.ui / textRole): sizes in Mac
// points, weights by SwiftUI name, the core's face rule, tabular figures.
// With a `role` (a customize element, e.g. "libraryTitle"), the user's text
// style replaces the design's size, weight, family, colour, opacity,
// tracking, alignment, line count and shadow.
import QtQuick
import QtQuick.Effects
import I2S

Text {
    id: t
    property real pt: 12
    property string weight: "regular"
    /// A core font id to use instead of the chosen family.
    property string family: ""
    property string role: ""

    readonly property var style: role !== "" ? Customize.style(role) : ({})

    // Customize frame: the drawn text, for the overlay's outline.
    readonly property string element: role
    readonly property bool shown: visible && role !== ""
    function frameRect() {
        const w = Math.min(width, contentWidth), h = Math.min(height, contentHeight)
        const x = horizontalAlignment === Text.AlignHCenter ? (width - w) / 2 : horizontalAlignment === Text.AlignRight ? width - w : 0
        const y = verticalAlignment === Text.AlignVCenter ? (height - h) / 2 : verticalAlignment === Text.AlignBottom ? height - h : 0
        return Qt.rect(x, y, w, h)
    }
    Component.onCompleted: if (role !== "") Customize.register(t)
    Component.onDestruction: Customize.unregister(t)
    readonly property string styledWeight: style.weight === "light" ? "light" : style.weight === "regular" ? "medium" : style.weight === "bold" ? "bold" : weight

    font: {
        const f = Type.font(pt * (style.sizeScale || 1), styledWeight, style.font || family)
        if (style.tracking) f.letterSpacing = style.tracking
        return f
    }
    color: Skin.textPrimary
    opacity: style.opacity === undefined ? 1 : style.opacity
    horizontalAlignment: style.align === "center" ? Text.AlignHCenter : style.align === "trailing" ? Text.AlignRight : Text.AlignLeft
    renderType: Text.NativeRendering
    elide: Text.ElideRight
    maximumLineCount: style.lines || 1
    wrapMode: style.lines > 1 ? Text.WordWrap : Text.NoWrap

    // A legibility shadow, only when asked for (it costs an offscreen pass).
    layer.enabled: style.shadow === true
    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Qt.rgba(0, 0, 0, 0.85); shadowBlur: 0.25; shadowVerticalOffset: 1 }

    Binding on color { when: t.style.color !== undefined; value: Skin.rgb(t.style.color) }
}
