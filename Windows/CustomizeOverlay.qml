// The customize mode's overlay over the main window (the Mac's
// CustomizeOverlay): it takes every hover, click and drag while active (the
// app underneath is frozen), picks the smallest element under the pointer,
// moves panes and the player bar, resizes panes from their shared edges with
// snapping, and handles the keys. Fill the window's content with it.
import QtQuick
import I2S

Item {
    id: overlay
    visible: opacity > 0
    opacity: Customize.active ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }

    /// The pane resize rules, for the self-test.
    readonly property alias resizeRules: rules
    /// The inspector's frame in this overlay, so drags near it fade it.
    property rect inspectorRect: Qt.rect(0, 0, 0, 0)
    property bool inspectorFaded: false

    // MARK: Frames

    property var frames: ({})
    property string framesKey: ""
    function refreshFrames() {
        const f = Customize.frames(overlay)
        const key = JSON.stringify(f)
        if (key !== framesKey) { framesKey = key; frames = f }
    }
    // Panes glide (springs); outlines follow them every frame while customizing.
    FrameAnimation { running: Customize.active; onTriggered: overlay.refreshFrames() }
    Component.onCompleted: refreshFrames()

    function rects(e) { return e ? (frames[e] || []) : [] }
    function firstRect(e) { const r = rects(e); return r.length ? r[0] : null }
    function contains(r, x, y) { return x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height }

    /// The smallest element whose frame contains the point: text inside a
    /// panel wins over the panel.
    function elementAt(x, y, kind) {
        let best = "", area = Infinity
        for (const e in frames) {
            if (kind && Customize.kind(e) !== kind) continue
            for (const r of frames[e]) if (contains(r, x, y) && r.width * r.height < area) { best = e; area = r.width * r.height }
        }
        return best
    }

    property real snapScale: 1
    function select(e, extending) {
        Customize.select(e, extending)
        if (e) {
            snapSpring.response = 0.22; snapSpring.dampingFraction = 0.6
            snapSpring.target = 1.025
            unsnap.restart()
        }
    }
    Spring { id: snapSpring; target: 1; response: 0.22; dampingFraction: 0.6 }
    Timer { id: unsnap; interval: 120; onTriggered: { snapSpring.response = 0.3; snapSpring.dampingFraction = 0.65; snapSpring.target = 1 } }

    // MARK: Veil

    /// Dims everything but the selection, so it reads as lifted.
    Canvas {
        id: veil
        anchors.fill: parent
        property real dim: Customize.selection.length ? 0.3 : 0.08
        Behavior on dim { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
        onDimChanged: requestPaint()
        Connections { target: overlay; function onFramesChanged() { veil.requestPaint() } }
        Connections { target: Customize; function onSelectionChanged() { veil.requestPaint() } }
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.fillRule = Qt.OddEvenFill
            ctx.beginPath()
            ctx.rect(0, 0, width, height)
            for (const e of Customize.selection) for (const r of overlay.rects(e)) ctx.rect(r.x, r.y, r.width, r.height)
            ctx.fillStyle = Qt.rgba(0, 0, 0, dim)
            ctx.fill()
        }
    }

    // MARK: Hit overlay

    property point pointer: Qt.point(-1, -1)
    property var move: null          // { element, origin, x, y, target }
    property var paneResize: null    // { session, result }
    property var barResize: null     // { element, edge, start, pressY }

    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        property point pressAt
        property bool moved: false
        onPositionChanged: (m) => {
            overlay.pointer = Qt.point(m.x, m.y)
            if (!pressed) {
                const e = overlay.elementAt(m.x, m.y)
                if (e !== Customize.hovered) Customize.hovered = e
                return
            }
            if (!moved && Math.abs(m.x - pressAt.x) + Math.abs(m.y - pressAt.y) < 5) return
            moved = true
            overlay.dragChanged(m.x, m.y, pressAt)
        }
        onExited: { Customize.hovered = ""; overlay.pointer = Qt.point(-1, -1) }
        onPressed: (m) => { pressAt = Qt.point(m.x, m.y); moved = false; overlay.forceActiveFocus() }
        onReleased: (m) => {
            if (moved) overlay.dragEnded()
            else overlay.select(overlay.elementAt(m.x, m.y), (m.modifiers & Qt.ShiftModifier) !== 0)
            moved = false
        }
        // Scrolling over selected text resizes it; anywhere else it passes through.
        onWheel: (w) => {
            const p = overlay.pointer
            const over = Customize.primary && Customize.kind(Customize.primary) === "text"
                && Customize.targets.some(e => overlay.rects(e).some(r => overlay.contains(Qt.rect(r.x - 10, r.y - 10, r.width + 20, r.height + 20), p.x, p.y)))
            if (!over) { w.accepted = false; return }
            // A wheel notch is 10 points of scroll on the Mac's line scale.
            const delta = w.pixelDelta.y !== 0 ? w.pixelDelta.y : w.angleDelta.y / 120 * 10
            Customize.edit(Customize.targets, "size", s => { s.sizeScale = Math.min(2.5, Math.max(0.6, (s.sizeScale || 1) * Math.pow(1.003, delta))) })
        }
    }

    // MARK: Hover and selection

    /// Dashed outlines whose dashes crawl, on every instance of the hovered
    /// element. Animates only while something is hovered.
    Canvas {
        id: ants
        anchors.fill: parent
        readonly property string element: overlay.move === null && Customize.hovered !== "" && Customize.selection.indexOf(Customize.hovered) < 0 ? Customize.hovered : ""
        property real phase: 0
        visible: element !== ""
        FrameAnimation { running: ants.visible && overlay.visible; onTriggered: { ants.phase = (ants.phase + frameTime * 24) % 8; ants.requestPaint() } }
        onElementChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            if (!element) return
            ctx.strokeStyle = Skin.withAlpha(Skin.textPrimary, 0.85)
            ctx.lineWidth = 1
            ctx.setLineDash([4, 4])
            ctx.lineDashOffset = -phase
            for (const r of overlay.rects(element)) ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1)
        }
    }
    Tag { element: ants.element; dim: true; visible: ants.element !== "" }

    Repeater {
        model: Customize.selection
        Item {
            id: sel
            required property string modelData
            readonly property bool primary: modelData === Customize.primary
            Repeater {
                model: overlay.rects(sel.modelData).length
                Item {
                    required property int index
                    readonly property var r: overlay.rects(sel.modelData)[index] || Qt.rect(0, 0, 0, 0)
                    x: r.x; y: r.y; width: r.width; height: r.height
                    scale: sel.primary ? snapSpring.value : 1
                    // An accent outline with square corner marks; thinner and unmarked for secondary selections.
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: sel.primary ? 1.5 : 1
                        border.color: Skin.withAlpha(Skin.accent, sel.primary ? 1 : 0.7)
                    }
                    Repeater {
                        model: sel.primary ? 4 : 0
                        Rectangle {
                            required property int index
                            width: 5; height: 5; color: Skin.accent
                            x: (index % 2 ? parent.width : 0) - 2.5
                            y: (index > 1 ? parent.height : 0) - 2.5
                        }
                    }
                }
            }
            Tag { element: sel.modelData; dim: !sel.primary }
        }
    }

    /// "label ×count  W×H" above an element's first frame.
    component Tag: Rectangle {
        id: tag
        property string element: ""
        property bool dim: false
        readonly property var r: overlay.firstRect(element)
        readonly property int count: overlay.rects(element).length
        visible: r !== null
        x: r ? r.x : 0
        y: r ? Math.max(0, r.y - 17) : 0
        width: tagText.implicitWidth + 12; height: 16
        color: dim ? Skin.withAlpha(Skin.textPrimary, 0.85) : Skin.accent
        Label {
            id: tagText
            anchors.centerIn: parent
            pt: 10; weight: "medium"
            color: tag.dim ? Skin.bgVoid : Skin.textOnAccent
            text: tag.r ? Customize.label(tag.element) + (tag.count > 1 ? " ×" + tag.count : "") + "  " + Math.floor(tag.r.width) + "×" + Math.floor(tag.r.height) : ""
        }
    }

    // MARK: Moving panes

    function dragChanged(x, y, start) {
        if (move === null) {
            if (paneResize !== null || barResize !== null) return
            const panel = elementAt(start.x, start.y, "panel")
            if (!panel || !(Customize.pane(panel) || panel === "playerBar")) return
            const origin = firstRect(panel)
            if (!origin) return
            Customize.select(panel, false)
            move = { element: panel, origin: origin, x: x, y: y, target: null }
        }
        const m = Object.assign({}, move)
        m.x = x; m.y = y
        m.target = targetFor(m, x, y)
        move = m
        updateFade(x, y, ghostRect(m))
    }

    function dragEnded() {
        const finished = move
        move = null
        updateFade(-1, -1, null)
        if (!finished || !finished.target) return
        if (finished.target.bar) Core.setSetting("playerBarPosition", finished.target.position)
        else Customize.move(Customize.pane(finished.element), finished.target.drop)
    }

    /// Where a drop lands: a pane's outer quarter makes a new column beside
    /// it; its top or bottom half stacks above or below it.
    function targetFor(m, x, y) {
        if (m.element === "playerBar") {
            let win = null
            for (const e in frames) for (const r of frames[e])
                win = win ? Qt.rect(Math.min(win.x, r.x), Math.min(win.y, r.y),
                                    Math.max(win.x + win.width, r.x + r.width) - Math.min(win.x, r.x),
                                    Math.max(win.y + win.height, r.y + r.height) - Math.min(win.y, r.y)) : r
            if (!win) return null
            const top = y < win.y + win.height / 2
            const position = top ? "top" : "bottom"
            if (position === Core.settings.playerBarPosition) return null
            return { bar: true, position: position, indicator: Qt.rect(win.x, top ? win.y : win.y + win.height - 4, win.width, 4) }
        }
        const dragged = Customize.pane(m.element)
        if (!dragged) return null
        const l = Customize.layout, gap = Skin.gap, bar = 4
        for (const p of Customize.paneIDs) {
            if (p === dragged) continue
            const r = firstRect(Customize.elementOfPane[p])
            if (!r || !contains(r, x, y)) continue
            const c = Customize.columnIndex(l, p)
            if (c < 0) continue
            const i = l.columns[c].panes.indexOf(p)
            const rx = (x - r.x) / r.width, ry = (y - r.y) / r.height
            let drop, indicator, text
            if (rx < 0.22) {
                drop = { stack: false, index: c }
                indicator = Qt.rect(r.x - gap / 2 - bar / 2, r.y, bar, r.height); text = "new column"
            } else if (rx > 0.78) {
                drop = { stack: false, index: c + 1 }
                indicator = Qt.rect(r.x + r.width + gap / 2 - bar / 2, r.y, bar, r.height); text = "new column"
            } else if (ry < 0.5) {
                drop = { stack: true, column: c, index: i }
                indicator = Qt.rect(r.x, r.y, r.width, r.height / 2); text = "above " + Customize.label(Customize.elementOfPane[p])
            } else {
                drop = { stack: true, column: c, index: i + 1 }
                indicator = Qt.rect(r.x, r.y + r.height / 2, r.width, r.height / 2); text = "below " + Customize.label(Customize.elementOfPane[p])
            }
            const trial = Customize.movedLayout(l, dragged, drop)
            if (JSON.stringify(trial.columns.map(c => c.panes)) === JSON.stringify(l.columns.map(c => c.panes))) return null
            return { bar: false, drop: drop, indicator: indicator, label: text }
        }
        return null
    }

    function ghostRect(m) {
        const scale = Math.min(1, 220 / Math.max(1, m.origin.width), 140 / Math.max(1, m.origin.height))
        const w = m.origin.width * scale, h = m.origin.height * scale
        return Qt.rect(m.x - w / 2, m.y - h / 2, w, h)
    }

    // Where the pane comes from, hatched.
    Canvas {
        id: hatch
        readonly property var o: overlay.move ? overlay.move.origin : null
        visible: o !== null
        x: o ? o.x : 0; y: o ? o.y : 0
        width: o ? o.width : 0; height: o ? o.height : 0
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = Skin.withAlpha(Skin.accent, 0.35)
            ctx.lineWidth = 1
            ctx.beginPath()
            for (let x = -height; x < width; x += 8) { ctx.moveTo(x, height); ctx.lineTo(x + height, 0) }
            ctx.stroke()
            ctx.strokeStyle = Skin.withAlpha(Skin.accent, 0.6)
            ctx.setLineDash([3, 3])
            ctx.strokeRect(0.5, 0.5, width - 1, height - 1)
        }
    }

    // The drop indicator: a bar for a new column, a tinted half for a stack.
    Rectangle {
        id: indicator
        readonly property var t: overlay.move ? overlay.move.target : null
        readonly property bool isBar: t !== null && (t.bar || t.indicator.width <= 8)
        visible: t !== null
        x: t ? t.indicator.x : 0; y: t ? t.indicator.y : 0
        width: t ? t.indicator.width : 0; height: t ? t.indicator.height : 0
        Behavior on x { enabled: indicator.visible; SpringAnimation { spring: 6; damping: 0.5 } }
        Behavior on y { enabled: indicator.visible; SpringAnimation { spring: 6; damping: 0.5 } }
        color: Skin.withAlpha(Skin.accent, isBar ? 1 : 0.16)
        border.width: isBar ? 0 : 1
        border.color: Skin.accent
        Rectangle {
            visible: indicator.t !== null && !indicator.t.bar
            x: indicator.isBar ? 8 : 6; y: 6
            width: dropLabel.implicitWidth + 10; height: 15
            color: Skin.accent
            Label { id: dropLabel; anchors.centerIn: parent; pt: 10; weight: "medium"; color: Skin.textOnAccent; text: indicator.t && !indicator.t.bar ? indicator.t.label : "" }
        }
    }

    // A ghost of the pane following the pointer.
    Rectangle {
        id: ghost
        readonly property var g: overlay.move ? overlay.ghostRect(overlay.move) : null
        visible: g !== null
        x: g ? g.x : 0; y: g ? g.y : 0
        width: g ? g.width : 0; height: g ? g.height : 0
        color: Qt.rgba(0, 0, 0, 0.75)
        border.width: 1; border.color: Skin.accent
        Ticks { anchors.fill: parent }
        Column {
            x: 8; y: 8; spacing: 4
            Label { pt: 11; weight: "medium"; text: overlay.move ? Customize.label(overlay.move.element) : "" }
            Label { pt: 9.5; color: Skin.textTertiary; text: overlay.move ? Math.floor(overlay.move.origin.width) + "×" + Math.floor(overlay.move.origin.height) : "" }
        }
    }

    // MARK: Resizing

    /// The pane frames on screen, by pane id.
    function paneFrames() {
        const out = {}
        for (const p of Customize.paneIDs) { const r = firstRect(Customize.elementOfPane[p]); if (r) out[p] = r }
        return out
    }

    /// Bars resize from their inner edge; panes from any corner or edge they share with a neighbour.
    function handleKinds(e) {
        if (e === "playerBar") return [{ bar: true, element: e, edge: Core.settings.playerBarPosition === "top" ? "bottom" : "top" }]
        if (e === "statusBar") return [{ bar: true, element: e, edge: "top" }]
        const pane = Customize.pane(e)
        if (!pane) return []
        const edges = rules.movableEdges(pane, Customize.draftLayout || Customize.layout, paneFrames())
        const out = []
        for (const h of [null].concat(edges.horizontal))
            for (const v of [null].concat(edges.vertical))
                if (h !== null || v !== null) out.push({ bar: false, pane: pane, horizontal: h, vertical: v })
        return out
    }

    readonly property string handleElement: move === null && Customize.selection.length === 1 ? Customize.primary : ""
    readonly property var handleRect: handleElement ? firstRect(handleElement) : null

    // The handle list changes only when its contents do, so a live resize
    // (which moves every frame) never rebuilds the handle being dragged.
    property var handleList: []
    property string handleListKey: "[]"
    function updateHandles() {
        if (paneResize !== null || barResize !== null) return
        const key = handleRect ? JSON.stringify(handleKinds(handleElement)) : "[]"
        if (key !== handleListKey) { handleListKey = key; handleList = JSON.parse(key) }
    }
    onHandleElementChanged: updateHandles()
    onFramesChanged: updateHandles()

    Repeater {
        model: overlay.handleList
        Rectangle {
            id: handle
            required property var modelData
            readonly property var r: overlay.handleRect || Qt.rect(0, 0, 0, 0)
            readonly property var k: modelData
            readonly property real cx: k.bar ? r.x + r.width / 2 : k.horizontal === "leading" ? r.x : k.horizontal === "trailing" ? r.x + r.width : r.x + r.width / 2
            readonly property real cy: k.bar ? (k.edge === "bottom" ? r.y + r.height : r.y)
                                     : k.vertical === "top" ? r.y : k.vertical === "bottom" ? r.y + r.height : r.y + r.height / 2
            width: k.bar ? Math.min(56, r.width - 8) : (k.horizontal && k.vertical) ? 9 : k.horizontal ? 6 : Math.min(40, r.width - 24)
            height: k.bar ? 6 : (k.horizontal && k.vertical) ? 9 : k.horizontal ? Math.min(40, r.height - 24) : 6
            x: cx - width / 2; y: cy - height / 2
            color: Skin.accent
            border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.6)
            MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: handle.k.bar ? Qt.SizeVerCursor
                    : handle.k.horizontal && handle.k.vertical
                      ? ((handle.k.horizontal === "leading") === (handle.k.vertical === "top") ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                    : handle.k.horizontal ? Qt.SizeHorCursor : Qt.SizeVerCursor
                property point start
                onPressed: (m) => { start = mapToItem(overlay, m.x, m.y); overlay.forceActiveFocus() }
                onPositionChanged: (m) => {
                    if (!pressed) return
                    const p = mapToItem(overlay, m.x, m.y)
                    overlay.resize(handle.k, overlay.handleRect, p.x - start.x, p.y - start.y, (m.modifiers & Qt.ControlModifier) !== 0)
                    overlay.updateFade(p.x, p.y, null)
                }
                onReleased: { overlay.endResize(); overlay.updateHandles() }
                Tip { text: handle.k.bar ? "Drag to resize" : "Drag to resize · hold Ctrl to turn off snapping"; shown: parent.containsMouse && !parent.pressed }
            }
        }
    }

    function resize(k, r, dx, dy, free) {
        if (k.bar) {
            if (barResize === null) barResize = { start: r.height }
            const h = k.edge === "bottom" ? barResize.start + dy : barResize.start - dy
            const lo = k.element === "statusBar" ? 20 : 40, hi = k.element === "statusBar" ? 48 : 140
            Customize.edit([k.element], "height", s => { s.height = Math.min(hi, Math.max(lo, h)) })
            return
        }
        if (paneResize === null) {
            const session = { pane: k.pane, horizontal: k.horizontal, vertical: k.vertical, frames: paneFrames(),
                              layout: Customize.layout, gap: Skin.gap }
            paneResize = { session: session, result: rules.apply(session, 0, 0, true) }
        }
        const result = rules.apply(paneResize.session, dx, dy, !free)
        paneResize = { session: paneResize.session, result: result }
        Customize.draftLayout = result.layout
    }

    function endResize() {
        barResize = null
        if (paneResize !== null) {
            const l = paneResize.result.layout
            Customize.draftLayout = null
            Customize.commitLayout(l)
        }
        paneResize = null
        updateFade(-1, -1, null)
    }

    /// Magnetic guides: thin dashed accent lines where the dragged edge snapped.
    Canvas {
        id: guides
        anchors.fill: parent
        readonly property var list: overlay.paneResize ? overlay.paneResize.result.guides : []
        onListChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.strokeStyle = Skin.accent
            ctx.lineWidth = 1
            ctx.setLineDash([6, 3])
            for (const g of list) {
                ctx.beginPath()
                if (g.axis === "y") { ctx.moveTo(0, g.position); ctx.lineTo(width, g.position) }
                else { ctx.moveTo(g.position, 0); ctx.lineTo(g.position, height) }
                ctx.stroke()
            }
        }
    }

    /// Fades the inspector while a drag passes over or near it.
    function updateFade(x, y, ghost) {
        const f = inspectorRect
        if (f.width <= 0) { inspectorFaded = false; return }
        const z = Qt.rect(f.x - 40, f.y - 40, f.width + 80, f.height + 80)
        const near = (x >= 0 && contains(z, x, y))
            || (ghost !== null && ghost.x < z.x + z.width && ghost.x + ghost.width > z.x && ghost.y < z.y + z.height && ghost.y + ghost.height > z.y)
        inspectorFaded = near
    }

    // MARK: Banner

    Rectangle {
        id: banner
        anchors.horizontalCenter: parent.horizontalCenter
        y: 8
        height: 30
        width: bannerRow.implicitWidth + 16
        color: Qt.rgba(0, 0, 0, 0.85)
        border.width: 1; border.color: Skin.withAlpha(Skin.accent, 0.7)
        Ticks { anchors.fill: parent }
        MouseArea { anchors.fill: parent; hoverEnabled: true }   // the banner isn't part of the window below
        Row {
            id: bannerRow
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Glyph { width: 12; height: 12; anchors.verticalCenter: parent.verticalCenter; name: "paintbrush.pointed"; color: Skin.accent }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                pt: 11
                text: Customize.peekOriginal ? "original design" : "customize"
                color: Customize.peekOriginal ? Skin.accent : Skin.textPrimary
            }
            Label { anchors.verticalCenter: parent.verticalCenter; pt: 11; color: Skin.textTertiary; text: overlay.hint }
            PillButton {
                anchors.verticalCenter: parent.verticalCenter
                text: "Done"; prominent: true; compact: true
                onClicked: Customize.active = false
            }
        }
    }

    readonly property string hint: {
        if (Customize.peekOriginal) return "release Alt to return"
        if (move !== null) return "drop on a pane's edge for a new column, its top or bottom half to stack"
        if (Customize.selection.length > 1) return Customize.selection.length + " selected · edits apply to all · Ctrl+C Ctrl+V copy style"
        if (Customize.primary && Customize.kind(Customize.primary) === "text") return "scroll to size · ↑↓ nudge · Shift-click adds · hold Alt to compare"
        if (Customize.primary) return "drag to move · corners resize and snap (Ctrl for free) · hold Alt to compare"
        return "click to select · drag a panel to move it · Shift-click adds · Esc to finish"
    }

    // MARK: Keys

    /// Esc deselects then finishes, Tab cycles, Ctrl+Z / Ctrl+Shift+Z undo
    /// and redo, Delete resets, Ctrl+C / Ctrl+V copy and paste a style,
    /// arrows nudge size, and holding Alt shows the original design.
    focus: Customize.active
    onVisibleChanged: if (visible) forceActiveFocus()
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Alt) { Customize.setPeek(e.modifiers === Qt.AltModifier); e.accepted = true; return }
        e.accepted = handleKey(e.key, e.modifiers)
    }
    Keys.onReleased: (e) => { if (e.key === Qt.Key_Alt) { Customize.setPeek(false); e.accepted = true } }

    function handleKey(key, mods) {
        const ctrl = (mods & Qt.ControlModifier) !== 0, shift = (mods & Qt.ShiftModifier) !== 0
        if (ctrl) {
            if (key === Qt.Key_Z) { shift ? Customize.redo() : Customize.undo(); return true }
            if (key === Qt.Key_Y) { Customize.redo(); return true }
            if (key === Qt.Key_C) { if (!Customize.primary) return false; Customize.copyStyle(Customize.primary); return true }
            if (key === Qt.Key_V) { if (!Customize.selection.length) return false; Customize.pasteStyle(Customize.selection); return true }
            return false
        }
        const step = shift ? 4 : 1
        switch (key) {
        case Qt.Key_Escape:
            if (Customize.selection.length) Customize.selection = []; else Customize.active = false
            return true
        case Qt.Key_Tab: case Qt.Key_Backtab: {
            const all = Customize.elements, n = all.length
            const i = Customize.primary ? all.indexOf(Customize.primary) : -1
            const back = shift || key === Qt.Key_Backtab
            Customize.select(all[(i + (back ? n - 1 : 1) + n) % n], false)
            return true
        }
        case Qt.Key_Delete: case Qt.Key_Backspace:
            if (!Customize.selection.length) return false
            Customize.reset(Customize.selection)
            return true
        case Qt.Key_Up: case Qt.Key_Down: {
            const p = Customize.primary
            if (!p) return false
            const dir = key === Qt.Key_Up ? 1 : -1
            if (Customize.kind(p) === "text") {
                Customize.edit(Customize.targets, "size", s => { s.sizeScale = Math.min(2.5, Math.max(0.6, (s.sizeScale || 1) + 0.05 * step * dir)) })
            } else if (p === "playerBar" || p === "statusBar") {
                const base = p === "statusBar" ? 28 : (Core.settings.playerBarStyle === "compact" ? 42 : 58)
                const lo = p === "statusBar" ? 20 : 40, hi = p === "statusBar" ? 48 : 140
                Customize.edit([p], "height", s => { s.height = Math.min(hi, Math.max(lo, (s.height === undefined ? base : s.height) + 2 * step * dir)) })
            }
            return true
        }
        case Qt.Key_Left: case Qt.Key_Right: {
            const pane = Customize.pane(Customize.primary)
            if (!pane) return false
            const c = Customize.columnIndex(Customize.layout, pane)
            if (c < 0 || Customize.layout.columns[c].panes.indexOf("library") >= 0) return false
            const current = Customize.layout.columns[c].width === undefined ? 280 : Customize.layout.columns[c].width
            Customize.setColumnWidth(c, Math.min(560, Math.max(160, current + (key === Qt.Key_Right ? 8 : -8) * step)))
            return true
        }
        }
        return false
    }

    // MARK: Pane resize rules (the Mac's PaneResize; interim until the core exports it)

    QtObject {
        id: rules
        readonly property real minWidth: 160
        readonly property real maxWidth: 560
        readonly property real libraryMinWidth: 360
        readonly property real minHeight: 80
        readonly property real snapDistance: 8

        function visiblePanes(s, c) { return s.layout.columns[c].panes.filter(p => s.frames[p] !== undefined) }
        function visibleColumns(s) { const out = []; for (let i = 0; i < s.layout.columns.length; i++) if (visiblePanes(s, i).length) out.push(i); return out }
        function isFlexible(s, c) { return s.layout.columns[c].panes.indexOf("library") >= 0 }
        function columnRect(s, c) {
            const rs = visiblePanes(s, c).map(p => s.frames[p])
            if (!rs.length) return null
            let x0 = rs[0].x, y0 = rs[0].y, x1 = rs[0].x + rs[0].width, y1 = rs[0].y + rs[0].height
            for (const r of rs) { x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y); x1 = Math.max(x1, r.x + r.width); y1 = Math.max(y1, r.y + r.height) }
            return Qt.rect(x0, y0, x1 - x0, y1 - y0)
        }

        /// The edges of a pane that move something: only edges shared with a neighbour.
        function movableEdges(pane, layout, frames) {
            const s = { layout: layout, frames: frames }
            const c = Customize.columnIndex(layout, pane)
            if (c < 0) return { horizontal: [], vertical: [] }
            const columns = visibleColumns(s), pos = columns.indexOf(c)
            if (pos < 0) return { horizontal: [], vertical: [] }
            const h = [], v = []
            if (pos > 0) h.push("leading")
            if (pos < columns.length - 1) h.push("trailing")
            const stack = visiblePanes(s, c), i = stack.indexOf(pane)
            if (i > 0) v.push("top")
            if (i >= 0 && i < stack.length - 1) v.push("bottom")
            return { horizontal: h, vertical: v }
        }

        /// The layout after dragging by (dx, dy); `snapping` off is Ctrl held.
        function apply(s, dx, dy, snapping) {
            const r0 = s.frames[s.pane]
            const result = { layout: Customize.copyLayout(s.layout), rect: r0 ? { x: r0.x, y: r0.y, width: r0.width, height: r0.height } : { x: 0, y: 0, width: 0, height: 0 }, guides: [] }
            const c = Customize.columnIndex(s.layout, s.pane)
            if (!r0 || c < 0) return result
            if (s.horizontal) resizeWidth(s, c, r0, s.horizontal, dx, snapping, result)
            if (s.vertical) resizeHeight(s, c, r0, s.vertical, dy, snapping, result)
            return result
        }

        function resizeWidth(s, c, r, edge, dx, snapping, result) {
            const columns = visibleColumns(s), pos = columns.indexOf(c)
            if (pos < 0) return
            const neighborPos = edge === "trailing" ? pos + 1 : pos - 1
            if (neighborPos < 0 || neighborPos >= columns.length) return
            const neighbor = columns[neighborPos]
            // The fixed column on this boundary changes; the library absorbs it.
            const resized = isFlexible(s, c) ? neighbor : c
            const rr = columnRect(s, resized), lib = columnRect(s, Customize.columnIndex(s.layout, "library"))
            if (!rr || !lib) return
            const own = resized === c, gap = s.gap
            const widthAt = b => own ? (edge === "trailing" ? b - rr.x : rr.x + rr.width - b)
                                     : (edge === "trailing" ? rr.x + rr.width - (b + gap) : (b - gap) - rr.x)
            const edgeFor = w => own ? (edge === "trailing" ? rr.x + w : rr.x + rr.width - w)
                                     : (edge === "trailing" ? rr.x + rr.width - w - gap : rr.x + w + gap)
            // A column never takes the library below its minimum.
            const upper = Math.min(maxWidth, rr.width + Math.max(0, lib.width - libraryMinWidth))
            let b = (edge === "trailing" ? r.x + r.width : r.x) + dx
            // Snap to another fixed column's width, so side columns can match.
            if (snapping) {
                for (const other of columns) {
                    if (other === resized || isFlexible(s, other)) continue
                    const o = columnRect(s, other)
                    if (!o) continue
                    const target = edgeFor(o.width)
                    if (Math.abs(b - target) < snapDistance) { b = target; result.guides.push({ axis: "x", position: target }); break }
                }
            }
            const width = Math.round(Math.min(upper, Math.max(minWidth, widthAt(b))))
            const id = s.layout.columns[resized].id
            const i = result.layout.columns.findIndex(col => col.id === id)
            if (i >= 0) result.layout.columns[i].width = width
            const landed = edgeFor(width)
            if (edge === "trailing") result.rect.width = landed - r.x
            else { result.rect.x = landed; result.rect.width = r.x + r.width - landed }
            result.guides = result.guides.filter(g => !(g.axis === "x" && Math.abs(g.position - landed) > 0.5))
        }

        function resizeHeight(s, c, r, edge, dy, snapping, result) {
            const stack = visiblePanes(s, c), i = stack.indexOf(s.pane)
            const j = edge === "bottom" ? i + 1 : i - 1
            if (i < 0 || j < 0 || j >= stack.length) return
            const n = s.frames[stack[j]]
            let line = (edge === "bottom" ? r.y + r.height : r.y) + dy
            if (snapping) {
                const snapped = snapY(s, line, c)
                if (snapped !== null) { line = snapped; result.guides.push({ axis: "y", position: snapped }) }
            }
            // The pair's combined height is fixed; trade it between them.
            const pair = r.height + n.height
            let mine = edge === "bottom" ? line - r.y : r.y + r.height - line
            mine = Math.round(Math.min(pair - minHeight, Math.max(minHeight, mine)))
            // Weights in points: every pane in the column at its current height.
            const weights = {}
            for (const p of stack) weights[p] = s.frames[p] ? s.frames[p].height : 0
            weights[s.pane] = mine
            weights[stack[j]] = pair - mine
            const id = s.layout.columns[c].id
            const k = result.layout.columns.findIndex(col => col.id === id)
            if (k >= 0) result.layout.columns[k].weights = Object.assign({}, result.layout.columns[k].weights || {}, weights)
            if (edge === "bottom") result.rect.height = mine
            else { result.rect.y = r.y + r.height - mine; result.rect.height = mine }
            // Guides only make sense where the edge actually landed.
            const landed = edge === "bottom" ? result.rect.y + result.rect.height : result.rect.y
            result.guides = result.guides.filter(g => !(g.axis === "y" && Math.abs(g.position - landed) > 0.5))
        }

        /// The nearest top or bottom edge of a pane in another column.
        function snapY(s, y, column) {
            let best = null, bestD = Infinity
            for (const p in s.frames) {
                if (Customize.columnIndex(s.layout, p) === column) continue
                const f = s.frames[p]
                for (const cand of [f.y, f.y + f.height]) {
                    const d = Math.abs(cand - y)
                    if (d < snapDistance && d < bestD) { best = cand; bestD = d }
                }
            }
            return best
        }
    }
}
