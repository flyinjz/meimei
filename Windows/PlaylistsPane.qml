// The right-hand rail (the Mac's CollectionRailView): the local account,
// settings, then manual and smart playlists.
import QtQuick
import I2S

Item {
    id: rail
    signal newPlaylist()

    Item {
        id: account
        width: parent.width; height: 20 + Math.max(20, accText.height)
        Glyph { x: 10; anchors.verticalCenter: parent.verticalCenter; width: 20; height: 20; name: "person.crop.circle"; color: Skin.textSecondary }
        Column {
            id: accText
            x: 39; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 39 - 40
            spacing: 1
            Label { width: parent.width; pt: 12; weight: "semibold"; text: "Listener" }
            Label { width: parent.width; pt: 10; text: Library.count + " tracks · " + Library.albumCount + " albums"; color: Skin.textTertiary }
        }
        GlyphButton { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; size: 26; icon: "gearshape"; iconSize: 12; help: "Settings" }
    }
    Flickable {
        id: flick
        y: account.height; width: parent.width; height: parent.height - y
        contentHeight: col.height + 10
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Glide { line: 40 }
        Column {
            id: col
            x: 6; width: flick.width - 12
            spacing: 2
            Item {
                width: parent.width; height: 14 + lab.height + 4
                Label { id: lab; x: 10; y: 14; pt: 11; weight: "medium"; role: "sectionLabels"; text: "playlists"; color: Skin.textTertiary }
                GlyphButton {
                    anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: lab.verticalCenter
                    size: 20; iconSize: 10; icon: "plus"; help: "New Playlist"
                    onClicked: rail.newPlaylist()
                }
            }
            Label { visible: Library.playlists.length === 0; x: 8; pt: 11; text: "No playlists yet"; color: Skin.textTertiary }
            Repeater {
                model: Library.playlists
                delegate: Item {
                    id: pr
                    required property var modelData
                    readonly property bool selected: Library.source === "playlist:" + modelData.id
                    width: col.width; height: 40
                    Rectangle {
                        anchors.fill: parent
                        color: pr.selected ? Skin.withAlpha(Skin.accent, 0.1) : prh.hovered ? Skin.hover : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    Item {
                        x: 6; width: 32; height: 32; anchors.verticalCenter: parent.verticalCenter
                        Rectangle { anchors.fill: parent; color: Skin.bgVoid; visible: pr.modelData.artwork === "" }
                        Glyph {
                            visible: pr.modelData.artwork === ""; anchors.centerIn: parent; width: 11; height: 11
                            name: pr.modelData.smart ? "gearshape" : "music.note.list"; color: Skin.textTertiary
                        }
                        Cover { visible: pr.modelData.artwork !== ""; anchors.fill: parent; art: pr.modelData.artwork; pixels: 64 }
                        Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Skin.hairline }
                    }
                    Column {
                        x: 48; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 54
                        spacing: 1
                        Label { width: parent.width; pt: 12; weight: pr.selected ? "semibold" : "regular"; role: "railRows"; text: pr.modelData.name }
                        Label {
                            width: parent.width; pt: 10; color: Skin.textTertiary
                            text: (pr.modelData.smart ? "Smart · " : "") + (pr.modelData.count === 1 ? "1 song" : pr.modelData.count + " songs")
                        }
                    }
                    HoverHandler { id: prh }
                    TapHandler { onTapped: Library.source = "playlist:" + pr.modelData.id }
                    ContextMenu {
                        menu: () => ({ title: pr.modelData.name, subtitle: pr.modelData.smart ? "smart playlist" : pr.modelData.count + " tracks", groups: [
                            { entries: [{ title: "Play", glyph: "play.fill", action: () => { Library.source = "playlist:" + pr.modelData.id; Player.play(Library.visibleTracks(), 0) } }] },
                            { entries: [{ title: "Delete Playlist…", glyph: "trash", destructive: true, enabled: !pr.modelData.builtIn,
                                          action: () => Library.editPlaylist("delete", pr.modelData.id, []) }] }] })
                    }
                }
            }
        }
    }
}
