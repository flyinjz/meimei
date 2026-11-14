import Foundation
import CoreServices

/// A folder the library is built from: scanned for new, changed, moved,
/// and missing files, and optionally watched for changes.
struct LibraryFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var added = Date()
    /// Rescanned automatically when something inside it changes.
    var watched = true
    /// Part of "Scan All"; off pauses a folder without forgetting it.
    var included = true
    var lastScanned: Date?

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }

    /// Whether `filePath` lies inside this folder.
    func contains(_ filePath: String) -> Bool {
        filePath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}

enum MissingFilePolicy: String, Codable, CaseIterable, Identifiable {
    case keep, remove
    var id: String { rawValue }
    var label: String { self == .keep ? "Keep and list them" : "Remove from library" }
}

struct ScanOptions: Codable, Equatable {
    var scanOnLaunch = true
    var watchFolders = true
    /// A missing file and a new one with the same name and size are the
    /// same file, moved: relink instead of losing its history.
    var detectMoves = true
    /// Files whose size or date changed get their tags read again.
    var refreshChangedFiles = true
    var missingPolicy: MissingFilePolicy = .keep
    /// File extensions scans pick up.
    var formats: Set<String> = LibraryStore.audioExtensions
    /// Folders with these names (anywhere in a path) are skipped.
    var ignoredFolderNames: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScanOptions()
        scanOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .scanOnLaunch) ?? d.scanOnLaunch
        watchFolders = try c.decodeIfPresent(Bool.self, forKey: .watchFolders) ?? d.watchFolders
        detectMoves = try c.decodeIfPresent(Bool.self, forKey: .detectMoves) ?? d.detectMoves
        refreshChangedFiles = try c.decodeIfPresent(Bool.self, forKey: .refreshChangedFiles) ?? d.refreshChangedFiles
        missingPolicy = try c.decodeIfPresent(MissingFilePolicy.self, forKey: .missingPolicy) ?? d.missingPolicy
        formats = try c.decodeIfPresent(Set<String>.self, forKey: .formats) ?? d.formats
        ignoredFolderNames = try c.decodeIfPresent([String].self, forKey: .ignoredFolderNames) ?? d.ignoredFolderNames
    }
}

/// What the last scan did.
struct ScanReport: Codable, Equatable {
    var finished: Date
    var seconds: Double
    var foldersScanned: Int
    var filesSeen: Int
    var added: Int
    var refreshed: Int
    var relinked: Int
    var missing: Int
    var removed: Int
    var offline: Int
}

/// A file's size and modification date, to notice when it changes.
struct FileStamp: Codable, Equatable {
    var size: Int64
    var modified: Double
}

