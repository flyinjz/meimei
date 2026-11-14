// A square switch in the accent colour (the Mac's SettingsToggleSwitch).
import QtQuick
import I2S

Item {
    id: root
    property bool on: false
    signal toggled(bool on)

    width: 34; height: 18

    Rectangle {
        anchors.fill: parent
        color: root.on ? Skin.accent : "transparent"
        border.width: 1
        border.color: root.on ? Skin.accent : Skin.withAlpha(Skin.textPrimary, 0.3)
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutQuad } }
    }
    Rectangle {
        width: 12; height: 12
        y: 3
        x: root.on ? root.width - 15 : 3
        color: root.on ? Skin.textOnAccent : Skin.textSecondary
        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutQuad } }
    }
    TapHandler { onTapped: root.toggled(!root.on) }
}
