#if DEBUG
import AppKit
import AVFoundation
import SwiftUI

/// Development-only launch options:
///
///     --snapshot <file.png> [--snapshot-delay <s>] [--open settings|settings:<page>|window:<name>|sheets|equalizer|eqwindow|palette|menu|buttons|albums|artists|profile|artist|album|liked|lyrics|cover|solid|artbackdrop] [--play]
///         Renders every visible window to PNG (the first to <file>, the rest
///         to <file>-1.png, …), then prints "snapshot: done" for the caller
///         to terminate the process. No screen-recording permission needed.
///     --bench
///         Times library and table work against the library in
///         MEIMEI_SUPPORT_DIR (meant for a large synthetic one), then exits.
///     --self-test
///         Runs model, tag-writer, analyzer, and audio-engine checks, prints
///         results, and exits non-zero on failure.
///
/// Set MEIMEI_SUPPORT_DIR to keep these runs away from the real library.
@MainActor
enum DebugHooks {
    /// Snapshot and self-test runs render offscreen; their windows stay invisible.
    static let isHeadless = ProcessInfo.processInfo.arguments.contains { $0 == "--snapshot" || $0 == "--self-test" || $0 == "--bench" || $0 == "--lookup" || $0 == "--lyrics" }

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--self-test") {
            Task { await SelfTest.run() }
        } else if let i = args.firstIndex(of: "--lyrics"), i + 2 < args.count {
            // `--lyrics <artist> <title>`: each lyrics source, then the chain.
            Task {
                setvbuf(stdout, nil, _IOLBF, 0)
                let t = Track(filePath: "/x.flac", title: args[i + 2], artist: args[i + 1], album: "", duration: 0, sampleRate: 44_100,
                              bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 0, fileFormat: "FLAC")
                for sources in LyricsSource.allCases.map({ [$0] }) + [LyricsSource.allCases] {
                    let result = await LyricsLookup.fetch(t, sources: sources, syncedOnly: false)
                    let label = sources.map(\.label).joined(separator: " → ")
                    switch result {
                    case .found(let text, let source): print("lyrics: \(label): found on \(source.label), \(LyricsState.of(text)), \(text.count) chars")
                    case .notFound: print("lyrics: \(label): not found")
                    case .unavailable(let why): print("lyrics: \(label): unavailable: \(why)")
                    }
                }
                exit(0)
            }
        } else if let i = args.firstIndex(of: "--lookup"), i + 2 < args.count {
            // `--lookup <artist> <album>`: what each online source returns.
            Task {
                setvbuf(stdout, nil, _IOLBF, 0)
                for source in OnlineSource.allCases {
                    let t0 = Date()
                    let matches = await OnlineMetadata.albums(artist: args[i + 1], album: args[i + 2], sources: [source])
                    print("lookup: \(source.label): \(matches.count) albums, \(matches.compactMap(\.cover).count) covers in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    for m in matches.prefix(3) {
                        print("lookup:   \(m.title) — \(m.artist) \(m.year.map(String.init) ?? "") [\(m.note ?? "")] \(m.trackCount) tracks")
                    }
                    if let first = matches.first {
                        let songs = (try? await OnlineMetadata.songs(of: first)) ?? []
                        print("lookup:   tracklist: \(songs.count) songs; first: \(songs.first.map { "\($0.disc)-\($0.number) \($0.title)" } ?? "none")")
                        if let cover = first.cover {
                            let data = await OnlineMetadata.image(cover.thumbnail)
                            print("lookup:   thumbnail \(data.map { "\($0.count) bytes" } ?? "failed")")
                        }
                    }
                }
                exit(0)
            }
        } else if args.contains("--bench") {
            Task { await Bench.run() }
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let delay = args.firstIndex(of: "--snapshot-delay").flatMap { Double(args[$0 + 1]) } ?? 2.5
            let open = args.firstIndex(of: "--open").map { args[$0 + 1] }
            Task { await snapshot(to: args[i + 1], delay: delay, open: open, play: args.contains("--play")) }
        }
    }

    private static func snapshot(to path: String, delay: Double, open: String?, play: Bool) async {
        // The session must not be created before SwiftUI has built the main
        // window (the window is what normally creates it); wait for it.
        for _ in 0..<100 where NSApp.windows.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let session = AppSession.shared
        if play, session.player.currentTrack == nil, let first = session.library.tracks.first {
            session.player.play(session.library.tracks(inAlbum: first.albumKey))
        } else if play {
            session.player.togglePlayPause()
        }
        switch open {
        case "settings": WindowRequest.settings.post()
        case "equalizer": WindowRequest.equalizer.post()
        case "palette": WindowRequest.palette.post()
        case "eqwindow":
            var d = session.player.equalizer.data
            d.enabled = true
            d.bands = [EQBand(type: .lowCut, frequency: 28, slope: 24), EQBand(type: .lowShelf, frequency: 110, gain: 4),
                       EQBand(frequency: 420, gain: -3, q: 1.4), EQBand(frequency: 3200, gain: 2.5, q: 0.9),
                       EQBand(type: .notch, frequency: 6800, q: 6), EQBand(type: .highShelf, frequency: 11000, gain: -2)]
            session.player.equalizer.data = d
            session.player.equalizer.selectedBandID = d.bands[3].id
        case "albums": session.library.source = .albums
        case "artists": session.library.source = .artists
        case "profile":
            session.library.source = .profile
            for _ in 0..<300 where !session.history.isReady { try? await Task.sleep(nanoseconds: 100_000_000) }
        case "customize":
            session.customize.isActive = true
            session.customize.cursor.select(.nowPlayingTitle)
        case "layout":
            session.settings.data.showLyrics = true
            if let lyrics = session.customize.layout.columnIndex(of: .lyrics) {
                session.customize.move(.playlists, to: .stack(column: lyrics, index: 1))
            }
            session.customize.move(.browse, to: .newColumn(index: 1))
        case "npwide":
            // Now playing stacked over the library: the cover must fit, not fill the column.
            if let library = session.customize.layout.columnIndex(of: .library) {
                session.customize.move(.nowPlaying, to: .stack(column: library, index: 0))
            }
        case "library":
            WindowRequest.library.post()
        case "customize-panel":
            session.customize.isActive = true
            session.customize.cursor.select(.collectionRail)
        case "artist": session.library.source = .artist(session.library.artistGroups.first?.name ?? "")
        case "liked": session.library.source = .liked
        case "lyrics": session.settings.data.showLyrics = true
        case "cover": session.theme.setActive(CustomTheme.albumReactiveID)
        case "solid": session.settings.data.surfaceStyle = .solid
        case "artbackdrop": session.settings.data.backdropStyle = .artwork
        case "album": session.library.albumKey = session.player.currentTrack?.albumKey ?? session.library.albumGroups.first?.key
        default:
            // "settings:<page>" opens the Settings window on that page; "window:<name>" opens a window
            // (equalizer, miniPlayer, library, downloads, customize). Captured as <file>-1.png etc.
            if let page = open?.split(separator: ":").last.map(String.init), open?.hasPrefix("settings:") == true {
                WindowRequest.settings.post()
                try? await Task.sleep(nanoseconds: 600_000_000)
                SettingsNavigator.shared.target = page
            } else if let name = open?.split(separator: ":").last.map(String.init), open?.hasPrefix("window:") == true,
                      let request = WindowRequest(rawValue: name) {
                request.post()
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        // Window capture misses layer-composited SwiftUI content on recent
        // macOS, so also render the main view directly. AppKit-backed views
        // (the track table) come out empty in this render.
        let size = NSApp.windows.first { $0.isVisible }?.contentLayoutRect.size ?? NSSize(width: 1240, height: 780)
        GlassRendering.forceFallback = true
        defer { GlassRendering.forceFallback = false }
        let content: AnyView = open == "eqwindow"
            ? AnyView(EqualizerWindowView().frame(width: 1020, height: 640))
            : AnyView(MainWindowView().frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let cg = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-swiftui.png")))
        }
        for w in NSApp.windows where w.isVisible {
            var aware = 0, local = 0
            func walk(_ l: CALayer) {
                if String(describing: type(of: l)).contains("Backdrop") {
                    if (l.value(forKey: "windowServerAware") as? Bool) == true { aware += 1 } else { local += 1 }
                }
                l.sublayers?.forEach(walk)
            }
            if let root = w.contentView?.superview?.layer ?? w.contentView?.layer { walk(root) }
            func views(_ v: NSView, _ depth: Int) {
                if v is NSScrollView || depth > 0 {
                    print("snapshot: view " + String(repeating: "  ", count: depth) + String(describing: type(of: v)) + " \(v.frame.integral) bounds=\(v.bounds.origin) hidden=\(v.isHidden)")
                    if depth < 6 { v.subviews.forEach { views($0, depth + 1) } }
                } else {
                    v.subviews.forEach { views($0, 0) }
                }
            }
            if ProcessInfo.processInfo.environment["MEIMEI_DUMP_VIEWS"] != nil, let root = w.contentView { views(root, 0) }
            print("snapshot: window \(w.title) titled=\(w.styleMask.contains(.titled)) key=\(w.canBecomeKey) shadow=\(w.hasShadow) opaque=\(w.isOpaque) bg=\(w.backgroundColor.description.prefix(40)) backdrops serverAware=\(aware) local=\(local)")
        }
        if open == "icons" {
            let s = session.settings.styled(session.theme.skin)
            let view = VStack(alignment: .leading, spacing: 20) {
                IconSettingsEditor(settings: session.settings, skin: s).frame(width: 560)
                HStack(spacing: 14) {
                    ForEach(["badge.lossless", "badge.hires", "music.note"], id: \.self) { role in
                        VStack { Glyph(role, size: 22); Text(IconRoles.name(role)).font(AppFont.ui(10)) }
                    }
                }
            }
            .padding(20).foregroundStyle(s.textPrimary).background(Color.black).preferredColorScheme(.dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-icons.png")))
            }
        }
        if open == "albums" || open == "artists" || open == "profile" {
            // The page at a wide pane's width, beside the window's own (narrow) layout.
            let s = session.settings.styled(session.theme.skin)
            let paths = Set(session.library.tracks.compactMap(\.artworkFilePath))
            for pixels in [128, 256, 512] {
                for p in paths { _ = await withCheckedContinuation { c in ArtworkCache.shared.load(p, pixels: pixels) { c.resume(returning: $0) } } }
            }
            let page = Group {
                if open == "albums" { AlbumsPage(library: session.library, skin: s) }
                else if open == "profile" { ProfilePage(library: session.library, history: session.history, settings: session.settings, skin: s) }
                else { ArtistsPage(library: session.library, skin: s) }
            }
            // On the window's backdrop inside the library pane's own surface, as in the app.
            let artwork = session.library.tracks.lazy.compactMap(\.artworkFilePath).first.flatMap { ArtworkCache.shared.cached($0, pixels: 256) }
            let view = page.contentSurface(s, fallback: s.bgRow).padding(Corners.inset).frame(width: 1000, height: open == "profile" ? 2700 : 1500)
                .background(WindowBackdrop(style: s.isGlass ? .artwork : .ambient, skin: s, artwork: artwork, glassTint: 0))
                .font(AppFont.ui(12)).foregroundStyle(s.textPrimary).preferredColorScheme(.dark)
            let r = ImageRenderer(content: view)
            r.scale = 1
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-wide.png")))
            }
        }
        if open == "downloads" {
            // Each setup step, then each Downloads page with sample data. Rendered offscreen only.
            let s = session.settings.styled(session.theme.skin)
            func render<V: View>(_ view: V, _ suffix: String, width: CGFloat = 900, height: CGFloat = 580) {
                let framed = view.frame(width: width, height: height)
                    .background(WindowBackdrop(style: .ambient, skin: s, artwork: nil, glassTint: 0))
                    .font(AppFont.ui(12)).foregroundStyle(s.textPrimary).preferredColorScheme(.dark)
                let r = ImageRenderer(content: framed)
                r.scale = 1.5
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
                }
            }
            render(SettingsView(settings: session.settings, theme: session.theme, equalizer: session.player.equalizer,
                                player: session.player, startOnSources: true), "settings-sources", width: 1080, height: 700)
            render(SourcesSettingsPage(store: SoulseekStore(), skin: s, prompted: true).padding(24)
                .frame(width: 760, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top), "sources-page")
            render(SoulseekLegalView(skin: s, scrolls: false), "legal", height: 1500)
            let tunnelStore = SoulseekStore()
            tunnelStore.persists = false
            tunnelStore.settings.routeMode = .tunnel
            tunnelStore.settings.tunnelEndpoint = "se-sto-wg-001.example.net:51820"
            tunnelStore.settings.tunnelAddress = "10.68.14.2"
            render(NetworkForm(store: tunnelStore, skin: s).padding(24).frame(width: 760).frame(maxHeight: .infinity, alignment: .top),
                   "network-tunnel", height: 1500)
            render(SoulseekOverview(store: SoulseekStore(), skin: s).padding(24).frame(width: 760).frame(maxHeight: .infinity, alignment: .top), "overview-full", height: 2300)
            let store = SoulseekStore()
            for step in SoulseekSetupView.Step.allCases {
                render(SoulseekSetupView(store: store, skin: s, onFinish: {}, scrolls: false, step: step), "setup-\(step.label)",
                       height: step == .overview ? 2400 : step == .network ? 1500 : 580)
            }
            store.debugFill()
            func dl(_ section: DownloadsView.Section, _ name: String, query: String? = nil, key: Bool = false, log: Bool = false, height: CGFloat = 580) {
                render(DownloadsView(store: store, skin: s, scrolls: false, section: section, logOpen: log,
                                     searchQuery: query, searchKey: key), "dl-\(name)", height: height)
            }
            dl(.search, "search")
            dl(.search, "search-key", query: "", height: 1650)
            dl(.search, "search-key-typed", query: "artist album .flac is:album -live @tapehiss kbps:256..320 year:1990..1999 sort:-size", key: true, height: 1800)
            dl(.search, "search-key-problem", query: "artist is:great", key: true)
            render(DownloadsView(store: store, skin: s, scrolls: false, section: .search, searchQuery: "artist album is:lo",
                                 searchAssist: true), "dl-search-assist")
            render(DownloadsView(store: store, skin: s, scrolls: false, section: .search, searchQuery: "artist album is:lossless ",
                                 searchKey: true, searchCorrection: ("is:losless", "is:lossless")), "dl-search-corrected", height: 1800)
            dl(.transfers, "transfers")
            store.debugBrowseRequest("northern_lights", received: nil)
            dl(.browse("northern_lights"), "browse-request")
            store.debugBrowseRequest("northern_lights", received: 1_300_000)
            dl(.browse("northern_lights"), "browse-receiving")
            store.debugBrowseRequest("warp_archive", received: nil, failed: true)
            dl(.browse("warp_archive"), "browse-failed")
            render(WindowButtonsSheet(settings: session.settings, skin: s, start: .minimize, scrolls: false) {}, "window-buttons", width: 560, height: 440)
            render(VStack(spacing: 0) {
                RailNotice(store: store, skin: s, onMessage: {}, sample: ("Message from tapehiss: the cd rip is in the same folder", false))
                RailNotice(store: store, skin: s, onMessage: {}, sample: ("Disconnected. The server closed the connection.", true))
            }.padding(10).frame(width: 196), "rail-notice", width: 196, height: 200)
            render(WindowControlSettingsEditor(settings: session.settings, skin: s).padding(12).frame(width: 300), "window-buttons-look", width: 300, height: 900)
            if let first = store.downloads.first {
                let folder = store.downloads.filter { $0.path.hasPrefix("Music\\Boards of Canada\\Geogaddi") }.map(\.id)
                render(TransferHistory(title: first.name, subtitle: "from tapehiss", ids: [first.id], upload: false, store: store, skin: s, scrolls: false),
                       "dl-history", width: 400, height: 330)
                render(TransferHistory(title: "Geogaddi", subtitle: "from tapehiss", ids: folder, upload: false, store: store, skin: s, scrolls: false),
                       "dl-history-folder", width: 400, height: 330)
            }
            dl(.shares, "sharing")
            dl(.network, "network", height: 1400)
            dl(.messages, "messages")
            dl(.search, "log", log: true, height: 700)
            store.settings.messagesAcknowledged = false
            dl(.messages, "messages-notice")
        }
        if open == "menu" {
            // The app menu as it opens on a track, rendered offscreen (no panel is shown).
            let s = session.settings.styled(session.theme.skin)
            let view = AppMenu.debugView(MenuContent.debugTrackMenu(), skin: s)
                .padding(20).background(Color.black).preferredColorScheme(.dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-menu.png")))
            }
        }
        if open == "buttons" {
            // One row of labelled buttons per button fill, on the library pane's surface over the
            // window backdrop (reference images for the Windows port). Writes -buttons-<fill>.png.
            let original = session.settings.data.buttonFill
            for fill in ButtonFill.allCases {
                session.settings.data.buttonFill = fill
                let s = session.settings.styled(session.theme.skin)
                let row = HStack(spacing: 10) {
                    Button {} label: { Label("Group", glyph: "rectangle.3.group") }.buttonStyle(PillButtonStyle(skin: s))
                    Button {} label: { Label("Shuffle", glyph: "shuffle") }.buttonStyle(PillButtonStyle(skin: s)).disabled(true)
                    Button {} label: { Label("Play", glyph: "play.fill") }.buttonStyle(PillButtonStyle(skin: s, prominent: true))
                    Button {} label: { Label("Add Music…", glyph: "plus") }.buttonStyle(PillButtonStyle(skin: s, isActive: true))
                    Button {} label: { Label("Compact", glyph: "slider.horizontal.3") }.buttonStyle(PillButtonStyle(skin: s, compact: true))
                }
                .padding(24)
                .frame(width: 620, height: 90, alignment: .leading)
                .contentSurface(s, fallback: s.bgRow)
                .padding(Corners.inset)
                .background(WindowBackdrop(style: session.settings.effectiveBackdrop(for: s), skin: s, artwork: nil, glassTint: 0))
                .font(AppFont.ui(12)).foregroundStyle(s.textPrimary).preferredColorScheme(.dark)
                let r = ImageRenderer(content: row)
                r.scale = 2
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-buttons-\(fill.rawValue).png")))
                }
            }
            session.settings.data.buttonFill = original
        }
        if open == "sheets" {
            // Every sheet and popover, offscreen, over the window backdrop: -sheet-<name>.png.
            let s = session.settings.styled(session.theme.skin)
            func sheet<V: View>(_ view: V, _ name: String) {
                let framed = view.padding(30)
                    .background(WindowBackdrop(style: session.settings.effectiveBackdrop(for: s), skin: s, artwork: nil, glassTint: 0))
                    .font(AppFont.ui(12)).foregroundStyle(s.textPrimary).preferredColorScheme(.dark)
                let r = ImageRenderer(content: framed)
                r.scale = 2
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-sheet-\(name).png")))
                }
            }
            if let t = session.library.tracks.first {
                sheet(MetadataEditorView(library: session.library, lyrics: session.lyrics, skin: s, trackID: t.id, onDismiss: {}), "get-info")
            }
            sheet(PlaylistEditorSheet(library: session.library, skin: s, onDismiss: {}), "new-playlist")
            if let smart = session.library.playlists.first(where: \.isSmart) {
                sheet(PlaylistEditorSheet(library: session.library, existingID: smart.id, skin: s, onDismiss: {}), "edit-smart-playlist")
            }
            sheet(DuplicateReviewView(library: session.library, skin: s, onDismiss: {}), "duplicates")
            sheet(ThemeGeneratorSheet(theme: session.theme, skin: s, onDone: {}), "theme-generator")
            sheet(UpNextView(player: session.player, skin: s, onDismiss: {}).frame(width: 340, height: 460), "up-next")
            sheet(MiniPlayerView().frame(width: 360, height: 140), "mini-player")
            sheet(EqualizerWindowView().frame(width: 1020, height: 640), "equalizer-window")
        }
        if open == "palette" {
            let s = session.settings.styled(session.theme.skin)
            let palette = ZStack {
                MainWindowView()
                CommandPaletteView(library: session.library, player: session.player, skin: s, onDismiss: {},
                                   onOpenAlbum: { _ in }, onCommand: { _ in })
            }
            .frame(width: 1240, height: 780).preferredColorScheme(.dark)
            let r = ImageRenderer(content: palette)
            r.scale = 1.5
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-overlay.png")))
            }
        }
        if open == "library" {
            let s = session.settings.styled(session.theme.skin)
            for section in LibraryManagerView.Section.allCases where section != .metadata || ProcessInfo.processInfo.environment["MEIMEI_SNAPSHOT_SECTION"] == nil
                || ProcessInfo.processInfo.environment["MEIMEI_SNAPSHOT_SECTION"] == section.rawValue {
              for mode in section == .metadata ? MetadataPage.Mode.allCases : [.albums] {
                let view = LibraryManagerView(library: session.library, scanner: session.scanner, skin: s, section: section, scrolls: false,
                                              metadataMode: mode)
                    .font(AppFont.ui(12)).foregroundStyle(s.textPrimary)
                    .frame(width: 920, height: 760).background(Color.black).preferredColorScheme(.dark)
                let r = ImageRenderer(content: view)
                r.scale = 1.5
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-library-\(section.rawValue)\(section == .metadata ? "-" + mode.rawValue : "").png")))
                }
              }
            }
        }
        if open?.hasPrefix("customize") == true {
            let s = session.settings.styled(session.theme.skin)
            for tab in CustomizeInspector.Tab.allCases {
                let inspector = CustomizeInspector(store: session.customize, cursor: session.customize.cursor,
                                                   settings: session.settings, skin: s, scrolls: false, tab: tab)
                    .padding(20).background(Color(white: 0.2)).preferredColorScheme(.dark)
                let r = ImageRenderer(content: inspector)
                r.scale = 2
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(tab.rawValue.lowercased()).png")))
                }
            }
        }
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 50 }
        print("snapshot: \(windows.count) visible of \(NSApp.windows.count) windows")
        for (n, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let out = n == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(n).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("snapshot: \(out) (\(window.title.isEmpty ? "untitled" : window.title))")
        }
        session.player.engine.pause()
        // Ending here with exit() mid-playback left the next launch without
        // a window; the caller terminates the process instead.
        print("snapshot: done")
        fflush(stdout)
    }
}

