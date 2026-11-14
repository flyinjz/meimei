// A 1px divider in the skin's hairline colour (the Mac's Hairline).
import QtQuick
import I2S

Rectangle {
    property bool vertical: false
    property real inset: 0
    implicitWidth: vertical ? 1 : 100
    implicitHeight: vertical ? 100 : 1
    color: Skin.hairline
}
