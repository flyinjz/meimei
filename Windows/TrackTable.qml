// The library table (the Mac's TrackTableView): pooled rows over the core's
// view, columns sized like the Mac's uniform autoresizing, click a header to
// sort, group headers, stripes, now-playing marker, multi-select (Ctrl,
// Shift), keyboard navigation, double-click or Return to play in table
// order, and the track menu.
import QtQuick
import I2S

Item {
    id: tt
    clip: true
    property bool hideAlbum: false
    signal removeRequested(var tracks)
    signal newPlaylistRequested(var tracks)

    // Column specs from the Mac table: key, title, width, min width, right-aligned.
    readonly property var allSpecs: [
        { key: "track", title: "#", w: 30, min: 22, right: true },
        { key: "title", title: "Title", w: 240, min: 100, right: false },
        { key: "artist", title: "Artist", w: 170, min: 70, right: false },
        { key: "album", title: "Album", w: 190, min: 70, right: false },
        { key: "time", title: "Time", w: 54, min: 44, right: true },
        { key: "genre", title: "Genre", w: 110, min: 50, right: false },
        { key: "format", title: "Format", w: 92, min: 72, right: false }
    ]
    readonly property var specs: hideAlbum ? allSpecs.filter(s => s.key !== "album") : allSpecs
    readonly property real spacing: 8
    readonly property real rowHeight: Core.settings.density === "compact" ? 19 : Core.settings.density === "spacious" ? 25 : 21
    // Uniform column autoresizing: the difference is shared equally, never below a column's minimum.
    readonly property var widths: {
        let w = specs.map(s => s.w)
        let free = specs.map(() => true)
        let delta = width - (w.reduce((a, b) => a + b, 0) + spacing * specs.length)
        for (let pass = 0; pass < 8 && Math.abs(delta) > 0.5; ++pass) {
            const n = free.filter(f => f).length
            if (n === 0) break
            const each = delta / n
            delta = 0
            for (let i = 0; i < w.length; ++i) {
                if (!free[i]) continue
                const next = w[i] + each
                if (next < specs[i].min) { delta += next - specs[i].min; w[i] = specs[i].min; free[i] = false }
                else w[i] = next
            }
        }
        return w
    }
    readonly property var xs: {
        let x = 0, out = []
        for (let i = 0; i < widths.length; ++i) { out.push(x); x += widths[i] + spacing }
        return out
    }

    // Selection by track (survives sorting and filtering), with an anchor for
    // Shift-extension and a cursor for the keyboard.
    property var selection: ({})
    property int selectionCount: 0
    property int anchorRow: -1
    property int cursorRow: -1
    function clearSelection() { selection = ({}); selectionCount = 0; anchorRow = -1; cursorRow = -1 }
    function setSelection(map) { selection = map; selectionCount = Object.keys(map).length }
    function selectRow(row, mods) {
        const track = Library.rows.trackAt(row)
        if (track < 0) return
        if ((mods & Qt.ShiftModifier) && anchorRow >= 0) {
            const map = {}
            const a = Math.min(anchorRow, row), b = Math.max(anchorRow, row)
            for (let r = a; r <= b; ++r) { const t = Library.rows.trackAt(r); if (t >= 0) map[t] = true }
            setSelection(map)
        } else if (mods & Qt.ControlModifier) {
            const map = Object.assign({}, selection)
            if (map[track]) delete map[track]; else map[track] = true
            setSelection(map)
            anchorRow = row
        } else {
            const map = {}
            map[track] = true
            setSelection(map)
            anchorRow = row
        }
        cursorRow = row
    }
    function moveCursor(delta, mods) {
        const n = list.count
        if (n === 0) return
        let r = Math.max(0, Math.min(n - 1, (cursorRow < 0 ? (delta > 0 ? -1 : n) : cursorRow) + delta))
        while (r >= 0 && r < n && Library.rows.trackAt(r) < 0) r += delta > 0 ? 1 : -1
        if (r < 0 || r >= n) return
        selectRow(r, mods & Qt.ShiftModifier)
        list.positionViewAtIndex(r, ListView.Contain)
    }
    function selectedTracks() {
        const out = []
        for (let r = 0; r < list.count; ++r) { const t = Library.rows.trackAt(r); if (t >= 0 && selection[t]) out.push(t) }
        return out
    }
    function playSelection() {
        const sel = selectedTracks()
        if (sel.length === 0) return
        if (sel.length > 1) Player.play(sel, 0); else Player.playFromTable(sel[0])
    }

    /// The shared track menu (the Mac's track context menu).
    function trackMenu(tracks) {
        const first = Library.track(tracks[0])
        const many = tracks.length > 1
        const allLiked = tracks.every(t => Library.track(t).liked)
        const manual = Library.playlists.filter(p => !p.smart)
        const inManual = Library.source.startsWith("playlist:") && manual.some(p => "playlist:" + p.id === Library.source)
        const groups = [
            { entries: [
                { title: "Play", glyph: "play.fill", detail: "↩", action: () => many ? Player.play(tracks, 0) : Player.playFromTable(tracks[0]) },
                { title: "Play Next", glyph: "arrow.uturn.forward", action: () => Player.playNext(tracks) },
                { title: "Add to Queue", glyph: "list.number", action: () => Player.addToQueue(tracks) }] },
            { entries: [
                { title: allLiked ? "Unlike" : "Like", glyph: allLiked ? "heart.slash" : "heart", action: () => Library.setLiked(tracks, !allLiked) },
                { title: "Add to Playlist", glyph: "plus.square.on.square", submenu: { groups: [
                    { entries: [{ title: "New Playlist from Selection…", glyph: "plus", action: () => tt.newPlaylistRequested(tracks) }] },
                    { entries: manual.map(p => ({ title: p.name, glyph: "music.note.list", action: () => Library.editPlaylist("add", p.id, tracks) })) }
                ].filter(g => g.entries.length > 0) } },
                { title: "Show Artist", glyph: "music.mic", enabled: !many, action: () => Library.source = "artist:" + (first.albumArtist || first.artist) }] },
            { label: "file", entries: [
                { title: "Show in Explorer", glyph: "arrow.up.forward", enabled: !many, action: () => Library.showInExplorer(tracks[0]) }] }
        ]
        if (inManual) groups.push({ entries: [{ title: "Remove from Playlist", glyph: "minus.circle",
                                                action: () => Library.editPlaylist("remove", Library.source.slice(9), tracks) }] })
        groups.push({ entries: [{ title: many ? "Remove " + tracks.length + " from Library…" : "Remove from Library…", glyph: "trash",
                                  detail: "Del", destructive: true, action: () => tt.removeRequested(tracks) }] })
        return { title: many ? tracks.length + " tracks" : first.title, subtitle: many ? "" : [first.artist, first.album].filter(s => s).join(" · "), groups: groups }
    }

    // A new list opens at the top with nothing selected.
    Connections {
        target: Library
        function onSourceChanged() { tt.clearSelection(); list.positionViewAtBeginning() }
    }

    focus: true
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Down) { moveCursor(1, e.modifiers); e.accepted = true }
        else if (e.key === Qt.Key_Up) { moveCursor(-1, e.modifiers); e.accepted = true }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { playSelection(); e.accepted = true }
        else if (e.key === Qt.Key_Delete) { const s = selectedTracks(); if (s.length > 0) tt.removeRequested(s); e.accepted = true }
        else if (e.key === Qt.Key_A && (e.modifiers & Qt.ControlModifier)) {
            const map = {}
            for (const t of Library.visibleTracks()) map[t] = true
            setSelection(map); e.accepted = true
        }
        else if (e.key === Qt.Key_Home) { list.positionViewAtBeginning(); e.accepted = true }
        else if (e.key === Qt.Key_End) { list.positionViewAtEnd(); e.accepted = true }
        else if (e.key === Qt.Key_PageDown) { list.contentY = Math.min(list.contentHeight - list.height, list.contentY + list.height); e.accepted = true }
        else if (e.key === Qt.Key_PageUp) { list.contentY = Math.max(0, list.contentY - list.height); e.accepted = true }
    }

    // Header: labels on no fill, one divider underneath; click to sort.
    Item {
        id: th
        width: parent.width; height: 28
        // The table header is a customizable panel.
        readonly property string element: "tableHeader"
        readonly property bool shown: visible
        readonly property var style: Customize.style("tableHeader")
        Component.onCompleted: Customize.register(th)
        Component.onDestruction: Customize.unregister(th)
        Rectangle { anchors.fill: parent; visible: th.style.fill !== undefined; color: th.style.fill !== undefined ? Skin.rgb(th.style.fill, th.style.fillOpacity === undefined ? 0.5 : th.style.fillOpacity) : "transparent" }
        Repeater {
            model: tt.specs.length
            delegate: Item {
                id: hc
                required property int index
                readonly property var spec: tt.specs[index]
                readonly property bool sorted: Library.sortKey === spec.key
                x: tt.xs[index]; width: tt.widths[index] + tt.spacing; height: th.height
                Label {
                    id: hl
                    x: hc.spec.right ? parent.width - 7 - implicitWidth - (hc.sorted ? 10 : 0) : 7
                    width: Math.min(implicitWidth, parent.width - 14)
                    anchors.verticalCenter: parent.verticalCenter
                    pt: 10.5; weight: "semibold"; role: "tableHeaderText"; text: hc.spec.title
                    color: hc.sorted ? Skin.textPrimary : Skin.textTertiary
                }
                Label {
                    visible: hc.sorted
                    x: hc.spec.right ? parent.width - 7 - 8 : hl.x + hl.width + 4
                    anchors.verticalCenter: parent.verticalCenter
                    pt: 9; text: Library.sortAscending ? "▴" : "▾"; color: Skin.accent
                }
                TapHandler { onTapped: Library.toggleSort(hc.spec.key) }
            }
        }
        Hairline { y: parent.height - 1; width: parent.width }
    }

    ListView {
        id: list
        y: th.height; width: parent.width; height: parent.height - y
        model: Library.rows
        reuseItems: true
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 200
        clip: true
        Glide { line: tt.rowHeight }
        delegate: Item {
            id: rowItem
            required property int index
            required property bool isHeader
            required property string headerTitle
            required property string headerDetail
            required property int track
            required property bool stripe
            required property string title
            required property string artist
            required property string album
            required property string trackNo
            required property string time
            required property string genre
            required property string format
            required property string quality
            required property bool hiRes
            width: list.width; height: isHeader ? tt.rowHeight + 8 : tt.rowHeight
            readonly property bool playing: !isHeader && track === Player.trackIndex
            readonly property bool selected: !isHeader && tt.selection[track] === true
            readonly property bool lossless: !isHeader && ["FLAC", "ALAC", "WAV", "AIFF", "PCM"].indexOf(format.toUpperCase()) >= 0

            Rectangle {
                x: 1; y: rowItem.isHeader ? 1 : 0; width: parent.width - 2; height: parent.height - (rowItem.isHeader ? 2 : 0)
                color: rowItem.isHeader ? Skin.bgRaised : Skin.bgRowAlt
                visible: rowItem.isHeader || (rowItem.stripe && Core.settings.alternatingRows !== false)
            }
            Rectangle { x: 1; width: parent.width - 2; height: parent.height; visible: rowItem.selected; color: Skin.withAlpha(Skin.accent, tt.activeFocus ? 0.7 : 0.42) }
            Rectangle { x: 1; width: 2; height: parent.height; visible: rowItem.selected; color: Skin.accent }

            // Group header: title, then the count and length.
            Row {
                visible: rowItem.isHeader
                x: 10; anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                Label { pt: 12; weight: "semibold"; text: rowItem.headerTitle }
                Label { pt: 10.5; text: rowItem.headerDetail; color: Skin.textTertiary; anchors.verticalCenter: parent.verticalCenter }
            }

            function cellText(key) {
                switch (key) {
                case "track": return trackNo
                case "title": return title
                case "artist": return artist
                case "album": return album
                case "time": return time
                case "genre": return genre
                case "format": return format
                }
                return ""
            }
            Repeater {
                model: rowItem.isHeader ? 0 : tt.specs.length
                delegate: Label {
                    required property int index
                    readonly property string key: tt.specs[index].key
                    readonly property bool numeric: key === "track" || key === "time"
                    visible: !(key === "track" && rowItem.playing)
                    x: tt.xs[index] + 4 + 6
                    width: tt.widths[index] - 12 - (key === "format" && rowItem.lossless ? 17 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: tt.specs[index].right ? Text.AlignRight : Text.AlignLeft
                    pt: numeric ? 11 : 11.5
                    weight: rowItem.playing && key === "title" ? "semibold" : "regular"
                    role: "tableText"
                    text: rowItem.cellText(key)
                    color: rowItem.playing ? Skin.accent : key === "title" ? Skin.textPrimary : Skin.textSecondary
                }
            }
            // Now playing: a speaker in the # column.
            Glyph {
                visible: rowItem.playing
                x: tt.xs[0] + 4 + tt.widths[0] - 20; width: 14; height: 14
                anchors.verticalCenter: parent.verticalCenter
                name: "speaker.wave.2.fill"; color: Skin.accent
            }
            // Lossless mark in the format column (hi-res in the accent).
            Glyph {
                visible: rowItem.lossless && Core.settings.showHiResBadge !== false
                x: tt.xs[tt.specs.length - 1] + 4 + tt.widths[tt.specs.length - 1] - 11 - 4; width: 11; height: 9
                anchors.verticalCenter: parent.verticalCenter
                name: rowItem.hiRes ? "badge.hires" : "badge.lossless"
                color: rowItem.hiRes ? Skin.withAlpha(Skin.accent, 0.7) : Skin.withAlpha(Skin.textPrimary, 0.55)
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: (m) => {
                    tt.forceActiveFocus()
                    if (rowItem.isHeader) return
                    if (m.button === Qt.RightButton) {
                        if (tt.selection[rowItem.track] !== true) tt.selectRow(rowItem.index, 0)
                        const g = mapToGlobal(m.x, m.y)
                        AppMenu.open(tt.trackMenu(tt.selectedTracks()), g.x, g.y)
                        return
                    }
                    tt.selectRow(rowItem.index, m.modifiers)
                    if (Core.settings.singleClickPlay === true && !(m.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) Player.playFromTable(rowItem.track)
                }
                onDoubleClicked: if (!rowItem.isHeader) Player.playFromTable(rowItem.track)
            }
        }
    }
}
