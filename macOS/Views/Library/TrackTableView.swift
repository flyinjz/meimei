import SwiftUI
import AppKit

/// What the library table can ask its host to do.
struct TrackTableActions {
    /// Plays one track within the list in the order it's shown (sorted as the table is).
    var play: (Track, [Track]) -> Void
    /// Plays exactly these tracks, in order.
    var playTracks: ([Track]) -> Void
    var playNext: ([Track]) -> Void
    var addToQueue: ([Track]) -> Void
    var setLiked: (Set<UUID>, Bool) -> Void
    var showAlbum: (Track) -> Void
    var getInfo: (Track) -> Void
    var refreshFromFile: (Set<UUID>) -> Void
    var addToPlaylist: ([UUID], UUID) -> Void
    var newPlaylist: ([UUID]) -> Void
    var removeFromPlaylist: (Set<UUID>) -> Void
    var removeFromLibrary: (Set<UUID>) -> Void
    var moveInPlaylist: ([UUID], Int) -> Void
}

struct TrackTableConfiguration: Equatable {
    var columns: [TrackColumnKind]
    var groupBy: TableGroupMode
    var rowHeight: CGFloat
    var fontSize: CGFloat
    var gridLines: Bool
    var alternatingRows: Bool
    var hiResBadge: Bool
    var playOnSingleClick: Bool
    var fontFamily: AppFontFamily
    var header = TableHeaderLook()
}

/// The column header's look, from customize mode's "table header" and
/// "table header labels". No fill by default: the panel shows through,
/// with one divider underneath.
struct TableHeaderLook: Equatable {
    static let defaultHeight: CGFloat = 28

    var fill: UInt32?
    var fillOpacity: Double = 0.5
    var border: UInt32?
    var borderWidth: CGFloat = 1
    var borderSides: BorderSides = [.bottom]
    var height: CGFloat = defaultHeight
    var textColor: UInt32?
    var textOpacity: Double = 1
    var family: AppFontFamily?
    var sizeScale: CGFloat = 1
    var weight: TextWeight?
    var tracking: CGFloat = 0
    var shadow = false

    init() {}

    init(panel: ElementStyle, text: ElementStyle, family: AppFontFamily) {
        fill = panel.fill
        fillOpacity = panel.fillOpacity ?? 0.5
        border = panel.border
        borderWidth = CGFloat(panel.borderWidth ?? 1)
        borderSides = panel.border == nil ? [.bottom] : (panel.borderSides ?? .all)
        height = CGFloat(panel.height ?? Double(Self.defaultHeight))
        textColor = text.color
        textOpacity = text.opacity ?? 1
        self.family = text.font
        sizeScale = CGFloat(text.sizeScale ?? 1)
        weight = text.weight
        tracking = CGFloat(text.tracking ?? 0)
        shadow = text.shadow ?? false
    }
}

/// The dense, sortable, native track list (an `NSTableView`).
struct TrackTableView: NSViewRepresentable {
    var tracks: [Track]
    /// Identifies the list being shown; changing it clears any column sort so
    /// a playlist opens in its own order.
    var sourceID: String
    @Binding var selection: Set<UUID>
    var skin: Skin
    var configuration: TrackTableConfiguration
    var nowPlayingID: UUID?
    /// When set, rows can be dragged to reorder this manual playlist.
    var reorderablePlaylist: UUID?
    var playlists: [Playlist]
    var actions: TrackTableActions

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackNSTableView()
        table.coordinator = context.coordinator
        table.headerView = ThemedHeaderView()
        // Overlay scrollers need no corner piece; the default one is system gray.
        table.cornerView = nil
        table.allowsMultipleSelection = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.gridStyleMask = []
        table.focusRingType = .none
        table.usesAlternatingRowBackgroundColors = false
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap

        let scroll = PocketlessScrollView()
        scroll.documentView = table
        // No scroll bars anywhere in i2s; wheel, trackpad and keyboard scroll as before.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        // The window has a full-size content view; don't let AppKit pad the
        // table down for a titlebar it isn't under.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()

