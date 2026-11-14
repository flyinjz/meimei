// The main window (the Mac's MainWindowView): title strip on top, the player
// bar above or below, the panes in the user's layout (now playing, browse,
// library, lyrics, playlists), the status bar, and the customize layer over
// everything. Drop folders or files anywhere to import them.
import QtQuick
import QtQuick.Dialogs
import I2S

Window {
    id: win
    width: 1240; height: 780
    minimumWidth: 960; minimumHeight: 620
    title: "i2s"
    color: "transparent"
    flags: Qt.Window | Qt.FramelessWindowHint

    readonly property var settings: Core.settings
    readonly property real gap: Skin.gap

    Backdrop {
        width: win.width; height: win.height
        style: Skin.backdrop
        glassTint: win.settings.glassTintStrength
        artwork: Player.track.artwork ? "image://backdrop/" + encodeURIComponent(Player.track.artwork) : ""
    }

    Item {
        id: content
        width: win.width; height: win.height

        Column {
            id: column
            x: win.gap
            width: parent.width - 2 * win.gap
            height: parent.height - win.gap
            spacing: win.gap

            TitleStrip { id: strip; width: parent.width; window: win }

            PlayerBar { id: barTop; width: parent.width; visible: Core.settings.playerBarPosition === "top" }

            PaneGrid {
                id: grid
                width: parent.width
                height: column.height - strip.height - column.spacing
                        - (barTop.visible ? barTop.height + column.spacing : 0)
                        - (barBottom.visible ? barBottom.height + column.spacing : 0)
                        - (status.visible ? status.height + column.spacing : 0)
                contents: ({ nowPlaying: nowPlayingPane, browse: browsePane, library: libraryPane, lyrics: lyricsPane, playlists: playlistsPane })
            }

            PlayerBar { id: barBottom; width: parent.width; visible: Core.settings.playerBarPosition !== "top" }

            StatusBar {
                id: status
                visible: win.settings.showStatusBar !== false
                width: parent.width
                selectionCount: win.table ? win.table.selectionCount : 0
            }
        }

        // Drop folders or audio files anywhere in the window to import them.
        DropArea {
            id: drop
            anchors.fill: parent
            keys: ["text/uri-list"]
            onDropped: (d) => { if (d.hasUrls) { Library.importItems(d.urls); d.acceptProposedAction() } }
        }
        Rectangle {
            visible: drop.containsDrag
            anchors.fill: parent; anchors.margins: win.gap
            color: Skin.withAlpha(Skin.accent, 0.06)
            border.width: 2; border.color: Skin.accent
        }

        CustomizeOverlay { id: overlay; anchors.fill: parent }
        ConfirmBox { id: dialog; anchors.fill: parent }
    }

    property TrackTable table: null

    Component { id: nowPlayingPane; NowPlayingPane {} }
    Component { id: browsePane; BrowsePane {} }
    Component {
        id: libraryPane
        LibraryPane {
            Component.onCompleted: win.table = table
            onAddMusic: folderDialog.open()
            onRemoveRequested: (tracks) => win.confirmRemoval(tracks)
            onNewPlaylistRequested: (tracks) => win.newPlaylist(tracks)
        }
    }
    Component { id: lyricsPane; LyricsPane {} }
    Component { id: playlistsPane; PlaylistsPane { onNewPlaylist: win.newPlaylist(win.table ? win.table.selectedTracks() : []) } }

    FolderDialog {
        id: folderDialog
        title: "Add to Library"
        onAccepted: Library.importItems([selectedFolder])
    }

    function confirmRemoval(tracks) {
        if (!tracks.length) return
        dialog.ask(tracks.length > 1 ? "Remove " + tracks.length + " tracks from the library?" : "Remove this track from the library?",
                   "The files stay where they are on disk. You can add them again any time.", "Remove",
                   () => { Library.removeTracks(tracks); if (win.table) win.table.clearSelection() })
    }
    function newPlaylist(tracks) {
        const id = Library.createPlaylist("New Playlist", tracks)
        Library.source = "playlist:" + id
    }

    /// A small in-window confirmation (the Mac's ConfirmDialog sheet).
    component ConfirmBox: Item {
        id: dlg
        visible: opacity > 0
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        property bool shown: false
        property string title
        property string message
        property string confirmTitle
        property var onConfirm: null
        function ask(t, m, c, f) { title = t; message = m; confirmTitle = c; onConfirm = f; shown = true; forceActiveFocus() }
        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.35); MouseArea { anchors.fill: parent; onClicked: dlg.shown = false } }
        GlassSurface {
            anchors.centerIn: parent
            width: 420; height: box.height + 40
            content: true
            Column {
                id: box
                x: 20; y: 20; width: parent.width - 40
                spacing: 10
                Label { width: parent.width; pt: 14; weight: "semibold"; text: dlg.title; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideNone }
                Label { width: parent.width; pt: 12; text: dlg.message; color: Skin.textSecondary; wrapMode: Text.WordWrap; maximumLineCount: 6; elide: Text.ElideNone }
                Item { width: 1; height: 6 }
                Row {
                    anchors.right: parent.right
                    spacing: 8
                    PillButton { text: "Cancel"; onClicked: dlg.shown = false }
                    PillButton { text: dlg.confirmTitle; prominent: true; onClicked: { dlg.shown = false; if (dlg.onConfirm) dlg.onConfirm() } }
                }
            }
        }
        Keys.onEscapePressed: shown = false
        Keys.onReturnPressed: { shown = false; if (onConfirm) onConfirm() }
    }

    /// The band across the top: window buttons and the sidebar toggle on the
    /// left, the search pill centred on the window, Downloads, Library and
    /// Customize on the right.
    component TitleStrip: TitleBand {
        id: band
        Row {
            // 10 after the window buttons (or the platform's 62-point traffic-light room).
            x: Core.settings.systemWindowFrame ? 8.5 + 62 + 10 : band.buttonsRight + 10
            anchors.verticalCenter: parent.verticalCenter
            GlyphButton {
                icon: "sidebar.left"; size: 24; iconSize: 13
                help: Core.settings.showSidebar ? "Hide Sidebar" : "Show Sidebar"
                onClicked: Core.setSetting("showSidebar", !Core.settings.showSidebar)
            }
        }
        // The search pill, centred on the band.
        Rectangle {
            x: (band.width - width) / 2
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(380, band.width * 0.4); height: 28
            color: Skin.withAlpha(Skin.textPrimary, pillHover.hovered ? 0.07 : 0.04)
            border.width: 1; border.color: Skin.withAlpha(Skin.textPrimary, pillHover.hovered ? 0.22 : 0.14)
            Glyph { x: 10; anchors.verticalCenter: parent.verticalCenter; width: 11; height: 11; name: "magnifyingglass"; color: Skin.textTertiary }
            Label { x: 28; anchors.verticalCenter: parent.verticalCenter; pt: 12; text: "Search songs, albums, artists, commands"; color: Skin.textTertiary; width: parent.width - 28 - 70 }
            Label { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; pt: 11; text: "[Ctrl+K]"; color: Skin.textTertiary }
            HoverHandler { id: pillHover }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 8.5
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            GlyphButton { icon: "downloads"; size: 24; iconSize: 13; help: "Downloads (Ctrl+Shift+D)" }
            GlyphButton { icon: "music.note.house"; size: 24; iconSize: 13; active: Library.scanning; help: "Library: folders and scanning (Ctrl+Shift+L)"; onClicked: folderDialog.open() }
            GlyphButton {
                icon: "paintbrush.pointed"; size: 24; iconSize: 13
                active: Customize.active
                help: "Customize the interface (Ctrl+Shift+C)"
                onClicked: Customize.active = !Customize.active
            }
        }
    }

    Timer { id: playSoon; interval: 2500; onTriggered: { Player.play(Library.visibleTracks(), 0) } }

    // MARK: Keyboard (the Mac's shortcuts, Ctrl for ⌘ and Alt for ⌥)
    Shortcut { sequence: "Space"; enabled: !Customize.active; onActivated: Player.togglePlayPause() }
    Shortcut { sequence: "Ctrl+Right"; onActivated: Player.next() }
    Shortcut { sequence: "Ctrl+Left"; onActivated: Player.previous() }
    Shortcut { sequence: "Ctrl+."; onActivated: Player.stop() }
    Shortcut { sequence: "Ctrl+Up"; onActivated: Player.volume = Math.min(1, Player.volume + 0.0625) }
    Shortcut { sequence: "Ctrl+Down"; onActivated: Player.volume = Math.max(0, Player.volume - 0.0625) }
    Shortcut { sequence: "Ctrl+Alt+S"; onActivated: Player.shuffle = !Player.shuffle }
    Shortcut { sequence: "Ctrl+Alt+R"; onActivated: Player.cycleRepeat() }
    Shortcut { sequence: "Ctrl+O"; onActivated: folderDialog.open() }
    Shortcut { sequence: "Ctrl+N"; onActivated: win.newPlaylist([]) }
    Shortcut { sequence: "Ctrl+Shift+R"; onActivated: Library.rescan() }
    Shortcut { sequence: "Ctrl+L"; onActivated: if (Player.hasTrack) Library.source = "artist:" + (Player.track.albumArtist || Player.track.artist) }

    // Test states: `--open customize,select:libraryPanel,select:libraryTitle`.
    Component.onCompleted: {
        for (const s of openStates) {
            if (s === "customize") Customize.active = true
            else if (s.startsWith("select:")) Customize.select(s.slice(7), true)
            else if (s.startsWith("hover:")) Customize.hovered = s.slice(6)
            else if (s === "customize-test") Qt.callLater(customizeTest)
            else if (s === "play") playSoon.start()
            else if (s.startsWith("set:")) { const kv = s.slice(4).split("="); Core.setSetting(kv[0], kv[1] === "true" ? true : kv[1] === "false" ? false : kv[1]) }
            else if (s.startsWith("source:")) Library.source = s.slice(7)
        }
    }

    /// `--open customize-test` (with a scratch --support-dir): exercises the
    /// customize store and the resize rules, one "customize:" line per check.
    function customizeTest() {
        const out = []
        const check = (name, ok, detail) => out.push("customize: " + (ok ? "pass " : "FAIL ") + name + (detail ? " · " + detail : ""))
        const order = () => JSON.stringify(Customize.storedLayout.columns.map(c => c.panes))
        Customize.resetAll()
        const start = order()

        Customize.move("playlists", { stack: false, index: 0 })
        check("move to a new column", order() === JSON.stringify([["playlists"], ["nowPlaying", "browse"], ["library"], ["lyrics"]]), order())
        Customize.move("lyrics", { stack: true, column: 2, index: 1 })
        check("stack below the library", order() === JSON.stringify([["playlists"], ["nowPlaying", "browse"], ["library", "lyrics"]]), order())
        Customize.undo()
        check("undo", order() === JSON.stringify([["playlists"], ["nowPlaying", "browse"], ["library"], ["lyrics"]]), order())
        Customize.undo()
        check("undo to the start", order() === start, order())
        Customize.redo()
        check("redo", order() === JSON.stringify([["playlists"], ["nowPlaying", "browse"], ["library"], ["lyrics"]]), order())
        Customize.resetLayout()

        // A scroll's worth of edits is one undo step.
        const steps = Customize.undoStack.length
        for (let i = 0; i < 5; i++) Customize.edit(["sectionLabels", "railRows"], "size", s => { s.sizeScale = (s.sizeScale || 1) + 0.05 })
        check("edits coalesce", Customize.undoStack.length === steps + 1 && Math.abs(Customize.storedStyle("sectionLabels").sizeScale - 1.25) < 1e-9,
              "steps " + (Customize.undoStack.length - steps))
        Customize.edit(["sectionLabels", "libraryPanel"], "", s => { s.weight = "bold" })
        check("edits stay in the first kind", Customize.storedStyle("sectionLabels").weight === "bold" && Customize.storedStyle("libraryPanel").weight === undefined)
        Customize.copyStyle("sectionLabels")
        Customize.pasteStyle(["libraryTitle", "browsePanel"])
        check("paste onto the same kind", Customize.storedStyle("libraryTitle").sizeScale > 1.2 && Customize.storedStyle("browsePanel").sizeScale === undefined)
        Customize.reset(["sectionLabels", "railRows", "libraryTitle"])
        check("reset", Customize.storedStyle("sectionLabels").sizeScale === undefined)

        // Resize rules on the frames on screen.
        overlay.refreshFrames()
        const frames = overlay.paneFrames()
        const rules = overlay.resizeRules
        const edges = rules.movableEdges("browse", Customize.layout, frames)
        check("browse edges", JSON.stringify(edges) === JSON.stringify({ horizontal: ["trailing"], vertical: ["top"] }), JSON.stringify(edges))
        const s = { pane: "browse", horizontal: null, vertical: "top", frames: frames, layout: Customize.layout, gap: Skin.gap }
        const r = rules.apply(s, 0, -100, false)
        const w = r.layout.columns[0].weights
        check("height trade", Math.round(w.browse - frames.browse.height) === 100 && Math.round(w.nowPlaying + w.browse) === Math.round(frames.nowPlaying.height + frames.browse.height),
              JSON.stringify(w))
        const tiny = rules.apply(s, 0, 2000, false)
        check("minimum height", tiny.layout.columns[0].weights.browse === 80, tiny.layout.columns[0].weights.browse)
        const ws = { pane: "playlists", horizontal: "leading", vertical: null, frames: frames, layout: Customize.layout, gap: Skin.gap }
        const wr = rules.apply(ws, -40, 0, false)
        check("width from the leading edge", wr.layout.columns[3].width === Math.round(frames.playlists.width + 40), wr.layout.columns[3].width)
        const wide = rules.apply(ws, -5000, 0, false)
        check("width keeps the library's minimum", wide.layout.columns[3].width <= 560, wide.layout.columns[3].width)
        // Snap: the playlists edge lands on the sidebar's width.
        const target = frames.playlists.width - frames.nowPlaying.width
        const snapped = rules.apply(ws, target + 3, 0, true)
        check("width snaps to another column", snapped.layout.columns[3].width === Math.round(frames.nowPlaying.width) && snapped.guides.length === 1,
              snapped.layout.columns[3].width + " guides " + snapped.guides.length)
        Customize.commitLayout(wr.layout)
        check("commit layout", Customize.storedLayout.columns[3].width === wr.layout.columns[3].width)

        // Workspaces and interchange.
        const id = Customize.saveWorkspace("Test")
        check("save workspace", Customize.activeWorkspaceID === id && Customize.workspaces.length === 1)
        Customize.resetLayout()
        check("an edit leaves the workspace", Customize.activeWorkspaceID === "")
        Customize.applyWorkspace(id)
        check("apply workspace", Customize.storedLayout.columns[3].width === wr.layout.columns[3].width && Customize.activeWorkspaceID === id)
        const text = Customize.exportText()
        Customize.resetAll()
        check("import", Customize.importText(text) && Customize.storedLayout.columns[3].width === wr.layout.columns[3].width)
        check("import refuses other files", !Customize.importText("{\"format\":\"other\"}"))
        Customize.deleteWorkspace(id)
        Customize.resetAll()
        Customize.setPeek(true)
        check("peek shows the original", Customize.layout === Core.standardLayout || JSON.stringify(Customize.layout) === JSON.stringify(Core.standardLayout))
        Customize.setPeek(false)
        for (const line of out) console.warn(line)
        console.warn("customize: " + out.filter(l => l.indexOf("pass") >= 0).length + "/" + out.length)
    }

    Shortcut { sequence: "Ctrl+Shift+C"; context: Qt.ApplicationShortcut; onActivated: Customize.active = !Customize.active }
    Shortcut { sequence: "Ctrl+Z"; enabled: Customize.active; onActivated: Customize.undo() }
    Shortcut { sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]; enabled: Customize.active; onActivated: Customize.redo() }
}
