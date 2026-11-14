// A navigation row (the Mac's SettingsNavRow: Settings sections, the Panels
// list): icon, label, optional trailing status.
import QtQuick
import I2S

Item {
    id: root
    property string icon: ""
    property string text: ""
    property bool selected: false
    property string trailingText: ""
    property bool trailingIsOn: false
    signal clicked()

    implicitHeight: Math.max(16, label.implicitHeight) + 10
    implicitWidth: 200

    Rectangle {
        anchors.fill: parent
        color: root.selected ? Skin.withAlpha(Skin.selection, 0.55) : hover.hovered ? Skin.hover : "transparent"
    }
    Row {
        x: 8; spacing: 8
        anchors.verticalCenter: parent.verticalCenter
        Item {
            width: 16; height: 12
            anchors.verticalCenter: parent.verticalCenter
            Glyph { anchors.centerIn: parent; width: 12; height: 12; name: root.icon; color: root.selected ? Skin.accent : Skin.textSecondary }
        }
        Label {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            pt: 12; weight: root.selected ? "semibold" : "regular"
            text: root.text
            color: root.selected ? Skin.textPrimary : Skin.textSecondary
        }
    }
    Label {
        visible: root.trailingText !== ""
        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
        pt: 9.5; weight: "medium"
        text: root.trailingText
        color: root.trailingIsOn ? Skin.accent : Skin.textTertiary
    }
    HoverHandler { id: hover }
    TapHandler { onTapped: root.clicked() }
}
