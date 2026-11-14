// The app's one shape for labeled actions (the Mac's PillButtonStyle): a
// rectangle with a 1px border that brightens under the pointer, accent-
// filled when prominent or active. Fill, content and size follow settings.
import QtQuick
import I2S

Item {
    id: root
    property string text: ""
    /// An icon role, shown per the "button content" setting.
    property string icon: ""
    property bool prominent: false
    property bool active: false
    property bool compact: false
    /// Forces what the button shows ("iconAndText", "text", "icon"), e.g. where space is short.
    property string contentOverride: ""
    /// Forces the fill ("solid", "outline", "text"); the setting otherwise.
    property string fill: ""
    signal clicked()

    readonly property var d: Core.settings
    readonly property real delta: Skin.buttonSizeDelta(d.buttonSize)
    readonly property bool accent: active || (prominent && d.buttonAccentPrimary)
    readonly property bool hovering: hover.hovered && enabled
    readonly property string fillStyle: fill || d.buttonFill
    readonly property var look: Skin.buttonLook(fillStyle, accent, hovering)
    readonly property string content: contentOverride || d.buttonContent
    readonly property bool showsIcon: icon !== "" && content !== "text"
    readonly property bool showsText: text !== "" && (content !== "icon" || icon === "")

    implicitWidth: row.implicitWidth + 2 * (fillStyle === "text" ? 4 : compact ? 8 : 11)
    implicitHeight: (compact ? 22 : 26) + delta
    width: implicitWidth; height: implicitHeight
    opacity: enabled ? 1 : 0.4

    Item {
        id: face
        anchors.fill: parent
        transform: Translate {
            y: tap.pressed ? 1 : 0
            Behavior on y { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
        }
        Rectangle {
            anchors.fill: parent
            color: root.look.background
            border.width: 1
            border.color: root.look.border
            Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
            Behavior on border.color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
        }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 5
            Glyph {
                visible: root.showsIcon
                width: 11; height: 11
                anchors.verticalCenter: parent.verticalCenter
                name: root.icon
                color: root.look.foreground
            }
            Label {
                visible: root.showsText
                anchors.verticalCenter: parent.verticalCenter
                pt: (root.compact ? 11 : 12) + root.delta / 3
                weight: root.accent ? "semibold" : "regular"
                text: root.text
                color: root.look.foreground
            }
        }
    }
    HoverHandler { id: hover }
    TapHandler { id: tap; enabled: root.enabled; onTapped: root.clicked() }
}
