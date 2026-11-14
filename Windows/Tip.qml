// A hover tooltip (the Mac's `.help`): appears after the pointer rests a
// moment, under the control, inside the window; a small dark box in the
// app's type. Put it inside the control and bind `shown` to its hover.
import QtQuick
import I2S

Item {
    id: root
    property string text: ""
    property bool shown: false
    readonly property Item host: parent

    Timer {
        id: delay
        interval: 900
        running: root.shown && root.text !== ""
        onTriggered: box.place()
    }
    onShownChanged: if (!shown) box.visible = false

    Rectangle {
        id: box
        parent: root.Window.window ? root.Window.window.contentItem : root
        visible: false
        z: 10000
        width: tipText.implicitWidth + 12
        height: tipText.implicitHeight + 6
        color: Qt.rgba(0.11, 0.11, 0.11, 0.96)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.14)
        function place() {
            if (!root.host || !parent) return
            const p = root.host.mapToItem(parent, 0, root.host.height + 6)
            x = Math.max(4, Math.min(parent.width - width - 4, p.x + (root.host.width - width) / 2))
            y = p.y + height > parent.height - 4 ? root.host.mapToItem(parent, 0, 0).y - height - 6 : p.y
            visible = true
        }
        Label {
            id: tipText
            anchors.centerIn: parent
            pt: 10.5
            text: root.text
            color: Skin.textPrimary
        }
    }
}
