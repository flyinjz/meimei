// A choice that opens an app menu below itself (the Mac's DialogMenu): the
// current option, a small up/down chevron, a faint fill.
import QtQuick
import I2S

Item {
    id: root
    /// [{value, label}] or plain strings.
    property var options: []
    property var selection
    signal picked(var value)

    implicitHeight: 26
    implicitWidth: 180

    function valueOf(o) { return typeof o === "object" ? o.value : o }
    function labelOf(o) { return typeof o === "object" ? o.label : String(o) }
    readonly property string current: {
        for (const o of options) if (valueOf(o) === selection) return labelOf(o)
        return ""
    }

    Rectangle { anchors.fill: parent; color: Skin.withAlpha(Skin.textPrimary, 0.07) }
    Label {
        anchors { left: parent.left; leftMargin: 11; right: chevron.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
        pt: 11
        text: root.current
    }
    Glyph {
        id: chevron
        anchors { right: parent.right; rightMargin: 11; verticalCenter: parent.verticalCenter }
        width: 8; height: 8
        name: "chevron.up.chevron.down"
        color: Skin.textTertiary
    }
    TapHandler {
        onTapped: AppMenu.openBelow(root, { groups: [{ entries: root.options.map(o => ({
            title: root.labelOf(o), checked: root.valueOf(o) === root.selection,
            action: () => root.picked(root.valueOf(o)) })) }] })
    }
}
