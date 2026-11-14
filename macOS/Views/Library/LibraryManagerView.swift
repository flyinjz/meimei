import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Library window: where the music lives and how Meimei keeps up with
/// it. Folders, scanning and watching, missing files, and upkeep.
struct LibraryManagerWindowView: View {
    @ObservedObject private var theme = AppSession.shared.theme
    @ObservedObject private var settings = AppSession.shared.settings

    var body: some View {
        let skin = settings.glassWindowSkin(theme.skin)
        LibraryManagerView(library: AppSession.shared.library, scanner: AppSession.shared.scanner, skin: skin)
            .font(AppFont.ui(12))
            .foregroundStyle(skin.textPrimary)
            .frame(minWidth: 820, minHeight: 560)
            .glassWindow(skin, minSize: NSSize(width: 820, height: 560))
            .navigationTitle("Library")
            .preferredColorScheme(.dark)
    }
}

struct LibraryManagerView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin

    enum Section: String, CaseIterable, Identifiable {
        case overview, folders, metadata, missing, scanning, maintenance
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .overview: return "chart.bar"
            case .folders: return "folder.badge.plus"
            case .metadata: return "music.note.list"
            case .missing: return "info.circle"
            case .scanning: return "arrow.counterclockwise"
            case .maintenance: return "slider.horizontal.3"
            }
        }
    }

    @State private var section: Section
    @State private var pendingRemoval: LibraryFolder?
    @ObservedObject private var navigator = LibraryNavigator.shared
    /// Off only for the debug snapshot, whose renderer can't draw scroll views.
    var scrolls = true

    var metadataMode: MetadataPage.Mode = .albums

    init(library: LibraryStore, scanner: LibraryScanner, skin: Skin, section: Section = .overview, scrolls: Bool = true,
         metadataMode: MetadataPage.Mode = .albums) {
        self.metadataMode = metadataMode
        self.library = library
        self.scanner = scanner
        self.skin = skin
        self.scrolls = scrolls
        _section = State(initialValue: section)
    }

    var body: some View {
        HStack(spacing: Corners.inset) {
            sidebar
                .frame(width: 196)
                .glassSurface(skin, in: Rectangle(), fallback: skin.bgPanel)
            Group {
                if section == .metadata {
                    // Its own lists and editor scroll independently.
                    MetadataPage(library: library, skin: skin, mode: metadataMode)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if scrolls {
                    ScrollView { pageStack }
                } else {
                    pageStack.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .contentSurface(skin, fallback: skin.bgPanel)
        }
        .padding(.horizontal, Corners.inset)
        .padding(.bottom, Corners.inset)
        .padding(.top, TitleBand.height)
        .overlay(alignment: .top) { WindowDragArea().frame(height: TitleBand.height) }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                if !AppSession.shared.settings.data.systemWindowFrame { WindowControls(skin: skin, closeOnly: true) }
                Text("library").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
            }
            .frame(height: TitleBand.height)
            .padding(.leading, TitleBand.controlsLeading)
        }
        .onAppear(perform: followRequest)
        .onChange(of: navigator.request) { _ in followRequest() }
        .sheet(item: $pendingRemoval) { folder in
            RemoveFolderDialog(folder: folder, trackCount: scanner.trackCount(in: folder), skin: skin) { removeTracks in
                scanner.removeFolder(folder.id, removingTracks: removeTracks)
                pendingRemoval = nil
            } onCancel: { pendingRemoval = nil }
        }
    }

    private var pageStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            page
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { s in
                SettingsNavRow(icon: s.icon, title: s.title, isSelected: section == s,
                               trailingText: trailing(for: s), trailingIsOn: s == .missing && !scanner.missingIDs.isEmpty,
                               skin: skin) { section = s }
            }
            Spacer()
            StatusBlock(library: library, scanner: scanner, skin: skin)
        }
        .padding(10)
    }

    /// Opens the section another part of the app asked for.
    private func followRequest() {
        if let r = navigator.request, let target = Section(rawValue: r.section) { section = target }
    }

    private func trailing(for s: Section) -> String? {
        switch s {
        case .folders: return scanner.folders.isEmpty ? nil : "\(scanner.folders.count)"
        case .missing: return scanner.missingIDs.isEmpty ? nil : "\(scanner.missingIDs.count)"
        default: return nil
        }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .overview: OverviewPage(library: library, scanner: scanner, skin: skin, show: { section = $0 })
        case .folders: FoldersPage(library: library, scanner: scanner, skin: skin) { pendingRemoval = $0 }
        case .metadata: MetadataPage(library: library, skin: skin)
        case .missing: MissingPage(library: library, scanner: scanner, skin: skin)
        case .scanning: ScanningPage(scanner: scanner, skin: skin)
        case .maintenance: MaintenancePage(library: library, scanner: scanner, skin: skin)
        }
    }
}

