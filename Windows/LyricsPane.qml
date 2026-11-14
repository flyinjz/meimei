// Lyrics for the playing track (the Mac's LyricsPanelView): synced lines
// highlight and spring to the current one (click a line to jump there);
// plain lyrics show as text; an empty state otherwise. Each line is its own
// customize outline ("lyrics").
import QtQuick
import QtQuick.Effects
import I2S

Item {
    id: lv
    Item {
        id: head
        width: parent.width; height: 30
        Label { x: 14; anchors.verticalCenter: parent.verticalCenter; pt: 11; weight: "medium"; role: "sectionLabels"; text: "lyrics"; color: Skin.textTertiary }
        Label {
            visible: Player.lyrics.length > 0
            anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
            pt: 9.5; weight: "medium"; text: Player.lyricsSynced ? "synced" : "plain"
            color: Player.lyricsSynced ? Skin.accent : Skin.textTertiary
        }
    }
    Column {
        visible: Player.lyrics.length === 0
        anchors.centerIn: parent
        width: parent.width
        spacing: 10
        Glyph { anchors.horizontalCenter: parent.horizontalCenter; width: 24; height: 24; name: "quote.bubble"; color: Skin.withAlpha(Skin.accent, 0.8) }
        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            pt: 12; weight: "medium"; color: Skin.textSecondary
            text: Player.hasTrack ? "No lyrics for this track" : "Nothing playing"
        }
        Label {
            visible: Player.hasTrack
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 40; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideNone
            pt: 10.5; color: Skin.textTertiary; text: "Put a matching .lrc next to the audio file."
        }
    }
    Item {
        id: viewport
        visible: Player.lyrics.length > 0 && Player.lyricsSynced
        y: head.height; width: parent.width; height: parent.height - y
        clip: true
        layer.enabled: true
        layer.effect: MultiEffect { maskEnabled: true; maskSource: fadeMask }

        readonly property int current: Player.lyricLine
        // Follow: centre the current line on 38% of the panel, never pushing
        // the first line below the 12 pt top inset.
        readonly property real follow: {
            const it = current >= 0 ? lines.itemAt(current) : null
            if (!it) return 12
            return Math.min(height * 0.38 - (it.y + it.height / 2), 12)
        }
        Spring { id: followSpring; target: viewport.follow; response: 0.75; dampingFraction: 1 }

        Column {
            id: stack
            x: 16; width: parent.width - 32
            y: followSpring.value
            spacing: 10
            Repeater {
                id: lines
                model: Player.lyrics
                delegate: Label {
                    id: line
                    required property int index
                    required property var modelData
                    readonly property bool isCurrent: index === viewport.current
                    readonly property bool isPast: viewport.current >= 0 && index < viewport.current
                    readonly property real distance: Math.min(viewport.current >= 0 ? Math.abs(index - viewport.current) : 0, 6)
                    width: stack.width
                    wrapMode: Text.WordWrap
                    maximumLineCount: 100
                    elide: Text.ElideNone
                    pt: 15; weight: "semibold"; role: "lyricsText"
                    renderType: Text.CurveRendering
                    text: modelData.text.length === 0 ? "♪" : modelData.text
                    color: isCurrent || lineHover.hovered ? Skin.textPrimary : Skin.textTertiary
                    transformOrigin: Item.Left
                    Spring { id: s; target: line.isCurrent ? 1 : 0.9; response: 0.75; dampingFraction: 1; delay: line.distance * 0.035 }
                    Spring { id: o; target: line.isCurrent ? 1 : Math.max(0.28, (line.isPast ? 0.62 : 0.78) - line.distance * 0.07); response: 0.75; dampingFraction: 1; delay: line.distance * 0.035 }
                    scale: s.value
                    opacity: lineHover.hovered && !isCurrent ? 0.85 : o.value
                    HoverHandler { id: lineHover }
                    TapHandler { onTapped: if (line.modelData.time >= 0) Player.seek(line.modelData.time) }
                }
            }
        }
    }
    Flickable {
        id: plain
        visible: Player.lyrics.length > 0 && !Player.lyricsSynced
        y: head.height; width: parent.width; height: parent.height - y
        contentHeight: plainCol.height + 48; clip: true
        boundsBehavior: Flickable.StopAtBounds
        Glide { line: 20 }
        Column {
            id: plainCol
            x: 16; y: 24; width: plain.width - 32; spacing: 4
            Repeater {
                model: Player.lyricsSynced ? [] : Player.lyrics
                delegate: Label {
                    required property var modelData
                    width: plainCol.width; wrapMode: Text.WordWrap; maximumLineCount: 20; elide: Text.ElideNone
                    pt: 12.5; role: "lyricsText"; color: Skin.textSecondary; text: modelData.text.length === 0 ? " " : modelData.text
                }
            }
        }
    }
    // The edge fade: clear → opaque by 6%, opaque → clear from 88%.
    Rectangle {
        id: fadeMask
        visible: false
        layer.enabled: true
        width: viewport.width; height: viewport.height
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 0.06; color: "black" }
            GradientStop { position: 0.88; color: "black" }
            GradientStop { position: 1; color: "transparent" }
        }
    }
}