        context.coordinator.table = table
        context.coordinator.update(from: self)
        table.autosaveName = "MeimeiTrackTable"
        table.autosaveTableColumns = true
        // The # column used to default to 36 pt; a saved width still at that
        // default moves to the tighter one (a width the user dragged stays).
        if let number = table.tableColumn(withIdentifier: .init("track")), (35...37).contains(number.width) {
            number.width = 30
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The list always fills what it's offered; answering directly spares
    /// SwiftUI an Auto Layout fitting pass over the scroll view per update.
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var parent: TrackTableView?
        private var rows: [LibraryRow] = []
        /// The tracks in the order the table shows them.
        private var shownOrder: [Track] = []
        /// Each track's row, for selection and targeted reloads.
        private var rowIndexByID: [UUID: Int] = [:]
        private var sourceTracks: [Track] = []
        private var sourceID = ""
        private var skin: Skin?
        private var colors: TableColors?
        private var configuration: TrackTableConfiguration?
        private var nowPlayingID: UUID?
        private var isApplyingSelection = false
        private var menuTargets: [Track] = []

        func update(from view: TrackTableView) {
            parent = view
            guard let table else { return }

            if view.sourceID != sourceID {
                sourceID = view.sourceID
                if !table.sortDescriptors.isEmpty { table.sortDescriptors = [] }
                table.scrollRowToVisible(0)
            }

            var needsReload = false
            // Only the list's contents changed (not columns, look, or grouping).
            var contentsOnly = true
            if view.configuration != configuration {
                contentsOnly = false
                let old = configuration
                configuration = view.configuration
                applyColumns(view.configuration.columns)
                applyHeader(view.configuration.header)
                table.rowHeight = view.configuration.rowHeight
                table.gridStyleMask = view.configuration.gridLines ? [.solidVerticalGridLineMask] : []
                needsReload = needsReload || old?.groupBy != view.configuration.groupBy || old != nil
            }
            if view.skin != skin {
                contentsOnly = false
                skin = view.skin
                applyTheme(view.skin)
                needsReload = true
            }
            if view.tracks != sourceTracks {
                if !needsReload, let changed = patchableRows(from: view.tracks) {
                    // Same tracks in the same places: redraw just the rows that changed.
                    sourceTracks = view.tracks
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
                } else {
                    sourceTracks = view.tracks
                    needsReload = true
                }
            }

            if needsReload {
                nowPlayingID = view.nowPlayingID
                rebuildRows()
                if contentsOnly, configuration?.groupBy == TableGroupMode.none {
                    refreshInPlace()
                } else {
                    table.reloadData()
                }
            } else if view.nowPlayingID != nowPlayingID {
                let previous = nowPlayingID
                nowPlayingID = view.nowPlayingID
                let changed = IndexSet([previous, view.nowPlayingID].compactMap { $0.flatMap { rowIndexByID[$0] } })
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
            }
            applySelection(view.selection)
        }

        private func rebuildRows() {
            let sorted = Self.sorted(sourceTracks, by: table?.sortDescriptors ?? [])
            rows = LibraryRow.build(from: sorted, groupBy: configuration?.groupBy ?? .none)
            // Playback continues in the order on screen, not the source order.
            shownOrder = rows.compactMap(\.track)
            var index: [UUID: Int] = [:]
            index.reserveCapacity(rows.count)
            for (i, row) in rows.enumerated() { if let id = row.track?.id { index[id] = i } }
            rowIndexByID = index
            // Variable row heights (asked per row, for every row) only when
            // group headers need them; re-setting the delegate re-reads that.
            let grouped = configuration?.groupBy != TableGroupMode.none
            if grouped != asksRowHeights, let table {
                asksRowHeights = grouped
                table.delegate = nil
                table.delegate = self
            }
        }

        private var asksRowHeights = true

        /// A new list in an ungrouped table: the row views on screen are
        /// reconfigured where they are. `reloadData` would detach every one
        /// from the window and attach new ones, which is most of the cost of
        /// filtering or switching views in a big library.
        private func refreshInPlace() {
            guard let table else { return }
            table.noteNumberOfRowsChanged()
            let columns = table.tableColumns
            table.enumerateAvailableRowViews { rowView, row in
                guard self.rows.indices.contains(row) else { return }
                if let rowView = rowView as? ThemedRowView, case .track(_, let stripe) = self.rows[row] {
                    rowView.kind = stripe && (self.configuration?.alternatingRows ?? true) ? .alternate : .plain
                }
                for (c, column) in columns.enumerated() {
                    guard let cell = rowView.view(atColumn: c) as? TrackCell else { continue }
                    self.configure(cell, row: row, column: column)
                }
            }
        }

        private func configure(_ cell: TrackCell, row: Int, column: NSTableColumn) {
            guard let colors, let configuration, let track = rows[row].track else { return }
            cell.configure(track: track, column: column.identifier.rawValue, playing: track.id == nowPlayingID, colors: colors,
                           fontSize: configuration.fontSize, family: configuration.fontFamily, hiResBadge: configuration.hiResBadge)
        }

        override func responds(to selector: Selector!) -> Bool {
            if selector == #selector(NSTableViewDelegate.tableView(_:heightOfRow:)) { return asksRowHeights }
            return super.responds(to: selector)
        }

        /// When `tracks` holds the same tracks in the same order and nothing
        /// that places them (sort key, group, header totals) changed, patches
        /// those rows in place and returns them; otherwise nil.
        private func patchableRows(from tracks: [Track]) -> IndexSet? {
            guard tracks.count == sourceTracks.count else { return nil }
            let key = table?.sortDescriptors.first?.key
            let groupBy = configuration?.groupBy ?? .none
            var changed = IndexSet()
            for i in tracks.indices {
                let new = tracks[i], old = sourceTracks[i]
                guard new.id == old.id else { return nil }
                guard new != old else { continue }
                if let key, !Self.sortKeyUnchanged(old, new, key) { return nil }
                if groupBy != .none, !Self.groupUnchanged(old, new, groupBy) { return nil }
                guard let row = rowIndexByID[new.id], case .track(_, let stripe) = rows[row] else { return nil }
                rows[row] = .track(new, stripe: stripe)
                changed.insert(row)
            }
            return changed
        }

        private static func sortKeyUnchanged(_ a: Track, _ b: Track, _ key: String) -> Bool {
            switch key {
            case "track": return a.trackNumber == b.trackNumber
            case "title": return a.title == b.title
            case "artist", "album":
                return a.artist == b.artist && a.album == b.album && a.albumArtist == b.albumArtist
                    && a.discNumber == b.discNumber && a.trackNumber == b.trackNumber && a.title == b.title
            case "year": return a.year == b.year
            case "time": return a.duration == b.duration
            case "genre": return a.genre == b.genre
            case "plays": return a.playCount == b.playCount
            case "format": return a.fileFormat == b.fileFormat
            case "quality": return a.sampleRate == b.sampleRate && a.bitDepth == b.bitDepth
            default: return false
            }
        }

        private static func groupUnchanged(_ a: Track, _ b: Track, _ groupBy: TableGroupMode) -> Bool {
            guard a.duration == b.duration else { return false } // header totals
            switch groupBy {
            case .none: return true
            case .album: return a.album == b.album
            case .albumArtist: return a.albumArtist == b.albumArtist
            case .genre: return a.genre == b.genre
            case .year: return a.year == b.year
            }
        }

        private func applyTheme(_ skin: Skin) {
            guard let table else { return }
            colors = TableColors(skin)
            table.gridColor = NSColor(skin.hairline)
            let background = skin.allowsBackdropBleed ? NSColor.clear : NSColor(skin.bgRow)
            table.backgroundColor = background
            table.enclosingScrollView?.drawsBackground = !skin.allowsBackdropBleed
            table.enclosingScrollView?.backgroundColor = background
            (table.superview as? NSClipView)?.drawsBackground = !skin.allowsBackdropBleed
            (table.headerView as? ThemedHeaderView)?.skin = skin
            table.headerView?.needsDisplay = true
        }

        private func applyHeader(_ look: TableHeaderLook) {
            guard let table, let header = table.headerView as? ThemedHeaderView else { return }
            header.look = look
            if header.frame.height != look.height {
                header.frame.size.height = look.height
                table.enclosingScrollView?.tile()
            }
            header.needsDisplay = true
        }

        /// Adds and removes columns to match the settings, keeping the user's
        /// widths and any order they dragged columns into.
        private func applyColumns(_ kinds: [TrackColumnKind]) {
            guard let table else { return }
            let wanted = ["title"] + kinds.map(\.rawValue)
            for column in table.tableColumns where !wanted.contains(column.identifier.rawValue) {
                table.removeTableColumn(column)
            }
            var added = false
            defer { if added { table.sizeToFit() } }
            let canonical = ["track", "title"] + TrackColumnKind.allCases.filter { $0 != .track }.map(\.rawValue)
            for id in canonical where wanted.contains(id) && table.tableColumn(withIdentifier: .init(id)) == nil {
                let spec = Self.columnSpec(id)
                let column = NSTableColumn(identifier: .init(id))
                column.headerCell = ThemedHeaderCell(textCell: spec.title)
                column.headerCell.alignment = spec.alignment
                column.width = spec.width
                column.minWidth = spec.minWidth
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
                table.addTableColumn(column)
                added = true
                // Place it where it belongs among the columns that exist.
                let position = canonical.prefix { $0 != id }.filter { table.tableColumn(withIdentifier: .init($0)) != nil }.count
                if let from = table.tableColumns.firstIndex(of: column), from != position {
                    table.moveColumn(from, toColumn: min(position, table.tableColumns.count - 1))
                }
            }
        }

        private static func columnSpec(_ id: String) -> (title: String, width: CGFloat, minWidth: CGFloat, alignment: NSTextAlignment) {
            switch id {
            case "track": return ("#", 30, 22, .right)
            case "title": return ("Title", 240, 100, .left)
            case "artist": return ("Artist", 170, 70, .left)
            case "album": return ("Album", 190, 70, .left)
            case "year": return ("Year", 48, 40, .right)
            case "time": return ("Time", 54, 44, .right)
            case "genre": return ("Genre", 110, 50, .left)
            case "plays": return ("Plays", 48, 40, .right)
            case "format": return ("Format", 76, 52, .left)
            case "quality": return ("Quality", 74, 52, .left)
            default: return (id.capitalized, 80, 40, .left)
            }
        }

        private func applySelection(_ ids: Set<UUID>) {
            guard let table, !isApplyingSelection else { return }
            let indexes = IndexSet(ids.compactMap { rowIndexByID[$0] })
            guard indexes != table.selectedRowIndexes else { return }
            isApplyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        func track(at row: Int) -> Track? {
            rows.indices.contains(row) ? rows[row].track : nil
        }

        var selectedTracks: [Track] {
            table?.selectedRowIndexes.compactMap { track(at: $0) } ?? []
        }

        static func sorted(_ tracks: [Track], by descriptors: [NSSortDescriptor]) -> [Track] {
            guard let first = descriptors.first, let key = first.key else { return tracks }
            let ranks = ["title", "artist", "album", "genre", "format"].contains(key)
                ? TextRanks.ranks(for: key, ascending: first.ascending, covering: tracks) : nil
            return TrackSort.sorted(tracks, key: key, ascending: first.ascending, ranks: ranks)
        }

        /// The text columns' orders (locale-aware, like Finder).
        nonisolated static func textOrder(_ key: String, _ a: Track, _ b: Track, _ asc: Bool) -> Bool {
            TrackSort.textOrder(key, a, b, asc)
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            rebuildRows()
            tableView.reloadData()
            tableView.headerView?.needsDisplay = true
            if let parent { applySelection(parent.selection) }
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].isHeader
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            track(at: row) != nil
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let base = configuration?.rowHeight ?? 21
            return rows.indices.contains(row) && rows[row].isHeader ? base + 12 : base
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let track = track(at: row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(TrackDrag.encode(track.id), forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard parent?.reorderablePlaylist != nil, info.draggingSource as? NSTableView === tableView,
                  tableView.sortDescriptors.isEmpty, configuration?.groupBy == TableGroupMode.none else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string).flatMap(TrackDrag.decode) }
            guard !ids.isEmpty, let parent else { return false }
            parent.actions.moveInPlaylist(ids, row)
            return true
        }

        // MARK: Cells

        /// Every row and cell view ever made. `reloadData` empties AppKit's
        /// reuse queue, so a full reload would otherwise build every visible
        /// row from scratch; views not in the table (no superview) and not
        /// in AppKit's queue (it was empty, or `makeView` would have
        /// returned one) are free to hand out again.
        private var rowPool: [ThemedRowView] = []
        private var cellPool: [TrackCell] = []

        private func reusable<V: NSView>(_ pool: inout [V], make: () -> V) -> V {
            if let free = pool.first(where: { $0.superview == nil }) { return free }
            let view = make()
            pool.append(view)
            return view
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = (tableView.makeView(withIdentifier: ThemedRowView.identifier, owner: nil) as? ThemedRowView)
                ?? reusable(&rowPool) { ThemedRowView() }
            view.identifier = ThemedRowView.identifier
            view.colors = colors
            switch rows.indices.contains(row) ? rows[row] : nil {
            case .header?:
                view.kind = .header
            case .track(_, let stripe)?:
                view.kind = stripe && (configuration?.alternatingRows ?? true) ? .alternate : .plain
            case nil:
                view.kind = .plain
            }
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let colors, let configuration else { return nil }
            let cell = (tableView.makeView(withIdentifier: TrackCell.identifier, owner: nil) as? TrackCell)
                ?? reusable(&cellPool) { TrackCell() }

            if case .header(let title, let detail) = rows[row] {
                cell.configureHeader(title: title, detail: detail, colors: colors, fontSize: configuration.fontSize, family: configuration.fontFamily)
                return cell
            }
            guard let column = tableColumn?.identifier.rawValue, let track = rows[row].track else { return nil }
            let playing = track.id == nowPlayingID
            cell.configure(track: track, column: column, playing: playing, colors: colors,
                           fontSize: configuration.fontSize, family: configuration.fontFamily, hiResBadge: configuration.hiResBadge)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, let parent, !isApplyingSelection else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { track(at: $0)?.id })
            isApplyingSelection = true
            parent.selection = ids
            isApplyingSelection = false
            if configuration?.playOnSingleClick == true, table.selectedRowIndexes.count == 1,
               NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .leftMouseDown,
               let row = table.selectedRowIndexes.first, let track = track(at: row) {
                parent.actions.play(track, shownOrder)
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard let track = track(at: sender.clickedRow) else { return }
            parent?.actions.play(track, shownOrder)
        }

        func playSelection() {
            let selected = selectedTracks
            guard let first = selected.first else { return }
            if selected.count > 1 { parent?.actions.playTracks(selected) } else { parent?.actions.play(first, shownOrder) }
        }

        func deleteSelection() {
            let ids = Set(selectedTracks.map(\.id))
            guard !ids.isEmpty, let parent else { return }
            if parent.reorderablePlaylist != nil {
                parent.actions.removeFromPlaylist(ids)
            } else {
                parent.actions.removeFromLibrary(ids)
            }
        }

        // MARK: Context menu

        /// The app menu for a right-click on `row`: it acts on the selection,
        /// selecting the clicked row first if it wasn't part of it.
        func presentMenu(forRow clicked: Int) {
            guard let table, let parent else { return }
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
            menuTargets = selectedTracks
            guard let first = menuTargets.first else { return }
            let many = menuTargets.count > 1
            let artists = Set(menuTargets.map(\.artist))
            let likeAll = menuTargets.contains { !$0.liked }
            let manual = parent.playlists.filter { !$0.isSmart }

            let playlists = MenuContent([
                MenuGroup(nil, [.action("New Playlist from Selection…", glyph: "plus") { [weak self] in self?.menuNewPlaylist() }]),
                MenuGroup(manual.isEmpty ? nil : "playlists", manual.map { playlist in
                    .action(playlist.name, glyph: "music.note.list") { [weak self] in
                        guard let self else { return }
                        self.parent?.actions.addToPlaylist(self.menuTargets.map(\.id), playlist.id)
                    }
                }),
            ])

            var remove: [MenuEntry] = []
            if parent.reorderablePlaylist != nil {
                remove.append(.action("Remove from Playlist", glyph: "minus.circle") { [weak self] in self?.menuRemoveFromPlaylist() })
            }
            remove.append(.action(many ? "Remove \(menuTargets.count) Tracks from Library…" : "Remove from Library…",
                                  glyph: "trash", detail: "⌫", destructive: true) { [weak self] in self?.menuRemoveFromLibrary() })

            let content = MenuContent(
                title: many ? "\(menuTargets.count) tracks" : first.title,
                subtitle: many ? (artists.count == 1 ? first.artist : "\(artists.count) artists")
                    : [first.artist, first.album].filter { !$0.isEmpty }.joined(separator: " · "),
                [
                    MenuGroup(nil, [
                        .action("Play", glyph: "play.fill", detail: "↩") { [weak self] in self?.menuPlay() },
                        .action("Play Next", glyph: "arrow.uturn.forward") { [weak self] in self?.menuPlayNext() },
                        .action("Add to Queue", glyph: "list.number") { [weak self] in self?.menuAddToQueue() },
                    ]),
                    MenuGroup(nil, [
                        .action(likeAll ? "Like" : "Unlike", glyph: likeAll ? "heart" : "heart.fill") { [weak self] in self?.menuToggleLiked() },
                        .submenu("Add to Playlist", glyph: "plus.square.on.square", playlists),
                    ] + (many ? [] : [
                        .action("Show Album", glyph: "opticaldisc") { [weak self] in self?.menuShowAlbum() },
                        .action("Get Info…", glyph: "info.circle") { [weak self] in self?.menuGetInfo() },
                    ])),
                    MenuGroup("file", [
                        .action("Refresh from File", glyph: "arrow.counterclockwise") { [weak self] in self?.menuRefresh() },
                        .action("Show in Finder", glyph: "arrow.up.forward") { [weak self] in self?.menuShowInFinder() },
                    ]),
                    MenuGroup(nil, remove),
                ])
            AppMenu.shared.present(content, at: NSEvent.mouseLocation)
        }

        private var targetIDs: Set<UUID> { Set(menuTargets.map(\.id)) }

        private func menuPlay() {
            guard let parent, let first = menuTargets.first else { return }
            if menuTargets.count > 1 {
                parent.actions.playTracks(menuTargets)
            } else {
                parent.actions.play(first, shownOrder)
            }
        }
        private func menuPlayNext() { parent?.actions.playNext(menuTargets) }
        private func menuAddToQueue() { parent?.actions.addToQueue(menuTargets) }
        private func menuToggleLiked() { parent?.actions.setLiked(targetIDs, menuTargets.contains { !$0.liked }) }
        private func menuShowAlbum() { menuTargets.first.map { parent?.actions.showAlbum($0) } }
        private func menuGetInfo() { menuTargets.first.map { parent?.actions.getInfo($0) } }
        private func menuRefresh() { parent?.actions.refreshFromFile(targetIDs) }
        private func menuNewPlaylist() { parent?.actions.newPlaylist(menuTargets.map(\.id)) }
        private func menuShowInFinder() {
            NSWorkspace.shared.activateFileViewerSelecting(menuTargets.map(\.url))
        }
        private func menuRemoveFromPlaylist() { parent?.actions.removeFromPlaylist(targetIDs) }
        private func menuRemoveFromLibrary() { parent?.actions.removeFromLibrary(targetIDs) }
    }
}