// MARK: - Self-test

@MainActor
private enum SelfTest {
    private static var failures = 0

    /// Waits on the main queue for `condition`, up to `seconds`.
    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private final class SlskLog {
        var events: [SlskClient.Event] = []
    }

    /// The Soulseek codec, then a whole session against a fake loopback network.
    static func soulseek(_ dir: URL) async {
        check(SlskMD5.hex(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72"
              && SlskMD5.hex(Data()) == "d41d8cd98f00b204e9800998ecf8427e", "soulseek: md5 login hash")
        let sample = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        check(SlskZlib.inflate(SlskZlib.deflate(sample)) == sample, "soulseek: zlib round trip")
        let file = SlskFile(path: "A\\B\\c.mp3", size: 1234, ext: "mp3", bitrate: 320, duration: 61)
        let reply = SlskSearchReply(username: "u", token: 9, files: [file], freeSlot: true, speed: 5, queue: 2)
        let back = try? SlskSearchReply.decode(reply.encode())
        check(back?.files == [file] && back?.queue == 2 && back?.freeSlot == true, "soulseek: search reply round trip")
        let folders = [SlskFolder(path: "A\\B", files: [file])]
        let listBack = try? SlskShareList.decode(SlskShareList.encode(folders))
        check(listBack?.first?.files.first?.path == file.path, "soulseek: share list round trip")
        check(SlskReasons.plain("Banned").contains("banned"), "soulseek: refusal reasons in plain words")
        check(SlskRoute.isIPv4("1.1.1.1") && SlskRoute.isIPv4("149.112.112.112") && !SlskRoute.isIPv4("1.1.1")
              && !SlskRoute.isIPv4("256.1.1.1") && !SlskRoute.isIPv4("1.1.1.1.") && !SlskRoute.isIPv4("a.b.c.d"), "soulseek: dns address parsing")
        var dnsSettings = SoulseekSettings()
        dnsSettings.dnsPreferred = "9.9.9.9"; dnsSettings.dnsAlternate = "149.112.112."
        check(dnsSettings.dnsServers == ["9.9.9.9"], "soulseek: incomplete dns address ignored")
        do {
            func fl(_ p: String, _ ext: String, br: Int? = nil, bd: Int? = nil, sr: Int? = nil) -> SlskFile {
                SlskFile(path: p, size: 1, ext: ext, bitrate: br, sampleRate: sr, bitDepth: bd)
            }
            let hi = SoulseekStore.SearchGroup(user: "a", folder: "x\\Album [24-96]", files: (1...5).map { fl("x\\Album [24-96]\\\($0).flac", "flac", bd: 24, sr: 96000) },
                                               freeSlot: true, speed: 100, queue: 0)
            let mp3 = SoulseekStore.SearchGroup(user: "b", folder: "y\\Album", files: (1...5).map { fl("y\\Album\\\($0).mp3", "mp3", br: $0 < 3 ? 192 : 320) },
                                                freeSlot: false, speed: 900, queue: 30)
            let live = SoulseekStore.SearchGroup(user: "c", folder: "z\\Album (Live)", files: [fl("z\\Album (Live)\\1.m4a", "m4a", br: 256)],
                                                 freeSlot: true, speed: 50, queue: 0)
            let all = [hi, mp3, live]
            var sf = SearchFilters()
            check(sf.apply(all, hidden: []).map(\.user) == ["a", "c", "b"], "search filters: best match puts free slots first")
            sf.quality = .hiRes
            check(sf.apply(all, hidden: []).map(\.user) == ["a"], "search filters: hi-res")
            sf = SearchFilters(); sf.kbps = NumRange(min: 320)
            let bitrate = sf.apply(all, hidden: [])
            check(bitrate.first { $0.user == "b" }?.files.count == 3 && bitrate.contains { $0.user == "a" }, "search filters: bitrate trims lossy files only")
            sf = SearchFilters(); sf.exclude = ["live"]; sf.files = NumRange(min: 4)
            check(sf.apply(all, hidden: ["b"]).map(\.user) == ["a"], "search filters: exclude, albums, hidden users")
            sf = SearchFilters(); sf.formats = ["aac"]; sf.sort = .speed
            check(sf.apply(all, hidden: []).map(\.user) == ["c"] && live.files[0].kind == "aac", "search filters: formats")
            sf = SearchFilters(); sf.sort = .speed
            check(sf.apply(all, hidden: [], starred: ["c"]).map(\.user) == ["c", "b", "a"], "search filters: starred users pinned first")
            sf.reversed = true
            check(sf.apply(all, hidden: []).map(\.user) == ["c", "a", "b"], "search filters: reversed order")

            let c = SearchCommand("Artist Album .flac is:album -Live @someone sort:speed kbps:320")
            check(c.words == ["Artist", "Album"] && c.filters.formats == ["flac"] && c.filters.files.min == 4
                  && c.filters.exclude == ["live"] && c.scope == .users(["someone"]) && c.filters.sort == .speed
                  && c.filters.kbps.min == 320 && c.wire == "Artist Album -Live" && c.problem == nil,
                  "search syntax: words, formats, is:, -words, @user, sort:, kbps:", "\(c)")
            let q = SearchCommand("\"exact title\" @* @* -\"some phrase\"")
            check(q.phrases == ["exact title"] && q.scope == .starred && q.wire == "exact title" && q.filters.notPhrases == ["some phrase"],
                  "search syntax: phrases, negated phrases, starred users")
            check(SearchCommand("@a @b @a x").scope == .users(["a", "b"]), "search syntax: several users")
            check(SearchCommand("x is:great").problem?.hasPrefix("is:") == true, "search syntax: unknown is: value explained")
            check(SearchCommand("x is:losless").problem?.contains("is:lossless") == true, "search syntax: problem suggests the fix")
            check(SearchCommand("-live").problem != nil && SearchCommand("@").problem != nil, "search syntax: needs a word and a name")
            check(SearchCommand("re:member").words == ["re:member"] && SearchCommand("Size:").words == ["Size:"],
                  "search syntax: unknown key or empty value is a plain word")
            check(SearchCommand("Name: Unknown").words == ["Name:", "Unknown"] && SearchCommand("x name:live").filters.fileWords == ["live"],
                  "search syntax: aliases fall back to words")
            check(SearchCommand("x .m4a").filters.formats == ["aac", "alac"] && SearchCommand("x .hack").words == ["x", ".hack"],
                  "search syntax: format aliases, other dotted words")
            check(NumRange.speed("500k") == 500_000 && NumRange.speed("2m") == 2_000_000 && NumRange.speed("x") == nil,
                  "search syntax: speeds")
            let n = SearchCommand("x kbps:256..320 size:<50m length:2:00..5:00 year:1990-1999 bits:24 rate:44.1 files:>=10 speed:>1m")
            check(n.problem == nil && n.filters.kbps == NumRange(min: 256, max: 320) && n.filters.size == NumRange(max: 50_000_000, maxOpen: true)
                  && n.filters.length == NumRange(min: 120, max: 300) && n.filters.year == NumRange(min: 1990, max: 1999)
                  && n.filters.bits.min == 24 && n.filters.rate.min == 44_100 && n.filters.files.min == 10
                  && n.filters.speed == NumRange(min: 1_000_000, minOpen: true), "search syntax: numeric ranges and units", "\(n.filters)")
            check(SearchCommand("x year:2002").filters.year == NumRange(min: 2002, max: 2002) && SearchCommand("x kbps:-320").problem != nil,
                  "search syntax: exact years, no negated numbers")
            let neg = SearchCommand("x -is:lossy -.mp3 -@someone -folder:live -file:remix ext:flac,wav")
            check(neg.filters.notQuality == [.lossy] && neg.filters.notFormats == ["mp3"] && neg.filters.hiddenUsers == ["someone"]
                  && neg.filters.notFolderWords == ["live"] && neg.filters.notFileWords == ["remix"] && neg.filters.formats == ["flac", "wav"],
                  "search syntax: negated filters and ext lists")
            check(SearchCommand("x sort:-year").filters.reversed && SearchCommand("x sort:-year").filters.sort == .year, "search syntax: reversed sort")
            let phrase = SoulseekStore.SearchGroup(user: "p", folder: "x\\Album (1997)", files: [fl("x\\Album (1997)\\Exact Title.flac", "flac"), fl("x\\Album (1997)\\Other Song.flac", "flac")],
                                                   freeSlot: true, speed: 1, queue: 0)
            check(SearchCommand("\"exact title\"").filters.apply([phrase], hidden: []).first?.files.count == 1, "search syntax: phrase keeps matching files")
            check(phrase.year == 1997 && SearchCommand("x year:1990..1999").filters.apply([phrase], hidden: []).count == 1
                  && SearchCommand("x year:2000..2009").filters.apply([phrase], hidden: []).isEmpty, "search syntax: year from the folder path")
            check(SearchCommand("x -@P").filters.apply([phrase], hidden: []).isEmpty, "search syntax: hide a user's results")

            // Covers and lyrics: not formats, never filtered out with the music.
            let extras = SoulseekStore.SearchGroup(user: "e", folder: "x\\Album", files: (1...4).map { fl("x\\Album\\\($0).mp3", "mp3", br: 320) }
                                                    + [fl("x\\Album\\cover.jpg", "jpg"), fl("x\\Album\\01.lrc", "lrc")], freeSlot: true, speed: 1, queue: 0)
            check(extras.kinds == ["mp3"] && extras.audioCount == 4 && extras.hasCover && extras.hasLyrics && extras.qualityLabel == "320",
                  "search results: format, count and quality from the music only")
            let kept = SearchCommand("x .mp3 kbps:320 is:album").filters.apply([extras], hidden: [])
            check(kept.first?.files.count == 6 && kept.first?.hasCover == true, "search results: covers and lyrics kept with the music")
            check(SearchCommand("x -cover").filters.apply([extras], hidden: []).first?.hasCover == false, "search results: leave-out words still drop extras")

            // Correction: syntax only, never words or names.
            check(SearchAssist.correction(for: "is:losless") == "is:lossless" && SearchAssist.correction(for: "kpbs:320") == "kbps:320"
                  && SearchAssist.correction(for: ".flca") == ".flac" && SearchAssist.correction(for: "sort:-sise") == "sort:-size"
                  && SearchAssist.correction(for: "-is:lossyy") == "-is:lossy" && SearchAssist.correction(for: "ext:flac,mp33") == "ext:flac,mp3",
                  "search assist: corrects misspelled syntax")
            check(SearchAssist.correction(for: "boards") == nil && SearchAssist.correction(for: "@tapehis") == nil
                  && SearchAssist.correction(for: "re:member") == nil && SearchAssist.correction(for: ".wma") == nil
                  && SearchAssist.correction(for: ".hack") == nil && SearchAssist.correction(for: "is:lossless") == nil
                  && SearchAssist.correction(for: "Live:") == nil && SearchAssist.correction(for: "mp3") == nil,
                  "search assist: leaves words, names and valid syntax alone")
            let sug = SearchAssist.suggestions(for: "is:l", users: [])
            check(sug.items.map(\.text) == ["is:lossless", "is:lossy"] && !sug.bare, "search assist: completes values")
            check(SearchAssist.suggestions(for: "@sta", users: ["stardust", "Starling", "other"]).items.map(\.text) == ["@stardust", "@Starling"],
                  "search assist: completes known users")
            check(SearchAssist.suggestions(for: "kb", users: []).bare && SearchAssist.suggestions(for: "kb", users: []).items.first?.text == "kbps:",
                  "search assist: quiet key completion for plain words")
            check(SearchAssist.suggestions(for: "-.fl", users: []).items.first?.text == "-.flac"
                  && SearchAssist.suggestions(for: "ext:flac,m", users: []).items.map(\.text).contains("ext:flac,mp3"),
                  "search assist: negated formats and ext lists")
            check(SearchAssist.lastToken("artist \"exact ti") == nil && SearchAssist.lastToken("artist is:lo") == "is:lo"
                  && SearchAssist.lastToken("artist ") == nil, "search assist: token at the caret")
        }

        do {
            // Tracks share their fields until one copy changes: still plain values.
            var a = Track(filePath: "/x/a.flac", title: "A", artist: "B", album: "C", duration: 61, sampleRate: 44100, bitDepth: 16,
                          channelCount: 2, estimatedBitrateKbps: 900, fileFormat: "FLAC")
            let b = a
            a.title = "Changed"
            a.playCount += 2
            check(b.title == "A" && b.playCount == 0 && a.title == "Changed" && a.playCount == 2 && a.id == b.id && a != b,
                  "tracks: a changed copy leaves the original alone")
            var c = b
            c.title = "A"
            check(c == b && c.hashValue == b.hashValue && Set([b, c]).count == 1, "tracks: equal fields are equal tracks")
            let json = (try? JSONEncoder().encode(b)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let back = (try? JSONEncoder().encode(a)).flatMap { try? JSONDecoder().decode(Track.self, from: $0) }
            check(json["title"] as? String == "A" && json["albumArtist"] as? String == "B" && json["year"] == nil
                  && json["lastPlayedAt"] == nil && json.count == 17 && back == a,
                  "tracks: saved the same way as before and read back", "\(json.keys.sorted())")
        }

        do {
            // Large result sets and file lists stay quick: summaries once, results cached.
            func clock(_ body: () -> Void) -> Double { let t0 = Date(); body(); return Date().timeIntervalSince(t0) * 1000 }
            let exts = ["flac", "mp3", "flac", "m4a", "jpg", "flac", "mp3", "lrc", "flac", "ogg", "mp3", "flac"]
            var groups: [SoulseekStore.SearchGroup] = []
            var folders: [SlskFolder] = []
            func makeFile(_ path: String, _ n: Int) -> SlskFile {
                let ext: String = exts[n]
                let name: String = path + "\\" + String(n) + " Track." + ext
                let depth: Int = n % 3 == 0 ? 24 : 16
                return SlskFile(path: name, size: UInt64(20_000_000 + n), ext: ext, bitrate: 320, duration: 200 + n,
                                sampleRate: 44100, bitDepth: depth)
            }
            func makeAll() {
                for i in 0..<20_000 {
                    let year: Int = 1960 + i % 60
                    let path: String = "share\\Artist " + String(i % 900) + "\\Album " + String(i) + " (" + String(year) + ")"
                    let files: [SlskFile] = (0..<12).map { makeFile(path, $0) }
                    let g = SoulseekStore.SearchGroup(user: "u" + String(i % 300), folder: path, files: files, freeSlot: i % 2 == 0,
                                                      speed: i * 37 % 9_000_000, queue: i % 7)
                    groups.append(g)
                    folders.append(SlskFolder(path: path, files: files))
                }
            }
            let build = clock(makeAll)
            let store = SoulseekStore()
            var search = SoulseekStore.Search(token: 99, query: "x")
            search.filters = SearchCommand("x is:lossless -live sort:quality").filters
            search.groups = Array(groups.prefix(18_000))
            var r1 = SoulseekStore.SearchResults(), r2 = r1, r3 = r1
            let cold = clock { r1 = store.results(for: search) }
            let warm = clock { for _ in 0..<100 { r2 = store.results(for: search) } } / 100
            search.groups = groups
            let more = clock { r3 = store.results(for: search) }
            let fresh = SoulseekStore().results(for: search)
            check(r1.groups.count == 18_000 && r2.groups.count == r1.groups.count && r3.groups.count == 20_000
                  && r3.groups.map(\.id) == fresh.groups.map(\.id) && r3.files == fresh.files,
                  "search results: cached and merged results match a full pass")
            var list: SoulseekStore.BrowseList?
            let index = clock { list = SoulseekStore.BrowseList(user: "u", folders: folders) }
            var hits = 0
            let filter = clock { hits = list!.matching("album 1999").count }
            print("  perf: 240k files, build \(Int(build)) ms; results cold \(Int(cold)) ms, cached \(String(format: "%.3f", warm)) ms, "
                  + "+2k folders \(Int(more)) ms; browse index \(Int(index)) ms, filter \(Int(filter)) ms (\(hits) hits)")
            check(warm < 1 && hits == 11 && list!.fileCount == 240_000, "search and browse: cached results and browse filter")
        }

        do {
            // Transfers group by user and remote folder, newest folder first, files in name order.
            typealias T = SoulseekStore.Transfer
            var a1 = T(id: UUID(), user: "u1", path: "m\\Album\\02 b.flac", size: 100); a1.bytes = 50; a1.state = .downloading
            var a2 = T(id: UUID(), user: "u1", path: "m\\Album\\01 a.flac", size: 100); a2.state = .done(URL(fileURLWithPath: "/tmp/a"))
            let b1 = T(id: UUID(), user: "u2", path: "m\\Album\\01 a.flac", size: 10)
            var c1 = T(id: UUID(), user: "u1", path: "m\\Other\\x.mp3", size: 10); c1.state = .failed("no")
            let groups = TransferGroup.make([a1, b1, a2, c1])
            check(groups.map(\.id) == ["u1|m\\Album", "u2|m\\Album", "u1|m\\Other"], "transfers: grouped by user and folder")
            check(groups[0].transfers.map(\.name) == ["01 a.flac", "02 b.flac"] && groups[0].name == "Album" && groups[0].parent == "m",
                  "transfers: files in name order")
            check(groups[0].done == 1 && groups[0].bytes == 150 && abs(groups[0].progress - 0.75) < 0.001 && groups[0].moving
                  && !groups[0].allFinished, "transfers: folder progress counts finished files whole")
            check(groups[2].allFinished && !groups[2].allDone && groups[2].failed.count == 1, "transfers: failed folder")
        }

        do {
            // Conversations, unread counts and ignored users, fed engine events directly.
            let store = SoulseekStore()
            store.persists = false
            store.debugHandle(.message(user: "alice", text: "hi there", sent: Date()))
            check(store.conversations.first?.user == "alice" && store.unreadMessages == 1, "messages: incoming message opens a conversation")
            store.startConversation(with: "alice")
            check(store.unreadMessages == 0 && store.openConversation == "alice", "messages: opening marks read")
            store.toggleIgnore("alice")
            store.debugHandle(.message(user: "alice", text: "again", sent: Date()))
            check(store.conversations.first?.messages.count == 1 && store.sessionLog.contains { $0.text.hasPrefix("dropped") },
                  "messages: ignored user's messages dropped and logged")
            check(store.sendMessage("hello", to: "bob")?.hasPrefix("Not connected") == true, "messages: not sent while offline")
            store.debugHandle(.trace("peer", "alice  connected directly  127.0.0.1:1"))
            check(store.sessionLog.last?.topic == .peer, "log: engine traces filed by topic")
        }

        let net = FakeSlskNetwork()
        guard await net.start() else { check(false, "soulseek: fake network listens"); return }

        // A taken name with the wrong password is refused with the server's reason.
        let taken = SlskClient()
        let takenLog = SlskLog()
        taken.onEvent = { takenLog.events.append($0) }
        taken.connect(.init(host: "127.0.0.1", port: net.serverPort, username: "taken", password: "nope", listenPort: 0, loopbackOnly: true))
        let refused = await waitUntil(5) { takenLog.events.contains { if case .loginFailed("INVALIDPASS") = $0 { return true } else { return false } } }
        check(refused, "soulseek: taken name refused", "\(takenLog.events)")
        check(SoulseekStore.loginReason("INVALIDPASS", creating: true).contains("already registered"), "soulseek: taken name explained")
        taken.disconnect()

        let shared = dir.appendingPathComponent("slsk-share/Shared Album", isDirectory: true)
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try? Data(count: 4096).write(to: shared.appendingPathComponent("01 Mine.flac"))
        let index = SlskShareIndex.build([shared])
        check(index.fileCount == 1 && index.lookup("Shared Album\\01 Mine.flac") != nil, "soulseek: share index")

        let client = SlskClient()
        let log = SlskLog()
        client.onEvent = { log.events.append($0) }
        client.setShares(index)
        client.connect(.init(host: "127.0.0.1", port: net.serverPort, username: "tester", password: "pw", listenPort: 0, loopbackOnly: true))
        let online = await waitUntil(5) { log.events.contains { if case .loggedIn = $0 { return true } else { return false } } }
        check(online, "soulseek: sign in", "\(log.events)")
        _ = await waitUntil(3) { log.events.contains { if case .listening(let p) = $0 { return p != nil } else { return false } } }

        client.search("test album", token: 77)
        let found = await waitUntil(5) { log.events.contains { if case .searchReply(let r) = $0 { return r.token == 77 && r.files.first == net.aliceFile } else { return false } } }
        check(found, "soulseek: search result from a peer", "\(log.events)")
        let browsed = await waitUntil(5) { net.browsedFolders != nil }
        check(browsed && net.browsedFolders?.first?.files.count == 1, "soulseek: peer browses our shares")
        check(log.events.contains { if case .sharesRequested("alice") = $0 { return true } else { return false } },
              "soulseek: share browsing reported")

        client.search("test single", user: "alice", token: 78)
        let userFound = await waitUntil(5) { log.events.contains { if case .searchReply(let r) = $0 { return r.token == 78 } else { return false } } }
        check(userFound, "soulseek: search one user's files", "\(log.events)")
        let messaged = await waitUntil(5) {
            log.events.contains { if case .message("alice", "hello from alice", _) = $0 { return true } else { return false } } && net.acked == [41]
        }
        check(messaged, "soulseek: private message received and acknowledged", "\(net.acked)")
        client.message("alice", "is the cd rip there too?")
        let replied = await waitUntil(5) {
            log.events.contains { if case .message("alice", "got: is the cd rip there too?", _) = $0 { return true } else { return false } }
        }
        check(replied && net.delivered.first?.0 == "alice", "soulseek: private message sent and answered", "\(net.delivered)")
        check(log.events.contains { if case .trace("peer", _) = $0 { return true } else { return false } }, "soulseek: peer connections traced")
        let counted = await waitUntil(5) { log.events.contains { if case .connections(let n) = $0 { return n > 0 } else { return false } } }
        check(counted, "soulseek: open connections reported")

        let target = dir.appendingPathComponent("slsk-dl/01 Test Song.flac")
        let id = UUID()
        client.download(id: id, user: "alice", path: net.aliceFile.path, size: net.aliceFile.size, to: target)
        let finished = await waitUntil(10) {
            log.events.contains { if case .download(let u) = $0, u.id == id { return u.state.isFinished } else { return false } }
        }
        let last = log.events.reversed().compactMap { e -> SlskTransferState? in if case .download(let u) = e, u.id == id { return u.state } else { return nil } }.first
        check(finished && (try? Data(contentsOf: target)) == net.aliceBytes, "soulseek: download completes byte for byte", "\(String(describing: last))")
        client.disconnect()

        // Raven Tunnel: config validation, then two WireGuard peers on loopback
        // with traffic through the tunnel's SOCKS5 endpoint (runs in the Go archive).
        if case .failure(let e) = RavenTunnel.describe("[Interface]\nAddress = 10.0.0.2/32\n") {
            check(e.message.contains("PrivateKey"), "raven tunnel: incomplete config rejected", e.message)
        } else {
            check(false, "raven tunnel: incomplete config rejected")
        }
        let tunnelFailure = RavenTunnel.selfTest()
        check(tunnelFailure == nil, "raven tunnel: wireguard round trip through the local endpoint", tunnelFailure ?? "")

        // Through a SOCKS5 proxy with a password: sign-in, then a search answered
        // by alice. Outbound only, so no listener is opened.
        let socks = FakeSocks5()
        socks.requireAuth = ("u", "p")
        if await socks.start() {
            let proxied = SlskClient()
            let plog = SlskLog()
            proxied.onEvent = { plog.events.append($0) }
            var route = SlskRoute()
            route.mode = .socks5
            route.proxyHost = "127.0.0.1"; route.proxyPort = socks.port
            route.proxyUser = "u"; route.proxyPassword = "p"
            proxied.connect(.init(host: "localhost", port: net.serverPort, username: "proxied", password: "pw",
                                  listenPort: 0, loopbackOnly: true, route: route))
            let up = await waitUntil(5) { plog.events.contains { if case .loggedIn = $0 { return true } else { return false } } }
            check(up && socks.targets.first == "localhost:\(net.serverPort)", "soulseek: sign-in through SOCKS5 (name resolved by proxy)", "\(plog.events) \(socks.targets)")
            check(plog.events.contains { if case .listening(nil) = $0 { return true } else { return false } }, "soulseek: no listener through a proxy")
            proxied.disconnect()

            var bad = route
            bad.proxyPassword = "wrong"
            let refused = SlskClient()
            let rlog = SlskLog()
            refused.onEvent = { rlog.events.append($0) }
            refused.connect(.init(host: "localhost", port: net.serverPort, username: "x", password: "pw", listenPort: 0, loopbackOnly: true, route: bad))
            let failed = await waitUntil(5) { rlog.events.contains { if case .loginFailed(let r) = $0 { return r.contains("username or password") } else { return false } } }
            check(failed, "soulseek: wrong proxy password refused", "\(rlog.events)")
            refused.disconnect()
            socks.stop()
        } else {
            check(false, "soulseek: fake proxy listens")
        }
        net.stop()
    }

    private static func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ✗ \(label) \(detail())")
        }
    }

