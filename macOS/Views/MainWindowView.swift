import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The main window: transport bar on top; now-playing rail, library,
/// lyrics, and collection rail in resizable panes; status bar below.
struct MainWindowView: View {
    @ObservedObject private var library = AppSession.shared.library
    @ObservedObject private var player = AppSession.shared.player
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings
    @ObservedObject private var customize = AppSession.shared.customize
    @ObservedObject private var draft = AppSession.shared.customize.draft
    private var lyrics: LyricsStore { AppSession.shared.lyrics }

    @State private var selection: Set<UUID> = []
    @State private var isDropTargeted = false
    @State private var editingTrack: Track?
    @State private var showingPalette = false
    @State private var showingDuplicates = false
    @State private var playlistEditor: PlaylistEditorRequest?
    @State private var pendingRemoval: RemovalRequest?
    @State private var dragOrigin: CGFloat?
    @State private var stackOrigin: [PaneID: Double]?
    /// A divider drag in progress, applied over the stored layout and saved
    /// once on release, so the drag doesn't churn the store (and every view
    /// that reads it) on each mouse move.
    @State private var liveWidth: (column: Int, width: Double)?
    @State private var liveWeights: (column: Int, weights: [PaneID: Double])?
    @Namespace private var paneSpace
    @Environment(\.openWindow) private var openWindow

    private var skin: Skin { settings.styled(theme.skin) }

    var body: some View {
        VStack(spacing: Corners.inset) {
            TitleStrip(settings: settings, skin: skin, onSearch: { showingPalette = true },
                       onCustomize: { withAnimation(.easeOut(duration: 0.2)) { customize.isActive.toggle() } })
            if settings.data.playerBarPosition == .top {
                playerBar
            }
            GeometryReader { proxy in
                panes(width: proxy.size.width)
            }
            if settings.data.playerBarPosition == .bottom {
                playerBar
            }
            if settings.data.showStatusBar {
                StatusBarView(
                    library: library,
                    visibleCount: library.albumKey == nil ? library.visibleTracks.count : library.tracks(inAlbum: library.albumKey ?? "").count,
                    selectedCount: selection.count,
                    skin: skin,
                    height: settings.data.density.statusBarHeight + 6,
                    useMonospaced: settings.data.useMonospacedNumbers,
                    showSelectionCount: settings.data.statusBarShowSelectionCount,
                    showScanProgress: settings.data.statusBarShowScanProgress
                )
            }
        }
        .padding(.horizontal, Corners.inset)
        .padding(.bottom, Corners.inset)
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: customizeSpace)
        .overlayPreferenceValue(CustomFramesKey.self) { frames in
            CustomizeLayer(frames: frames, store: customize, settings: settings, skin: skin)
        }
        .background {
            WindowBackdrop(style: settings.effectiveBackdrop(for: skin), skin: skin, artwork: theme.artworkImage,
                           glassTint: settings.data.glassTintStrength)
        }
        .foregroundStyle(skin.textPrimary)
        .font(AppFont.ui(12))
        .frame(minWidth: 960, minHeight: 620)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                Rectangle()
                    .fill(skin.accent.opacity(0.06))
                    .overlay(Rectangle().strokeBorder(skin.accent, lineWidth: 2))
                    .padding(Corners.inset)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if showingPalette {
                CommandPaletteView(
                    library: library,
                    player: player,
                    skin: skin,
                    onDismiss: { showingPalette = false },
                    onOpenAlbum: { library.albumKey = $0.key },
                    onCommand: runPaletteCommand
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showingPalette)
        .navigationTitle("i2s")
        .background(WindowChromeGuard(minSize: NSSize(width: 960, height: 620),
                                      transparent: settings.effectiveBackdrop(for: skin) == .translucent))
        .onAppear(perform: onAppear)
        .onReceive(NotificationCenter.default.publisher(for: WindowRequest.notification)) { note in
            WindowRequest(note).map(handle)
        }
        .onChange(of: library.source) { newValue in
            selection.removeAll()
            if settings.data.rememberLastView { DefaultsStore.save(newValue, key: Self.lastSourceKey) }
        }
        .onChange(of: library.albumKey) { _ in selection.removeAll() }
        .onChange(of: library.pendingDuplicates.isEmpty) { empty in
            if !empty { showingDuplicates = true }
        }
        .sheet(item: $editingTrack) { track in
            MetadataEditorView(library: library, lyrics: AppSession.shared.lyrics, skin: skin, trackID: track.id) {
                editingTrack = nil
            }
        }
        .sheet(isPresented: $showingDuplicates) {
            DuplicateReviewView(library: library, skin: skin) { showingDuplicates = false }
        }
        .sheet(item: $playlistEditor) { request in
            PlaylistEditorSheet(library: library, existingID: request.existingID, initialTrackIDs: request.trackIDs, skin: skin) {
                playlistEditor = nil
            }
        }
        .sheet(item: $pendingRemoval) { request in
            ConfirmDialog(
                title: request.ids.count > 1 ? "Remove \(request.ids.count) tracks from the library?" : "Remove this track from the library?",
                message: "The files stay where they are on disk. You can add them again any time.",
                confirmTitle: "Remove",
                skin: skin,
                onConfirm: {
                    library.removeTracks(request.ids)
                    selection.subtract(request.ids)
                    pendingRemoval = nil
                },
                onCancel: { pendingRemoval = nil }
            )
        }
    }

