// The library column (the Mac's LibraryHeaderView + table / empty state):
// eyebrow, title and summary; the filter, group menu, Shuffle and Play
// (one row when it fits, wrapped under the title otherwise, icons only when
// narrowest); then the track table, or the empty state.
import QtQuick
import I2S

Item {
    id: lc
    property alias table: table
    signal addMusic()
    signal removeRequested(var tracks)
    signal newPlaylistRequested(var tracks)

    readonly property bool grid: Library.source === "albums" || Library.source === "artists"
    readonly property var groupLabels: ({ none: "No grouping", album: "Album", albumArtist: "Album Artist", genre: "Genre", year: "Year" })
    readonly property string groupBy: Core.settings.groupBy || "none"

    Item {
        id: header
        width: parent.width
        readonly property real filterWidth: Core.settings.searchFieldWidth || 200
        readonly property real fullControls: filterWidth + 3 * 10 + groupPill.implicitWidth + shufflePill.implicitWidth + playPill.implicitWidth
        readonly property bool oneRow: titleBlock.width + 16 + fullControls <= width - 36
        readonly property bool iconsOnly: !oneRow && fullControls > width - 36
        height: 16 + (oneRow ? Math.max(titleBlock.height, 26) : titleBlock.height + 12 + 26) + 12
        Column {
            id: titleBlock
            x: 18; y: header.oneRow ? 16 + (Math.max(height, 26) - height) / 2 : 16
            spacing: 2
            Label { visible: Library.eyebrow.length > 0; pt: 11; weight: "medium"; text: Library.eyebrow; color: Skin.accent }
            Label { pt: 22; weight: "bold"; role: "libraryTitle"; text: Library.sourceTitle; width: Math.min(implicitWidth, header.width - 36) }
            Label { pt: 11; role: "librarySummary"; text: Library.summary; color: Skin.textTertiary }
        }
        Row {
            id: controls
            x: header.oneRow ? header.width - 18 - width : 18
            y: header.oneRow ? titleBlock.y + (titleBlock.height - 26) / 2 : titleBlock.y + titleBlock.height + 12
            spacing: header.iconsOnly ? 6 : 10
            // The live filter: Ctrl+F focuses it, Escape clears it.
            Item {
                visible: !lc.grid && Core.settings.showSearchField !== false
                width: header.iconsOnly ? Math.max(90, Math.min(header.filterWidth, header.width - 36 - 3 * 6 - 3 * 48)) : header.filterWidth
                height: 26
                Rectangle {
                    anchors.fill: parent
                    color: Skin.withAlpha(Skin.textPrimary, filter.activeFocus ? 0.12 : 0.07)
                    border.width: filter.activeFocus ? 1 : 0.5
                    border.color: filter.activeFocus ? Skin.withAlpha(Skin.accent, 0.6) : Qt.rgba(1, 1, 1, 0.06)
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                Glyph {
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    width: 10.5; height: 10.5; name: "line.3.horizontal.decrease"
                    color: filter.activeFocus || filter.text.length > 0 ? Skin.accent : Skin.textTertiary
                }
                TextInput {
                    id: filter
                    x: 26.5; width: parent.width - 36.5 - (clear.visible ? 17 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    font: Type.font(12, "regular", "")
                    renderType: Text.NativeRendering
                    color: Skin.textPrimary
                    selectionColor: Skin.withAlpha(Skin.accent, 0.4)
                    selectByMouse: true
                    clip: true
                    text: Library.filterText
                    onTextEdited: Library.filterText = text
                    Keys.onEscapePressed: { Library.filterText = ""; text = ""; table.forceActiveFocus() }
                    Label { visible: filter.text.length === 0; pt: 12; text: "Filter"; color: Skin.textTertiary }
                }
                GlyphButton {
                    id: clear
                    visible: filter.text.length > 0
                    anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                    size: 16; iconSize: 11; icon: "xmark.circle.fill"; restColor: Skin.textTertiary
                    onClicked: { Library.filterText = ""; filter.text = "" }
                }
                Shortcut { sequences: [StandardKey.Find]; onActivated: filter.forceActiveFocus() }
            }
            PillButton {
                id: groupPill
                visible: !lc.grid
                text: lc.groupBy === "none" ? "Group" : lc.groupLabels[lc.groupBy]
                icon: "rectangle.3.group"; contentOverride: header.iconsOnly ? "icon" : ""
                active: lc.groupBy !== "none"
                onClicked: AppMenu.openBelow(groupPill, { groups: [{ entries: ["none", "album", "albumArtist", "genre", "year"].map(m => ({
                    title: lc.groupLabels[m], checked: lc.groupBy === m, action: () => Core.setSetting("groupBy", m) })) }] })
            }
            PillButton {
                id: shufflePill
                text: "Shuffle"; icon: "shuffle"; contentOverride: header.iconsOnly ? "icon" : ""
                enabled: Library.visibleCount > 0
                onClicked: Player.shuffleTable()
            }
            PillButton {
                id: playPill
                text: "Play"; icon: "play.fill"; prominent: true; contentOverride: header.iconsOnly ? "icon" : ""
                enabled: Library.visibleCount > 0
                onClicked: Player.play(Library.visibleTracks(), 0)
            }
        }
    }

    TrackTable {
        id: table
        visible: Library.visibleCount > 0
        y: header.height
        width: parent.width; height: parent.height - y
        hideAlbum: false
        onRemoveRequested: (tracks) => lc.removeRequested(tracks)
        onNewPlaylistRequested: (tracks) => lc.newPlaylistRequested(tracks)
    }

    // Shown instead of an empty table.
    Column {
        visible: Library.visibleCount === 0
        y: header.height + (lc.height - header.height - height) / 2
        width: parent.width
        spacing: 12
        Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 30; height: 30
            name: Library.count === 0 ? "music.note.house" : Library.filterText.length > 0 ? "magnifyingglass"
                  : Library.source === "liked" ? "heart" : Library.source.startsWith("playlist:") ? "music.note.list" : "music.note"
            color: Skin.withAlpha(Skin.accent, 0.8)
        }
        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            pt: 13; weight: "semibold"
            text: Library.count === 0 ? "Your library is empty"
                  : Library.filterText.length > 0 ? "No results for “" + Library.filterText + "”"
                  : Library.source === "liked" ? "No liked songs yet"
                  : (Library.source === "recentlyPlayed" || Library.source === "mostPlayed") ? "Nothing played yet"
                  : Library.source.startsWith("playlist:") ? "This playlist is empty" : "Nothing here"
        }
        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(300, parent.width - 40)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideNone
            pt: 11.5; color: Skin.textTertiary
            text: Library.count === 0 ? "Drop folders or audio files anywhere in this window, or choose them with Add Music (Ctrl+O)."
                  : Library.filterText.length > 0 ? "Try fewer words, or clear the filter (Esc)."
                  : Library.source === "liked" ? "Right-click a track and choose Like."
                  : (Library.source === "recentlyPlayed" || Library.source === "mostPlayed") ? "Songs you listen to will collect here."
                  : Library.source.startsWith("playlist:") ? "Drag tracks onto the playlist in the sidebar, or right-click → Add to Playlist." : ""
        }
        PillButton {
            visible: Library.count === 0
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Add Music…"; icon: "plus"; prominent: true
            onClicked: lc.addMusic()
        }
    }
}
