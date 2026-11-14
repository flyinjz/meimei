// A flat segmented picker (the Mac's SettingsSegmented): the selected
// segment slides between options with the Mac's spring.
import QtQuick
import I2S

Item {
    id: root
    /// [{value, label}] or plain strings.
    property var options: []
    property var selection
    signal picked(var value)

    implicitHeight: 28
    implicitWidth: 240

    function valueOf(o) { return typeof o === "object" ? o.value : o }
    function labelOf(o) { return typeof o === "object" ? o.label : String(o) }
    readonly property int selectedIndex: {
        for (let i = 0; i < options.length; ++i) if (valueOf(options[i]) === selection) return i
        return -1
    }

    Rectangle { anchors.fill: parent; color: Skin.withAlpha(Skin.textPrimary, 0.06) }
    Item {
        id: lane
        anchors { fill: parent; margins: 2 }
        readonly property real segment: root.options.length ? (width - 2 * (root.options.length - 1)) / root.options.length : 0
        // The Mac's .spring(response: 0.28, dampingFraction: 0.85).
        Spring { id: slide; target: Math.max(0, root.selectedIndex) * (lane.segment + 2); response: 0.28; dampingFraction: 0.85 }
        Rectangle {
            visible: root.selectedIndex >= 0
            width: lane.segment; height: lane.height
            x: slide.value
            color: Skin.withAlpha(Skin.textPrimary, 0.16)
            border.width: 0.5; border.color: Qt.rgba(1, 1, 1, 0.1)
        }
        Row {
            spacing: 2
            Repeater {
                model: root.options
                Item {
                    required property var modelData
                    required property int index
                    width: lane.segment; height: lane.height
                    readonly property bool selected: index === root.selectedIndex
                    Label {
                        anchors.centerIn: parent
                        pt: 11; weight: parent.selected ? "semibold" : "regular"
                        text: root.labelOf(parent.modelData)
                        color: parent.selected ? Skin.textPrimary : Skin.textSecondary
                    }
                    TapHandler { onTapped: root.picked(root.valueOf(parent.modelData)) }
                }
            }
        }
    }
}