// MARK: - Shared pieces

enum LibraryFormat {
    static func bytes(_ n: Int64) -> String {
        n == 0 ? "—" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}

/// Scan state at the bottom of the sidebar: what's happening, progress,
/// and the two buttons that matter most.
private struct StatusBlock: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("status").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
            Text(statusText)
                .font(AppFont.ui(11))
                .foregroundStyle(scanner.isScanning || library.scan != nil ? skin.textPrimary : skin.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if scanner.isScanning || library.scan != nil {
                CapsuleProgress(fraction: fraction, skin: skin).frame(height: 3)
            }
            HStack(spacing: 6) {
                Button { scanner.scan() } label: { Label("Scan", glyph: "arrow.counterclockwise") }
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                    .disabled(scanner.isScanning)
                    .help("Look for new, changed, moved, and missing files in every library folder")
                Button { refreshAll() } label: { Label("Refresh", glyph: "waveform") }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                    .disabled(scanner.isScanning || library.tracks.isEmpty)
                    .help("Read every track's tags and details from its file again")
            }
        }
        .padding(8)
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
    }

    private var statusText: String {
        if let scan = library.scan {
            return scan.total > 0 ? "Importing \(scan.completed) of \(scan.total)" : "Preparing import…"
        }
        if scanner.isScanning { return scanner.phase.label }
        if refreshing { return "Refreshing metadata…" }
        return "Last scan " + LibraryFormat.ago(scanner.lastReport?.finished)
    }

    @State private var refreshing = false

    private var fraction: Double? {
        guard let scan = library.scan, scan.total > 0 else { return nil }
        return Double(scan.completed) / Double(scan.total)
    }

    private func refreshAll() {
        refreshing = true
        library.refreshFromFiles(Set(library.tracks.map(\.id))) { _ in refreshing = false }
    }
}

private struct StatTile: View {
    var label: String
    var value: String
    var skin: Skin
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(accent ? skin.accent : skin.textPrimary)
                .lineLimit(1)
            Text(label).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Overview

private struct OverviewPage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin
    var show: (LibraryManagerView.Section) -> Void

    var body: some View {
        LibraryHeader(title: "Library", skin: skin)
        if scanner.folders.isEmpty { FirstFoldersCard(library: library, scanner: scanner, skin: skin) }

        let tracks = library.tracks
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            StatTile(label: "tracks", value: "\(tracks.count)", skin: skin)
            StatTile(label: "albums", value: "\(library.albumGroups.count)", skin: skin)
            StatTile(label: "artists", value: "\(library.artistGroups.count)", skin: skin)
            StatTile(label: "total length", value: LibraryHeaderView.longDuration(library.totalDuration), skin: skin)
            StatTile(label: "on disk", value: LibraryFormat.bytes(scanner.libraryBytes), skin: skin)
            StatTile(label: "hi-res", value: "\(tracks.reduce(0) { $0 + ($1.isHiRes ? 1 : 0) })", skin: skin)
            StatTile(label: "liked", value: "\(library.likedCount)", skin: skin)
            StatTile(label: "missing", value: "\(scanner.missingIDs.count)", skin: skin, accent: !scanner.missingIDs.isEmpty)
                .onTapGesture { if !scanner.missingIDs.isEmpty { show(.missing) } }
        }

