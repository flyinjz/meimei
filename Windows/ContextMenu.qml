// Opens an app menu on right-click (the Mac's appContextMenu): `menu` is a
// function returning the content, built at click time so it can depend on
// where the pointer is. Fill the area it serves; other clicks pass through.
import QtQuick
import I2S

Item {
    id: root
    property var menu: function () { return null }
    anchors.fill: parent
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: (point) => {
            const g = root.mapToGlobal(point.position.x, point.position.y)
            AppMenu.open(root.menu(point.position), g.x, g.y)
        }
    }
}
