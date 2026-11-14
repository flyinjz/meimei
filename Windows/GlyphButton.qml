// A bare glyph button (the Mac's TransportButton + GlyphButtonStyle): no
// background in any state; secondary at rest, primary under the pointer,
// accent when active; dips when pressed.
import QtQuick
import I2S

Item {
    id: root
    property string icon: ""
    property real size: 22
    property real iconSize: 12
    property bool active: false
    property string help: ""
    /// The colour at rest (secondary by default).
    property color restColor: Skin.textSecondary
    signal clicked()

    width: size; height: size

    Glyph {
        anchors.centerIn: parent
        width: root.iconSize; height: root.iconSize
        name: root.icon
        color: root.active ? Skin.accent : hover.hovered ? Skin.textPrimary : root.restColor
        scale: tap.pressed ? 0.92 : 1
        opacity: root.enabled ? (tap.pressed ? 0.7 : 1) : 0.35
        Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
        Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
    }
    HoverHandler { id: hover; enabled: root.enabled }
    TapHandler { id: tap; enabled: root.enabled; onTapped: root.clicked() }
    Tip { text: root.help; shown: hover.hovered }
}