        LibrarySection(title: "Formats", skin: skin) { FormatBreakdown(tracks: tracks, skin: skin) }

        LibrarySection(title: "Last scan", skin: skin) {
            if let r = scanner.lastReport {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(LibraryFormat.ago(r.finished)) · \(LibraryFormat.count(r.foldersScanned, "folder")) · \(r.filesSeen) files seen in \(String(format: "%.1f", r.seconds)) s")
                        .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                    HStack(spacing: 14) {
                        tag("added", r.added)
                        tag("re-read", r.refreshed)
                        tag("relinked", r.relinked)
                        tag("missing", r.missing)
                        if r.removed > 0 { tag("removed", r.removed) }
                        if r.offline > 0 { tag("offline", r.offline) }
                    }
                }
            } else {
                Text("No scans yet.")
                    .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
            }
        }
    }

    private func tag(_ label: String, _ n: Int) -> some View {
        Text("[\(n) \(label)]")
            .font(AppFont.ui(11))
            .foregroundStyle(n > 0 ? skin.textPrimary : skin.textTertiary)
    }
}

/// For a library with no folders yet: add some, or adopt the ones its
/// tracks already come from.
private struct FirstFoldersCard: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin

    var body: some View {
        let suggestions = scanner.suggestedFolders()
        LibrarySection(title: "Library folders", skin: skin) {
            Text("Add the folders that contain your music.")
                .font(AppFont.ui(11.5)).foregroundStyle(skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { AddFolderPanel.run(scanner) } label: { Label("Add Folder…", glyph: "folder.badge.plus") }
                    .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
                if !suggestions.isEmpty {
                    Button { scanner.addFolders(suggestions) } label: {
                        Text("Use the \(LibraryFormat.count(suggestions.count, "folder")) your library already uses")
                    }
                    .buttonStyle(PillButtonStyle(skin: skin))
                    .help(suggestions.map(\.path).joined(separator: "\n"))
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Track counts per file format, as bars.
private struct FormatBreakdown: View {
    var tracks: [Track]
    var skin: Skin

    var body: some View {
        let counts = Dictionary(grouping: tracks, by: \.fileFormat).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let top = counts.first?.1 ?? 1
        if counts.isEmpty {
            Text("No tracks yet.").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(counts, id: \.0) { format, n in
                    HStack(spacing: 10) {
                        Text(format.isEmpty ? "Other" : format).font(AppFont.ui(11)).frame(width: 54, alignment: .leading)
                        GeometryReader { geo in
                            Rectangle().fill(skin.accent.opacity(0.75))
                                .frame(width: max(2, geo.size.width * CGFloat(n) / CGFloat(top)))
                        }
                        .frame(height: 6)
                        Text("\(n)").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }
}

enum AddFolderPanel {
    @MainActor
    static func run(_ scanner: LibraryScanner) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose the folders your music is in. i2s scans them now and keeps watching them."
        if panel.runModal() == .OK { scanner.addFolders(panel.urls) }
    }
}

// MARK: - Folders

private struct FoldersPage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin
    var onRemove: (LibraryFolder) -> Void

    var body: some View {
        LibraryHeader(title: "Folders", skin: skin)
        HStack(spacing: 8) {
            Button { AddFolderPanel.run(scanner) } label: { Label("Add Folder…", glyph: "folder.badge.plus") }
                .buttonStyle(PillButtonStyle(skin: skin, prominent: true))
            Button { scanner.scan() } label: { Label("Scan All", glyph: "arrow.counterclockwise") }
                .buttonStyle(PillButtonStyle(skin: skin))
                .disabled(scanner.isScanning || scanner.folders.isEmpty)
            Spacer()
        }
        if scanner.folders.isEmpty {
            FirstFoldersCard(library: library, scanner: scanner, skin: skin)
        } else {
            let counts = folderCounts
            VStack(spacing: 0) {
                ForEach(scanner.folders) { folder in
                    FolderRow(folder: folder, tracks: counts[folder.id] ?? 0, bytes: scanner.bytes(in: folder),
                              offline: scanner.offlineFolderIDs.contains(folder.id), scanner: scanner, skin: skin) {
                        onRemove(folder)
                    }
                    if folder.id != scanner.folders.last?.id { SettingsRowDivider(skin: skin) }
                }
            }
            .padding(.horizontal, 12)
            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
            let suggestions = scanner.suggestedFolders()
            if !suggestions.isEmpty {
                LibrarySection(title: "Outside your folders", skin: skin) {
                    Text("\(LibraryFormat.count(library.tracks.filter { t in !scanner.folders.contains { $0.contains(t.filePath) } }.count, "track")) are outside your library folders.")
                        .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { scanner.addFolders(suggestions) } label: { Text("Add their \(LibraryFormat.count(suggestions.count, "folder"))") }
                        .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        .help(suggestions.map(\.path).joined(separator: "\n"))
                }
            }
        }
    }

    /// Tracks per folder, in one pass over the library.
    private var folderCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for t in library.tracks {
            if let f = scanner.folders.first(where: { $0.contains(t.filePath) }) { counts[f.id, default: 0] += 1 }
        }
        return counts
    }
}

private struct FolderRow: View {
    var folder: LibraryFolder
    var tracks: Int
    var bytes: Int64
    var offline: Bool
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(folder.name).font(AppFont.ui(12.5, weight: .semibold)).lineLimit(1)
                    if offline { Text("[offline]").font(AppFont.ui(10.5)).foregroundStyle(skin.accent) }
                    if !folder.included { Text("[paused]").font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary) }
                }
                Text(folder.path)
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(LibraryFormat.count(tracks, "track")) · \(LibraryFormat.bytes(bytes)) · scanned \(LibraryFormat.ago(folder.lastScanned))")
                    .font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary)
            }
            Spacer(minLength: 8)
            IconButton(icon: "dot.radiowaves.up.forward", isActive: folder.watched && scanner.options.watchFolders,
                       help: folder.watched ? "Watching for changes (click to stop)" : "Not watched (click to watch for changes)", skin: skin) {
                scanner.setWatched(folder.id, !folder.watched)
            }
            IconButton(icon: folder.included ? "pause.fill" : "play.fill",
                       help: folder.included ? "Pause: leave this folder out of scans" : "Resume scanning this folder", skin: skin) {
                scanner.setIncluded(folder.id, !folder.included)
            }
            IconButton(icon: "arrow.counterclockwise", help: "Scan this folder", skin: skin) { scanner.scan([folder.id]) }
                .disabled(scanner.isScanning || offline || !folder.included)
            IconButton(icon: "arrow.up.forward", help: "Show in Finder", skin: skin) {
                NSWorkspace.shared.activateFileViewerSelecting([folder.url])
            }
            .disabled(offline)
            IconButton(icon: "trash", help: "Remove this folder…", skin: skin, action: onRemove)
        }
        .padding(.vertical, 10)
        .opacity(folder.included ? 1 : 0.7)
    }
}

