// A pane's glass (the Mac's glassSurface / contentSurface + panelSurface):
// a translucent fill over the backdrop, a 1px border, a faint top highlight
// on control panes, the corner ticks; solid skins get `fallback`. With an
// `element`, the user's customize style applies on top: fill, border on
// chosen sides, ticks on/off, depth. (Padding is the pane's content's job:
// read `padding`.)
import QtQuick
import I2S

Item {
    id: root
    /// The content layer (library, EQ graph): denser and darker, no highlight.
    property bool content: false
    /// Fill for solid (non-glass) skins; transparent draws nothing.
    property color fallback: "transparent"
    /// The customizable element this pane is (e.g. "libraryPanel"), if any.
    property string element: ""

    readonly property var style: element !== "" ? Customize.style(element) : ({})
    readonly property bool shown: visible && element !== ""
    Component.onCompleted: if (element !== "") Customize.register(root)
    Component.onDestruction: Customize.unregister(root)
    readonly property real padding: style.padding || 0
    readonly property bool glass: Skin.isGlass
    readonly property bool drawn: glass || content || fallback.a > 0
    readonly property bool ticks: style.ticks === undefined ? Skin.showTicks : style.ticks
    readonly property int depth: style.depth || 0

    // Depth: a dark slab with a soft shadow under the pane.
    Rectangle {
        visible: root.depth > 0
        anchors.fill: parent
        anchors.topMargin: root.depth * 3; anchors.bottomMargin: -root.depth * 3
        color: Qt.rgba(0, 0, 0, Math.min(0.9, 0.35 + root.depth * 0.1))
        opacity: 0.6
    }
    Rectangle {
        anchors.fill: parent
        visible: root.drawn
        color: root.glass ? Qt.rgba(0, 0, 0, root.content ? Skin.contentOpacity : Skin.panelOpacity) : root.fallback
        border.width: Skin.borderWidth
        border.color: root.glass ? Qt.rgba(1, 1, 1, 0.14) : Skin.hairline
    }
    Rectangle {
        // The user's fill, over the design's.
        visible: root.style.fill !== undefined
        anchors.fill: parent
        color: root.style.fill !== undefined ? Skin.rgb(root.style.fill, root.style.fillOpacity === undefined ? 0.5 : root.style.fillOpacity) : "transparent"
    }
    Rectangle {
        // The top highlight, inside the border.
        visible: root.glass && !root.content
        x: 1; y: 0; width: parent.width - 2; height: 1
        color: Qt.rgba(1, 1, 1, 0.07)
    }
    // The user's border, on the chosen sides (1 top, 2 bottom, 4 leading, 8 trailing).
    Item {
        anchors.fill: parent
        visible: root.style.border !== undefined
        readonly property int sides: root.style.borderSides === undefined ? 15 : root.style.borderSides
        readonly property real w: root.style.borderWidth === undefined ? 1 : root.style.borderWidth
        readonly property color c: root.style.border !== undefined ? Skin.rgb(root.style.border) : "transparent"
        Rectangle { visible: parent.sides & 1; width: parent.width; height: parent.w; color: parent.c }
        Rectangle { visible: parent.sides & 2; y: parent.height - parent.w; width: parent.width; height: parent.w; color: parent.c }
        Rectangle { visible: parent.sides & 4; width: parent.w; height: parent.height; color: parent.c }
        Rectangle { visible: parent.sides & 8; x: parent.width - parent.w; width: parent.w; height: parent.height; color: parent.c }
    }
    Ticks { anchors.fill: parent; visible: root.drawn && root.ticks }
}
