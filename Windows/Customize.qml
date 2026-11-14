pragma Singleton
// The customize mode's state (the Mac's CustomizeStore + CustomizeCursor +
// LayoutDraft): on/off, hover and selection, the original-design peek, undo
// and redo, and every edit to styles, layout, tokens and workspaces. The
// stored data is the core's (Core.customize, normalized on every write).
//
// Interim: the element table, PaneLayout.move and ElementStyle.merging below
// mirror the core's Swift until it exports them (asked for); then these
// become calls.
import QtQuick
import I2S

QtObject {
    id: store

    // MARK: Mode

    property bool active: false
    onActiveChanged: if (!active) { hovered = ""; selection = []; Core.peekOriginal = false }
    readonly property bool peekOriginal: Core.peekOriginal
    function setPeek(on) { if (Core.peekOriginal !== on) Core.peekOriginal = on }

    // MARK: Reading

    readonly property var state: Core.customize
    readonly property var storedStyles: state.styles || ({})
    readonly property var storedLayout: state.layout || Core.standardLayout
    readonly property var storedTokens: state.tokens || ({})
    readonly property var workspaces: state.workspaces || []
    readonly property string activeWorkspaceID: state.activeWorkspaceID || ""

    /// What renders: nothing customized while peeking at the original.
    readonly property var styles: peekOriginal ? ({}) : storedStyles
    readonly property var layout: peekOriginal ? Core.standardLayout : storedLayout
    /// A layout being dragged; only the pane grid reads it, the store gets the result on release.
    property var draftLayout: null
    readonly property var shownLayout: draftLayout || layout

    function style(e) { return styles[e] || ({}) }
    function storedStyle(e) { return storedStyles[e] || ({}) }

    // MARK: Elements (core: CustomElement)

    readonly property var elements: [
        "playerBar", "nowPlayingPanel", "browsePanel", "libraryPanel", "collectionRail", "lyricsPanel", "statusBar",
        "eqGraph", "eqPanels", "tableHeader",
        "playerTitle", "playerSubtitle", "playerTimes",
        "miniTitle", "miniArtist", "eqLabels", "tableHeaderText",
        "nowPlayingTitle", "nowPlayingArtist", "nowPlayingDetails",
        "libraryTitle", "librarySummary", "sectionLabels", "sidebarRows", "railRows", "tableText", "statusText", "lyricsText",
        "windowControls"
    ]
    readonly property var labels: ({
        playerBar: "player bar", nowPlayingPanel: "now playing", browsePanel: "browse", libraryPanel: "library",
        collectionRail: "playlists", lyricsPanel: "lyrics panel", statusBar: "status bar",
        playerTitle: "player title", playerSubtitle: "player artist", playerTimes: "player times",
        nowPlayingTitle: "track title", nowPlayingArtist: "track artist", nowPlayingDetails: "track details",
        libraryTitle: "library title", librarySummary: "library summary", sectionLabels: "section labels",
        sidebarRows: "browse rows", railRows: "playlist rows", tableText: "track list", statusText: "status text",
        lyricsText: "lyrics", eqGraph: "eq graph", eqPanels: "eq panels", miniTitle: "mini title", miniArtist: "mini artist",
        eqLabels: "eq labels", tableHeader: "table header", tableHeaderText: "table header labels", windowControls: "window buttons"
    })
    readonly property var panels: ["playerBar", "nowPlayingPanel", "browsePanel", "libraryPanel", "collectionRail",
                                   "lyricsPanel", "statusBar", "eqGraph", "eqPanels", "tableHeader"]
    readonly property var paneOfElement: ({ nowPlayingPanel: "nowPlaying", browsePanel: "browse", libraryPanel: "library",
                                            collectionRail: "playlists", lyricsPanel: "lyrics" })
    readonly property var elementOfPane: ({ nowPlaying: "nowPlayingPanel", browse: "browsePanel", library: "libraryPanel",
                                            playlists: "collectionRail", lyrics: "lyricsPanel" })
    readonly property var paneIDs: ["nowPlaying", "browse", "library", "lyrics", "playlists"]
    readonly property var titles: ["playerTitle", "playerSubtitle", "nowPlayingTitle", "nowPlayingArtist", "libraryTitle",
                                   "librarySummary", "miniTitle", "miniArtist"]

    function kind(e) { return e === "windowControls" ? "controls" : panels.indexOf(e) >= 0 ? "panel" : "text" }
    function label(e) { return labels[e] || e }
    function pane(e) { return paneOfElement[e] || "" }
    function isTitle(e) { return titles.indexOf(e) >= 0 }

    // MARK: Frames

    /// Every on-screen instance of each element (Frame items), for the overlay.
    property var frameItems: []
    function register(item) { frameItems.push(item) }
    function unregister(item) { const i = frameItems.indexOf(item); if (i >= 0) frameItems.splice(i, 1) }

    /// Each element's rects in `space`'s coordinates (visible instances only).
    function frames(space) {
        const out = {}
        for (const f of frameItems) {
            if (!f.element || !f.shown) continue
            const lr = f.frameRect ? f.frameRect() : Qt.rect(0, 0, f.width, f.height)
            const r = f.mapToItem(space, lr.x, lr.y, lr.width, lr.height)
            if (r.width <= 1 || r.height <= 1) continue
            ;(out[f.element] = out[f.element] || []).push(r)
        }
        return out
    }

    // MARK: Cursor

    property string hovered: ""
    /// In selection order; the last is the primary (shown in the inspector).
    property var selection: []
    readonly property string primary: selection.length ? selection[selection.length - 1] : ""
    /// The selected elements an edit applies to: those of the primary's kind.
    readonly property var targets: primary ? selection.filter(e => kind(e) === kind(primary)) : []

    function select(e, extending) {
        if (!e) { if (!extending) selection = []; return }
        if (extending) {
            const s = selection.slice(), i = s.indexOf(e)
            if (i >= 0) s.splice(i, 1); else s.push(e)
            selection = s
        } else {
            selection = [e]
        }
    }

    // MARK: Undo

    property var undoStack: []
    property var redoStack: []
    property var clipboard: null
    property string lastEditKey: ""
    property real lastEditAt: 0

    function snapshot() { return JSON.stringify({ styles: storedStyles, layout: storedLayout, tokens: storedTokens }) }

    /// Records the current state so the next change can be undone.
    function checkpoint() {
        const s = snapshot(), u = undoStack.slice()
        if (u.length === 0 || u[u.length - 1] !== s) u.push(s)
        if (u.length > 300) u.shift()
        undoStack = u
        redoStack = []
    }

    /// Checkpoints unless the same kind of change happened a moment ago, so
    /// a drag or a scroll is one undo step.
    function checkpointCoalescing(key) {
        if (!key) { checkpoint(); return }
        const now = Date.now()
        if (lastEditKey !== key || now - lastEditAt > 800) checkpoint()
        lastEditKey = key
        lastEditAt = now
    }

    function undo() {
        if (!undoStack.length) return
        const u = undoStack.slice(), previous = u.pop()
        redoStack = redoStack.concat([snapshot()])
        undoStack = u
        restore(previous)
    }

    function redo() {
        if (!redoStack.length) return
        const r = redoStack.slice(), next = r.pop()
        undoStack = undoStack.concat([snapshot()])
        redoStack = r
        restore(next)
    }

    function restore(json) {
        const s = JSON.parse(json)
        write({ styles: s.styles, layout: s.layout, tokens: s.tokens })
    }

    // MARK: Writing

    /// Writes changed parts of the state through the core. Edits after
    /// applying a workspace leave it (the inspector shows "unsaved").
    function write(changes) {
        const next = Object.assign({}, state, changes)
        if (next.activeWorkspaceID && changes.activeWorkspaceID === undefined) {
            const ws = (next.workspaces || []).find(w => w.id === next.activeWorkspaceID)
            if (ws && (JSON.stringify(ws.layout) !== JSON.stringify(next.layout)
                       || JSON.stringify(ws.tokens) !== JSON.stringify(next.tokens)
                       || JSON.stringify(ws.styles) !== JSON.stringify(next.styles)))
                delete next.activeWorkspaceID
        }
        if (!next.activeWorkspaceID) delete next.activeWorkspaceID
        Core.setCustomize(next)
    }

    function isEmptyStyle(s) { return Object.keys(s).length === 0 }

    // MARK: Styles

    /// Changes elements' styles; only those of the first element's kind.
    function edit(elements, coalesce, body) {
        if (!elements.length) return
        checkpointCoalescing(coalesce ? elements.join(",") + "." + coalesce : "")
        const k = kind(elements[0]), styles = Object.assign({}, storedStyles)
        for (const e of elements) {
            if (kind(e) !== k) continue
            const s = Object.assign({}, styles[e] || {})
            body(s)
            for (const key in s) if (s[key] === undefined || s[key] === null) delete s[key]
            if (isEmptyStyle(s)) delete styles[e]; else styles[e] = s
        }
        write({ styles: styles })
    }

    function reset(elements) {
        if (!elements.some(e => storedStyles[e] !== undefined)) return
        checkpoint()
        const styles = Object.assign({}, storedStyles)
        for (const e of elements) delete styles[e]
        write({ styles: styles })
    }

    function copyStyle(e) { clipboard = { kind: kind(e), style: Object.assign({}, storedStyle(e)) } }

    readonly property var textKeys: ["font", "sizeScale", "weight", "color", "opacity", "tracking", "align", "lines", "shadow"]
    readonly property var panelKeys: ["fill", "fillOpacity", "border", "borderWidth", "borderSides", "ticks", "padding", "depth"]

    /// Pastes the copied style onto elements of the same kind, keeping
    /// whatever else they already have (core: ElementStyle.merging).
    function pasteStyle(elements) {
        if (!clipboard) return
        const into = elements.filter(e => kind(e) === clipboard.kind)
        if (!into.length) return
        checkpoint()
        const keys = clipboard.kind === "text" ? textKeys : clipboard.kind === "panel" ? panelKeys : []
        const styles = Object.assign({}, storedStyles)
        for (const e of into) {
            const s = Object.assign({}, styles[e] || {})
            for (const key of keys) if (clipboard.style[key] !== undefined) s[key] = clipboard.style[key]
            if (isEmptyStyle(s)) delete styles[e]; else styles[e] = s
        }
        write({ styles: styles })
    }

    // MARK: Tokens

    function editTokens(coalesce, body) {
        checkpointCoalescing(coalesce ? "tokens." + coalesce : "")
        const t = Object.assign({}, storedTokens)
        body(t)
        write({ tokens: t })
    }

    // MARK: Layout

    function copyLayout(l) { return JSON.parse(JSON.stringify(l)) }
    function columnIndex(l, pane) { return l.columns.findIndex(c => c.panes.indexOf(pane) >= 0) }
    function uuid() {
        const h = "0123456789ABCDEF"
        let s = ""
        for (let i = 0; i < 36; i++) s += [8, 13, 18, 23].indexOf(i) >= 0 ? "-" : i === 14 ? "4" : h[Math.floor(Math.random() * 16)]
        return s
    }

    /// Keeps every pane in exactly one column and drops empty columns (core: PaneLayout.normalize).
    function normalizeLayout(l) {
        const seen = {}
        for (const c of l.columns) c.panes = c.panes.filter(p => seen[p] ? false : (seen[p] = true))
        l.columns = l.columns.filter(c => c.panes.length)
        for (const p of paneIDs) if (!seen[p]) l.columns.push({ id: uuid(), panes: [p], weights: {} })
        return l
    }

    /// The layout with `pane` moved (core: PaneLayout.move). target:
    /// { stack: true, column, index } or { stack: false, index } (new column).
    function movedLayout(layout, pane, target) {
        const l = copyLayout(layout)
        const from = columnIndex(l, pane)
        if (from < 0) return l
        const fromIndex = l.columns[from].panes.indexOf(pane)
        const weights = l.columns[from].weights || {}
        const weight = weights[pane]
        const width = l.columns[from].panes.length === 1 ? l.columns[from].width : undefined
        l.columns[from].panes.splice(fromIndex, 1)
        l.columns[from].weights = {}
        if (target.stack) {
            if (target.column >= 0 && target.column < l.columns.length) {
                // An index past the removed pane in the same column shifts up by one.
                const i = (target.column === from && target.index > fromIndex) ? target.index - 1 : target.index
                const col = l.columns[target.column]
                col.panes.splice(Math.min(Math.max(0, i), col.panes.length), 0, pane)
                // Resized stacks keep weights in points; a newcomer would get a
                // sliver, so a changed stack starts from even shares again.
                if (target.column === from) { if (weight !== undefined) col.weights[pane] = weight }
                else col.weights = {}
            }
        } else {
            const column = { id: uuid(), panes: [pane], weights: {} }
            if (width !== undefined) column.width = width
            l.columns.splice(Math.min(Math.max(0, target.index), l.columns.length), 0, column)
        }
        return normalizeLayout(l)
    }

    function move(pane, target) {
        checkpoint()
        write({ layout: movedLayout(storedLayout, pane, target) })
    }

    function setHidden(pane, hidden) {
        if (pane === "library") return
        checkpoint()
        const l = copyLayout(storedLayout), h = (l.hidden || []).filter(p => p !== pane)
        if (hidden) h.push(pane)
        l.hidden = h
        write({ layout: l })
    }

    /// Saves a dragged layout as one undo step.
    function commitLayout(l) {
        if (JSON.stringify(l) === JSON.stringify(storedLayout)) return
        checkpoint()
        write({ layout: l })
    }

    function setColumnWidth(column, width) {
        if (column < 0 || column >= storedLayout.columns.length) return
        checkpointCoalescing("width." + column)
        const l = copyLayout(storedLayout)
        l.columns[column].width = width
        write({ layout: l })
    }

    function setWeights(column, weights) {
        if (column < 0 || column >= storedLayout.columns.length) return
        checkpointCoalescing("weights." + column)
        const l = copyLayout(storedLayout)
        l.columns[column].weights = Object.assign({}, l.columns[column].weights || {}, weights)
        write({ layout: l })
    }

    function resetLayout() { checkpoint(); write({ layout: Core.standardLayout }) }

    function resetAll() { checkpoint(); write({ styles: {}, layout: Core.standardLayout, tokens: Core.customizeDefaults().tokens }) }

    // MARK: Workspaces

    function saveWorkspace(name) {
        const trimmed = (name || "").trim()
        const ws = { id: uuid(), name: trimmed || "Workspace " + (workspaces.length + 1),
                     layout: storedLayout, tokens: storedTokens, styles: storedStyles }
        write({ workspaces: workspaces.concat([ws]), activeWorkspaceID: ws.id })
        return ws.id
    }

    function updateWorkspace(id) {
        const list = workspaces.map(w => w.id === id ? Object.assign({}, w, { layout: storedLayout, tokens: storedTokens, styles: storedStyles }) : w)
        if (!list.some(w => w.id === id)) return
        write({ workspaces: list, activeWorkspaceID: id })
    }

    function applyWorkspace(id) {
        const ws = workspaces.find(w => w.id === id)
        if (!ws) return
        checkpoint()
        write({ styles: ws.styles, layout: ws.layout, tokens: ws.tokens, activeWorkspaceID: id })
    }

    function applyWorkspaceNumber(n) { if (n >= 1 && n <= workspaces.length) applyWorkspace(workspaces[n - 1].id) }

    function renameWorkspace(id, name) {
        const trimmed = (name || "").trim()
        if (!trimmed || !workspaces.some(w => w.id === id)) return
        write({ workspaces: workspaces.map(w => w.id === id ? Object.assign({}, w, { name: trimmed }) : w),
                activeWorkspaceID: activeWorkspaceID })
    }

    function deleteWorkspace(id) {
        write({ workspaces: workspaces.filter(w => w.id !== id),
                activeWorkspaceID: activeWorkspaceID === id ? "" : activeWorkspaceID })
    }

    function moveWorkspace(index, step) {
        const to = index + step
        if (index < 0 || to < 0 || index >= workspaces.length || to >= workspaces.length) return
        const list = workspaces.slice(), t = list[index]
        list[index] = list[to]; list[to] = t
        write({ workspaces: list, activeWorkspaceID: activeWorkspaceID })
    }

    // MARK: Interchange (the Mac's "meimei-style" export, version 2)

    function exportText() {
        return JSON.stringify({ format: "meimei-style", version: 2, styles: storedStyles, layout: storedLayout, tokens: storedTokens }, null, 2)
    }

    function importText(text) {
        let e
        try { e = JSON.parse(text) } catch (err) { return false }
        if (!e || e.format !== "meimei-style" || typeof e.styles !== "object") return false
        checkpoint()
        const changes = { styles: e.styles }
        if (e.layout) changes.layout = e.layout
        if (e.tokens) changes.tokens = e.tokens
        write(changes)
        return true
    }
}