/// Locale-aware text comparison is the slow part of sorting a big list,
/// and filtering or switching views re-sorts. So the whole library is
/// ranked once per text column (ties share a rank) and any list of its
/// tracks sorts by those integers; a stable sort keeps tied tracks in the
/// list's order, exactly as sorting with the comparator would.
@MainActor
enum TextRanks {
    private static var cache: [String: (version: Int, ranks: [UUID: Int])] = [:]

    /// Each library track's place in the column's order (`ascending` as
    /// the comparator sees it: some columns keep album order either way).
    /// Dense ranks of `tracks` in the column's order; safe off the main thread.
    nonisolated static func compute(_ key: String, ascending: Bool, over tracks: [Track]) -> [UUID: Int] {
        TrackSort.ranks(key, ascending: ascending, over: tracks)
    }

    /// Keeps ranks computed elsewhere (the library warms them in the background).
    static func store(_ ranks: [UUID: Int], for key: String, ascending: Bool, version: Int) {
        cache[key + (ascending ? "+" : "-")] = (version, ranks)
    }

    static func ranks(for key: String, ascending: Bool, covering tracks: [Track]) -> [UUID: Int]? {
        let library = AppSession.shared.library
        // Small lists sort fast enough directly.
        guard tracks.count > 400 else { return nil }
        let cacheKey = key + (ascending ? "+" : "-")
        if let hit = cache[cacheKey], hit.version == library.tracksVersion {
            return tracks.allSatisfy({ hit.ranks[$0.id] != nil }) ? hit.ranks : nil
        }
        let ranks = compute(key, ascending: ascending, over: library.tracks)
        cache[cacheKey] = (library.tracksVersion, ranks)
        return tracks.allSatisfy({ ranks[$0.id] != nil }) ? ranks : nil
    }
}

