// A cover image decoded off the main thread at the size shown, or the
// placeholder glyph on the raised fill (the Mac's ArtworkView).
import QtQuick
import I2S

Item {
    id: cv
    property string art: ""
    property int pixels: 128
    property string placeholder: "music.note"
    clip: true
    Rectangle { anchors.fill: parent; color: Skin.bgRaised; visible: img.status !== Image.Ready }
    Glyph {
        visible: img.status !== Image.Ready
        anchors.centerIn: parent
        width: Math.max(9, cv.width * 0.26); height: width
        name: cv.placeholder; color: Skin.textTertiary
    }
    Image {
        id: img
        anchors.fill: parent
        source: cv.art.length > 0 ? "image://art/" + encodeURIComponent(cv.art) : ""
        sourceSize: Qt.size(cv.pixels, cv.pixels)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true; mipmap: true
    }
}
