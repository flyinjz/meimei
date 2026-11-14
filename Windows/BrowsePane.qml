// The browse list under the now-playing art (the Mac's SidebarView): the
// library views, collections, then genres.
import QtQuick
import I2S

Flickable {
    id: side
    clip: true
    contentHeight: list.height + 12
    boundsBehavior: Flickable.StopAtBounds
    property bool genresOpen: false
    Glide { line: 27 }

    component SectionLabel: Item {
        id: sl
        property string title
        property bool chevron: false
        property bool open: false
        signal toggled()
        width: parent ? parent.width : 0
        height: visible ? 14 + lab.height + 4 : 0
        Label { id: lab; x: 10; y: 14; pt: 11; weight: "medium"; role: "sectionLabels"; text: sl.title; color: Skin.textTertiary }
        GlyphButton {
            visible: sl.chevron
            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: lab.verticalCenter
            size: 18; iconSize: 9; icon: "chevron.right"; restColor: Skin.textTertiary
            rotation: sl.open ? 90 : 0
            Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
            onClicked: sl.toggled()
        }
    }

    component Row_: Item {
        id: sr
        property string source
        property string title
        property string icon
        property string filled: ""
        property int count: -1
        readonly property bool selected: Library.source === source
        width: parent ? parent.width : 0
        height: 27
        Rectangle {
            anchors.fill: parent
            color: sr.selected ? Skin.withAlpha(Skin.accent, 0.1) : hov.hovered ? Skin.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        Glyph {
            x: 10; anchors.verticalCenter: parent.verticalCenter
            width: 14; height: 10.5
            name: sr.selected && sr.filled.length > 0 ? sr.filled : sr.icon
            color: sr.selected ? Skin.accent : Skin.textTertiary
        }
        Label {
            x: 32; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 32 - 10 - (cnt.visible ? cnt.width + 4 : 0)
            pt: 12; weight: sr.selected ? "semibold" : "regular"; role: "sidebarRows"
            text: sr.title
            color: sr.selected ? Skin.textPrimary : Skin.textSecondary
        }
        Label {
            id: cnt
            visible: sr.count >= 0
            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
            pt: 10.5; text: sr.count; color: Skin.textTertiary
        }
        HoverHandler { id: hov }
        TapHandler { onTapped: Library.source = sr.source }
    }

    Column {
        id: list
        x: 8; width: side.width - 16
        spacing: 1
        SectionLabel { title: "library" }
        Row_ { source: "all"; title: "All Music"; icon: "music.note"; count: Library.count }
        Row_ { source: "albums"; title: "Albums"; icon: "opticaldisc"; count: Library.albumCount }
        Row_ { source: "artists"; title: "Artists"; icon: "music.mic"; count: Library.artistCount }
        Row_ { source: "liked"; title: "Liked Songs"; icon: "heart"; filled: "heart.fill"; count: Library.likedCount }
        SectionLabel { title: "collections" }
        Row_ { source: "recentlyAdded"; title: "Recently Added"; icon: "clock.badge.checkmark" }
        Row_ { source: "recentlyPlayed"; title: "Recently Played"; icon: "clock.arrow.circlepath" }
        Row_ { source: "mostPlayed"; title: "Most Played"; icon: "chart.bar"; filled: "chart.bar.fill" }
        SectionLabel {
            visible: Library.genres.length > 0
            title: "genres"; chevron: true; open: side.genresOpen
            onToggled: side.genresOpen = !side.genresOpen
        }
        Repeater {
            model: Library.genres
            delegate: Row_ {
                required property var modelData
                readonly property bool wanted: side.genresOpen || Library.source === source
                source: "genre:" + modelData.name
                title: modelData.name
                icon: "guitars"; count: modelData.count
                height: wanted ? 27 : 0
                opacity: wanted ? 1 : 0
                clip: true
                Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
            }
        }
    }
}