/// Track ids on the drag pasteboard, as plain strings so SwiftUI drop
/// targets (playlists in the rail) can read them. Kept off the file-URL
/// type so dragging a row never looks like an import.
enum TrackDrag {
    private static let prefix = "meimei-track:"

    static func encode(_ id: UUID) -> String { prefix + id.uuidString }

    static func decode(_ string: String) -> UUID? {
        guard string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

/// Return plays the selection; Delete removes it.
private final class TrackNSTableView: NSTableView {
    weak var coordinator: TrackTableView.Coordinator?

    /// Right-click opens i2s's own menu instead of an NSMenu.
    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.presentMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
        return nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: coordinator?.playSelection()
        case 51, 117: coordinator?.deleteSelection()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Row and cell views

/// The skin's colors as AppKit colors, converted once per theme rather
/// than per cell and per row drawn while scrolling.
final class TableColors {
    let bgRow, bgRowAlt, bgRaised, selection, accent, textPrimary, textSecondary, textTertiary: NSColor
    let opaqueRows: Bool

    init(_ skin: Skin) {
        bgRow = NSColor(skin.bgRow)
        bgRowAlt = NSColor(skin.bgRowAlt)
        bgRaised = NSColor(skin.bgRaised)
        selection = NSColor(skin.selection)
        accent = NSColor(skin.accent)
        textPrimary = NSColor(skin.textPrimary)
        textSecondary = NSColor(skin.textSecondary)
        textTertiary = NSColor(skin.textTertiary)
        opaqueRows = !skin.allowsBackdropBleed
    }
}

/// Skin-colored rows: stripes, group headers, and the selection with an
/// accent cursor bar on its leading edge.
final class ThemedRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ThemedRow")
    enum Kind { case plain, alternate, header }

    var colors: TableColors? {
        didSet { if colors !== oldValue { needsDisplay = true } }
    }
    var kind: Kind = .plain {
        didSet { if kind != oldValue { needsDisplay = true } }
    }

    private var pillRect: NSRect { bounds.insetBy(dx: 1, dy: kind == .header ? 1 : 0) }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let colors else { return }
        if colors.opaqueRows {
            colors.bgRow.setFill()
            dirtyRect.fill()
        }
        switch kind {
        case .header: colors.bgRaised.setFill()
        case .alternate: colors.bgRowAlt.setFill()
        case .plain: return
        }
        pillRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let colors else { return }
        colors.selection.withAlphaComponent(isEmphasized ? 0.7 : 0.42).setFill()
        pillRect.fill(using: .sourceOver)
        // A cursor bar down the leading edge.
        colors.accent.setFill()
        NSRect(x: 1, y: 0, width: 2, height: bounds.height).fill()
    }
}

/// One table cell: a label, plus an optional leading glyph (now playing)
/// or trailing badge (Hi-Res), created only when first needed. Properties
/// are written only when they change, so reuse while scrolling is cheap.
final class TrackCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TrackCell")

