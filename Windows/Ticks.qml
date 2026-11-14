// The L-shaped registration ticks at a box's four corners (the Mac's
// fuiCorners): textPrimary at half strength, 1px, `length` long.
import QtQuick
import I2S

Item {
    id: root
    property real length: Skin.tickLength
    property color color: Skin.withAlpha(Skin.textPrimary, 0.5)
    Repeater {
        model: 4
        Item {
            required property int index
            readonly property bool atRight: index % 2 === 1
            readonly property bool atBottom: index >= 2
            x: atRight ? root.width - root.length : 0
            y: atBottom ? root.height - root.length : 0
            width: root.length; height: root.length
            Rectangle { y: parent.atBottom ? parent.height - 1 : 0; width: parent.width; height: 1; color: root.color }
            Rectangle { x: parent.atRight ? parent.width - 1 : 0; width: 1; height: parent.height; color: root.color }
        }
    }
}
