// Every design-system component in its main states, for snapshots and for
// comparing with the Mac (`--open gallery`).
import QtQuick
import I2S

Item {
    id: root
    readonly property var trackMenu: ({
        title: "Pleine lune", subtitle: "Artist · Album",
        groups: [
            { entries: [{ title: "Play", glyph: "play.fill", detail: "↩" }, { title: "Play Next", glyph: "arrow.uturn.forward" }, { title: "Add to Queue", glyph: "list.number" }] },
            { entries: [{ title: "Like", glyph: "heart" }, { title: "Add to Playlist", glyph: "plus.square.on.square", submenu: { groups: [{ entries: [{ title: "New Playlist from Selection…", glyph: "plus" }] }] } },
                        { title: "Show Album", glyph: "opticaldisc" }, { title: "Get Info…", glyph: "info.circle" }] },
            { label: "file", entries: [{ title: "Refresh from File", glyph: "arrow.counterclockwise" }, { title: "Show in Explorer", glyph: "arrow.up.forward" }] },
            { entries: [{ title: "Remove from Library…", glyph: "trash", detail: "Del", destructive: true }] }
        ]
    })

    component Caption: Label { pt: 10.5; weight: "semibold"; color: Skin.textTertiary }

    Row {
        anchors { fill: parent; margins: Skin.gap }
        spacing: Skin.gap

        Item {
            width: (parent.width - parent.spacing) * 0.62; height: parent.height
            GlassSurface { anchors.fill: parent }
            Column {
                x: 18; y: 16; width: parent.width - 36
                spacing: 12

                Caption { text: "Buttons · solid · outline · text" }
                Repeater {
                    model: ["solid", "outline", "text"]
                    Row {
                        required property string modelData
                        spacing: 8
                        PillButton { fill: modelData; text: "Group"; icon: "rectangle.3.group" }
                        PillButton { fill: modelData; text: "Shuffle"; icon: "shuffle"; enabled: false }
                        PillButton { fill: modelData; text: "Play"; icon: "play.fill"; prominent: true }
                        PillButton { fill: modelData; text: "Add Music…"; icon: "plus"; active: true }
                        PillButton { fill: modelData; text: "Compact"; compact: true }
                        IconButton { fill: modelData; icon: "gearshape" }
                        IconButton { fill: modelData; icon: "heart.fill"; active: true }
                    }
                }

                Caption { text: "Glyph buttons" }
                Row {
                    spacing: 14
                    GlyphButton { icon: "shuffle"; anchors.verticalCenter: parent.verticalCenter }
                    GlyphButton { icon: "backward.fill"; iconSize: 14; anchors.verticalCenter: parent.verticalCenter }
                    PlayPauseButton { anchors.verticalCenter: parent.verticalCenter }
                    GlyphButton { icon: "forward.fill"; iconSize: 14; anchors.verticalCenter: parent.verticalCenter }
                    GlyphButton { icon: "repeat"; active: true; anchors.verticalCenter: parent.verticalCenter }
                    GlyphButton { icon: "heart"; enabled: false; anchors.verticalCenter: parent.verticalCenter }
                }

                Caption { text: "Sliders · line · knob · accent" }
                Row {
                    spacing: 24
                    MinimalSlider { width: 140; value: 0.4; style: "line" }
                    MinimalSlider { width: 140; value: 0.65; style: "knob" }
                    MinimalSlider { width: 140; value: 0.25; style: "knob"; accentFill: true }
                }

                Caption { text: "Knobs · unipolar · bipolar · log" }
                Row {
                    spacing: 18
                    Knob { value: 0.3 }
                    Knob { from: -12; to: 12; value: 4.5; bipolar: true }
                    Knob { from: 20; to: 20000; value: 1000; logarithmic: true; tint: Skin.textPrimary }
                    Knob { size: 32; value: 0.8 }
                }

                Caption { text: "Fields · segmented · switch · dropdown" }
                Row {
                    spacing: 12
                    Field { width: 200; placeholder: "Playlist name" }
                    Field { width: 160; text: "Night Session" }
                    Segmented { width: 240; options: [{ value: "compact", label: "Compact" }, { value: "comfortable", label: "Comfortable" }, { value: "spacious", label: "Spacious" }]; selection: "comfortable" }
                }
                Row {
                    spacing: 12
                    Switch { on: true; anchors.verticalCenter: parent.verticalCenter }
                    Switch { on: false; anchors.verticalCenter: parent.verticalCenter }
                    Dropdown { width: 180; options: ["Title", "Artist", "Album"]; selection: "Artist" }
                }

                Caption { text: "Progress · determinate · indeterminate" }
                Column {
                    spacing: 10
                    ProgressLine { width: 300; height: 3; fraction: 0.6 }
                    ProgressLine { width: 300; height: 3; fraction: -1 }
                    ProgressLine { width: 300; height: 2; fraction: 0.2; tint: Skin.accent }
                }

                Caption { text: "Navigation rows" }
                Column {
                    width: 240
                    NavRow { width: parent.width; icon: "paintpalette"; text: "Appearance"; selected: true }
                    NavRow { width: parent.width; icon: "slider.horizontal.3"; text: "Equalizer"; trailingText: "ON"; trailingIsOn: true }
                    NavRow { width: parent.width; icon: "downloads"; text: "Sources"; trailingText: "OFF" }
                }
                Hairline { width: parent.width }
            }
        }

        Item {
            width: (parent.width - parent.spacing) * 0.38; height: parent.height
            GlassSurface { anchors.fill: parent; content: true }
            Caption { x: 18; y: 16; text: "Menu" }
            MenuView {
                x: 18; y: 40
                width: implicitWidth; height: implicitHeight
                content: root.trackMenu
                highlighted: 1
            }
        }
    }
}