    private let label = NSTextField(labelWithString: "")
    private var glyph: NSTextField?
    private var badge: NSTextField?
    private var labelHeight: CGFloat = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var showsGlyph = false
    private var showsBadge = false
    private var showedHeader = false

    private func makeField() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = true
        addSubview(field)
        return field
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        // Clear of the row highlight's edges.
        var labelFrame = bounds.insetBy(dx: 6, dy: 0)
        if showsGlyph, let glyph {
            let gh = glyph.font.map(Self.lineHeight) ?? h
            glyph.frame = NSRect(x: max(0, bounds.width - 22), y: (h - gh) / 2, width: 20, height: gh)
            labelFrame.size.width = 0
        }
        if showsBadge, let badge {
            let w: CGFloat = 11
            let bh = badge.font.map(Self.lineHeight) ?? h
            badge.frame = NSRect(x: bounds.width - w - 4, y: (h - bh) / 2, width: w, height: bh)
            labelFrame.size.width -= w + 6
        }
        label.frame = NSRect(x: labelFrame.minX, y: (h - labelHeight) / 2, width: max(0, labelFrame.width), height: labelHeight)
    }

    /// A single line's height in `font`, as the label lays it out.
    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 1
    }

    private func set(font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        if label.font !== font {
            label.font = font
            labelHeight = Self.lineHeight(font)
            needsLayout = true
        }
        if label.textColor !== color { label.textColor = color }
        if label.alignment != alignment { label.alignment = alignment }
    }

    func configure(track: Track, column: String, playing: Bool, colors: TableColors, fontSize: CGFloat, family: AppFontFamily, hiResBadge: Bool) {
        var text = ""
        var alignment = NSTextAlignment.left
        var numeric = false
        switch column {
        case "track": text = track.trackNumber.map(String.init) ?? ""; alignment = .right; numeric = true
        case "title": text = track.title
        case "artist": text = track.artist
        case "album": text = track.album
        case "year": text = track.year.map(String.init) ?? ""; alignment = .right; numeric = true
        case "time": text = track.formattedDuration; alignment = .right; numeric = true
        case "genre": text = track.genre
        case "plays": text = track.playCount > 0 ? "\(track.playCount)" : ""; alignment = .right; numeric = true
        case "format": text = track.fileFormat
        case "quality": text = Self.quality(track); numeric = true
        default: break
        }

        let wantsGlyph = playing && column == "track"
        if wantsGlyph != showsGlyph { showsGlyph = wantsGlyph; needsLayout = true }
        if wantsGlyph {
            let glyph = self.glyph ?? makeField()
            self.glyph = glyph
            glyph.stringValue = Glyph.glyph("speaker.wave.2.fill")
            glyph.font = IconTheme.font(fontSize)
            glyph.textColor = colors.accent
            glyph.setAccessibilityLabel("Now playing")
        }
        glyph?.isHidden = !wantsGlyph

        // Quality icon: hi-res in the accent, other lossless files quieter.
        let wantsBadge = hiResBadge && column == "format" && track.isLossless
        if wantsBadge != showsBadge { showsBadge = wantsBadge; needsLayout = true }
        if wantsBadge {
            let badge = self.badge ?? makeField()
            self.badge = badge
            // A small mark, not a sticker: three-quarter size and toned down.
            badge.font = IconTheme.font(fontSize * 0.75)
            badge.stringValue = Glyph.glyph(track.isHiRes ? "badge.hires" : "badge.lossless")
            badge.textColor = track.isHiRes ? colors.accent.withAlphaComponent(0.7) : colors.textTertiary.withAlphaComponent(0.55)
            badge.toolTip = track.isHiRes ? "Hi-Res lossless" : "Lossless"
        }
        badge?.isHidden = !wantsBadge

        if label.isHidden != wantsGlyph { label.isHidden = wantsGlyph }
        if showedHeader {
            // Back from a group header's attributed text: restyle fully.
            showedHeader = false
            label.stringValue = text
            label.font = nil
            label.textColor = nil
        } else if label.stringValue != text {
            label.stringValue = text
        }
        let weight: NSFont.Weight = playing && column == "title" ? .semibold : .regular
        let color = playing ? colors.accent : (column == "title" ? colors.textPrimary : colors.textSecondary)
        set(font: AppFont.ns(numeric ? fontSize - 0.5 : fontSize, weight: weight, family: family), color: color, alignment: alignment)
    }

    func configureHeader(title: String, detail: String, colors: TableColors, fontSize: CGFloat, family: AppFontFamily) {
        showsGlyph = false
        showsBadge = false
        glyph?.isHidden = true
        badge?.isHidden = true
        label.isHidden = false
        label.alignment = .left
        let titleFont = AppFont.ns(fontSize + 0.5, weight: .semibold, family: family)
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: colors.textPrimary
        ])
        text.append(NSAttributedString(string: "   " + detail, attributes: [
            .font: AppFont.ns(fontSize - 1, family: family),
            .foregroundColor: colors.textTertiary
        ]))
        label.attributedStringValue = text
        showedHeader = true
        labelHeight = Self.lineHeight(titleFont)
        needsLayout = true
    }

    private static func quality(_ t: Track) -> String {
        let khz = t.sampleRate / 1000
        let rate = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
        return t.isLossless ? "\(t.bitDepth)/\(rate)" : (t.estimatedBitrateKbps > 0 ? "\(t.estimatedBitrateKbps)k" : rate)
    }
}

