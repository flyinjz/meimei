// The player bar (the Mac's PlayerBarView): transport on the left, what's
// playing centred (cover, title, artist, seek line with times), lyrics, Up
// Next, equalizer and volume on the right. Comfy (58) or compact (42); the
// customize height overrides it.
import QtQuick
import I2S

GlassSurface {
    id: bar
    element: "playerBar"
    fallback: Skin.bgPanel
    readonly property bool compact: Core.settings.playerBarStyle === "compact"
    readonly property real baseHeight: compact ? 42 : 58
    height: style.height === undefined ? baseHeight : style.height
    signal upNextRequested(Item anchor)

    Item {
        id: pb
        x: 16 + bar.padding; width: parent.width - 32 - 2 * bar.padding; height: parent.height
        readonly property real moduleWidth: Math.min(540, Math.max(280, width * 0.4))

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            GlyphButton {
                anchors.verticalCenter: parent.verticalCenter; size: 26; icon: "shuffle"; iconSize: 12
                help: "Shuffle"; active: Player.shuffle; onClicked: Player.shuffle = !Player.shuffle
            }
            GlyphButton { anchors.verticalCenter: parent.verticalCenter; size: 30; icon: "backward.fill"; iconSize: 15; help: "Previous"; onClicked: Player.previous() }
            PlayPauseButton {
                anchors.verticalCenter: parent.verticalCenter; size: bar.compact ? 28 : 34
                playing: Player.playing; onClicked: Player.togglePlayPause()
            }
            GlyphButton { anchors.verticalCenter: parent.verticalCenter; size: 30; icon: "forward.fill"; iconSize: 15; help: "Next"; onClicked: Player.next() }
            GlyphButton {
                anchors.verticalCenter: parent.verticalCenter; size: 26; iconSize: 12
                icon: Player.repeatMode === "one" ? "repeat.1" : "repeat"
                help: Player.repeatMode === "off" ? "Repeat" : Player.repeatMode === "all" ? "Repeat All" : "Repeat One"
                active: Player.repeatMode !== "off"; onClicked: Player.cycleRepeat()
            }
        }

        // Now playing: cover, title, artist, progress.
        Item {
            id: module
            width: pb.moduleWidth
            x: (pb.width - width) / 2
            height: Math.max(art.height, info.height)
            anchors.verticalCenter: parent.verticalCenter
            Cover {
                id: art
                width: bar.compact ? 32 : 44; height: width
                anchors.verticalCenter: parent.verticalCenter
                opacity: Player.hasTrack ? 1 : 0.5
                art: Player.track.artwork || ""; pixels: 96
            }
            Column {
                id: info
                x: art.width + 11; width: module.width - art.width - 11
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Column {
                    width: parent.width
                    spacing: 1
                    Label {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        pt: 12.5; weight: "semibold"; role: "playerTitle"
                        text: Player.hasTrack ? Player.track.title : "Not Playing"
                        color: Player.hasTrack ? Skin.textPrimary : Skin.textTertiary
                    }
                    Label {
                        visible: Player.hasTrack
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        pt: 11; role: "playerSubtitle"; color: Skin.textSecondary
                        text: [Player.track.artist, Player.track.album].filter(s => s).join(" — ")
                        TapHandler { onTapped: if (Player.hasTrack) Library.source = "artist:" + (Player.track.albumArtist || Player.track.artist) }
                    }
                }
                Item {
                    id: seekRow
                    width: parent.width; height: 10
                    property real seekValue: -1
                    readonly property real shownTime: seekValue >= 0 ? seekValue : Player.position
                    Label {
                        width: 34; anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        pt: 9.5; weight: "medium"; role: "playerTimes"; color: Skin.textTertiary
                        text: Player.clock(seekRow.shownTime)
                    }
                    MinimalSlider {
                        x: 42; width: parent.width - 42 - 46
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: Player.hasTrack
                        value: Player.duration > 0 ? seekRow.shownTime / Player.duration : 0
                        onMoved: (v) => seekRow.seekValue = v * Player.duration
                        onEditingChanged: (editing) => { if (!editing && seekRow.seekValue >= 0) { Player.seek(seekRow.seekValue); seekRow.seekValue = -1 } }
                    }
                    Label {
                        x: parent.width - 38; width: 38; anchors.verticalCenter: parent.verticalCenter
                        pt: 9.5; weight: "medium"; role: "playerTimes"; color: Skin.textTertiary
                        text: "−" + Player.clock(Math.max(0, Player.duration - seekRow.shownTime))
                    }
                }
            }
        }

        Row {
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            GlyphButton {
                anchors.verticalCenter: parent.verticalCenter; size: 26
                icon: "quote.bubble"; iconSize: 13; active: Core.settings.showLyrics
                help: Core.settings.showLyrics ? "Hide Lyrics" : "Show Lyrics"
                onClicked: Core.setSetting("showLyrics", !Core.settings.showLyrics)
            }
            GlyphButton {
                id: upNextButton
                anchors.verticalCenter: parent.verticalCenter; size: 26; icon: "list.bullet"; iconSize: 13
                help: "Up Next"
                onClicked: bar.upNextRequested(upNextButton)
            }
            GlyphButton { anchors.verticalCenter: parent.verticalCenter; size: 26; icon: "slider.vertical.3"; iconSize: 13; help: "Equalizer" }
            Item { width: 6; height: 1 }
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                GlyphButton {
                    anchors.verticalCenter: parent.verticalCenter; size: 22; iconSize: 12
                    icon: Player.volume < 0.001 ? "speaker.slash.fill" : Player.volume < 0.34 ? "speaker.wave.1.fill"
                          : Player.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
                    help: Player.volume < 0.001 ? "Unmute" : "Mute"
                    onClicked: Player.toggleMute()
                }
                MinimalSlider {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Core.settings.volumeSliderWidth || 84; value: Player.volume
                    onMoved: (v) => Player.volume = v
                }
            }
        }
    }
}
