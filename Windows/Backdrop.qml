// What fills a window behind its panes (the Mac's WindowBackdrop).
// "translucent": the platform's blur of what's behind the window (drawn by
// Windows; this only lays the theme's veil over it), "themeColor", "ambient"
// (a faint measuring grid), "artwork" (the cover, blurred).
import QtQuick
import I2S

Item {
    id: root
    property string style: "translucent"
    /// How strongly the theme's base colour veils what's behind (0…1).
    property real glassTint: 0.5
    /// The blurred cover for "artwork" (an image source), if any.
    property url artwork

    clip: true

    Rectangle {
        anchors.fill: parent
        color: Skin.bgVoid
        // Translucent: only the veil, unless snapshots can't see the blur.
        opacity: root.style === "translucent" && !Platform.forceFallback ? root.glassTint : 1
    }
    Canvas {
        anchors.fill: parent
        visible: root.style === "ambient"
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.035)
            ctx.lineWidth = 1
            ctx.beginPath()
            for (let x = 0; x <= width; x += 24) { ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, height) }
            for (let y = 0; y <= height; y += 24) { ctx.moveTo(0, y + 0.5); ctx.lineTo(width, y + 0.5) }
            ctx.stroke()
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
    Item {
        anchors.fill: parent
        visible: root.style === "artwork" && root.artwork.toString() !== ""
        Image {
            anchors.fill: parent
            source: root.artwork
            fillMode: Image.PreserveAspectCrop
            smooth: true
            asynchronous: true
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 800; easing.type: Easing.InOutQuad } }
        }
        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.45) }
    }
}