    /// Mouse-wheel notches glide to exactly where AppKit would jump; trackpad
    /// (precise) deltas still move at once.
    @MainActor
    static func wheelGlide() async {
        SmoothWheel.install()
        var targetWindow = 0
        func wheel(_ lines: Int32, precise: Bool = false) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1,
                                   wheel1: lines, wheel2: 0, wheel3: 0) else { return nil }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
            // Over the middle of the test window, as a real pointer would be.
            let screenHeight = NSScreen.screens.first?.frame.height ?? 1000
            cg.location = CGPoint(x: 250, y: screenHeight - 250)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(targetWindow))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(targetWindow))
            return NSEvent(cgEvent: cg)
        }
        func findScroll(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = findScroll(sub) { return s } }
            return nil
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        targetWindow = window.windowNumber
        KeyableWindow.enable(window)
        for kind in ["AppKit", "SwiftUI"] {
            let scroll: NSScrollView
            if kind == "AppKit" {
                scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
                let doc = FlippedDoc(frame: NSRect(x: 0, y: 0, width: 300, height: 5000))
                scroll.documentView = doc
                window.contentView = scroll
            } else {
                let host = NSHostingView(rootView: ScrollView { VStack(spacing: 0) { ForEach(0..<300) { i in Text("row \(i)").frame(height: 20) } } }
                    .scrollIndicators(.never).frame(width: 300, height: 300))
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let s = findScroll(host) else { check(false, "wheel glide: SwiftUI scroll view found"); continue }
                scroll = s
            }
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let clip = scroll.contentView
            guard let notch = wheel(-3) else { continue }
            func send(_ e: NSEvent) { if kind == "AppKit" { window.sendEvent(e) } else { scroll.scrollWheel(with: e) } }
            SmoothWheel.enabled = false
            send(notch)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let native = clip.bounds.origin.y
            clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
            SmoothWheel.enabled = true
            send(notch)
            try? await Task.sleep(nanoseconds: 40_000_000)
            let mid = clip.bounds.origin.y
            try? await Task.sleep(nanoseconds: 300_000_000)
            let end = clip.bounds.origin.y
            check(native > 0 && mid > 0 && mid < native && abs(end - native) < 0.5,
                  "wheel glide (\(kind)): eases to the same place AppKit jumps to", "native \(native) mid \(mid) end \(end)")
            clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip)
            if let pad = wheel(-40, precise: true) {
                send(pad)
                try? await Task.sleep(nanoseconds: 100_000_000)
                check(clip.bounds.origin.y > 0, "wheel glide (\(kind)): trackpad deltas move at once", "\(clip.bounds.origin.y)")
            }
        }
        window.orderOut(nil)
    }

    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    /// Real clicks on the window buttons in a borderless window like ours.
    @MainActor
    static func windowButtons() async {
        func click(_ window: NSWindow, at p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
        }
        let skin = AppSession.shared.settings.styled(AppSession.shared.theme.skin)
        for closeOnly in [true, false] {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 80),
                                  styleMask: [.borderless, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = false
            let root = HStack { WindowControls(skin: skin, closeOnly: closeOnly); Spacer() }
                .padding(.leading, 14).frame(width: 300, height: 46, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
            window.contentView = NSHostingView(rootView: root)
            KeyableWindow.enable(window)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let side = CGFloat(AppSession.shared.settings.data.windowControlSide)
            let first = NSPoint(x: 14 + side / 2, y: window.frame.height - 23)
            // Close sits first unless the user moved it last.
            click(window, at: first)
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(!window.isVisible || AppSession.shared.settings.data.windowControlCloseLast,
                  "window buttons: a click on Close closes the window" + (closeOnly ? " (child window)" : ""),
                  "still visible: \(window.isVisible)")
            window.orderOut(nil)
        }
    }

    static func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("i2s self-test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meimei-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        paneResize()
        navigationHistory()
        await sheetFrame()
        iconPacks()
        equalizer()
        await flac(dir)
        id3()
        analyzer()
        await coverTheme(dir)
        await scanner(dir)
        await metadataSaving(dir)
        await engineGapless(dir)
        await engineCrossfade(dir)
        await soulseek(dir)
        failures += CoreChecks.run(dir)
        appModels()
        await listenTracking(dir)
        await profileStats(dir)
        await windowButtons()
        await wheelGlide()

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    /// The real player and history: muted playback isn't a listen; audible
    /// playback past half the track is, timed by what was actually heard.
    @MainActor
    private static func listenTracking(_ dir: URL) async {
        let session = AppSession.shared
        let url = dir.appendingPathComponent("listen.wav")
        guard writeTone(url, hz: 0, seconds: 31, bitDepth: 16) else { return check(false, "listen tracking: test file") }
        guard await waitUntil(10, { session.history.isReady }), session.history.device != nil else {
            return check(false, "listen tracking: history opens", session.history.failure ?? "")
        }
        let track = Track(filePath: url.path, title: "Silence", artist: "Test", album: "Test", duration: 31, sampleRate: 44100,
                          bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 1411, fileFormat: "WAV")
        let player = session.player
        let volume = player.engine.volume
        let before = session.history.listens.count

        player.engine.volume = 0
        player.play([track])
        try? await Task.sleep(nanoseconds: 16_500_000_000)
        player.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(session.history.listens.count == before, "listen tracking: muted playback isn't a listen")

        player.engine.volume = 0.5
        player.play([track])
        try? await Task.sleep(nanoseconds: 16_500_000_000)
        player.stop()
        let recorded = await waitUntil(3) { session.history.listens.count == before + 1 }
        let heard = session.history.listens.last?.heardSeconds ?? 0
        check(recorded && heard > 15 && heard < 17.5, "listen tracking: half a track heard is a listen", "\(session.history.listens.count - before) listens, heard \(heard)s")
        player.engine.volume = volume
    }

    /// Profile stats are the same after the history is read back from disk,
    /// and the library's play counts are exactly the history's.
    @MainActor
    /// The library half of the profile checks (the core half is `CoreChecks.profile`,
    /// which seeds the history this reopens): play counts come from the history only.
    private static func profileStats(_ dir: URL) async {
        let support = dir.appendingPathComponent("profile", isDirectory: true)
        let historyDir = support.appendingPathComponent("History", isDirectory: true)
        guard let second = try? ListenLog(dir: historyDir, secrets: FileHistorySecrets(dir: historyDir)) else {
            return check(false, "profile: history reopens")
        }

        let library = LibraryStore(supportDirectory: support)
        check(library.tracks.count == 40 && library.tracks.allSatisfy { $0.playCount == 0 && $0.lastPlayedAt == nil },
              "profile: play counts in the library file are ignored", "\(library.tracks.map(\.playCount).prefix(5))")
        library.applyListenStats(ListenStats(second.listens))
        var expected: [UUID: (Int, Date)] = [:]
        for l in second.listens {
            let e = expected[l.trackID]
            expected[l.trackID] = ((e?.0 ?? 0) + 1, max(e?.1 ?? l.endedAt, l.endedAt))
        }
        let matches = library.tracks.allSatisfy { t in
            let e = expected[t.id]
            return t.playCount == (e?.0 ?? 0) && t.lastPlayedAt == e?.1
        }
        check(matches, "profile: library play counts are exactly the history's")
    }

    // MARK: Library scanner

    private static func scanner(_ dir: URL) async {
        print("library scanner")
        let fm = FileManager.default
        let support = dir.appendingPathComponent("scan-support")
        let music = dir.appendingPathComponent("Scan Music")
        let albumA = music.appendingPathComponent("Artist/Album A")
        let albumB = music.appendingPathComponent("Artist/Album B")
        let skipped = music.appendingPathComponent("Samples")
        for d in [support, albumA, albumB, skipped] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for (i, d) in [albumA, albumA, albumB].enumerated() {
            _ = writeTone(d.appendingPathComponent("track\(i).wav"), hz: 440 + Double(i) * 110, seconds: 0.5, bitDepth: 16)
        }
        _ = writeTone(skipped.appendingPathComponent("hit.wav"), hz: 880, seconds: 0.2, bitDepth: 16)

        let library = LibraryStore(supportDirectory: support)
        let scanner = LibraryScanner(library: library)
        scanner.options.ignoredFolderNames = ["Samples"]
        func settle() async {
            for _ in 0..<200 where scanner.isScanning { try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        scanner.addFolders([music])
        await settle()
        check(library.tracks.count == 3, "adding a folder imports its files", "\(library.tracks.count)")
        check(scanner.lastReport?.added == 3, "the report counts them")
        check(!library.tracks.contains { $0.filePath.contains("/Samples/") }, "ignored folder names are skipped")
        scanner.addFolders([albumA])
        check(scanner.folders.count == 1, "a folder inside a library folder isn't added twice")

        // Changed: rewrite a file longer.
        let changedURL = albumB.appendingPathComponent("track2.wav")
        try? fm.removeItem(at: changedURL)
        _ = writeTone(changedURL, hz: 660, seconds: 1.0, bitDepth: 16)
        scanner.scan()
        await settle()
        check(scanner.lastReport?.refreshed == 1, "a changed file is read again", "\(String(describing: scanner.lastReport))")
        check(library.tracks.first { $0.filePath == changedURL.path }.map { $0.duration > 0.9 } == true, "with its new length")

        // Moved: same name and size, new place.
        library.recordPlay(library.tracks.first { $0.filePath.hasSuffix("track0.wav") }!.id)
        let moved = albumB.appendingPathComponent("track0.wav")
        try? fm.moveItem(at: albumA.appendingPathComponent("track0.wav"), to: moved)
        scanner.scan()
        await settle()
        let movedTrack = library.tracks.first { $0.filePath == moved.path }
        check(scanner.lastReport?.relinked == 1 && library.tracks.count == 3, "a moved file is relinked, not re-added",
              "\(String(describing: scanner.lastReport)) count \(library.tracks.count)")
        check(movedTrack?.playCount == 1, "and keeps its play count")

        // Missing, then located.
        let gone = albumA.appendingPathComponent("track1.wav")
        let elsewhere = dir.appendingPathComponent("track1.wav")
        try? fm.moveItem(at: gone, to: elsewhere)
        scanner.scan()
        await settle()
        check(scanner.missingIDs.count == 1, "a deleted file is listed as missing", "\(scanner.missingIDs.count)")
        if let id = scanner.missingIDs.first {
            scanner.locate(id, at: elsewhere)
            check(scanner.missingIDs.isEmpty && library.track(id: id)?.filePath == elsewhere.path, "locating relinks it")
        }

        // Offline: the folder vanishes (an unplugged drive).
        let parked = dir.appendingPathComponent("Parked")
        try? fm.moveItem(at: music, to: parked)
        scanner.scan()
        await settle()
        check(scanner.offlineFolderIDs.count == 1, "an unreachable folder is offline")
        check(scanner.missingIDs.isEmpty, "and its tracks aren't marked missing", "\(scanner.missingIDs.count)")
        try? fm.moveItem(at: parked, to: music)

        // Suggestions for a library built without folders.
        let loose = LibraryScanner(library: library)
        loose.removeFolder(loose.folders.first!.id, removingTracks: false)
        let suggested = loose.suggestedFolders().map(\.path)
        check(suggested.contains(where: { music.path.hasPrefix($0) || $0.hasPrefix(music.path) }),
              "existing tracks suggest their folders", "\(suggested)")
    }

    // MARK: Metadata saving

    private static func metadataSaving(_ dir: URL) async {
        print("metadata saving")
        let folder = dir.appendingPathComponent("meta-music")
        let support = dir.appendingPathComponent("meta-support")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("a.wav")
        let flac = folder.appendingPathComponent("a.flac")
        _ = writeTone(wav, hz: 440, seconds: 0.5, bitDepth: 16)
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        try? convert.run()
        convert.waitUntilExit()
        try? FileManager.default.removeItem(at: wav)

        let library = LibraryStore(supportDirectory: support)
        await withCheckedContinuation { c in library.importItems([flac]) { c.resume() } }
        guard var track = library.tracks.first else { return check(false, "import a FLAC to edit") }
        let saver = MetadataSaver(library: library)
        track.title = "Edited Title"
        track.albumArtist = "Beyoncé"
        track.year = 2016
        let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let cover = ArtworkStore.normalizedJPEG(from: red.tiffRepresentation!)
        await saver.save([track], cover: cover, writeFiles: true)
        check(library.track(id: track.id)?.title == "Edited Title", "the library takes the edit")
        check(library.track(id: track.id)?.artworkFilePath != nil, "and the new cover")
        check(saver.failures.isEmpty, "the file is written", saver.failures.map(\.reason).joined())
        let reread = await MetadataReader.readTrack(url: flac, artwork: library.artwork)
        check(reread?.title == "Edited Title" && reread?.albumArtist == "Beyoncé" && reread?.year == 2016,
              "the file's tags read back", "\(reread.map { "\($0.title) / \($0.albumArtist) / \(String(describing: $0.year))" } ?? "nil")")
        check(reread?.artworkFilePath != nil, "with the cover embedded")

        // Lyrics inside the tags.
        if let current = library.track(id: track.id) {
            let lrc = "[00:01.00] first line\n[00:02.50] second line"
            do {
                try await MetadataWriter.write(MetadataWriter.Fields(current, lyrics: lrc), artworkJPEG: nil, to: flac)
                let back = await EmbeddedLyrics.read(flac)
                check(back == lrc, "lyrics embed and read back", back ?? "nil")
                try await MetadataWriter.write(MetadataWriter.Fields(current), artworkJPEG: nil, to: flac)
                check(await EmbeddedLyrics.read(flac) == lrc, "a tag edit leaves lyrics alone")
            } catch {
                check(false, "lyrics write", error.localizedDescription)
            }
        }
        check(LyricsState.of("[01:02.03] hi") == .synced && LyricsState.of("just words") == .plain && LyricsState.of("  ") == LyricsState.none,
              "lyrics are told apart: synced, plain, none")

        // Pairing a tracklist with local tracks.
        func t(_ n: Int?, _ title: String) -> Track {
            Track(filePath: "/x/\(title).flac", title: title, artist: "x", album: "x", trackNumber: n, duration: 1,
                  sampleRate: 44_100, bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 0, fileFormat: "FLAC")
        }
        let songs = [AlbumMatch.Song(disc: 1, number: 1, title: "One More Time", artist: "Daft Punk"),
                     AlbumMatch.Song(disc: 1, number: 2, title: "Aerodynamic", artist: "Daft Punk")]
        let match = AlbumMatch(id: "x", source: .musicBrainz, title: "Discovery", artist: "Daft Punk", year: 2001, genre: nil,
                               trackCount: 2, note: nil, cover: nil, lookupID: "x")
        let numbered = AlbumMatcher.apply(match, songs: songs, to: [t(2, "aerodynamic"), t(1, "one more time")], fields: [.titles, .album, .year])
        check(numbered.first { $0.trackNumber == 2 }?.title == "Aerodynamic" && numbered.allSatisfy { $0.album == "Discovery" && $0.year == 2001 },
              "numbered tracks pair by number")
        let loose = AlbumMatcher.apply(match, songs: songs, to: [t(nil, "a"), t(nil, "b")], fields: [.titles, .numbers])
        check(loose.map(\.trackNumber) == [1, 2] && loose.map(\.title) == ["One More Time", "Aerodynamic"], "unnumbered tracks pair in order")
    }

    // MARK: Icon packs

    private static func iconPacks() {
        print("icon packs")
        for pack in IconPack.allCases {
            let blank = IconTheme.roles.filter { role in
                (pack.table[role] ?? Glyph.codes[role]).flatMap(GlyphOutlines.outline) == nil
            }
            check(blank.isEmpty, "\(pack.label): every icon draws", blank.joined(separator: ", "))
        }
        let unnamed = IconTheme.roles.filter { IconRoles.info[$0] == nil }
        check(unnamed.isEmpty, "every icon has a name", unnamed.joined(separator: ", "))
        let theme = IconTheme.shared
        theme.apply(pack: .codicons, scale: 1, overrides: ["heart": 0xF0F25])
        check(theme.code(for: "heart") == 0xF0F25 && theme.code(for: "play.fill") == IconPackTables.codicons["play.fill"],
              "overrides win over the pack")
        theme.apply(pack: .material, scale: 1, overrides: [:])
    }

    // MARK: Sheets

    /// A real sheet over an invisible window: square (no titled, rounded
    /// frame) and still able to take typing.
    private static func sheetFrame() async {
        print("sheet frame")
        let skin = AppSession.shared.settings.styled(AppSession.shared.theme.skin)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SheetHost(skin: skin))
        window.orderFront(nil)
        var sheet: NSWindow?
        for _ in 0..<40 where sheet == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
            sheet = window.attachedSheet
        }
        // It squares itself within a frame or two of attaching.
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(sheet != nil, "a sheet attaches", NSApp.windows.map { "\(type(of: $0)) mask=\($0.styleMask.rawValue) sheet=\($0.isSheet) parent=\($0.sheetParent === window)" }.joined(separator: "; "))
        if let sheet {
            check(!sheet.styleMask.contains(.titled), "sheets are square (no titled frame)", "mask \(sheet.styleMask.rawValue)")
            check(sheet.canBecomeKey, "sheets can take typing")
            window.endSheet(sheet)
        }
        window.orderOut(nil)
    }

    private struct SheetHost: View {
        var skin: Skin
        @State private var shown = false
        var body: some View {
            Color.clear.frame(width: 500, height: 400)
                .sheet(isPresented: $shown) { ConfirmDialog(title: "Test", message: "Sheet frame", confirmTitle: "OK", skin: skin, onConfirm: {}, onCancel: {}) }
                .onAppear { shown = true }
        }
    }

    // MARK: Back and forward

    private static func navigationHistory() {
        print("navigation history")
        let lib = AppSession.shared.library
        let start = lib.source
        lib.resetNavigationHistory()
        check(!lib.canGoBack && !lib.canGoForward, "a fresh history goes nowhere")
        lib.source = .albums
        lib.source = .artists
        lib.source = .liked
        lib.goBack()
        check(lib.source == .artists && lib.navigationMove.direction == -1, "back returns to the last page", "\(lib.source)")
        lib.goBack()
        check(lib.source == .albums && lib.canGoForward, "back again, forward is open", "\(lib.source)")
        lib.goForward()
        check(lib.source == .artists && lib.navigationMove.direction == 1, "forward returns", "\(lib.source)")
        lib.source = .recentlyAdded
        check(!lib.canGoForward, "a new visit clears what was ahead")
        lib.goBack()
        check(lib.source == .artists, "back after a new visit", "\(lib.source)")
        lib.albumKey = "missing::album"
        lib.source = .liked
        lib.goBack()
        check(lib.source == .artists && lib.albumKey == nil, "a removed album falls back to its page", "\(lib.source) \(lib.albumKey ?? "-")")
        while lib.canGoBack { lib.goBack() }
        lib.goBack()
        check(!lib.canGoBack, "back at the start does nothing", "\(lib.source)")
        lib.source = start
        lib.resetNavigationHistory()
    }

    // MARK: Pane resize

    private static func paneResize() {
        print("pane resize")
        let layout = PaneLayout(columns: [
            PaneColumn(panes: [.nowPlaying, .browse]),
            PaneColumn(panes: [.library]),
            PaneColumn(panes: [.lyrics, .playlists]),
        ])
        let frames: [PaneID: CGRect] = [
            .nowPlaying: CGRect(x: 0, y: 0, width: 260, height: 300),
            .browse: CGRect(x: 0, y: 308, width: 260, height: 492),
            .library: CGRect(x: 268, y: 0, width: 632, height: 800),
            .lyrics: CGRect(x: 908, y: 0, width: 260, height: 400),
            .playlists: CGRect(x: 908, y: 408, width: 260, height: 392),
        ]
        let edges = PaneResize.movableEdges(of: .nowPlaying, layout: layout, frames: frames)
        check(edges.horizontal == [.trailing] && edges.vertical == [.bottom], "only shared edges resize", "\(edges)")
        let lib = PaneResize.movableEdges(of: .library, layout: layout, frames: frames)
        check(lib.horizontal == [.leading, .trailing] && lib.vertical.isEmpty, "library resizes sideways only", "\(lib)")

        let corner = PaneResize(pane: .nowPlaying, horizontal: .trailing, vertical: .bottom, frames: frames, layout: layout, gap: 8)
        let snapped = corner.apply(CGSize(width: 0, height: 95))
        check(snapped.rect.maxY == 400, "bottom edge snaps to the next column's edge", "\(snapped.rect)")
        check(snapped.guides.contains { $0.axis == .y && $0.position == 400 }, "snap shows a guide")
        let w = snapped.layout.columns[0].weights
        check(w[.nowPlaying] == 400 && w[.browse] == 392, "the pane below gives up the height", "\(w)")
        let free = corner.apply(CGSize(width: 0, height: 95), snapping: false)
        check(free.rect.maxY == 395 && free.guides.isEmpty, "⌘ turns snapping off", "\(free.rect)")
        let tiny = corner.apply(CGSize(width: 0, height: -1000))
        check(tiny.rect.height == PaneResize.minHeight, "panes keep a minimum height", "\(tiny.rect)")
        let wide = corner.apply(CGSize(width: 2000, height: 0))
        check(wide.layout.columns[0].width == 532, "a column never squeezes the library below its minimum",
              "\(String(describing: wide.layout.columns[0].width))")

        let fromLibrary = PaneResize(pane: .library, horizontal: .trailing, vertical: nil, frames: frames, layout: layout, gap: 8)
        let shrunk = fromLibrary.apply(CGSize(width: 50, height: 0))
        check(shrunk.layout.columns[2].width == 210 && shrunk.rect.maxX == 950,
              "the library's edge resizes its neighbor", "\(String(describing: shrunk.layout.columns[2].width)) \(shrunk.rect)")
        let matched = fromLibrary.apply(CGSize(width: 3, height: 0))
        check(matched.layout.columns[2].width == 260, "widths snap to match the other side column",
              "\(String(describing: matched.layout.columns[2].width))")

        var moved = snapped.layout
        moved.move(.nowPlaying, to: .stack(column: 2, index: 0))
        check(moved.columns.allSatisfy { $0.weights.isEmpty }, "moving a pane resets the stacks it leaves and joins")
    }

    // MARK: Equalizer

    private static func equalizer() {
        print("equalizer")
        let bell = EQBand(frequency: 1000, gain: 6, q: 1)
        check(abs(EqualizerResponse.gain(atHz: 1000, band: bell) - 6) < 0.05, "bell peaks at its gain")
        check(abs(EqualizerResponse.gain(atHz: 50, band: bell)) < 0.3, "bell leaves distant frequencies alone")
        let cut = EQBand(type: .lowCut, frequency: 100, slope: 48)
        let octaveBelow = EqualizerResponse.gain(atHz: 50, band: cut)
        check(octaveBelow < -40 && octaveBelow > -60, "48 dB/oct cut is ~48 dB down an octave below", "\(octaveBelow)")
        check(abs(EqualizerResponse.gain(atHz: 1000, band: cut)) < 0.2, "cut passband is flat")
        check(cut.slotCount == 4 && bell.slotCount == 1, "cuts cascade one slot per 12 dB/oct")
        check(abs(EQBand.q(fromOctaves: bell.octaves) - bell.q) < 1e-9, "Q ↔ octaves round-trips")

        let legacy = #"{"enabled":true,"preampGain":-3,"bandGains":[4,0,0,0,0,0,0,0,0,-2],"bandBypass":[false,false,false,false,false,false,false,false,false,true],"bandwidth":1}"#
        let migrated = EqualizerSettingsData.load(from: Data(legacy.utf8))
        check(migrated.enabled && migrated.preampGain == -3, "legacy EQ keeps on/off and preamp")
        check(migrated.bands.count == 2 && migrated.bands[0].frequency == 31 && migrated.bands[1].enabled == false,
              "legacy graphic bands become bells", "\(migrated.bands.map { ($0.frequency, $0.gain, $0.enabled) })")

        let apo = "Preamp: -6.2 dB\nFilter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70\nFilter 2: ON LSC Fc 80 Hz Gain 2.0 dB Q 0.71\nFilter 3: ON HPQ Fc 20 Hz Q 0.7\nFilter 4: OFF PK Fc 3000 Hz Gain -3 dB Q 2\n"
        let parsed = ParametricEQText.parse(apo, name: "Test")
        check(parsed?.bands.count == 3 && parsed?.preampGain == -6.2 && parsed?.bands[1].type == .lowShelf && parsed?.bands[2].type == .lowCut,
              "AutoEQ text imports", "\(parsed.map { $0.bands.map(\.type) } ?? [])")
        var d = EqualizerSettingsData()
        d.bands = parsed?.bands ?? []
        d.preampGain = parsed?.preampGain ?? 0
        let again = ParametricEQText.parse(ParametricEQText.export(d), name: "Again")
        check(again?.bands.map(\.type) == d.bands.map(\.type) && again?.bands.first?.gain == 5.5, "AutoEQ text round-trips")
        check(EQFormat.parseFrequency("2.5k") == 2500 && EQFormat.parseFrequency("80 Hz") == 80, "typed frequencies parse")
    }

    // MARK: App models

    /// Model checks that still live in the app (lyrics store, Mac colours); the rest are `CoreChecks.models`.
    @MainActor
    private static func appModels() {
        print("app models")
        let store = LyricsStore()
        store.apply("[00:01.50]one\n[00:03.00][00:07.25]two\n[00:05]three", label: "t")
        check(store.isSynced && store.currentIndex(at: 4) == 1, "lyrics store follows the shared rules")

        // Built-in themes drawn on the Mac carry exactly the shared palettes' colours.
        let roundTrip = CustomTheme.starterThemes.allSatisfy { t in
            var back = CustomTheme(id: t.id, name: t.name, from: t.makeSkin())
            back.category = t.category
            back.isAlbumReactive = t.isAlbumReactive
            return back == t
        }
        check(roundTrip, "starter themes survive the trip through Mac colours")
    }

    // MARK: Tag writers

    private static func flac(_ dir: URL) async {
        print("FLAC tags")
        let wav = dir.appendingPathComponent("tone.wav")
        let flac = dir.appendingPathComponent("tone.flac")
        guard writeTone(wav, hz: 440, seconds: 1, bitDepth: 24) else { return check(false, "make test WAV") }
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "flac", "-d", "flac", wav.path, flac.path]
        try? convert.run()
        convert.waitUntilExit()
        guard FileManager.default.fileExists(atPath: flac.path) else { return check(false, "afconvert to FLAC") }

        check(MetadataReader.losslessBitDepth(url: flac, format: "FLAC") == 24, "reads 24-bit from STREAMINFO")

        // Seed a foreign comment that must survive our write.
        var fields = MetadataWriter.Fields(Track(filePath: flac.path, title: "Seed", artist: "A", album: "B", duration: 1,
                                                 sampleRate: 44100, bitDepth: 24, channelCount: 2, estimatedBitrateKbps: 0, fileFormat: "FLAC"))
        do {
            try FLACWriter.write(fields, artwork: nil, to: flac)
            var data = try Data(contentsOf: flac)
            var (blocks, audio) = try FLACWriter.parse(data)
            if let i = blocks.firstIndex(where: { $0.type == 4 }) {
                var (vendor, comments) = try FLACWriter.parseComments(blocks[i].body)
                comments.append("REPLAYGAIN_TRACK_GAIN=-6.20 dB")
                vendor = "test"
                blocks[i].body = FLACWriter.encodeComments(vendor: vendor, comments: comments)
            }
            var rebuilt = Data("fLaC".utf8)
            for (n, b) in blocks.enumerated() {
                let len = b.body.count
                rebuilt.append(contentsOf: [(n == blocks.count - 1 ? 0x80 : 0) | b.type, UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)])
                rebuilt.append(b.body)
            }
            rebuilt.append(data[audio...])
            try rebuilt.write(to: flac)

            fields.title = "Wörld & Friends"
            fields.artist = "Ärtist"
            fields.year = 2024
            fields.trackNumber = 7
            let cover = ArtworkStore.normalizedJPEG(from: NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
                NSColor.systemPink.setFill(); r.fill(); return true
            }.tiffRepresentation!)!
            try FLACWriter.write(fields, artwork: cover, to: flac)

            data = try Data(contentsOf: flac)
            (blocks, audio) = try FLACWriter.parse(data)
            let comments = try FLACWriter.parseComments(blocks.first { $0.type == 4 }!.body)
            check(comments.vendor == "test", "vendor string preserved")
            check(comments.comments.contains("REPLAYGAIN_TRACK_GAIN=-6.20 dB"), "foreign comment preserved")
            check(comments.comments.filter { $0.hasPrefix("TITLE=") } == ["TITLE=Wörld & Friends"], "title replaced, not duplicated")
            check(blocks.contains { $0.type == 6 }, "picture block written")

            let store = ArtworkStore(directory: dir)
            let read = await MetadataReader.readTrack(url: flac, artwork: store)
            check(read?.title == "Wörld & Friends" && read?.artist == "Ärtist" && read?.year == 2024 && read?.trackNumber == 7,
                  "AVFoundation reads the written tags back", "\(String(describing: read))")
            check(read?.artworkFilePath != nil, "AVFoundation reads the written cover back")
            check(read?.bitDepth == 24, "bit depth survives the rewrite")
            check(abs((read?.duration ?? 0) - 1) < 0.05, "audio intact after rewrite")
        } catch {
            check(false, "FLAC write", "\(error)")
        }
    }

    private static func id3() {
        print("ID3 tags")
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            return Array(id.utf8) + [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), 0, 0] + body
        }
        let frames = frame("TIT2", [0] + Array("Old".utf8)) + frame("COMM", [0] + Array("engHello".utf8))
            + frame("USLT", [0] + Array("eng\u{0}la la".utf8)) + frame("APIC", [0] + Array("image/png".utf8) + [0, 3, 0, 1, 2, 3])
        let size = frames.count
        let header: [UInt8] = Array("ID3".utf8) + [3, 0, 0, UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        let audio = Data((0..<4096).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meimei-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try (Data(header + frames) + audio).write(to: url)
            var fields = MetadataWriter.Fields(Track(filePath: url.path, title: "New Title", artist: "Someone", album: "", duration: 1,
                                                     sampleRate: 44100, bitDepth: 16, channelCount: 2, estimatedBitrateKbps: 128, fileFormat: "MP3"))
            fields.year = 1999
            try ID3Writer.write(fields, artwork: nil, to: url)
            let written = try Data(contentsOf: url)
            let (parsed, audioStart) = try ID3Writer.parse(written)
            let ids = parsed.map(\.id)
            check(written[3] == 4, "rewritten as ID3v2.4")
            check(ids.filter { $0 == "TIT2" }.count == 1 && String(decoding: parsed.first { $0.id == "TIT2" }!.body.dropFirst(), as: UTF8.self) == "New Title",
                  "title replaced")
            check(ids.contains("COMM") && ids.contains("USLT"), "comment and lyrics frames preserved", "\(ids)")
            check(ids.contains("APIC"), "existing cover kept when artwork unchanged")
            check(ids.contains("TDRC") && !ids.contains("TALB"), "year written, empty album omitted")
            check(written[audioStart...] == audio, "audio bytes untouched")
        } catch {
            check(false, "ID3 write", "\(error)")
        }
    }

    // MARK: Analyzer

    private static func analyzer() {
        print("spectrum analyzer")
        SpectrumAnalyzer.bandCount.value = 24
        let analyzer = SpectrumAnalyzer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        for c in 0..<2 {
            for i in 0..<4096 { buffer.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 1000 * Float(i) / 44_100) }
        }
        let bands = analyzer.process(buffer)?.bands ?? []
        let peak = bands.indices.max { bands[$0] < bands[$1] } ?? -1
        let center = 30 * pow(16_000 / 30.0, (Double(peak) + 0.5) / 24)
        check(center > 700 && center < 1400, "1 kHz tone lands in the 1 kHz band", "peak band center \(Int(center)) Hz")
        check((bands.max() ?? 0) > 0.8, "−6 dBFS tone reads near the top", "\(bands.max() ?? 0)")
        let far = bands.enumerated().filter { abs($0.offset - peak) > 4 }.map(\.element).max() ?? 1
        check(far < 0.45, "energy stays local to the tone", "\(far)")
        for c in 0..<2 { for i in 0..<4096 { buffer.floatChannelData![c][i] = 0 } }
        check((analyzer.process(buffer)?.bands ?? [1]).allSatisfy { $0 == 0 }, "silence reads as zero")
    }

    // MARK: Theme

    private static func coverTheme(_ dir: URL) async {
        print("cover theme")
        let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.15, alpha: 1).setFill(); r.fill(); return true
        }
        let path = dir.appendingPathComponent("red.jpg").path
        guard let jpeg = ArtworkStore.normalizedJPEG(from: red.tiffRepresentation!),
              (try? jpeg.write(to: URL(fileURLWithPath: path))) != nil else { return check(false, "make test cover") }

        let theme = ThemeManager()
        let before = theme.activeThemeID
        theme.ingestArtwork(at: path)            // not live yet: only remembered
        theme.setActive(CustomTheme.albumReactiveID)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        check(theme.artworkImage != nil, "switching to From Cover samples the current cover")
        let accent = NSColor(theme.skin.accent).usingColorSpace(.sRGB)
        check((accent?.redComponent ?? 0) > (accent?.blueComponent ?? 1), "palette follows a red cover", "\(String(describing: accent))")
        theme.setActive(before)
    }

    // MARK: Engine

    /// Plays two tones back to back and measures the rendered output for any dip.
    private static func engineGapless(_ dir: URL) async {
        print("engine: gapless")
        let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
        guard writeTone(a, hz: 440, seconds: 2.5, bitDepth: 16), writeTone(b, hz: 660, seconds: 1.5, bitDepth: 16) else {
            return check(false, "make test tones")
        }
        let engine = AudioEngine()
        engine.volume = 1
        let recorder = OutputRecorder(node: engine.outputNode)
        var advanced: (UUID, Date)?
        var ended = false
        engine.onAdvance = { advanced = ($0, Date()) }
        engine.onEnded = { ended = true }
        let idB = UUID()
        let started = Date()
        do { try engine.start(url: a, id: UUID()) } catch { return check(false, "engine start", "\(error)") }
        engine.setNext(url: b, id: idB)
        try? await Task.sleep(nanoseconds: 4_600_000_000)
        recorder.stop()

        check(advanced?.0 == idB, "advanced to the prepared track")
        if let at = advanced?.1 {
            check(abs(at.timeIntervalSince(started) - 2.5) < 0.35, "advance at the boundary", "\(at.timeIntervalSince(started))s")
        }
        check(ended, "end reported after the last track")
        let windows = recorder.rmsWindows(ms: 5)
        // Skip the engine's start-up, then cover both tracks up to just before the end.
        let body = windows.drop(while: { $0 < 0.05 }).dropFirst(10).prefix(Int(3.6 / 0.005))
        let quietest = body.min() ?? 0
        check(quietest > 0.2, "no gap between tracks (quietest 5 ms window \(String(format: "%.3f", quietest)))")
        check(engine.currentID == idB, "engine reports the new current id")
        engine.stop()

        // Control: the old approach (wait for the end, then load the next
        // file) must show up as a gap, or the measurement above proves nothing.
        let naive = AudioEngine()
        naive.volume = 1
        let control = OutputRecorder(node: naive.outputNode)
        naive.onEnded = { try? naive.start(url: b, id: idB) }
        do { try naive.start(url: a, id: UUID()) } catch { return check(false, "control start", "\(error)") }
        try? await Task.sleep(nanoseconds: 4_400_000_000)
        control.stop()
        let controlBody = control.rmsWindows(ms: 5).drop(while: { $0 < 0.05 }).dropFirst(10).prefix(Int(3.6 / 0.005))
        check((controlBody.min() ?? 1) < 0.1, "control: end-then-load does leave a measurable gap (quietest \(String(format: "%.3f", controlBody.min() ?? 1)))")
        naive.stop()
    }

    private static func engineCrossfade(_ dir: URL) async {
        print("engine: crossfade")
        let a = dir.appendingPathComponent("c.wav"), b = dir.appendingPathComponent("d.wav")
        guard writeTone(a, hz: 330, seconds: 3, bitDepth: 16), writeTone(b, hz: 550, seconds: 3, bitDepth: 16) else {
            return check(false, "make test tones")
        }
        let engine = AudioEngine()
        engine.volume = 1
        engine.crossfadeDuration = 1.0
        let recorder = OutputRecorder(node: engine.outputNode)
        var advancedAt: Date?
        engine.onAdvance = { _ in advancedAt = Date() }
        let started = Date()
        do { try engine.start(url: a, id: UUID()) } catch { return check(false, "engine start", "\(error)") }
        engine.setNext(url: b, id: UUID())
        try? await Task.sleep(nanoseconds: 3_400_000_000)
        recorder.stop()
        if let advancedAt {
            check(abs(advancedAt.timeIntervalSince(started) - 2.0) < 0.3, "fade starts 1 s before the end",
                  "\(advancedAt.timeIntervalSince(started))s")
        } else {
            check(false, "crossfade started")
        }
        let windows = recorder.rmsWindows(ms: 10)
        let body = windows.drop(while: { $0 < 0.05 }).dropFirst(10).prefix(250)
        let quietest = body.min() ?? 0
        check(quietest > 0.2, "no dip through the fade (quietest \(String(format: "%.3f", quietest)))")
        engine.stop()
    }

    // MARK: Helpers

    private static func writeTone(_ url: URL, hz: Double, seconds: Double, bitDepth: Int) -> Bool {
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bitDepth, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * seconds)) else {
            return false
        }
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate))
            }
        }
        return (try? file.write(from: buffer)) != nil
    }
}

/// Captures the engine's rendered output for analysis.
private final class OutputRecorder: @unchecked Sendable {
    private let node: AVAudioMixerNode
    private let samples = LockedValue<[Float]>([])
    private(set) var rate: Double = 44_100

    @MainActor
    init(node: AVAudioMixerNode) {
        self.node = node
        let format = node.outputFormat(forBus: 0)
        rate = format.sampleRate
        let samples = self.samples
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            samples.mutate { $0.append(contentsOf: chunk) }
        }
    }

    func stop() { node.removeTap(onBus: 0) }

    func rmsWindows(ms: Double) -> [Float] {
        let all = samples.value
        let size = max(1, Int(rate * ms / 1000))
        return stride(from: 0, to: all.count - size, by: size).map { start in
            var sum: Float = 0
            for i in start..<(start + size) { sum += all[i] * all[i] }
            return (sum / Float(size)).squareRoot()
        }
    }
}
#endif