/// Library folders and scanning: finds new files to import, re-reads
/// changed ones, relinks moved ones, and tracks missing ones; watches the
/// folders for changes. Folder settings and the file index live next to
/// the library file.
@MainActor
final class LibraryScanner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listing(found: Int)
        case importing
        case refreshing

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .listing(let n): return n == 0 ? "Looking for files…" : "Looking for files… \(n)"
            case .importing: return "Importing new files…"
            case .refreshing: return "Reading changed files…"
            }
        }
    }

    @Published private(set) var folders: [LibraryFolder] = []
    @Published var options = ScanOptions() {
        didSet { if options != oldValue { saveSettings(); updateWatching() } }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastReport: ScanReport?
    /// Tracks whose files weren't found by the last scan.
    @Published private(set) var missingIDs: [UUID] = []
    /// Folders that weren't reachable (an unplugged drive): their tracks
    /// aren't marked missing.
    @Published private(set) var offlineFolderIDs: Set<UUID> = []

    var isScanning: Bool { phase != .idle }

    private let library: LibraryStore
    private let settingsURL: URL
    private let indexURL: URL
    private var stamps: [String: FileStamp] = [:]
    private var rescanQueued: Set<UUID>?? = nil
    private var stream: FSEventStreamRef?
    private var watchDebounce: DispatchWorkItem?

    private struct Saved: Codable {
        var folders: [LibraryFolder]
        var options: ScanOptions
        var lastReport: ScanReport?
        var missingIDs: [UUID]?
    }

    init(library: LibraryStore) {
        self.library = library
        settingsURL = library.supportDirectory.appendingPathComponent("library-folders.json")
        indexURL = library.supportDirectory.appendingPathComponent("scan-index.json")
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            // Same spelling as scanned file paths (e.g. /private/tmp → /tmp),
            // or no file would count as inside its folder.
            folders = saved.folders.map { folder in
                var folder = folder
                folder.path = URL(fileURLWithPath: folder.path).standardizedFileURL.path
                return folder
            }
            options = saved.options
            lastReport = saved.lastReport
            missingIDs = saved.missingIDs ?? []
        }
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode([String: FileStamp].self, from: data) {
            stamps = index
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts watching and, if asked for, a scan shortly after launch.
    func start() {
        updateWatching()
        if options.scanOnLaunch, !folders.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scan() }
        }
    }

    // MARK: Folders

    /// Adds folders (ignoring ones already covered) and scans them.
    func addFolders(_ urls: [URL]) {
        var added: Set<UUID> = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !folders.contains(where: { $0.path == path || $0.contains(path) }) else { continue }
            // A new parent replaces folders inside it.
            folders.removeAll { LibraryFolder(path: path).contains($0.path) }
            let folder = LibraryFolder(path: path)
            folders.append(folder)
            added.insert(folder.id)
        }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        saveSettings()
        updateWatching()
        if !added.isEmpty { scan(added) }
    }

    /// Forgets a folder; with `removingTracks`, its tracks leave the library too.
    func removeFolder(_ id: UUID, removingTracks: Bool) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        folders.removeAll { $0.id == id }
        offlineFolderIDs.remove(id)
        if removingTracks {
            let ids = Set(library.tracks.filter { folder.contains($0.filePath) }.map(\.id))
            library.removeTracks(ids)
            missingIDs.removeAll { ids.contains($0) }
        }
        stamps = stamps.filter { !folder.contains($0.key) }
        saveSettings()
        saveIndex()
        updateWatching()
    }

    func setWatched(_ id: UUID, _ watched: Bool) {
        modify(id) { $0.watched = watched }
        updateWatching()
    }

    func setIncluded(_ id: UUID, _ included: Bool) {
        modify(id) { $0.included = included }
        updateWatching()
    }

    private func modify(_ id: UUID, _ body: (inout LibraryFolder) -> Void) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        body(&folders[i])
        saveSettings()
    }

    /// Folders the library already uses but that aren't library folders:
    /// each track's folder, merged upward while siblings share a parent
    /// (never past a top-level folder like the home folder or a volume).
    func suggestedFolders() -> [URL] {
        let uncovered = library.tracks.map(\.filePath).filter { path in !folders.contains { $0.contains(path) } }
        var dirs = Set(uncovered.map { ($0 as NSString).deletingLastPathComponent })
        func depth(_ p: String) -> Int { p.split(separator: "/").count }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var changed = true
        while changed {
            changed = false
            // Drop folders inside other candidates.
            let sorted = dirs.sorted { $0.count < $1.count }
            var kept: [String] = []
            for d in sorted where !kept.contains(where: { d.hasPrefix($0 + "/") }) { kept.append(d) }
            dirs = Set(kept)
            // Siblings collapse into their parent.
            let byParent = Dictionary(grouping: dirs) { ($0 as NSString).deletingLastPathComponent }
            for (parent, children) in byParent where children.count >= 2 && depth(parent) >= 3 && parent != home {
                dirs.subtract(children)
                dirs.insert(parent)
                changed = true
            }
        }
        return dirs.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Status

    func trackCount(in folder: LibraryFolder) -> Int {
        library.tracks.reduce(0) { $0 + (folder.contains($1.filePath) ? 1 : 0) }
    }

    func bytes(in folder: LibraryFolder) -> Int64 {
        stamps.reduce(0) { $0 + (folder.contains($1.key) ? $1.value.size : 0) }
    }

    /// Size on disk of the library's files, as of the last scan.
    var libraryBytes: Int64 {
        library.tracks.reduce(0) { $0 + (stamps[$1.filePath]?.size ?? 0) }
    }

    var missingTracks: [Track] { missingIDs.compactMap { library.track(id: $0) } }

    // MARK: Scanning

    /// Scans the given folders (default: every included one) and applies
    /// what it finds. A request during a scan runs once it's done.
    func scan(_ ids: Set<UUID>? = nil) {
        guard phase == .idle else {
            // Merge with whatever is already queued; nil means everything.
            switch rescanQueued {
            case .none: rescanQueued = .some(ids)
            case .some(let queued?): rescanQueued = .some(ids.map { $0.union(queued) })
            case .some(.none): break
            }
            return
        }
        let targets = folders.filter { $0.included && (ids?.contains($0.id) ?? true) }
        guard !targets.isEmpty || ids == nil else { return }
        let started = Date()
        phase = .listing(found: 0)

        let fm = FileManager.default
        let online = targets.filter { fm.fileExists(atPath: $0.path) }
        let offline = Set(targets.filter { !fm.fileExists(atPath: $0.path) }.map(\.id))
        let allFolders = folders
        let options = self.options
        let known = library.tracks.map { (id: $0.id, path: $0.filePath) }
        let oldStamps = stamps
        // Tracks to check on disk: those in the scanned folders, and on a
        // full scan those outside every folder; never those on offline drives.
        let offlineFolders = allFolders.filter { offline.contains($0.id) || (!$0.included && ids == nil) }
        let checkOutside = ids == nil

        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [String: FileStamp] = [:]
            for folder in online {
                Self.list(folder.url, options: options, into: &found) { count in
                    Task { @MainActor in self?.phase = .listing(found: count) }
                }
            }
            var missing: [UUID] = []
            for (id, path) in known {
                if offlineFolders.contains(where: { $0.contains(path) }) { continue }
                let inScanned = online.contains { $0.contains(path) }
                let outside = !allFolders.contains { $0.contains(path) }
                guard inScanned || (outside && checkOutside) else { continue }
                if found[path] == nil, !fm.fileExists(atPath: path) { missing.append(id) }
            }
            let result = ScanResult(found: found, missing: missing, oldStamps: oldStamps, known: known,
                                    detectMoves: options.detectMoves)
            await self?.apply(result, scanned: online, offline: offline, full: checkOutside, started: started)
        }
    }

    private struct ScanResult: Sendable {
        var found: [String: FileStamp]
        var missing: [UUID]
        var newPaths: [String] = []
        var changed: [UUID] = []
        var moves: [UUID: String] = [:]

        init(found: [String: FileStamp], missing: [UUID], oldStamps: [String: FileStamp],
             known: [(id: UUID, path: String)], detectMoves: Bool) {
            self.found = found
            self.missing = missing
            let knownPaths = Dictionary(known.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
            var fresh = found.keys.filter { knownPaths[$0] == nil }
            for (path, stamp) in found {
                if let id = knownPaths[path], let old = oldStamps[path], old != stamp { changed.append(id) }
            }
            if detectMoves, !missing.isEmpty, !fresh.isEmpty {
                // Same file name and size on both sides, and only one candidate each.
                let pathByID = Dictionary(known.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
                func key(_ path: String, _ size: Int64) -> String { (path as NSString).lastPathComponent + "|\(size)" }
                var gone: [String: [UUID]] = [:]
                for id in missing {
                    guard let path = pathByID[id], let size = oldStamps[path]?.size else { continue }
                    gone[key(path, size), default: []].append(id)
                }
                var appeared: [String: [String]] = [:]
                for path in fresh { if let size = found[path]?.size { appeared[key(path, size), default: []].append(path) } }
                for (k, ids) in gone where ids.count == 1 {
                    guard let paths = appeared[k], paths.count == 1 else { continue }
                    moves[ids[0]] = paths[0]
                }
                let moved = Set(moves.values)
                fresh.removeAll { moved.contains($0) }
                self.missing.removeAll { moves[$0] != nil }
            }
            newPaths = fresh.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func apply(_ result: ScanResult, scanned: [LibraryFolder], offline: Set<UUID>, full: Bool, started: Date) async {
        library.relink(result.moves)
        for (path, stamp) in result.found { stamps[path] = stamp }

        var refreshed = 0
        if options.refreshChangedFiles, !result.changed.isEmpty {
            phase = .refreshing
            refreshed = await withCheckedContinuation { c in library.refreshFromFiles(Set(result.changed)) { c.resume(returning: $0) } }
        }
        let before = library.tracks.count
        if !result.newPaths.isEmpty {
            phase = .importing
            await withCheckedContinuation { c in
                library.importItems(result.newPaths.map { URL(fileURLWithPath: $0) }) { c.resume() }
            }
        }
        let added = max(0, library.tracks.count - before)

        // Missing: replace this scan's verdict for the tracks it looked at.
        let checked = Set(library.tracks.filter { t in
            scanned.contains { $0.contains(t.filePath) } || (full && !folders.contains { $0.contains(t.filePath) })
        }.map(\.id))
        var missing = missingIDs.filter { !checked.contains($0) && library.track(id: $0) != nil && result.moves[$0] == nil }
        missing.append(contentsOf: result.missing.filter { !missing.contains($0) })
        var removed = 0
        if options.missingPolicy == .remove, !missing.isEmpty {
            removed = missing.count
            for id in missing { if let path = library.track(id: id)?.filePath { stamps[path] = nil } }
            library.removeTracks(Set(missing))
            missing = []
        }
        missingIDs = missing
        offlineFolderIDs = offlineFolderIDs.subtracting(scanned.map(\.id)).union(offline)

        let now = Date()
        for folder in scanned { modify(folder.id) { $0.lastScanned = now } }
        lastReport = ScanReport(finished: now, seconds: now.timeIntervalSince(started), foldersScanned: scanned.count,
                                filesSeen: result.found.count, added: added, refreshed: refreshed,
                                relinked: result.moves.count, missing: missing.count, removed: removed, offline: offline.count)
        phase = .idle
        saveSettings()
        saveIndex()

        if let queued = rescanQueued {
            rescanQueued = nil
            scan(queued)
        }
    }

    /// Every audio file under `root` that the options let through.
    nonisolated private static func list(_ root: URL, options: ScanOptions, into found: inout [String: FileStamp],
                                         progress: (Int) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let ignored = Set(options.ignoredFolderNames.map { $0.lowercased() }.filter { !$0.isEmpty })
        var count = found.count
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if ignored.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, options.formats.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            found[path] = FileStamp(size: Int64(values?.fileSize ?? 0),
                                    modified: values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            count += 1
            if count % 250 == 0 { progress(count) }
        }
        progress(count)
    }

    // MARK: Missing files

    /// Points a missing track at `url`, then relinks every other missing
    /// track from the same old folder whose file is in the new one.
    @discardableResult
    func locate(_ id: UUID, at url: URL) -> Int {
        guard let track = library.track(id: id) else { return 0 }
        let oldDir = (track.filePath as NSString).deletingLastPathComponent
        let newDir = url.deletingLastPathComponent().path
        var moves: [UUID: String] = [id: url.standardizedFileURL.path]
        for other in missingTracks where other.id != id && (other.filePath as NSString).deletingLastPathComponent == oldDir {
            let candidate = (newDir as NSString).appendingPathComponent((other.filePath as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate) { moves[other.id] = candidate }
        }
        library.relink(moves)
        missingIDs.removeAll { moves[$0] != nil }
        saveSettings()
        return moves.count
    }

    func removeMissing(_ ids: Set<UUID>) {
        library.removeTracks(ids)
        missingIDs.removeAll { ids.contains($0) }
        saveSettings()
    }

    // MARK: Watching

    /// One FSEvents stream over the watched folders; changes rescan the
    /// folders they happened in, a moment after things settle.
    private func updateWatching() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        #if DEBUG
        if DebugHooks.isHeadless { return }
        #endif
        let paths = folders.filter { $0.watched && $0.included }.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard options.watchFolders, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let scanner = Unmanaged<LibraryScanner>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { scanner.filesChanged(changed) }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private var changedFolderIDs: Set<UUID> = []

    private func filesChanged(_ paths: [String]) {
        for path in paths {
            let dir = path.hasSuffix("/") ? String(path.dropLast()) : path
            for folder in folders where folder.watched && (folder.path == dir || folder.contains(dir)) {
                changedFolderIDs.insert(folder.id)
            }
        }
        guard !changedFolderIDs.isEmpty else { return }
        watchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.changedFolderIDs
            self.changedFolderIDs = []
            self.scan(ids)
        }
        watchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Persistence

    private func saveSettings() {
        let saved = Saved(folders: folders, options: options, lastReport: lastReport, missingIDs: missingIDs)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    private func saveIndex() {
        let index = stamps
        let url = indexURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(index) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