    // MARK: - Layout

    private var playerBar: some View {
        PlayerBarView(
            player: player,
            engine: player.engine,
            settings: settings,
            skin: skin,
            onOpenMiniPlayer: { openWindow(id: "mini-player") }
        )
    }

    // MARK: - Panes

    /// The panes in the user's layout: columns of stacked panes. The column
    /// holding the library stretches; the gaps between columns and between
    /// stacked panes drag to resize. Moved panes fly to their new place.
    private func panes(width: CGFloat) -> some View {
        var layout = draft.layout ?? customize.layout
        if let liveWidth, layout.columns.indices.contains(liveWidth.column) {
            layout.columns[liveWidth.column].width = liveWidth.width
        }
        if let liveWeights, layout.columns.indices.contains(liveWeights.column) {
            layout.columns[liveWeights.column].weights.merge(liveWeights.weights) { $1 }
        }
        let columns: [(index: Int, column: PaneColumn, panes: [PaneID])] = layout.columns.enumerated().compactMap { i, c in
            let visible = c.panes.filter { isVisible($0, in: layout) }
            return visible.isEmpty ? nil : (i, c, visible)
        }
        // Fixed columns shrink together when they'd crowd the library below
        // its minimum, so the layout always fits the window.
        let gaps = CGFloat(max(0, columns.count - 1)) * Corners.inset
        let fixed = columns.filter { !isFlexible($0.column) }.reduce(0) { $0 + columnWidth($1.column, total: width) }
        let room = width - Self.libraryMinWidth - gaps
        let fit = fixed > room && fixed > 0 ? max(0.4, room / fixed) : 1
        // The library's column gets exactly what's left.
        let libraryWidth = max(Self.libraryMinWidth, width - gaps - columns.filter { !isFlexible($0.column) }
            .reduce(0) { $0 + (columnWidth($1.column, total: width) * fit).rounded() })
        return HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.column.id) { position, entry in
                if position > 0 {
                    columnHandle(left: columns[position - 1], right: entry, total: width)
                }
                columnView(entry.index, entry.column, entry.panes, total: width, fit: fit, flexibleWidth: libraryWidth)
            }
        }
    }

    private static let libraryMinWidth: CGFloat = 360

    private func isVisible(_ pane: PaneID, in layout: PaneLayout) -> Bool {
        if layout.hidden.contains(pane) { return false }
        switch pane {
        case .library: return true
        case .nowPlaying, .browse: return settings.data.showSidebar
        case .lyrics: return settings.data.showLyrics
        case .playlists: return settings.data.showAlbumGrid
        }
    }

    private func isFlexible(_ column: PaneColumn) -> Bool { column.panes.contains(.library) }

    private func columnWidth(_ column: PaneColumn, total: CGFloat) -> CGFloat {
        if let w = column.width { return CGFloat(w) }
        switch column.panes.first {
        case .lyrics?: return CGFloat(settings.data.lyricsPanelWidth)
        case .playlists?: return CGFloat(settings.data.collectionRailWidth)
        default: return sidebarWidth(for: total)
        }
    }

    @ViewBuilder
    private func columnView(_ index: Int, _ column: PaneColumn, _ visible: [PaneID], total: CGFloat, fit: CGFloat,
                            flexibleWidth: CGFloat) -> some View {
        let stack = GeometryReader { geo in
            WeightedStack {
                ForEach(Array(visible.enumerated()), id: \.element) { i, pane in
                    if i > 0 {
                        stackHandle(column: index, above: visible[i - 1], below: pane, visible: visible, weights: column, size: geo.size)
                    }
                    paneView(pane, width: geo.size.width)
                        .layoutValue(key: PaneWeight.self, value: column.weight(pane))
                }
            }
        }
        if isFlexible(column) {
            stack.frame(width: flexibleWidth)
        } else {
            stack.frame(width: (columnWidth(column, total: total) * fit).rounded())
        }
    }

    @ViewBuilder
    private func paneView(_ pane: PaneID, width: CGFloat) -> some View {
        Group {
            switch pane {
            case .nowPlaying:
                NowPlayingPanelView(
                    player: player,
                    skin: skin,
                    artworkSize: width,
                    showFormatStrip: settings.data.showFormatStrip,
                    showSubtitle: settings.data.showNowPlayingSubtitle
                )
                .panelSurface(.nowPlayingPanel, skin: skin, fallback: skin.bgPanel)
            case .browse:
                SidebarView(library: library, skin: skin, density: settings.data.density)
                    .frame(maxHeight: .infinity)
                    .panelSurface(.browsePanel, skin: skin, fallback: skin.bgPanel)
            case .library:
                libraryColumn
                    .modifier(NavigationSlide(move: library.navigationMove))
                    .panelSurface(.libraryPanel, skin: skin, fallback: skin.bgRow, content: true)
            case .lyrics:
                LyricsPanelView(player: player, clock: player.engine.clock, lyrics: AppSession.shared.lyrics, skin: skin)
                    .panelSurface(.lyricsPanel, skin: skin, fallback: skin.bgPanel)
            case .playlists:
                CollectionRailView(
                    library: library,
                    settings: settings,
                    skin: skin,
                    onOpenSettings: { openSettings() },
                    onCreatePlaylist: { playlistEditor = PlaylistEditorRequest() },
                    onEditPlaylist: { playlistEditor = PlaylistEditorRequest(existingID: $0) },
                    onPlay: playPlaylist
                )
                .panelSurface(.collectionRail, skin: skin, fallback: skin.bgPanel)
            }
        }
        .matchedGeometryEffect(id: pane, in: paneSpace)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    /// The gap between two columns. Drags resize the fixed column beside
    /// it; the library's column takes up the difference.
    private func columnHandle(left: (index: Int, column: PaneColumn, panes: [PaneID]),
                              right: (index: Int, column: PaneColumn, panes: [PaneID]), total: CGFloat) -> some View {
        let resizeLeft = !isFlexible(left.column)
        let target = resizeLeft ? left : right
        return PaneResizeHandle(
            skin: skin,
            showsLine: false,
            onDrag: { dx in
                let origin = dragOrigin ?? columnWidth(target.column, total: total)
                if dragOrigin == nil { dragOrigin = origin }
                let w = resizeLeft ? origin + dx : origin - dx
                liveWidth = (target.index, Double(min(560, max(160, w))))
            },
            onEnd: {
                if let liveWidth { customize.setColumnWidth(liveWidth.column, liveWidth.width) }
                liveWidth = nil
                dragOrigin = nil
            }
        )
    }

    /// The gap between two stacked panes; drags trade height between them.
    /// The first drag pins every pane in the column to its current height
    /// (as weights in points), so a natural-height pane resizes too.
    private func stackHandle(column: Int, above: PaneID, below: PaneID, visible: [PaneID], weights: PaneColumn,
                             size: CGSize) -> some View {
        StackSplitHandle(
            enabled: true,
            onDrag: { dy in
                let start = stackOrigin ?? currentHeights(visible, weights: weights, size: size)
                if stackOrigin == nil { stackOrigin = start }
                guard let a0 = start[above], let b0 = start[below] else { return }
                let minHeight = 80.0
                let a = min(a0 + b0 - minHeight, max(minHeight, a0 + Double(dy)))
                var next = start
                next[above] = a
                next[below] = a0 + b0 - a
                liveWeights = (column, next)
            },
            onEnd: {
                if let liveWeights { customize.setWeights(column: liveWeights.column, liveWeights.weights) }
                liveWeights = nil
                stackOrigin = nil
            }
        )
    }

    /// The panes' current heights in a column, mirroring `WeightedStack`.
    private func currentHeights(_ panes: [PaneID], weights: PaneColumn, size: CGSize) -> [PaneID: Double] {
        let height = Double(size.height) - Double(panes.count - 1) * Double(Corners.inset)
        let flexibleWeight = panes.reduce(0) { $0 + weights.weight($1) }
        var result: [PaneID: Double] = [:]
        var fixed = 0.0
        for pane in panes where weights.weight(pane) == 0 {
            // The now-playing panel's natural height: square cover plus details.
            let natural = Double(min(size.width - 24, NowPlayingPanelView.maxArtwork)) + 12 + 78
            let h = flexibleWeight > 0 ? min(natural, height * 0.6) : natural
            result[pane] = h
            fixed += h
        }
        for pane in panes where weights.weight(pane) > 0 {
            result[pane] = max(1, (height - fixed) * weights.weight(pane) / max(flexibleWeight, 0.0001))
        }
        return result
    }

    // MARK: - Library column

    @ViewBuilder
    private var libraryColumn: some View {
        VStack(spacing: 0) {
            if let key = library.albumKey, let album = library.albumGroup(for: key) {
                let tracks = library.tracks(inAlbum: key)
                AlbumDetailView(
                    album: album,
                    tracks: tracks,
                    skin: skin,
                    onBack: { library.albumKey = nil },
                    onPlay: { player.play(tracks) },
                    onShuffle: { playShuffled(tracks) }
                )
                trackTable(tracks, sourceID: "album:" + key, columns: settings.orderedVisibleColumns.filter { $0 != .album }, groupBy: .none)
            } else if library.source == .profile {
                ProfilePage(library: library, history: AppSession.shared.history, settings: settings, skin: skin)
            } else if library.source == .albums, !library.tracks.isEmpty {
                // The latest addition heads this page in place of the usual header.
                AlbumsPage(library: library, skin: skin)
            } else {
                LibraryHeaderView(
                    library: library,
                    settings: settings,
                    skin: skin,
                    onPlay: { player.play(library.visibleTracks) },
                    onShuffle: { playShuffled(library.visibleTracks) },
                    onEditRules: { id in playlistEditor = PlaylistEditorRequest(existingID: id) }
                )
                if case .artist = library.source {
                    let keys = Set(library.visibleTracks.map(\.albumKey))
                    ArtistAlbumsStrip(
                        albums: library.albumGroups.filter { keys.contains($0.key) }.sorted { ($0.year ?? 0) > ($1.year ?? 0) },
                        skin: skin,
                        onOpen: { library.albumKey = $0.key },
                        onPlay: { player.play(library.tracks(inAlbum: $0.key)) }
                    )
                }
                if library.source == .artists, !library.tracks.isEmpty {
                    ArtistsPage(library: library, skin: skin)
                } else if library.visibleTracks.isEmpty {
                    EmptyLibraryView(library: library, skin: skin, onAddMusic: promptAddMusic)
                } else {
                    trackTable(library.visibleTracks, sourceID: sourceID, columns: settings.orderedVisibleColumns, groupBy: settings.data.groupBy)
                }
            }
        }
    }

    private var sourceID: String { library.source.key }

    private func trackTable(_ tracks: [Track], sourceID: String, columns: [TrackColumnKind], groupBy: TableGroupMode) -> some View {
        let reorderable: UUID? = {
            if library.visibleListIsReorderable, case .playlist(let id) = library.source { return id }
            return nil
        }()
        return TrackTableView(
            tracks: tracks,
            sourceID: sourceID,
            selection: $selection,
            skin: skin,
            configuration: TrackTableConfiguration(
                columns: columns,
                groupBy: groupBy,
                rowHeight: settings.data.density.rowHeight * max(1, CGFloat(customize.style(.tableText).sizeScale ?? 1)),
                fontSize: settings.data.density.rowFontSize * CGFloat(customize.style(.tableText).sizeScale ?? 1),
                gridLines: settings.data.tableShowGridLines,
                alternatingRows: settings.data.tableAlternatingRows,
                hiResBadge: settings.data.showHiResBadge,
                playOnSingleClick: settings.data.playOnSingleClick,
                fontFamily: customize.style(.tableText).font ?? settings.data.fontFamily,
                header: TableHeaderLook(panel: customize.style(.tableHeader), text: customize.style(.tableHeaderText),
                                        family: settings.data.fontFamily)
            ),
            nowPlayingID: player.currentTrack?.id,
            reorderablePlaylist: reorderable,
            playlists: library.playlists,
            actions: TrackTableActions(
                play: { player.play(track: $0, within: $1) },
                playTracks: { player.play($0) },
                playNext: { player.playNext($0) },
                addToQueue: { player.addToQueue($0) },
                setLiked: { library.setLiked($0, $1) },
                showAlbum: { library.albumKey = $0.albumKey },
                getInfo: { editingTrack = $0 },
                refreshFromFile: { library.refreshFromFiles($0) },
                addToPlaylist: { library.addTracks($0, toPlaylist: $1) },
                newPlaylist: { playlistEditor = PlaylistEditorRequest(trackIDs: $0) },
                removeFromPlaylist: { ids in
                    if let reorderable { library.removeTracks(ids, fromPlaylist: reorderable) }
                },
                removeFromLibrary: requestRemoval,
                moveInPlaylist: { ids, index in
                    if let reorderable { library.moveTracks(ids, inPlaylist: reorderable, to: index) }
                }
            )
        )
        .customFrame(.tableText, active: customize.isActive)
        .overlay(alignment: .top) {
            if customize.isActive {
                // Pick targets for the AppKit header: the bar, and its labels inside it.
                let height = CGFloat(customize.style(.tableHeader).height ?? Double(TableHeaderLook.defaultHeight))
                Color.clear
                    .frame(height: height)
                    .customFrame(.tableHeader, active: true)
                    .overlay(Color.clear.padding(.horizontal, 12).padding(.vertical, 5).customFrame(.tableHeaderText, active: true))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Actions

    private func onAppear() {
        player.fallbackSource = {
            let visible = library.albumKey.map { library.tracks(inAlbum: $0) } ?? library.visibleTracks
            let selected = visible.filter { selection.contains($0.id) }
            return selected.isEmpty ? visible : selected
        }
        if settings.data.rememberLastView, let saved = DefaultsStore.load(LibrarySource.self, key: Self.lastSourceKey) {
            library.source = saved
        }
        library.resetNavigationHistory()
        importFromCommandLineIfRequested()
        if !library.pendingDuplicates.isEmpty { showingDuplicates = true }
    }

    private func handle(_ request: WindowRequest) {
        switch request {
        case .settings: openSettings()
        case .equalizer: openWindow(id: "equalizer")
        case .palette: showingPalette = true
        case .addMusic: promptAddMusic()
        case .newPlaylist: playlistEditor = PlaylistEditorRequest(trackIDs: Array(selection))
        case .miniPlayer: openWindow(id: "mini-player")
        case .customize: withAnimation(.easeOut(duration: 0.2)) { customize.isActive.toggle() }
        case .library: openWindow(id: "library")
        case .downloads:
            // Off: send the user to Settings → Sources, which explains and offers to turn it on.
            if AppSession.shared.soulseek.settings.enabled {
                openWindow(id: "downloads")
            } else {
                SettingsNavigator.shared.target = "sources"
                openWindow(id: "settings")
            }
        }
    }

    private func runPaletteCommand(_ command: PaletteCommand) {
        showingPalette = false
        switch command {
        case .settings: openSettings()
        case .equalizer: openWindow(id: "equalizer")
        case .addMusic: promptAddMusic()
        case .miniPlayer: openWindow(id: "mini-player")
        case .getInfo:
            if let id = selection.first, let track = library.track(id: id) { editingTrack = track }
        case .newPlaylist: playlistEditor = PlaylistEditorRequest(trackIDs: Array(selection))
        case .library: openWindow(id: "library")
        case .goToCurrent:
            if let track = player.currentTrack {
                library.albumKey = track.albumKey
                selection = [track.id]
            }
        }
    }

    private func openSettings(equalizer: Bool = false) {
        if equalizer { SettingsNavigator.shared.target = "equalizer" }
        openWindow(id: "settings")
    }

    private func playPlaylist(_ playlist: Playlist) {
        library.source = .playlist(playlist.id)
        player.play(library.contents(of: playlist))
    }

    private func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        player.shuffle = true
        player.play(tracks, startAt: Int.random(in: tracks.indices))
    }

    private func requestRemoval(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if settings.data.confirmBeforeRemovingFromLibrary {
            pendingRemoval = RemovalRequest(ids: ids)
        } else {
            library.removeTracks(ids)
            selection.subtract(ids)
        }
    }

    private func sidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        switch settings.data.sidebarWidthMode {
        case .fixed: return CGFloat(settings.data.sidebarFixedWidth)
        case .proportional: return min(420, max(200, windowWidth * CGFloat(settings.data.sidebarProportionalPercent)))
        }
    }

    private func promptAddMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "Add to Library"
        panel.message = "Choose folders or audio files to add."
        if panel.runModal() == .OK {
            library.importItems(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { library.importItems([url]) }
            }
        }
        return true
    }

    /// `MeimeiPlayer --import <path>` adds a folder at launch, for scripted setups.
    private func importFromCommandLineIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--import"), i + 1 < args.count else { return }
        library.importItems([URL(fileURLWithPath: args[i + 1])])
    }

    private static let lastSourceKey = "com.meimei.player.lastSource.v2"
}

private struct PlaylistEditorRequest: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var trackIDs: [UUID] = []
}


private struct RemovalRequest: Identifiable {
    let id = UUID()
    var ids: Set<UUID>
}

/// Back and forward through the library history: the new page slides in
/// from the side it comes from (back from the left, forward from the right)
/// and settles with a spring. Moves the content in place, so tables and
/// pages keep their views instead of being rebuilt.
private struct NavigationSlide: ViewModifier {
    var move: LibraryStore.NavigationMove
    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(opacity)
            // The slide stays inside the pane.
            .clipped()
            .onChange(of: move) { m in
                guard m.direction != 0 else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    offset = CGFloat(m.direction) * 44
                    opacity = 0
                }
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { offset = 0 }
                    withAnimation(.easeOut(duration: 0.24)) { opacity = 1 }
                }
            }
    }
}
