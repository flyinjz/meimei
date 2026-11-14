// The app's horizontal slider (the Mac's MinimalSlider): a thin line that
// thickens under the pointer. "line" shows the knob only while hovering or
// dragging; "knob" keeps a small knob visible.
import QtQuick
import I2S

Item {
    id: root
    property real value: 0
    property real from: 0
    property real to: 1
    property real trackHeight: 3
    property string style: Core.settings.sliderStyle || "line"
    /// Fill in the accent instead of the primary text colour.
    property bool accentFill: false
    readonly property bool dragging: drag.active || press.pressed
    signal moved(real value)
    signal editingChanged(bool editing)

    readonly property real fraction: to > from ? Math.min(1, Math.max(0, (value - from) / (to - from))) : 0
    readonly property bool isActive: hover.hovered || dragging
    readonly property real thickness: isActive ? trackHeight + 1 : trackHeight

    implicitHeight: 14
    implicitWidth: 120

    function setFrom(px) {
        const f = width > 0 ? Math.min(Math.max(0, px), width) / width : 0
        moved(from + f * (to - from))
    }

    Rectangle {
        width: parent.width; height: root.thickness
        anchors.verticalCenter: parent.verticalCenter
        color: Skin.withAlpha(Skin.textPrimary, 0.14)
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
    }
    Rectangle {
        width: Math.max(root.thickness, root.width * root.fraction); height: root.thickness
        anchors.verticalCenter: parent.verticalCenter
        color: root.accentFill ? Skin.accent : Skin.withAlpha(Skin.textPrimary, root.isActive ? 0.9 : 0.62)
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
    }
    Rectangle {
        id: knob
        readonly property real side: root.isActive ? 11 : 8
        width: side; height: side
        x: root.width * root.fraction - side / 2
        anchors.verticalCenter: parent.verticalCenter
        color: Skin.textPrimary
        opacity: root.style === "knob" || root.isActive ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        // The Mac's small drop shadow under the knob.
        Rectangle { z: -1; x: 0; y: 0.5; width: parent.width; height: parent.height; color: Qt.rgba(0, 0, 0, 0.3); opacity: parent.opacity; antialiasing: true }
    }
    HoverHandler { id: hover }
    // Press anywhere jumps there; dragging follows the pointer.
    TapHandler {
        id: press
        gesturePolicy: TapHandler.WithinBounds
        onPressedChanged: {
            if (pressed) { root.editingChanged(true); root.setFrom(point.position.x) }
            else if (!drag.active) root.editingChanged(false)
        }
    }
    DragHandler {
        id: drag
        target: null
        xAxis.enabled: true; yAxis.enabled: false
        dragThreshold: 0
        onCentroidChanged: if (active) root.setFrom(centroid.position.x)
        onActiveChanged: if (!active) root.editingChanged(false)
    }
}
