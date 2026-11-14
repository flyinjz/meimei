// Close, minimize and full screen, drawn by i2s for its square frame (the
// Mac's WindowControls): every look option comes from settings
// (windowControl*), exactly as the Mac draws them.
import QtQuick
import I2S

Row {
    id: root
    /// The window the buttons act on.
    property Window window
    property bool canZoom: true
    /// Child windows show only Close.
    property bool closeOnly: false
    /// A settings preview: drawn and hoverable, but the buttons do nothing.
    property bool preview: false

    readonly property var d: Core.settings
    readonly property var kinds: {
        let list = closeOnly ? ["close"] : canZoom ? ["close", "minimize", "zoom"] : ["close", "minimize"]
        if (d.windowControlCloseLast) list = list.filter(k => k !== "close").concat(["close"])
        return list
    }
    property bool hoveringGroup: hoverArea.hovered

    spacing: d.windowControlStyle === "bare" ? d.windowControlSpacing + 2 : d.windowControlSpacing

    HoverHandler { id: hoverArea }

    Repeater {
        model: root.kinds
        delegate: Item {
            id: button
            required property string modelData
            readonly property string kind: modelData
            readonly property string style: root.d.windowControlStyle
            readonly property real side: root.d.windowControlSide
            readonly property real rest: root.d.windowControlRestOpacity
            readonly property bool hovering: hover.hovered
            readonly property bool showsGlyph: style === "bare" ? true
                : root.d.windowControlGlyphs === "hover" ? root.hoveringGroup : root.d.windowControlGlyphs === "always"

            readonly property color base: root.d.windowControlColoring === "accent" ? Skin.accent
                : root.d.windowControlColoring === "custom" && root.d.windowControlColors[kind] !== undefined ? Skin.rgb(root.d.windowControlColors[kind])
                : root.d.windowControlColoring === "theme" && root.d.windowControlAccent ? Skin.accent : Skin.textPrimary
            readonly property color hoverColor: root.d.windowControlHover === "accent" ? Skin.accent : base
            readonly property bool brighten: root.d.windowControlHover === "brighten"
            readonly property color glyphColor: style === "bare" ? (hovering ? hoverColor : Skin.withAlpha(base, rest))
                : !hovering ? Skin.withAlpha(base, Math.min(1, rest + 0.3))
                : brighten ? base
                : Skin.luminance(hoverColor) > 0.55 ? Qt.rgba(0, 0, 0, 0.85) : "white"
            readonly property color fill: style === "bare" ? "transparent"
                : style === "outline" ? (hovering ? (brighten ? Skin.withAlpha(base, 0.18) : hoverColor) : Skin.withAlpha(base, 0.06))
                : (hovering ? (brighten ? Skin.withAlpha(base, 0.6) : hoverColor) : Skin.withAlpha(base, rest * 0.5))
            readonly property color border: hovering ? hoverColor : Skin.withAlpha(base, rest * 0.6)
            readonly property real borderWidth: style === "outline" ? root.d.windowControlBorder : 0

            width: side; height: side

            Rectangle {
                anchors.fill: parent
                radius: root.d.windowControlShape === "circle" ? width / 2 : root.d.windowControlShape === "rounded" ? width * 0.28 : 0
                color: button.fill
                border.width: button.borderWidth
                border.color: button.border
                antialiasing: radius > 0
                Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
                Behavior on border.color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
            }
            Glyph {
                anchors.centerIn: parent
                readonly property real size: button.side * (button.style === "bare" ? Math.min(1, root.d.windowControlIconScale * 1.35) : root.d.windowControlIconScale)
                width: size; height: size
                name: "window." + button.kind
                color: button.glyphColor
                opacity: button.showsGlyph ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
                Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
            }
            // The hit area reaches 3 points past the drawn square.
            Item {
                anchors.fill: parent
                anchors.margins: -3
                HoverHandler { id: hover }
                TapHandler {
                    enabled: !root.preview
                    onTapped: {
                        if (button.kind === "close") root.window.close()
                        else if (button.kind === "minimize") Platform.minimize(root.window)
                        else Platform.toggleFullScreen(root.window, Platform.altDown())
                    }
                }
            }
        }
    }
}
