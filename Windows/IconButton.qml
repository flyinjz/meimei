// A square icon button with the pill buttons' treatment (the Mac's IconButton).
import QtQuick
import I2S

Item {
    id: root
    property string icon: ""
    property real size: 26
    property bool active: false
    property string help: ""
    property string fill: ""
    signal clicked()

    readonly property var look: Skin.buttonLook(fill || Core.settings.buttonFill, active, hover.hovered)
    width: size; height: size

    Item {
        anchors.fill: parent
        scale: tap.pressed ? 0.94 : 1
        opacity: tap.pressed ? 0.75 : 1
        Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
        Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
        Rectangle {
            anchors.fill: parent
            color: root.look.background
            border.width: 1
            border.color: root.look.border
            Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
        }
        Glyph {
            anchors.centerIn: parent
            width: root.size * 0.42; height: width
            name: root.icon
            color: root.look.foreground
        }
    }
    HoverHandler { id: hover }
    TapHandler { id: tap; onTapped: root.clicked() }
    Tip { text: root.help; shown: hover.hovered }
}