/// macOS 26 puts a frosted "scroll pocket" and a backdrop behind a table's
/// header, drawn in the system's gray whatever the theme. Meimei draws its
/// own header, so those layers are hidden (and stay hidden: AppKit re-adds
/// them on layout). The header itself lives in a separate clip view.
final class PocketlessScrollView: NSScrollView {
    /// Rows start below the header instead of scrolling under it, so the
    /// header needs no fill and shows the panel's own surface.
    override func tile() {
        super.tile()
        guard let header = subviews.first(where: { ($0 as? NSClipView)?.documentView is NSTableHeaderView }) else { return }
        let h = header.frame.height
        var frame = contentView.frame
        if frame.minY < h {
            frame.size.height -= h - frame.minY
            frame.origin.y = h
            contentView.frame = frame
        }
        // AppKit also insets the rows by the header's height, for the
        // overlapping layout this replaces; that would leave a gap.
        if contentView.automaticallyAdjustsContentInsets || contentView.contentInsets.top != 0 {
            contentView.automaticallyAdjustsContentInsets = false
            contentView.contentInsets = NSEdgeInsets()
        }
        if contentView.bounds.minY < 0 {
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    override func layout() {
        super.layout()
        hideSystemHeaderBackground()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideSystemHeaderBackground()
    }

    private func hideSystemHeaderBackground() {
        for view in subviews {
            let name = NSStringFromClass(type(of: view))
            if name.contains("Pocket") || name.hasSuffix("BackdropView") {
                if !view.isHidden { view.isHidden = true }
            } else if let clip = view as? NSClipView, clip.documentView is NSTableHeaderView, clip.drawsBackground {
                clip.drawsBackground = false
            }
        }
    }
}

/// Holds the skin and look for its header cells, and draws what spans the
/// whole width: the optional fill and the borders. AppKit copies cells
/// bitwise, which over-releases any Swift reference stored on them, so
/// cells keep none.
final class ThemedHeaderView: NSTableHeaderView {
    var skin: Skin?
    var look = TableHeaderLook()

    override func draw(_ dirtyRect: NSRect) {
        if let fill = look.fill {
            NSColor(Color(hex: fill)).withAlphaComponent(look.fillOpacity).setFill()
            bounds.fill()
        }
        if draggedColumn >= 0 {
            // AppKit draws a column being dragged itself.
            super.draw(dirtyRect)
        } else if let table = tableView {
            // Just the cells: AppKit's own drawing adds a system-styled
            // filler past the last column.
            for i in table.tableColumns.indices {
                let rect = headerRect(ofColumn: i)
                if rect.intersects(dirtyRect) { table.tableColumns[i].headerCell.draw(withFrame: rect, in: self) }
            }
        }
        guard let skin else { return }
        (look.border.map { NSColor(Color(hex: $0)) } ?? NSColor(skin.hairline)).setFill()
        let w = look.border == nil ? 1 : look.borderWidth
        let b = bounds
        // The header view is flipped: y grows downward.
        if look.borderSides.contains(.bottom) { NSRect(x: b.minX, y: b.maxY - w, width: b.width, height: w).fill() }
        if look.borderSides.contains(.top) { NSRect(x: b.minX, y: b.minY, width: b.width, height: w).fill() }
        if look.borderSides.contains(.leading) { NSRect(x: b.minX, y: b.minY, width: w, height: b.height).fill() }
        if look.borderSides.contains(.trailing) { NSRect(x: b.maxX - w, y: b.minY, width: w, height: b.height).fill() }
    }
}

/// Column headers drawn in the skin: labels only, on no fill (the header
/// view draws any fill and the divider).
final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let header = controlView as? ThemedHeaderView, let skin = header.skin else { return super.draw(withFrame: cellFrame, in: controlView) }
        let look = header.look

        let table = header.tableView
        let column = table?.tableColumns.first { $0.headerCell === self }
        let sorted = table?.sortDescriptors.first.flatMap { d in column.map { d.key == $0.identifier.rawValue ? d.ascending : nil } } ?? nil

        let base: NSColor = look.textColor.map { NSColor(Color(hex: $0)) } ?? NSColor(sorted != nil ? skin.textPrimary : skin.textTertiary)
        let weight: NSFont.Weight = switch look.weight {
        case .light?: .regular
        case .bold?: .bold
        default: .semibold
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: AppFont.ns(10.5 * look.sizeScale, weight: weight, family: look.family ?? AppFont.family),
            .foregroundColor: base.withAlphaComponent(base.alphaComponent * look.textOpacity),
            .kern: look.tracking
        ]
        if look.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            attributes[.shadow] = shadow
        }
        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let size = title.size()
        let inset = cellFrame.insetBy(dx: 7, dy: 0)
        var x = inset.minX
        if alignment == .right { x = inset.maxX - size.width - (sorted != nil ? 10 : 0) }
        title.draw(at: NSPoint(x: x, y: cellFrame.midY - size.height / 2))

        if let ascending = sorted {
            let arrow = NSAttributedString(string: ascending ? "▴" : "▾", attributes: [
                .font: AppFont.ns(9 * look.sizeScale),
                .foregroundColor: NSColor(skin.accent)
            ])
            let ax = alignment == .right ? inset.maxX - 8 : x + size.width + 4
            arrow.draw(at: NSPoint(x: ax, y: cellFrame.midY - arrow.size().height / 2))
        }
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}
