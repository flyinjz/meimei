// One level of an app menu as drawn (the Mac's MenuPanelView + MenuRow):
// an optional header naming what it acts on, then groups set apart by space
// and an optional lowercase label, never by a rule. Content:
//   { title, subtitle, groups: [{ label, entries: [{ title, glyph, detail,
//     checked, destructive, enabled, action: function, submenu: content }] }] }
import QtQuick
import I2S

Item {
    id: root
    property var content: ({ groups: [] })
    property real minWidth: 0
    /// Index into `entries` (every row, in order) of the highlighted row; -1 none.
    property int highlighted: -1
    /// Draw the glass look (a live blur sits behind the window) or the solid one.
    property bool glass: Skin.isGlass && !Platform.forceFallback
    signal hovered(int index, Item row)
    signal activated(int index, Item row)

    readonly property var groups: (content && content.groups ? content.groups : []).filter(g => g.entries && g.entries.length)
    readonly property var entries: {
        let out = []
        for (const g of groups) for (const e of g.entries) out.push(e)
        return out
    }
    function enabledOf(e) { return e.enabled === undefined ? true : e.enabled }
    function rowItem(index) { return rows.itemAt(index) }

    readonly property real rowsWidth: { let w = 0; for (let i = 0; i < rows.count; ++i) { const r = rows.itemAt(i); if (r) w = Math.max(w, r.implicitWidth) } return w }
    readonly property real naturalWidth: Math.max(header.implicitWidth, rowsWidth) + 8
    implicitWidth: Math.min(320, Math.max(188, minWidth, naturalWidth))
    implicitHeight: rowY(entries.length) + 4

    // The surface.
    Rectangle {
        anchors.fill: parent
        color: root.glass ? Qt.rgba(0, 0, 0, Math.min(0.85, Skin.panelOpacity + 0.1)) : Skin.withAlpha(Skin.bgVoid, 0.97)
        border.width: 1
        border.color: root.glass ? Qt.rgba(1, 1, 1, 0.16) : Skin.withAlpha(Skin.textPrimary, 0.2)
        Rectangle { visible: !root.glass; z: -1; anchors.fill: parent; color: "black" }
    }
    Rectangle { visible: root.glass; x: 1; width: parent.width - 2; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
    Ticks { anchors.fill: parent; visible: Skin.showTicks }

    Rectangle {
        id: header
        visible: !!(root.content && root.content.title)
        width: parent.width
        height: visible ? headerColumn.implicitHeight + 19 : 0
        implicitWidth: headerColumn.implicitWidth + 28
        color: Skin.withAlpha(Skin.textPrimary, 0.04)
        Column {
            id: headerColumn
            x: 14; y: 10
            width: parent.width - 28
            spacing: 2
            Label { width: parent.width; pt: 11.5; weight: "semibold"; text: root.content.title || ""; color: Skin.textPrimary }
            Label { visible: !!root.content.subtitle; width: parent.width; pt: 10; text: root.content.subtitle || ""; color: Skin.textTertiary }
        }
    }

    // Group labels, each placed just above its group's first row.
    Repeater {
        model: root.groups
        Label {
            required property var modelData
            required property int index
            visible: !!modelData.label
            x: 4 + 10
            y: root.labelY(index)
            pt: 9.5
            text: (modelData.label || "").toLowerCase()
            color: Skin.textTertiary
        }
    }
    // One row per entry, placed by rowY.
    Repeater {
        id: rows
        model: root.entries
        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property bool enabledRow: root.enabledOf(modelData)
            readonly property bool lit: root.highlighted === index
            readonly property bool isSubmenu: !!modelData.submenu
            x: 4; width: root.width - 8; height: 25
            y: root.rowY(index)
            opacity: enabledRow ? 1 : 0.35
            implicitWidth: 8 + 14 + 9 + title.implicitWidth + 18 + (detail.visible ? detail.implicitWidth + 9 : 0) + (chevron.visible ? 8 + 9 : 0) + 8

            Rectangle {
                anchors.fill: parent
                color: row.lit && row.enabledRow ? Skin.withAlpha(Skin.textPrimary, 0.09) : "transparent"
                Behavior on color { ColorAnimation { duration: 80; easing.type: Easing.OutQuad } }
            }
            readonly property color iconColor: modelData.checked ? Skin.accent : modelData.destructive ? Skin.withAlpha(Skin.accent, 0.85) : lit ? Skin.textPrimary : Skin.textTertiary
            Item {
                x: 8; width: 14; height: parent.height
                Rectangle { visible: !!row.modelData.checked; anchors.centerIn: parent; width: 6; height: 6; color: Skin.accent }
                Glyph { visible: !row.modelData.checked && !!row.modelData.glyph; anchors.centerIn: parent; width: 11; height: 11; name: row.modelData.glyph || ""; color: row.iconColor }
            }
            Label {
                id: title
                x: 8 + 14 + 9
                width: Math.min(implicitWidth, row.width - x - 18 - (detail.visible ? detail.implicitWidth + 9 : 0) - (chevron.visible ? 17 : 0) - 8)
                anchors.verticalCenter: parent.verticalCenter
                pt: 11.5
                text: row.modelData.title
                elide: Text.ElideMiddle
                color: row.modelData.destructive ? (row.lit ? Skin.accent : Skin.withAlpha(Skin.accent, 0.85)) : row.lit ? Skin.textPrimary : Skin.textSecondary
            }
            Label {
                id: detail
                visible: !!row.modelData.detail
                anchors { right: chevron.visible ? chevron.left : parent.right; rightMargin: chevron.visible ? 9 : 8; verticalCenter: parent.verticalCenter }
                pt: 10
                text: row.modelData.detail || ""
                color: Skin.textTertiary
            }
            Glyph {
                id: chevron
                visible: row.isSubmenu
                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                width: 8; height: 8
                name: "chevron.right"
                color: row.lit ? Skin.textPrimary : Skin.textTertiary
            }
            HoverHandler { onHoveredChanged: if (hovered) root.hovered(row.index, row) }
            TapHandler { onTapped: root.activated(row.index, row) }
        }
    }

    // Each row's top: header, padding, group spacing and labels before it.
    function rowY(index) {
        let y = (header.visible ? header.height : 0) + 4, n = 0
        for (let gi = 0; gi < groups.length; ++gi) {
            const g = groups[gi]
            if (g.label) y += (gi === 0 ? 4 : 10) + labelHeight + 3
            else if (gi > 0) y += 6
            for (let k = 0; k < g.entries.length; ++k, ++n) {
                if (n === index) return y
                y += 25
            }
        }
        return y
    }
    // A group label's top: its group's first row, less the label and its bottom padding.
    function labelY(gi) {
        let n = 0
        for (let k = 0; k < gi; ++k) n += groups[k].entries.length
        return rowY(n) - 3 - labelHeight
    }
    readonly property real labelHeight: probe.implicitHeight
    Label { id: probe; visible: false; pt: 9.5; text: "x" }

}
