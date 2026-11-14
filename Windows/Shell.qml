// Phase 1 window: the platform layer on its own (frame, glass, type, icons,
// wheel glide, audio, media keys), before the real main window replaces it.
import QtQuick
import I2S

Window {
    id: win
    width: 1240; height: 780
    minimumWidth: 960; minimumHeight: 620
    title: "i2s"
    color: "transparent"
    flags: Qt.Window | Qt.FramelessWindowHint

    readonly property real gap: Skin.gap
    readonly property bool gallery: openStates.indexOf("gallery") >= 0

    Backdrop {
        anchors.fill: parent
        style: "translucent"
        glassTint: Core.settings.glassTintStrength
    }

    TitleBand {
        id: band
        window: win
        anchors { left: parent.left; right: parent.right; top: parent.top }
        Label {
            anchors.centerIn: parent
            pt: 12; weight: "medium"
            text: "i2s · platform layer"
            color: Skin.textSecondary
        }
    }

    Gallery {
        visible: win.gallery
        x: 0; y: band.height - win.gap
        width: parent.width; height: parent.height - y
    }

    Row {
        id: panes
        visible: !win.gallery
        x: win.gap; y: band.height
        width: parent.width - 2 * win.gap
        height: parent.height - band.height - win.gap
        spacing: win.gap
        readonly property real paneWidth: (width - 2 * spacing) / 3

        // Type: every bundled family in its three faces.
        Item {
            width: panes.paneWidth; height: parent.height
            GlassSurface { anchors.fill: parent }
            Flickable {
                id: typeList
                objectName: "typeList"
                anchors { fill: parent; margins: 14 }
                clip: true
                contentHeight: typeColumn.height
                boundsBehavior: Flickable.StopAtBounds
                Glide { line: 18 }
                Column {
                    id: typeColumn
                    width: parent.width
                    spacing: 14
                    Label { pt: 10.5; weight: "semibold"; text: "Type"; color: Skin.textTertiary }
                    Repeater {
                        model: Core.fonts
                        Column {
                            required property var modelData
                            width: typeColumn.width
                            spacing: 3
                            Label { width: parent.width; pt: 22; weight: "bold"; family: modelData.id; text: modelData.label }
                            Label { width: parent.width; pt: 12; family: modelData.id; text: "Light 12 · The quick brown fox 0123456789" }
                            Label { width: parent.width; pt: 10.5; family: modelData.id; text: "Regular 10.5 · " + modelData.note; color: Skin.textSecondary }
                        }
                    }
                }
            }
        }

        // Icons: every role in the chosen pack.
        Item {
            width: panes.paneWidth; height: parent.height
            GlassSurface { anchors.fill: parent; content: true }
            Label { x: 14; y: 14; pt: 10.5; weight: "semibold"; text: "Icons · " + Core.settings.iconPack; color: Skin.textTertiary }
            GridView {
                id: iconGrid
                objectName: "iconGrid"
                anchors { fill: parent; margins: 14; topMargin: 36 }
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                cellWidth: width / Math.max(1, Math.floor(width / 56)); cellHeight: 52
                model: Core.icons.roles
                reuseItems: true
                Glide { line: 52 }
                delegate: Item {
                    required property var modelData
                    width: iconGrid.cellWidth; height: iconGrid.cellHeight
                    Glyph { width: 18; height: 18; anchors.horizontalCenter: parent.horizontalCenter; y: 6; name: modelData.role; color: Skin.textPrimary }
                    Label { width: parent.width - 4; x: 2; y: 30; pt: 8; text: modelData.role; color: Skin.textTertiary; horizontalAlignment: Text.AlignHCenter }
                }
            }
        }

        // Audio, media keys, and a long list for the glide.
        Item {
            width: panes.paneWidth; height: parent.height
            GlassSurface { anchors.fill: parent }
            Column {
                id: audioColumn
                x: 14; y: 14; width: parent.width - 28
                spacing: 8
                Label { pt: 10.5; weight: "semibold"; text: "Audio"; color: Skin.textTertiary }
                Row {
                    spacing: 14
                    Glyph {
                        width: 18; height: 18
                        name: Audio.playing ? "pause.fill" : "play.fill"
                        color: playTap.pressed ? Skin.accent : Skin.textPrimary
                        TapHandler {
                            id: playTap
                            onTapped: Audio.currentID === "" ? Audio.start("gen:1:240", "test") : Audio.playing ? Audio.pause() : Audio.play()
                        }
                    }
                    Label {
                        pt: 12
                        text: (Audio.currentID === "" ? "Nothing playing" : "Generated 4:00 tone (silent)")
                              + "  " + Math.floor(Audio.position / 60) + ":" + String(Math.floor(Audio.position % 60)).padStart(2, "0")
                    }
                }
                Label { pt: 10.5; text: "Media keys: " + (MediaSession.active ? "connected" : "not connected"); color: Skin.textSecondary }
            }
            ListView {
                id: glideList
                objectName: "glideList"
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; top: audioColumn.bottom; margins: 1; topMargin: 14 }
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: 1000
                reuseItems: true
                Glide { id: listGlide; objectName: "glideHandler"; line: 21 }
                delegate: Rectangle {
                    required property int index
                    width: glideList.width; height: 21
                    color: index % 2 === 1 ? Skin.bgRowAlt : "transparent"
                    Label { x: 13; anchors.verticalCenter: parent.verticalCenter; pt: 11.5; text: "Row " + (parent.index + 1); color: Skin.textSecondary }
                }
            }
        }
    }
}
