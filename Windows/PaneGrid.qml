// The main window's panes in the user's layout (the Mac's MainWindowView
// panes + WeightedStack + the split handles): columns of stacked panes; the
// column holding the library stretches, the gaps between columns and between
// stacked panes drag to resize, and moved panes fly to their new place.
import QtQuick
import I2S

Item {
    id: grid
    /// Pane id → Component drawn inside the pane's glass (placeholders until the screens land).
    property var contents: ({})

    readonly property var settings: Core.settings
    readonly property var layout: Customize.shownLayout
    readonly property real gap: Skin.gap
    readonly property var geometry: compute(layout, width, height, gap, settings)

    readonly property real libraryMinWidth: 360
    readonly property real maxArtwork: 520

    // Panes move with a spring only when the stored layout changes (a move,
    // undo, a workspace); window resizes and live drags follow at once.
    property bool animate: false
    Connections {
        target: Customize
        function onLayoutChanged() { if (Customize.draftLayout === null && !grid.dragging) { grid.animate = true; settle.restart() } }
    }
    Connections {
        target: Core
        function onSettingsChanged() { grid.animate = true; settle.restart() }
    }
    Timer { id: settle; interval: 900; onTriggered: grid.animate = false }
    property bool dragging: false

    function isVisible(pane, l, s) {
        if ((l.hidden || []).indexOf(pane) >= 0) return false
        switch (pane) {
        case "library": return true
        case "nowPlaying": case "browse": return s.showSidebar !== false
        case "lyrics": return s.showLyrics !== false
        case "playlists": return s.showAlbumGrid !== false
        }
        return true
    }
    function isFlexible(c) { return c.panes.indexOf("library") >= 0 }
    function sidebarWidth(total, s) {
        return s.sidebarWidthMode === "fixed" ? s.sidebarFixedWidth
             : Math.min(420, Math.max(200, total * s.sidebarProportionalPercent))
    }
    function columnWidth(c, total, s) {
        if (c.width !== undefined && c.width !== null) return c.width
        switch (c.panes[0]) {
        case "lyrics": return s.lyricsPanelWidth
        case "playlists": return s.collectionRailWidth
        }
        return sidebarWidth(total, s)
    }
    function weight(c, pane) {
        const w = (c.weights || {})[pane]
        return w !== undefined ? w : (pane === "nowPlaying" ? 0 : 1)
    }
    /// The now-playing panel's natural height: square cover plus details.
    function naturalHeight(pane, width) { return Math.max(48, Math.floor(Math.min(width - 24, maxArtwork))) + 12 + nowPlayingInfo }
    /// The now-playing panel's details height (title, artist, format strip), from its content.
    property real nowPlayingInfo: 78

    /// Heights of a column's visible panes, as the Mac's WeightedStack places them.
    function stackHeights(c, visible, width, height, gap) {
        const heights = {}
        const handles = (visible.length - 1) * gap
        let total = 0
        for (const p of visible) total += weight(c, p)
        const cap = total > 0 ? height * 0.6 : height
        let fixed = handles
        for (const p of visible) if (weight(c, p) === 0) {
            const natural = naturalHeight(p, width)
            heights[p] = natural > 40 ? Math.min(natural, cap) : natural
            fixed += heights[p]
        }
        const flexible = Math.max(0, height - fixed)
        for (const p of visible) if (weight(c, p) !== 0) heights[p] = total > 0 ? flexible * weight(c, p) / total : 0
        return heights
    }

    function compute(l, W, H, gap, s) {
        const out = { panes: {}, columns: [], columnHandles: [], stackHandles: [] }
        if (!l || !l.columns || W <= 0 || H <= 0) return out
        const columns = []
        l.columns.forEach((c, i) => {
            const visible = c.panes.filter(p => isVisible(p, l, s))
            if (visible.length) columns.push({ index: i, column: c, panes: visible })
        })
        // Fixed columns shrink together when they'd crowd the library below
        // its minimum, so the layout always fits the window.
        const gaps = Math.max(0, columns.length - 1) * gap
        let fixed = 0
        for (const e of columns) if (!isFlexible(e.column)) fixed += columnWidth(e.column, W, s)
        const room = W - libraryMinWidth - gaps
        const fit = fixed > room && fixed > 0 ? Math.max(0.4, room / fixed) : 1
        let fixedRounded = 0
        for (const e of columns) if (!isFlexible(e.column)) fixedRounded += Math.round(columnWidth(e.column, W, s) * fit)
        const libraryWidth = Math.max(libraryMinWidth, W - gaps - fixedRounded)

        let x = 0
        columns.forEach((e, position) => {
            if (position > 0) {
                out.columnHandles.push({ left: columns[position - 1], right: e, x: x })
                x += gap
            }
            const w = isFlexible(e.column) ? libraryWidth : Math.round(columnWidth(e.column, W, s) * fit)
            const heights = stackHeights(e.column, e.panes, w, H, gap)
            let y = 0
            e.panes.forEach((p, i) => {
                if (i > 0) {
                    out.stackHandles.push({ column: e.index, above: e.panes[i - 1], below: p, visible: e.panes,
                                            col: e.column, x: x, y: y, width: w, height: H })
                    y += gap
                }
                out.panes[p] = { x: x, y: y, width: w, height: heights[p] }
                y += heights[p]
            })
            out.columns.push({ index: e.index, x: x, width: w, flexible: isFlexible(e.column), panes: e.panes })
            x += w
        })
        return out
    }

    // MARK: Panes

    Repeater {
        model: Customize.paneIDs
        Item {
            id: pane
            required property string modelData
            readonly property var frame: grid.geometry.panes[modelData]
            readonly property bool shownHere: frame !== undefined
            readonly property string element: Customize.elementOfPane[modelData]

            Spring { id: sx; target: pane.frame ? pane.frame.x : sx.value; response: 0.45; dampingFraction: 0.82; instant: !grid.animate }
            Spring { id: sy; target: pane.frame ? pane.frame.y : sy.value; response: 0.45; dampingFraction: 0.82; instant: !grid.animate }
            Spring { id: sw; target: pane.frame ? pane.frame.width : sw.value; response: 0.45; dampingFraction: 0.82; instant: !grid.animate }
            Spring { id: sh; target: pane.frame ? pane.frame.height : sh.value; response: 0.45; dampingFraction: 0.82; instant: !grid.animate }
            x: Math.round(sx.value); y: Math.round(sy.value)
            width: Math.round(sw.value); height: Math.round(sh.value)

            // Shown and hidden panes fade and scale (the Mac's opacity + 0.97 scale transition).
            opacity: shownHere ? 1 : 0
            scale: shownHere ? 1 : 0.97
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }

            GlassSurface {
                id: surface
                anchors.fill: parent
                element: pane.element
                content: pane.modelData === "library"
                fallback: pane.modelData === "library" ? Skin.bgRow : Skin.bgPanel
            }
            Loader {
                anchors.fill: parent
                anchors.margins: surface.padding
                clip: true
                sourceComponent: grid.contents[pane.modelData] || placeholder
                property string paneID: pane.modelData
                onLoaded: if (pane.modelData === "nowPlaying" && item.infoHeight !== undefined) grid.nowPlayingInfo = Qt.binding(() => item.infoHeight)
            }
        }
    }

    Component {
        id: placeholder
        Item {
            Label {
                x: 14; y: 12
                pt: 10.5; weight: "semibold"
                role: "sectionLabels"
                color: Skin.textTertiary
                text: Customize.label(Customize.elementOfPane[parent.parent.paneID])
            }
        }
    }

    // MARK: Handles

    property var dragOrigin: null
    property var stackOrigin: null

    /// The gap between two columns. Drags resize the fixed column beside it;
    /// the library's column takes up the difference.
    Repeater {
        // Counted, so a live drag doesn't rebuild the handle it is dragging.
        model: grid.geometry.columnHandles.length
        Item {
            required property int index
            readonly property var modelData: grid.geometry.columnHandles[index] || grid.geometry.columnHandles[0]
            x: modelData.x + grid.gap / 2 - 4; width: 8
            height: grid.height
            enabled: !Customize.active
            readonly property bool resizeLeft: !grid.isFlexible(modelData.left.column)
            readonly property var target: resizeLeft ? modelData.left : modelData.right
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeHorCursor
                property real pressX
                onPressed: (m) => { pressX = mapToItem(grid, m.x, 0).x; grid.dragOrigin = grid.columnWidth(parent.target.column, grid.width, grid.settings); grid.dragging = true }
                onPositionChanged: (m) => {
                    if (!pressed) return
                    const dx = mapToItem(grid, m.x, 0).x - pressX
                    const w = parent.resizeLeft ? grid.dragOrigin + dx : grid.dragOrigin - dx
                    const l = Customize.copyLayout(Customize.layout)
                    l.columns[parent.target.index].width = Math.min(560, Math.max(160, w))
                    Customize.draftLayout = l
                }
                onReleased: {
                    const d = Customize.draftLayout
                    Customize.draftLayout = null
                    if (d) Customize.setColumnWidth(parent.target.index, d.columns[parent.target.index].width)
                    grid.dragOrigin = null
                    grid.dragging = false
                }
            }
        }
    }

    /// The gap between two stacked panes; drags trade height between them.
    /// The first drag pins every pane in the column to its current height
    /// (as weights in points), so a natural-height pane resizes too.
    Repeater {
        model: grid.geometry.stackHandles.length
        Item {
            required property int index
            readonly property var modelData: grid.geometry.stackHandles[index] || grid.geometry.stackHandles[0]
            readonly property var paneFrame: grid.geometry.panes[modelData.below]
            x: modelData.x; width: modelData.width
            y: paneFrame ? paneFrame.y - grid.gap - 3 : 0
            height: grid.gap + 6
            enabled: !Customize.active
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeVerCursor
                property real pressY
                onPressed: (m) => {
                    pressY = mapToItem(grid, 0, m.y).y
                    const h = grid.stackHeights(parent.modelData.col, parent.modelData.visible, parent.modelData.width, parent.modelData.height, grid.gap)
                    grid.stackOrigin = h
                    grid.dragging = true
                }
                onPositionChanged: (m) => {
                    if (!pressed || !grid.stackOrigin) return
                    const dy = mapToItem(grid, 0, m.y).y - pressY
                    const d = parent.modelData, start = grid.stackOrigin
                    const a0 = start[d.above], b0 = start[d.below], minHeight = 80
                    const a = Math.min(a0 + b0 - minHeight, Math.max(minHeight, a0 + dy))
                    const next = Object.assign({}, start)
                    next[d.above] = a
                    next[d.below] = a0 + b0 - a
                    const l = Customize.copyLayout(Customize.layout)
                    l.columns[d.column].weights = Object.assign({}, l.columns[d.column].weights || {}, next)
                    Customize.draftLayout = l
                }
                onReleased: {
                    const dl = Customize.draftLayout, d = parent.modelData
                    Customize.draftLayout = null
                    if (dl) Customize.setWeights(d.column, dl.columns[d.column].weights)
                    grid.stackOrigin = null
                    grid.dragging = false
                }
            }
        }
    }
}