private struct RemoveFolderDialog: View {
    var folder: LibraryFolder
    var trackCount: Int
    var skin: Skin
    var onRemove: (_ removeTracks: Bool) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "Remove “\(folder.name)” from your library folders?",
                         subtitle: "The files on disk are never touched.", skin: skin)
            Text("Its \(LibraryFormat.count(trackCount, "track")) can stay in the library (they just won't be scanned), or leave with the folder.")
                .font(AppFont.ui(12)).foregroundStyle(skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            HStack(spacing: 8) {
                Spacer()
                DialogButton(title: "Cancel", skin: skin, action: onCancel)
                DialogButton(title: "Keep Tracks", skin: skin) { onRemove(false) }
                DialogButton(title: "Remove Tracks Too", prominent: true, skin: skin) { onRemove(true) }
            }
            .padding(18)
        }
        .frame(width: 460)
        .background(skin.bgPanel)
    }
}

// MARK: - Missing

private struct MissingPage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin
    @State private var note: String?

    var body: some View {
        LibraryHeader(title: "Missing Files", skin: skin)
        let missing = scanner.missingTracks
        HStack(spacing: 8) {
            Button { scanner.scan() } label: { Label("Scan Again", glyph: "arrow.counterclockwise") }
                .buttonStyle(PillButtonStyle(skin: skin))
                .disabled(scanner.isScanning)
            Button { scanner.removeMissing(Set(missing.map(\.id))) } label: { Label("Remove All from Library", glyph: "trash") }
                .buttonStyle(PillButtonStyle(skin: skin))
                .disabled(missing.isEmpty)
            Spacer()
            if let note { Text(note).font(AppFont.ui(11)).foregroundStyle(skin.accent) }
        }
        if missing.isEmpty {
            LibrarySection(skin: skin) {
                Text(scanner.lastReport == nil ? "Nothing checked yet. Scan to find files that moved or were deleted." : "Every track's file is where it should be.")
                    .font(AppFont.ui(11.5)).foregroundStyle(skin.textTertiary)
            }
        } else {
            Text("Locating a file also relinks missing files from the same folder.")
                .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVStack(spacing: 0) {
                ForEach(missing) { track in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(AppFont.ui(12)).lineLimit(1)
                            Text("\(track.artist) · \(track.album)").font(AppFont.ui(10.5)).foregroundStyle(skin.textSecondary).lineLimit(1)
                            Text(track.filePath).font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button("Locate…") { locate(track) }
                            .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        IconButton(icon: "trash", size: 22, help: "Remove from library", skin: skin) {
                            scanner.removeMissing([track.id])
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    SettingsRowDivider(skin: skin)
                }
            }
            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.12), lineWidth: 1))
        }
    }

    private func locate(_ track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Where is “\(track.title)” now? (\((track.filePath as NSString).lastPathComponent))"
        panel.prompt = "Relink"
        panel.directoryURL = URL(fileURLWithPath: (track.filePath as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let n = scanner.locate(track.id, at: url)
        note = n > 1 ? "Relinked \(n) tracks" : "Relinked"
    }
}

// MARK: - Scanning

private struct ScanningPage: View {
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin
    @State private var newIgnored = ""

    var body: some View {
        LibraryHeader(title: "Scanning", skin: skin)
        LibrarySection(title: "Automatic", skin: skin) {
            SettingsToggleRow(title: "Scan when i2s opens", 
                              isOn: $scanner.options.scanOnLaunch, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Watch folders for changes",
                              
                              isOn: $scanner.options.watchFolders, skin: skin)
        }
        LibrarySection(title: "Changes", skin: skin) {
            SettingsToggleRow(title: "Re-read files that changed", 
                              isOn: $scanner.options.refreshChangedFiles, skin: skin)
            SettingsRowDivider(skin: skin)
            SettingsToggleRow(title: "Follow moved files", subtitle: "Matches files by name and size.",
                              isOn: $scanner.options.detectMoves, skin: skin)
            SettingsRowDivider(skin: skin)
            Text("Missing files").font(AppFont.ui(12)).padding(.bottom, 4)
            SettingsSegmented(options: MissingFilePolicy.allCases, selection: $scanner.options.missingPolicy, label: \.label, skin: skin)
            Text("Folders on disconnected drives are skipped.")
                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        LibrarySection(title: "File types", skin: skin) {
            let all = LibraryStore.audioExtensions.sorted()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                ForEach(all, id: \.self) { ext in
                    let on = scanner.options.formats.contains(ext)
                    Button(".\(ext)") {
                        if on { scanner.options.formats.remove(ext) } else { scanner.options.formats.insert(ext) }
                    }
                    .buttonStyle(PillButtonStyle(skin: skin, isActive: on, compact: true))
                }
            }
        }
        LibrarySection(title: "Skip folders named", skin: skin) {
            if !scanner.options.ignoredFolderNames.isEmpty {
                VStack(spacing: 0) {
                    ForEach(scanner.options.ignoredFolderNames, id: \.self) { name in
                        HStack {
                            Text(name).font(AppFont.ui(12))
                            Spacer()
                            IconButton(icon: "window.close", size: 20, help: "Stop skipping", skin: skin) {
                                scanner.options.ignoredFolderNames.removeAll { $0 == name }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            HStack(spacing: 6) {
                DialogTextField(placeholder: "e.g. Samples, Stems, Voice Memos", text: $newIgnored, skin: skin)
                    .onSubmit(addIgnored)
                DialogButton(title: "Add", enabled: !newIgnored.trimmingCharacters(in: .whitespaces).isEmpty, skin: skin, action: addIgnored)
            }
            Text("Matches folder names anywhere in a path, ignoring case.")
                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).padding(.top, 2)
        }
    }

    private func addIgnored() {
        let name = newIgnored.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !scanner.options.ignoredFolderNames.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        scanner.options.ignoredFolderNames.append(name)
        newIgnored = ""
    }
}

// MARK: - Maintenance

private struct MaintenancePage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var scanner: LibraryScanner
    var skin: Skin
    @State private var artworkBytes: Int64 = 0
    @State private var refreshing = false
    @State private var note: String?

    var body: some View {
        LibraryHeader(title: "Maintenance", skin: skin)
        LibrarySection(title: "Metadata", skin: skin) {
            row("Refresh all metadata", "Reads every track's tags, artwork, and technical details from its file again. Plays, likes, and dates added stay.") {
                Button(refreshing ? "Refreshing…" : "Refresh") {
                    refreshing = true
                    library.refreshFromFiles(Set(library.tracks.map(\.id))) { n in
                        refreshing = false
                        note = "Re-read \(LibraryFormat.count(n, "track"))"
                    }
                }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
                .disabled(refreshing || library.tracks.isEmpty)
            }
            SettingsRowDivider(skin: skin)
            row("Find duplicates", "Looks for the same song or album imported more than once. The review opens in the main window.") {
                Button("Find") { library.detectDuplicates() }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
        }
        LibrarySection(title: "Artwork", skin: skin) {
            row("Cover cache", artworkBytes == 0 ? "No covers stored yet." : "\(LibraryFormat.bytes(artworkBytes)) of covers extracted from your files.") {
                Button("Remove Unused") {
                    library.pruneArtworkCache()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { measure() }
                    note = "Unused covers removed"
                }
                .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
        }
        LibrarySection(title: "Library data", skin: skin) {
            row("Where it lives", library.supportDirectory.path) {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([library.supportDirectory]) }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
            SettingsRowDivider(skin: skin)
            row("Back up", "Saves a copy of the library (tracks, playlists, plays, likes) and its folder settings.") {
                Button("Export…") { exportBackup() }
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
        }
        if let note { Text(note).font(AppFont.ui(11)).foregroundStyle(skin.accent) }
        Color.clear.frame(height: 0).onAppear(perform: measure)
    }

    private func row<Trailing: View>(_ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.ui(12))
                Text(detail).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 4)
    }

    private func measure() {
        let dir = library.artwork.directory
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let total = names.reduce(Int64(0)) { sum, name in
                sum + ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            await MainActor.run { artworkBytes = total }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "i2s Library \(stamp)"
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the backup folder."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for name in ["library.json", "library-folders.json"] {
                let source = library.supportDirectory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = url.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
            }
            note = "Backed up to \(url.lastPathComponent)"
        } catch {
            note = "Couldn't back up: \(error.localizedDescription)"
        }
    }
}
