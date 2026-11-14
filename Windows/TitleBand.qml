// The band across the top of every i2s window (the Mac's TitleBand): 46
// points tall, the window buttons 14 points from the left edge and centered
// in it. Dragging the band moves the window (with snap); a double-click
// zooms it, as a title bar does.
import QtQuick
import I2S

Item {
    id: root
    property Window window
    property bool closeOnly: false
    property bool canZoom: true
    /// Shown when the platform's own frame draws the buttons instead.
    property bool showButtons: !Core.settings.systemWindowFrame
    default property alias content: slot.data

    height: 46

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        property point pressedAt
        // The system move starts once the pointer actually moves, so a
        // double-click still reaches the band.
        onPressed: (mouse) => pressedAt = Qt.point(mouse.x, mouse.y)
        onPositionChanged: (mouse) => {
            if (pressed && Math.abs(mouse.x - pressedAt.x) + Math.abs(mouse.y - pressedAt.y) > 3) Platform.startMove(root.window)
        }
        onDoubleClicked: Platform.toggleFullScreen(root.window, true)
    }
    /// Where the window buttons end (band coordinates), for what follows them.
    readonly property real buttonsRight: showButtons ? buttons.x + buttons.width : 0
    WindowButtons {
        id: buttons
        visible: root.showButtons
        x: 14
        anchors.verticalCenter: parent.verticalCenter
        window: root.window
        closeOnly: root.closeOnly
        canZoom: root.canZoom
    }
    Item { id: slot; anchors.fill: parent }
}
