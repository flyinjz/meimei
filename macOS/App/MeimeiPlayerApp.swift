import SwiftUI
import AppKit

@main
struct MeimeiPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Before any view asks for a font.
        AppFont.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .scrollIndicators(.never)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1240, height: 780)
        .commands { MeimeiCommands() }

        Window("Equalizer", id: "equalizer") {
            EqualizerWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1020, height: 640)

        Window("Settings", id: "settings") {
            SettingsWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)

        Window("Library", id: "library") {
            LibraryManagerWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 640)

        Window("Downloads", id: "downloads") {
            DownloadsWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 580)

        Window("Legal and Compliance", id: "soulseek-legal") {
            SoulseekLegalWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 720)

        Window("Mini Player", id: "mini-player") {
            MiniPlayerView()
                .scrollIndicators(.never)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 88)
    }
}

/// Menu bar commands. Playback acts on the session directly; anything that
/// presents UI is routed to the main window as a `WindowRequest`.
struct MeimeiCommands: Commands {
    private var player: PlayerController { AppSession.shared.player }
    private var settings: AppSettings { AppSession.shared.settings }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WindowRequest.settings.post() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { WindowRequest.newPlaylist.post() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Add Music…") { WindowRequest.addMusic.post() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Library…") { WindowRequest.library.post() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Downloads…") { WindowRequest.downloads.post() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Scan Library Folders") { AppSession.shared.scanner.scan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Search…") { WindowRequest.palette.post() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Filter Library") { NotificationCenter.default.post(name: FilterField.focusRequest, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Playback") {
            // Space is handled by a key monitor so it never steals typing from text fields.
            Button("Play / Pause  (Space)") { player.togglePlayPause() }
            Button("Next Track") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Track") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Volume Up") { player.setVolume(player.engine.volume + 0.05) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { player.setVolume(player.engine.volume - 0.05) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Shuffle") { player.shuffle.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Cycle Repeat Mode") { player.repeatMode = player.repeatMode.next }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Toggle("Stop After Current Track", isOn: Binding(get: { player.stopAfterCurrent }, set: { player.stopAfterCurrent = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .option])
            Menu("Sleep Timer") {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                    Button(m < 60 ? "\(m) Minutes" : m == 60 ? "1 Hour" : "\(Double(m) / 60, specifier: "%g") Hours") {
                        player.setSleepTimer(minutes: m)
                    }
                }
                Divider()
                Button("Turn Off") { player.setSleepTimer(minutes: nil) }
            }
            Divider()
            Button("Equalizer…") { WindowRequest.equalizer.post() }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Back") { AppSession.shared.library.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { AppSession.shared.library.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            go("All Music", .all, "1")
            go("Albums", .albums, "2")
            go("Artists", .artists, "3")
            go("Liked Songs", .liked, "4")
            Divider()
            go("Recently Added", .recentlyAdded, "5")
            go("Recently Played", .recentlyPlayed, "6")
            go("Most Played", .mostPlayed, "7")
            Divider()
            Button("Now Playing Album") {
                if let key = player.currentTrack?.albumKey { AppSession.shared.library.albumKey = key }
            }
            .keyboardShortcut("l", modifiers: .command)
        }
        CommandGroup(before: .sidebar) {
            Button("Customize Interface") { WindowRequest.customize.post() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Menu("Workspaces") {
                ForEach(1...9, id: \.self) { n in
                    Button("Workspace \(n)") { AppSession.shared.customize.applyWorkspace(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
                }
            }
            Divider()
            Button("Toggle Now Playing Rail") { settings.data.showSidebar.toggle() }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Toggle Lyrics") { settings.data.showLyrics.toggle() }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Toggle Collection Rail") { settings.data.showAlbumGrid.toggle() }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Toggle Status Bar") { settings.data.showStatusBar.toggle() }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(after: .windowList) {
            Button("Mini Player") { WindowRequest.miniPlayer.post() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

extension MeimeiCommands {
    private func go(_ title: String, _ source: LibrarySource, _ key: KeyEquivalent) -> some View {
        Button(title) {
            let library = AppSession.shared.library
            library.source = source
            library.albumKey = nil
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}

/// UI the main window should present, sent from menus and the app delegate.
enum WindowRequest: String {
    case settings, equalizer, palette, addMusic, newPlaylist, miniPlayer, customize, library, downloads

    static let notification = Notification.Name("meimei.windowRequest")

    func post() {
        NotificationCenter.default.post(name: Self.notification, object: nil, userInfo: ["request": rawValue])
    }

    init?(_ note: Notification) {
        guard let raw = note.userInfo?["request"] as? String else { return nil }
        self.init(rawValue: raw)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var headlessActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        SmoothWheel.install()
        #if DEBUG
        let headless = DebugHooks.isHeadless
        #else
        let headless = false
        #endif
        // Headless test runs stay out of the Dock, the app switcher, and
        // focus, and a crash in one shows no dialog.
        NSApp.setActivationPolicy(headless ? .accessory : .regular)
        if headless {
            // Invisible apps get App Nap, which stretches timers and sleeps
            // far past what the tests measure.
            headlessActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "i2s self-test")
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        installSpaceToPlay()
        installBackForwardButtons()
        MainActor.assumeIsolated { AppSession.shared.soulseek.start() }
        #if DEBUG
        DebugHooks.runIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppSession.shared.flush() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The mouse's back and forward side buttons move through the main
    /// window's library history, as in a browser.
    private func installBackForwardButtons() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 3 || event.buttonNumber == 4, event.window?.title == "i2s" else { return event }
            MainActor.assumeIsolated {
                if event.buttonNumber == 3 { AppSession.shared.library.goBack() } else { AppSession.shared.library.goForward() }
            }
            return nil
        }
    }

    /// Space toggles playback unless a text control is being edited.
    private func installSpaceToPlay() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(event.window?.firstResponder is NSText) else { return event }
            MainActor.assumeIsolated { AppSession.shared.player.togglePlayPause() }
            return nil
        }
    }
}
