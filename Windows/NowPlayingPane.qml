// The cover-art panel (the Mac's NowPlayingPanelView): the largest square
// cover that fits, then title, artist, details, the format strip and the
// play count. Its natural height is reported to the pane grid.
import QtQuick
import QtQuick.Effects
import I2S

Item {
    id: np
    readonly property var t: Player.track
    readonly property bool has: Player.hasTrack
    readonly property real side: Math.max(48, Math.floor(Math.min(width - 24, 520, height - 12 - info.height)))
    /// Cover plus details, as WeightedStack measures it.
    readonly property real infoHeight: info.height
    readonly property real naturalHeight: 12 + Math.max(48, Math.floor(Math.min(width - 24, 520))) + info.height

    Item {
        x: (parent.width - np.side) / 2; y: 12
        width: np.side; height: width
        RectangularShadow { anchors.fill: parent; offset.y: 6; blur: 24; color: Qt.rgba(0, 0, 0, 0.35) }
        Cover { anchors.fill: parent; art: np.t.artwork || ""; pixels: 512; placeholder: "waveform" }
    }
    Column {
        id: info
        y: 12 + np.side
        width: parent.width
        Item { width: 1; height: 9 }
        Item {
            x: 12; width: parent.width - 24
            height: text.height
            Column {
                id: text
                width: parent.width - 28
                spacing: 2
                Label { width: parent.width; pt: 13; weight: "semibold"; role: "nowPlayingTitle"; text: np.has ? np.t.title : "Nothing playing" }
                Label {
                    width: parent.width; pt: 11.5; role: "nowPlayingArtist"; color: Skin.textSecondary
                    text: np.has ? (np.t.artist || "Unknown Artist") : "Pick something from your library"
                }
                Label {
                    width: parent.width; pt: 10.5; role: "nowPlayingDetails"; color: Skin.textTertiary
                    visible: np.has && text.length > 0
                    text: np.has ? [np.t.album, np.t.year > 0 ? String(np.t.year) : ""].filter(s => s).join(" · ") : ""
                }
            }
            GlyphButton {
                visible: np.has
                anchors.right: parent.right
                size: 22; iconSize: 12
                icon: np.t.liked ? "heart.fill" : "heart"; active: !!np.t.liked
                restColor: Skin.textTertiary
                help: np.t.liked ? "Unlike" : "Like"
                onClicked: Player.toggleLiked()
            }
        }
        Item { width: 1; height: np.has ? 6 : 10 }
        Item {
            visible: np.has && Core.settings.showFormatStrip !== false
            x: 12; width: parent.width - 24; height: visible ? fmt.height : 0
            Row {
                id: fmt
                spacing: 6
                Label {
                    pt: 10.5; weight: "medium"; color: Skin.textTertiary
                    text: !np.has ? "" : np.t.lossless ? np.t.format + " · " + np.t.bitDepth + "-bit · " + (np.t.sampleRate / 1000).toFixed(np.t.sampleRate % 1000 ? 1 : 0) + " kHz"
                          : (np.t.bitrate > 0 ? np.t.format + " · " + np.t.bitrate + " kbps" : np.t.format)
                }
                Row {
                    visible: !!np.t.hiRes
                    spacing: 3
                    anchors.verticalCenter: parent.verticalCenter
                    Glyph { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; name: "badge.hires"; color: Skin.withAlpha(Skin.accent, 0.75) }
                    Label { pt: 10.5; weight: "medium"; text: "Hi-Res"; color: Skin.withAlpha(Skin.accent, 0.75) }
                }
            }
            Label {
                anchors.right: parent.right
                visible: np.t.plays > 0
                pt: 10.5; weight: "medium"; color: Skin.textTertiary
                text: np.t.plays === 1 ? "1 play" : np.t.plays + " plays"
            }
        }
        Item { width: 1; height: np.has ? 10 : 0 }
    }
}
