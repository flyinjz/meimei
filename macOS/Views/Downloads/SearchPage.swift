import SwiftUI
import AppKit

// Soulseek search in the Downloads window: a typed search (syntax in the
// search syntax file), completion and correction as you type, the key that
// explains the syntax, and the result list.

// MARK: - Filters

/// What a search's results show and in what order. Read from the typed
/// search (see `SearchCommand`) and applied on this Mac to what comes back.
struct SearchFilters: Equatable {
    enum Quality: String, CaseIterable {
        case any, lossless, hiRes, lossy
        var title: String {
            switch self {
            case .any: return "any quality"
            case .lossless: return "lossless"
            case .hiRes: return "hi-res"
            case .lossy: return "lossy"
            }
        }
    }

    enum Encoding { case any, cbr, vbr }

    enum Sort: String, CaseIterable {
        case best, speed, quality, size, files, length, year, user, name
        var title: String {
            switch self {
            case .best: return "Best match"
            case .speed: return "Fastest"
            case .quality: return "Highest quality"
            case .size: return "Largest"
            case .files: return "Most files"
            case .length: return "Longest"
            case .year: return "Newest"
            case .user: return "User"
            case .name: return "Folder name"
            }
        }
        var reversedTitle: String {
            switch self {
            case .best: return "Best match, reversed"
            case .speed: return "Slowest"
            case .quality: return "Lowest quality"
            case .size: return "Smallest"
            case .files: return "Fewest files"
            case .length: return "Shortest"
            case .year: return "Oldest"
            case .user: return "User, Z to A"
            case .name: return "Folder name, Z to A"
            }
        }
    }

    var quality: Quality = .any
    var notQuality: [Quality] = []
    var encoding: Encoding = .any
    /// File kinds to keep ("flac", "mp3"); empty keeps all.
    var formats: [String] = []
    var notFormats: [String] = []
    /// Lossy files only; lossless files are kept.
    var kbps = NumRange()
    var bits = NumRange()
    /// Hertz.
    var rate = NumRange()
    /// Bytes, per file.
    var size = NumRange()
    /// Seconds, per file.
    var length = NumRange()
    /// Matching files per folder.
    var files = NumRange()
    /// The year in the folder's path.
    var year = NumRange()
    /// Bytes per second.
    var speed = NumRange()
    var folderWords: [String] = []
    var notFolderWords: [String] = []
    var fileWords: [String] = []
    var notFileWords: [String] = []
    /// Lowercased words; matching files and folders are dropped.
    var exclude: [String] = []
    /// Lowercased phrases each kept file's path must contain, or must not.
    var phrases: [String] = []
    var notPhrases: [String] = []
    /// Users whose results this search hides.
    var hiddenUsers: [String] = []
    var sort: Sort = .best
    var reversed = false

    static let lossless: Set<String> = ["flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff", "tta", "shn"]
    /// A folder with at least this many matching files counts as an album.
    static let albumFiles = 4

    var sortTitle: String { reversed ? sort.reversedTitle : sort.title }

    /// Short descriptions of what is kept (the order is not one).
    var summary: [String] {
        var out: [String] = []
        if !formats.isEmpty { out.append(formats.joined(separator: " or ")) }
        if !notFormats.isEmpty { out.append("no " + notFormats.joined(separator: ", ")) }
        if quality != .any { out.append(quality.title) }
        out += notQuality.map { "not " + $0.title }
        if encoding == .cbr { out.append("constant bitrate") }
        if encoding == .vbr { out.append("variable bitrate") }
        if !kbps.isAny { out.append(kbps.describe { "\(Int($0))" } + " kbps") }
        if !bits.isAny { out.append(bits.describe { "\(Int($0))" } + "-bit") }
        if !rate.isAny { out.append(rate.describe { Self.khz($0) } + " kHz") }
        if !size.isAny { out.append("files " + size.describe { Format.bytes(UInt64($0)) }) }
        if !length.isAny { out.append("tracks " + length.describe(Self.clock)) }
        if !files.isAny {
            if files.min == Double(Self.albumFiles) && files.max == nil { out.append("albums") }
            else if files.max == Double(Self.albumFiles - 1) && files.min == nil { out.append("single files") }
            else { out.append(files.describe { "\(Int($0))" } + " files per folder") }
        }
        if !year.isAny { out.append("year " + year.describe { "\(Int($0))" }) }
        if !speed.isAny { out.append("users at " + speed.describe { Format.speed($0) }) }
        out += folderWords.map { "folder has \($0)" }
        out += notFolderWords.map { "folder without \($0)" }
        out += fileWords.map { "file has \($0)" }
        out += notFileWords.map { "file without \($0)" }
        out += phrases.map { "\u{201C}\($0)\u{201D}" }
        out += notPhrases.map { "without \u{201C}\($0)\u{201D}" }
        out += exclude.map { "without " + $0 }
        out += hiddenUsers.map { "not from " + $0 }
        return out
    }

    static func khz(_ hz: Double) -> String {
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k))" : String(format: "%.1f", k)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    func keeps(_ f: SlskFile) -> Bool {
        let lossless = f.isLossless
        switch quality {
        case .any: break
        case .lossless: guard lossless else { return false }
        case .hiRes: guard f.isHiRes else { return false }
        case .lossy: guard !lossless else { return false }
        }
        for q in notQuality {
            switch q {
            case .lossless: if lossless { return false }
            case .hiRes: if f.isHiRes { return false }
            case .lossy: if !lossless { return false }
            case .any: break
            }
        }
        if encoding != .any && !lossless && (encoding == .vbr) != f.vbr { return false }
        if !formats.isEmpty || !notFormats.isEmpty {
            let kind = f.kind
            if !formats.isEmpty, !formats.contains(kind) { return false }
            if notFormats.contains(kind) { return false }
        }
        if !kbps.isAny, !lossless {
            guard let b = f.bitrate, kbps.contains(Double(b)) else { return false }
        }
        if !bits.isAny { guard let d = f.bitDepth, bits.contains(Double(d)) else { return false } }
        if !rate.isAny { guard let r = f.sampleRate, rate.contains(Double(r)) else { return false } }
        if !size.isAny, !size.contains(Double(f.size)) { return false }
        if !length.isAny { guard let d = f.duration, length.contains(Double(d)) else { return false } }
        let name = f.lowerName
        if !fileWords.allSatisfy(name.has) { return false }
        if notFileWords.contains(where: name.has) { return false }
        if exclude.contains(where: name.has) { return false }
        if !phrases.isEmpty || !notPhrases.isEmpty {
            let path = f.path.lowercased()
            guard phrases.allSatisfy(path.has), !notPhrases.contains(where: path.has) else { return false }
        }
        return true
    }

    /// Any filter about the music itself (format, quality, size, length).
    var filtersAudio: Bool {
        quality != .any || !notQuality.isEmpty || encoding != .any || !formats.isEmpty || !notFormats.isEmpty
            || !kbps.isAny || !bits.isAny || !rate.isAny || !size.isAny || !length.isAny
    }

    /// Images, lyrics and other non-music files: only leave-out words apply.
    func keepsExtra(_ f: SlskFile) -> Bool {
        let name = f.lowerName
        if exclude.contains(where: name.has) || notFileWords.contains(where: name.has) { return false }
        if !notPhrases.isEmpty, notPhrases.contains(where: f.path.lowercased().has) { return false }
        return true
    }

    /// Filters and sorts; groups from `starred` users come first, in sort order.
    func apply(_ groups: [SoulseekStore.SearchGroup], hidden: Set<String>,
               starred: Set<String> = []) -> [SoulseekStore.SearchGroup] {
        ordered(filtered(groups, hidden: hidden), starred: starred)
    }

    /// The groups these filters keep, with only the files they keep.
    func filtered(_ groups: ArraySlice<SoulseekStore.SearchGroup>, hidden: Set<String>) -> [SoulseekStore.SearchGroup] {
        let hiddenHere = Set(hiddenUsers.map { $0.lowercased() })
        let audioFilter = filtersAudio
        let checksFolder = !exclude.isEmpty || !folderWords.isEmpty || !notFolderWords.isEmpty
        return groups.compactMap { g -> SoulseekStore.SearchGroup? in
            if hidden.contains(g.user) || (!hiddenHere.isEmpty && hiddenHere.contains(g.user.lowercased())) { return nil }
            if !speed.isAny && !speed.contains(Double(g.speed)) { return nil }
            if checksFolder {
                let folder = g.lowerFolder
                if exclude.contains(where: folder.has) { return nil }
                if !folderWords.allSatisfy(folder.has) || notFolderWords.contains(where: folder.has) { return nil }
            }
            if !year.isAny { guard let y = g.year, year.contains(Double(y)) else { return nil } }
            var g = g
            if g.summary.hasAudio {
                // Audio decides; covers, lyrics and other extras ride along
                // unless a leave-out word names them.
                let kept = g.files.filter { $0.isAudio ? keeps($0) : keepsExtra($0) }
                if kept.count != g.files.count { g.files = kept }
                guard g.summary.hasAudio else { return nil }
            } else {
                // A folder with no music in it: kept only while nothing asks about the music.
                guard !audioFilter else { return nil }
                let kept = g.files.filter { keepsExtra($0) && fileWords.allSatisfy($0.lowerName.has) }
                if kept.isEmpty { return nil }
                if kept.count != g.files.count { g.files = kept }
            }
            if !files.isAny && !files.contains(Double(g.audioCount)) { return nil }
            return g
        }
    }

    func filtered(_ groups: [SoulseekStore.SearchGroup], hidden: Set<String>) -> [SoulseekStore.SearchGroup] {
        filtered(groups[...], hidden: hidden)
    }

    /// In this search's order, starred users first.
    func ordered(_ groups: [SoulseekStore.SearchGroup], starred: Set<String> = []) -> [SoulseekStore.SearchGroup] {
        var out = groups
        switch sort {
        case .best:
            // Free slots first, then the shortest queue, then the fastest.
            out.sort { ($0.freeSlot ? 0 : 1, $0.queue, -$0.speed) < ($1.freeSlot ? 0 : 1, $1.queue, -$1.speed) }
        case .speed: out.sort { $0.speed > $1.speed }
        case .quality: out.sort { ($0.summary.qualityScore, $0.speed) > ($1.summary.qualityScore, $1.speed) }
        case .size: out.sort { $0.summary.size > $1.summary.size }
        case .files: out.sort { $0.summary.audioCount > $1.summary.audioCount }
        case .length: out.sort { $0.summary.duration > $1.summary.duration }
        case .year: out.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .user, .name:
            // Keys worked out once, not in every comparison.
            let keys = out.map { (sort == .user ? $0.user : $0.folderName).lowercased() }
            out = keys.indices.sorted { keys[$0] < keys[$1] }.map { out[$0] }
        }
        if reversed { out.reverse() }
        guard !starred.isEmpty else { return out }
        return out.filter { starred.contains($0.user) } + out.filter { !starred.contains($0.user) }
    }
}

extension SlskFile {
    /// The file's format, from its extension: "flac", "mp3". `m4a` is ALAC
    /// when the file reports a bit depth, else AAC.
    var kind: String { isMPEG4 ? (bitDepth != nil ? "alac" : "aac") : baseKind }

    var isLossless: Bool { isMPEG4 ? bitDepth != nil : losslessKind }

    static let audioKinds = Set(SearchSyntax.formats.values.flatMap { $0 })
    static let imageKinds: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "tif", "tiff", "heic"]

    var isImage: Bool { Self.imageKinds.contains(kind) }
    var isLyrics: Bool { baseKind == "lrc" || baseKind == "elrc" || (baseKind == "txt" && lowerName.contains("lyric")) }

    var isHiRes: Bool { isLossless && ((bitDepth ?? 0) >= 24 || (sampleRate ?? 0) > 48000) }

    /// "24/96" for lossless files that report it, "320" or "v245" for lossy ones.
    var qualityLabel: String {
        if isLossless {
            guard let d = bitDepth, let r = sampleRate else { return "" }
            return "\(d)/" + (r % 1000 == 0 ? "\(r / 1000)" : String(format: "%.1f", Double(r) / 1000))
        }
        guard let b = bitrate else { return "" }
        return (vbr ? "v" : "") + "\(b)"
    }

    var qualityScore: Int {
        if isLossless { return 100_000 + (bitDepth ?? 16) * 1000 + (sampleRate ?? 44100) / 100 }
        return bitrate ?? 0
    }

    var durationLabel: String {
        guard let d = duration else { return "" }
        return d >= 3600 ? String(format: "%d:%02d:%02d", d / 3600, d / 60 % 60, d % 60) : String(format: "%d:%02d", d / 60, d % 60)
    }
}

extension SoulseekStore.SearchGroup {
    /// The music formats in the folder, most common first; images, lyrics
    /// and other files aren't formats.
    var kinds: [String] { summary.kinds }
    var audioCount: Int { summary.audioCount }
    /// An image (usually the cover) is in the folder.
    var hasCover: Bool { summary.hasCover }
    /// Lyrics (.lrc, or a text file named for lyrics) are in the folder.
    var hasLyrics: Bool { summary.hasLyrics }
    var qualityScore: Int { summary.qualityScore }
    var qualityLabel: String { summary.qualityLabel }
    /// Total length of the files, in seconds.
    var duration: Int { summary.duration }
}

extension SoulseekStore.SearchScope {
    /// Who was asked, for headers: nil for everyone.
    var label: String? {
        switch self {
        case .everyone: return nil
        case .starred: return "starred users"
        case .users(let names): return names.joined(separator: ", ")
        }
    }
}

// MARK: - Page

struct SearchPage: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var scrolls: Bool
    var onBrowse: (String) -> Void

    @State private var query: String
    /// Open with the key button; the key also shows while the field is blank.
    @State private var keyOpen: Bool
    @State private var problem: String?
    @State private var expanded: Set<String> = []
    @FocusState private var focused: Bool

    // Completion and correction
    /// The text as of the last change, to tell a typed space from an edit.
    @State private var lastQuery: String
    @State private var selection = 0
    /// Arrow keys moved through the list, so Return takes the selection.
    @State private var navigated = false
    /// The token whose suggestions were dismissed with Esc.
    @State private var dismissedFor: String?
    @State private var correction: Correction?
    /// Tokens the user restored after a correction: never corrected again.
    @State private var keepAsTyped: Set<String> = []
    @State private var flash: Flash?
    @State private var monitor: Any?
    @Namespace private var suggestionSpace

    struct Correction: Equatable {
        let id = UUID()
        let from: String
        let to: String
    }

    /// A token just completed or corrected, briefly highlighted in place.
    struct Flash: Equatable {
        let id = UUID()
        let prefix: String
        let token: String
        var lit = true
    }

    /// Snapshots only: show the list of suggestions as if the field had focus.
    private let showsAssist: Bool

    init(store: SoulseekStore, skin: Skin, scrolls: Bool, query: String? = nil, keyOpen: Bool = false,
         showsAssist: Bool = false, correction: (String, String)? = nil, onBrowse: @escaping (String) -> Void) {
        self.store = store
        self.skin = skin
        self.scrolls = scrolls
        self.onBrowse = onBrowse
        self.showsAssist = showsAssist
        let current = store.searches.first { $0.id == store.selectedSearch } ?? store.searches.first
        let text = query ?? current?.query ?? ""
        _query = State(initialValue: text)
        _lastQuery = State(initialValue: text)
        _keyOpen = State(initialValue: keyOpen)
        _correction = State(initialValue: correction.map { Correction(from: $0.0, to: $0.1) })
    }

    private var blank: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var showsKey: Bool { keyOpen || blank || store.searches.isEmpty }
    private static let fieldFont = AppFont.ui(14)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchBar
            ZStack(alignment: .top) {
                if showsKey {
                    SearchKey(store: store, skin: skin, scrolls: scrolls, query: query, problem: problem,
                              canClose: !blank && !store.searches.isEmpty,
                              onInsert: insert, onReplace: { query = $0; focused = true },
                              onSelect: select, onClose: { setKey(false) })
                        .transition(.opacity.combined(with: .offset(y: -6)))
                } else {
                    resultsArea.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.16), value: showsKey)
            .overlay(alignment: .topLeading) { suggestionList }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onChange(of: query, perform: queryChanged)
        .onChange(of: focused) { f in if f { installKeys() } else { removeKeys() } }
        .onAppear { if store.searches.isEmpty { focused = true } }
        .onDisappear(perform: removeKeys)
    }

    private func setKey(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.16)) { keyOpen = open }
    }

    /// Adds a token from the key to the end of the search.
    private func insert(_ token: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "" : trimmed + " "
        lastQuery = base + token
        query = base + token
        light(prefix: base, token: token)
        setKey(true)
        focused = true
    }

    private func select(_ id: UUID) {
        guard let s = store.searches.first(where: { $0.id == id }) else { return }
        store.selectedSearch = id
        lastQuery = s.query
        query = s.query
        expanded = []
        setKey(false)
    }

    private func run() {
        // A misspelled filter at the very end is fixed before searching.
        if let t = SearchAssist.lastToken(query), !keepAsTyped.contains(t), let fix = SearchAssist.correction(for: t) {
            correct(base: String(query.dropLast(t.count)), from: t, to: fix, trailing: "")
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let existing = store.searches.first(where: { $0.query == text }), existing.id != current?.id {
            select(existing.id)
            return
        }
        if let p = store.search(text) {
            problem = p
            setKey(true)
            return
        }
        problem = nil
        expanded = []
        setKey(false)
    }

    private var current: SoulseekStore.Search? {
        store.searches.first { $0.id == store.selectedSearch } ?? store.searches.first
    }

    // MARK: Completion

    /// Names worth completing after @: starred users, users being browsed,
    /// and users in the open search's results.
    /// Names to complete after "@": starred, browsed, then this search's
    /// users, up to 200. Gathered only while an @name is being typed, and
    /// stops at 200 rather than walking every result.
    private var knownUsers: [String] {
        guard let t = typedToken, t.hasPrefix("@") || t.hasPrefix("-@") else { return [] }
        var seen = Set<String>(), out: [String] = []
        func add(_ u: String) -> Bool {
            if seen.insert(u.lowercased()).inserted { out.append(u) }
            return out.count >= 200
        }
        for u in store.settings.starredUsers where add(u) { return out }
        for u in store.browsing.keys.sorted() where add(u) { return out }
        for g in current?.groups ?? [] where add(g.user) { return out }
        return out
    }

    private var typedToken: String? { SearchAssist.lastToken(query) }

    private var assist: (items: [SearchAssist.Suggestion], bare: Bool) {
        guard let t = typedToken, t != dismissedFor else { return ([], false) }
        return SearchAssist.suggestions(for: t, users: knownUsers)
    }

    /// The list under the field: syntax only, never for ordinary words.
    private var listItems: [SearchAssist.Suggestion] {
        let a = assist
        return a.bare ? [] : a.items
    }

    private var picked: SearchAssist.Suggestion? {
        let a = assist
        guard !a.items.isEmpty else { return nil }
        return a.bare ? a.items.first : a.items[min(selection, a.items.count - 1)]
    }

    /// The rest of the picked suggestion, drawn after the caret.
    private var ghost: String? {
        guard let t = typedToken, let s = picked, s.text.lowercased().hasPrefix(t.lowercased()), s.text.count > t.count else { return nil }
        return String(s.text.dropFirst(t.count))
    }

    private func accept(_ s: SearchAssist.Suggestion) {
        guard let t = typedToken else { return }
        let base = String(query.dropLast(t.count))
        let open = s.text.hasSuffix(":") || s.text.hasSuffix(",")
        let next = base + s.text + (open ? "" : " ")
        lastQuery = next
        query = next
        selection = 0
        navigated = false
        light(prefix: base, token: s.text)
    }

    private func queryChanged(_ new: String) {
        let old = lastQuery
        lastQuery = new
        problem = nil
        selection = 0
        navigated = false
        if dismissedFor != nil && dismissedFor != SearchAssist.lastToken(new) { dismissedFor = nil }
        // A space just ended a token: fix it if it's misspelled syntax.
        if new.count == old.count + 1, new.hasPrefix(old), new.last == " ",
           let t = SearchAssist.lastToken(old), !keepAsTyped.contains(t), let fix = SearchAssist.correction(for: t) {
            correct(base: String(old.dropLast(t.count)), from: t, to: fix, trailing: " ")
        }
    }

    private func correct(base: String, from: String, to: String, trailing: String) {
        let next = base + to + trailing
        lastQuery = next
        query = next
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { correction = Correction(from: from, to: to) }
        light(prefix: base, token: to)
        let id = correction?.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if correction?.id == id { withAnimation(.easeOut(duration: 0.25)) { correction = nil } }
        }
    }

    private func undoCorrection() {
        guard let c = correction else { return }
        var words = query.components(separatedBy: " ")
        if let i = words.lastIndex(of: c.to) { words[i] = c.from }
        keepAsTyped.insert(c.from)
        let next = words.joined(separator: " ")
        lastQuery = next
        query = next
        withAnimation(.easeOut(duration: 0.2)) { correction = nil }
        focused = true
    }

    /// Highlights a token in the field, then lets the highlight fade.
    private func light(prefix: String, token: String) {
        let f = Flash(prefix: prefix, token: token)
        flash = f
        withAnimation(.easeOut(duration: 0.9).delay(0.12)) { flash?.lit = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if flash?.id == f.id { flash = nil }
        }
    }

    // MARK: Keys

    /// Tab completes, the arrows choose, Esc dismisses, Return takes a
    /// suggestion chosen with the arrows. Installed while the field has focus.
    private func installKeys() {
        removeKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            let items = listItems
            switch e.keyCode {
            case 48: // Tab
                guard !e.modifierFlags.contains(.shift), caretAtEnd(), let s = picked else { return e }
                accept(s)
                return nil
            case 125, 126: // Down, Up
                guard !items.isEmpty else { return e }
                let step = e.keyCode == 125 ? 1 : items.count - 1
                withAnimation(.easeOut(duration: 0.12)) { selection = (selection + step) % items.count }
                navigated = true
                return nil
            case 124: // Right, at the end: take the inline completion
                guard caretAtEnd(), ghost != nil, let s = picked else { return e }
                accept(s)
                return nil
            case 53: // Esc
                guard let t = typedToken, !assist.items.isEmpty else { return e }
                withAnimation(.easeOut(duration: 0.12)) { dismissedFor = t }
                return nil
            case 36, 76: // Return
                guard navigated, !items.isEmpty else { return e }
                accept(items[min(selection, items.count - 1)])
                return nil
            default:
                return e
            }
        }
    }

    private func removeKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func caretAtEnd() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        let r = editor.selectedRange()
        return r.length == 0 && r.location >= (editor.string as NSString).length
    }

    // MARK: Search bar

    /// Spaces that Text keeps at the end of a line, so measured prefixes line up.
    private static func keepSpaces(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Glyph("magnifyingglass", size: 13).foregroundStyle(focused ? skin.textPrimary : skin.textTertiary)
            ZStack(alignment: .leading) {
                if let flash {
                    HStack(spacing: 0) {
                        Text(verbatim: Self.keepSpaces(flash.prefix)).opacity(0)
                        Text(verbatim: flash.token).foregroundStyle(.clear)
                            .background(Rectangle().fill(skin.accent.opacity(flash.lit ? 0.3 : 0)).padding(.vertical, -2))
                    }
                    .font(Self.fieldFont)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                }
                TextField("Search Soulseek", text: $query)
                    .textFieldStyle(.plain)
                    .font(Self.fieldFont)
                    .foregroundStyle(skin.textPrimary)
                    .focused($focused)
                    .onSubmit(run)
                    .onExitCommand { if keyOpen { setKey(false) } }
                if let ghost, focused || showsAssist {
                    HStack(spacing: 0) {
                        Text(verbatim: Self.keepSpaces(query)).opacity(0)
                        Text(verbatim: ghost).foregroundStyle(skin.textTertiary)
                            .id(ghost)
                            .transition(.opacity.combined(with: .offset(x: -3)))
                    }
                    .font(Self.fieldFont)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.14), value: ghost)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            if ghost != nil && (focused || showsAssist) {
                Text("tab").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    .transition(.opacity)
            }
            if let c = correction {
                HStack(spacing: 6) {
                    Text(c.from).strikethrough(true, color: skin.textTertiary).foregroundStyle(skin.textTertiary)
                    Text("→").foregroundStyle(skin.textTertiary)
                    Text(c.to).foregroundStyle(skin.textSecondary)
                    TextAction(title: "Undo", skin: skin, action: undoCorrection)
                }
                .font(TypeScale.caption)
                .lineLimit(1)
                .fixedSize()
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .help("Corrected a misspelled filter. Undo keeps what you typed.")
            }
            if !query.isEmpty {
                Button { query = ""; focused = true } label: { Glyph("xmark.circle.fill", size: 10) }
                    .buttonStyle(.plain)
                    .foregroundStyle(skin.textTertiary)
                    .help("Clear")
            }
            if store.status != .online {
                Text(store.status == .connecting ? "connecting" : "offline")
                    .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
            }
            KeyButton(on: showsKey, skin: skin) { setKey(!keyOpen || !showsKey) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Rectangle().fill(skin.textPrimary.opacity(focused ? 0.07 : 0.045)))
        .overlay(Rectangle().strokeBorder(focused ? skin.accent.opacity(0.8) : skin.textPrimary.opacity(0.14), lineWidth: 1))
        .fuiCorners(skin)
        .animation(.easeOut(duration: 0.18), value: correction)
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionList: some View {
        let items = listItems
        if (focused || showsAssist) && !items.isEmpty, let typed = typedToken {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                    SuggestionRow(suggestion: s, typed: typed, selected: i == min(selection, items.count - 1),
                                  space: suggestionSpace, skin: skin) { accept(s); focused = true }
                }
                HStack(spacing: 12) {
                    hint("tab", "complete")
                    hint("↑↓", "choose")
                    hint("esc", "dismiss")
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            .padding(.top, 4)
            .frame(width: 380, alignment: .leading)
            .background(Color.black.opacity(0.78))
            .background(.ultraThinMaterial)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .padding(.leading, 30)
            .transition(.opacity.combined(with: .offset(y: -4)))
            .animation(.easeOut(duration: 0.14), value: items.map(\.text))
            .zIndex(2)
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        (Text(key).foregroundColor(skin.textSecondary) + Text(" " + text).foregroundColor(skin.textTertiary))
            .font(TypeScale.caption)
            .fixedSize()
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.searches.count > 1 { searchTabs }
            if let search = current {
                let shown = store.results(for: search)
                header(search, shown: shown)
                ResultColumnsHeader(sort: search.filters.sort, skin: skin) { store.setSort(search.id, $0) }
                results(search, shown.groups)
            }
        }
    }

    private var searchTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(store.searches) { s in
                    let selected = s.id == current?.id
                    HStack(spacing: 6) {
                        Text(s.query).lineLimit(1)
                        Text("\(s.groups.count)").foregroundStyle(skin.textTertiary)
                        Button { store.closeSearch(s.id); if let next = current { query = next.query } } label: {
                            Glyph("xmark.circle.fill", size: 9)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(skin.textTertiary)
                    }
                    .font(TypeScale.caption)
                    .foregroundStyle(selected ? skin.textPrimary : skin.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Rectangle().fill(selected ? skin.textPrimary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { select(s.id) }
                }
            }
        }
    }

    private func header(_ search: SoulseekStore.Search, shown results: SoulseekStore.SearchResults) -> some View {
        let shown = results.groups
        let searching = Date().timeIntervalSince(search.started) < 20
        let hidden = search.groups.count - shown.count
        let kept = search.filters.summary
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SyntaxLine(tokens: SearchCommand(search.query).tokens, skin: skin, size: 15)
                    .lineLimit(1)
                if searching { Text("searching").font(TypeScale.caption).foregroundStyle(skin.textTertiary) }
                Spacer(minLength: 8)
                if !shown.isEmpty {
                    TextAction(title: expanded.isEmpty ? "Expand All" : "Collapse All", skin: skin) {
                        expanded = expanded.isEmpty ? Set(shown.prefix(200).map(\.id)) : []
                    }
                }
            }
            Text("\(shown.count) folders · \(results.users) users · \(results.files) files"
                 + (search.scope.label.map { " · from " + $0 } ?? "")
                 + (hidden > 0 ? " · \(hidden) filtered out" : "")
                 + (search.filters.sort == .best && !search.filters.reversed ? "" : " · " + search.filters.sortTitle.lowercased()))
                .font(TypeScale.caption).foregroundStyle(skin.textTertiary).lineLimit(1)
            (Text("query ").foregroundColor(skin.textTertiary) + Text(search.wire).foregroundColor(skin.textSecondary)
             + Text(kept.isEmpty ? "" : "   filters ").foregroundColor(skin.textTertiary)
             + Text(kept.joined(separator: ", ")).foregroundColor(skin.textSecondary))
                .font(TypeScale.caption).lineLimit(1).truncationMode(.tail)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func results(_ search: SoulseekStore.Search, _ groups: [SoulseekStore.SearchGroup]) -> some View {
        if groups.isEmpty {
            VStack(spacing: 10) {
                Text(search.groups.isEmpty ? "Waiting for responses" : "No results match this search's filters")
                    .font(TypeScale.strong).foregroundStyle(skin.textSecondary)
                if search.groups.isEmpty {
                    CapsuleProgress(fraction: nil, skin: skin).frame(width: 120, height: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let queued = store.transferKeys
            let starred = Set(store.settings.starredUsers)
            let list = LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(groups.prefix(scrolls ? 600 : 9)) { g in
                    ResultGroupRow(group: g, expanded: expanded.contains(g.id), skin: skin, queued: queued,
                                   starred: starred.contains(g.user),
                                   onToggle: { toggle(g.id) },
                                   onDownload: { files in store.download(files, from: g.user) },
                                   onBrowse: { onBrowse(g.user) },
                                   onStar: { store.toggleStar(g.user) },
                                   onHideUser: { store.hideUser(g.user) })
                }
            }
            if scrolls { ScrollView { list } } else { list.frame(maxHeight: .infinity, alignment: .top).clipped() }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

extension SoulseekStore {
    /// "user\0path" for every download in the list, to mark results already requested.
    var transferKeys: Set<String> { Set(downloads.map { $0.user + "\u{0}" + $0.path }) }
}

/// The small "?" that opens and closes the syntax key.
private struct KeyButton: View {
    var on: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph("help", size: 10)
                .foregroundStyle(on ? skin.textSecondary : hovering ? skin.textSecondary : skin.textTertiary.opacity(0.8))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Hide the search syntax" : "Search syntax")
    }
}

private struct SuggestionRow: View {
    var suggestion: SearchAssist.Suggestion
    var typed: String
    var selected: Bool
    var space: Namespace.ID
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // What's typed already in full, the rest lighter.
                let n = min(typed.count, suggestion.text.count)
                let matches = suggestion.text.lowercased().hasPrefix(typed.lowercased())
                (Text(matches ? String(suggestion.text.prefix(n)) : "").foregroundColor(skin.textPrimary)
                 + Text(matches ? String(suggestion.text.dropFirst(n)) : suggestion.text).foregroundColor(skin.textSecondary))
                    .font(AppFont.ui(12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(suggestion.detail).font(TypeScale.caption).foregroundStyle(skin.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                if selected {
                    Rectangle().fill(skin.textPrimary.opacity(0.1)).matchedGeometryEffect(id: "selection", in: space)
                } else if hovering {
                    Rectangle().fill(skin.textPrimary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A search written out with each part weighted by what it does: words in
/// full, @users and filters lighter, problems struck through.
struct SyntaxLine: View {
    var tokens: [SearchCommand.Token]
    var skin: Skin
    var size: CGFloat = 12

    var body: some View {
        tokens.enumerated().reduce(Text("")) { line, item in
            let (i, t) = item
            return line + Text(i == 0 ? "" : " ") + styled(t)
        }
        .font(AppFont.ui(size))
    }

    private func styled(_ t: SearchCommand.Token) -> Text {
        switch t.kind {
        case .word, .phrase: return Text(t.text).font(AppFont.ui(size, weight: .bold)).foregroundColor(skin.textPrimary)
        case .user: return Text(t.text).foregroundColor(skin.textPrimary)
        case .exclude, .filter: return Text(t.text).foregroundColor(skin.textSecondary)
        case .invalid: return Text(t.text).foregroundColor(skin.textTertiary).strikethrough(true, color: skin.textTertiary)
        }
    }
}

// MARK: - Key

/// The search syntax, shown over the results while the field is blank or
/// the "?" is on: every form with what it does, and, while typing, how the
/// current search reads. Click a row to add it.
private struct SearchKey: View {
    @ObservedObject var store: SoulseekStore
    var skin: Skin
    var scrolls: Bool
    var query: String
    var problem: String?
    var canClose: Bool
    var onInsert: (String) -> Void
    var onReplace: (String) -> Void
    var onSelect: (UUID) -> Void
    var onClose: () -> Void

    struct Entry {
        var form: String
        var meaning: String
        /// Added to the search when the row is clicked; empty for none.
        var insert: String
        /// Shown as written, not read as a search (number forms).
        var literal = false
    }

    static let groups: [(String, [Entry])] = [
        ("find", [
            Entry(form: "artist title", meaning: "Each word, anywhere in a path", insert: ""),
            Entry(form: "\"exact title\"", meaning: "These words together, in order", insert: "\""),
            Entry(form: "-word", meaning: "Leave out paths with this word", insert: "-"),
            Entry(form: "-\"exact phrase\"", meaning: "Leave out this phrase", insert: "-\""),
        ]),
        ("who", [
            Entry(form: "@username", meaning: "Ask only this user; add more", insert: "@"),
            Entry(form: "@*", meaning: "Ask only your starred users", insert: "@*"),
            Entry(form: "-@username", meaning: "Hide this user's results", insert: "-@"),
            Entry(form: "speed:>1m", meaning: "Uploading faster than 1 MB/s", insert: "speed:>"),
        ]),
        ("format", [
            Entry(form: ".flac", meaning: "Only this format", insert: ".flac"),
            Entry(form: ".flac .alac", meaning: "Any of these formats", insert: ".alac"),
            Entry(form: "-.mp3", meaning: "Leave out a format", insert: "-.mp3"),
            Entry(form: "ext:flac,wav", meaning: "Formats as one list", insert: "ext:"),
        ]),
        ("quality", [
            Entry(form: "is:lossless", meaning: "FLAC, ALAC, WAV, AIFF and more", insert: "is:lossless"),
            Entry(form: "is:hires", meaning: "Over 16-bit or over 48 kHz", insert: "is:hires"),
            Entry(form: "is:lossy", meaning: "MP3, AAC, Ogg, Opus and others", insert: "is:lossy"),
            Entry(form: "is:cbr is:vbr", meaning: "Constant or variable bitrate", insert: "is:"),
            Entry(form: "kbps:256..320", meaning: "Lossy bitrate; lossless kept", insert: "kbps:"),
            Entry(form: "bits:24", meaning: "Bit depth", insert: "bits:24"),
            Entry(form: "rate:96", meaning: "Sample rate, in kHz", insert: "rate:"),
        ]),
        ("folder", [
            Entry(form: "is:album", meaning: "\(SearchFilters.albumFiles) or more matching files", insert: "is:album"),
            Entry(form: "is:single", meaning: "Fewer than \(SearchFilters.albumFiles) matching files", insert: "is:single"),
            Entry(form: "files:>=10", meaning: "Matching files per folder", insert: "files:"),
            Entry(form: "folder:word", meaning: "Word in the folder path", insert: "folder:"),
            Entry(form: "year:1990..1999", meaning: "Year in the folder path", insert: "year:"),
        ]),
        ("file", [
            Entry(form: "file:word", meaning: "Word in the file name", insert: "file:"),
            Entry(form: "size:<50m", meaning: "File size: k, m or g", insert: "size:"),
            Entry(form: "length:>6m", meaning: "Track length: 90s, 4m or 3:30", insert: "length:"),
        ]),
        ("order", [
            Entry(form: "sort:size", meaning: "speed quality size files length year user name", insert: "sort:"),
            Entry(form: "sort:-size", meaning: "The same order, reversed", insert: "sort:-"),
        ]),
        ("numbers", [
            Entry(form: "320", meaning: "That much or more", insert: "", literal: true),
            Entry(form: ">320  <192", meaning: "More than, less than", insert: "", literal: true),
            Entry(form: ">=320  <=192", meaning: "At least, at most", insert: "", literal: true),
            Entry(form: "256..320", meaning: "Between, inclusive", insert: "", literal: true),
            Entry(form: "=2002", meaning: "Exactly", insert: "", literal: true),
        ]),
        ("not", [
            Entry(form: "-is:lossy", meaning: "A leading - reverses is:, folder:, file:, .format and @", insert: "-is:"),
        ]),
    ]

    static let examples = [
        "artist album .flac is:album -live",
        "@username title",
        "\"exact title\" kbps:320 sort:quality",
        "artist year:1990..1999 is:lossless",
        "title -remix length:<6m sort:-size",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                scrolling { main.padding(18) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                scrolling { side.padding(16) }
                    .frame(width: 176, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(skin.textPrimary.opacity(0.03))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Rectangle().fill(skin.textPrimary.opacity(0.035)))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.14), lineWidth: 1))
        .fuiCorners(skin)
    }

    @ViewBuilder
    private func scrolling<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if scrolls { ScrollView { content() } } else { content().frame(maxHeight: .infinity, alignment: .top).clipped() }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
    }

    // MARK: Main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { readsAs }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.groups, id: \.0) { group in
                    labelled(group.0) {
                        ForEach(group.1, id: \.form) { entry in
                            KeyRow(entry: entry, skin: skin) { if !entry.insert.isEmpty { onInsert(entry.insert) } }
                        }
                    }
                }
                labelled("examples") {
                    ForEach(Self.examples, id: \.self) { ex in
                        ExampleRow(text: ex, skin: skin) { onReplace(ex) }
                    }
                }
            }
            Text("Soulseek receives the words, phrases and -words, and only the users named with @ are asked. Every other filter applies here, to what comes back.")
                .font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                .lineSpacing(TypeScale.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder _ rows: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { rows() }
        }
    }

    private var readsAs: some View {
        let cmd = SearchCommand(query)
        let shown = problem ?? cmd.problem
        let rows: [(String, String)] = [
            ("query", cmd.wire.isEmpty ? "none yet" : cmd.wire),
            ("scope", cmd.scope.label.map { $0 == "starred users" ? "starred users (\(store.settings.starredUsers.count))" : $0 } ?? "everyone"),
            ("filters", cmd.filters.summary.isEmpty ? "none" : cmd.filters.summary.joined(separator: ", ")),
            ("sort", cmd.filters.sortTitle.lowercased()),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            SyntaxLine(tokens: cmd.tokens, skin: skin, size: 14).lineLimit(2)
                .animation(.easeOut(duration: 0.15), value: query)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(rows, id: \.0) { row in
                        GridRow {
                            Text(row.0).font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                            Text(row.1).font(TypeScale.body).foregroundStyle(skin.textSecondary).lineLimit(2)
                                .contentTransition(.opacity)
                        }
                    }
                }
            .animation(.easeOut(duration: 0.15), value: rows.map(\.1))
            .padding(.top, 2)
            ForEach(cmd.hints, id: \.self) { hint in
                Text(hint).font(TypeScale.caption).foregroundStyle(skin.textSecondary)
            }
            if let shown {
                HStack(spacing: 6) {
                    Glyph("info.circle", size: 11)
                    Text(shown).font(TypeScale.strong)
                }
                .foregroundStyle(skin.textPrimary)
                .padding(.top, 4)
                .transition(.opacity)
            } else {
                Text("Press Return to search.").font(TypeScale.caption).foregroundStyle(skin.textTertiary).padding(.top, 4)
            }
        }
    }

    // MARK: Side column

    private var side: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !store.searches.isEmpty {
                heading("open").padding(.bottom, 4)
                ForEach(store.searches) { s in
                    PanelListRow(title: s.query, selected: s.id == store.selectedSearch, detail: "\(s.groups.count)", skin: skin) { onSelect(s.id) }
                }
                Color.clear.frame(height: 12)
            }
            HStack(alignment: .firstTextBaseline) {
                heading("recent")
                Spacer()
                if !store.settings.searchHistory.isEmpty {
                    TextAction(title: "Clear", skin: skin) { store.clearSearchHistory() }
                }
            }
            .padding(.bottom, 4)
            if store.settings.searchHistory.isEmpty {
                Text(store.settings.keepSearchHistory ? "No searches yet" : "History is off")
                    .font(TypeScale.caption).foregroundStyle(skin.textTertiary).padding(.leading, 6)
            }
            ForEach(store.settings.searchHistory.prefix(6), id: \.self) { q in
                PanelListRow(title: q, selected: false, skin: skin) { onReplace(q) }
            }
            TextAction(title: store.settings.keepSearchHistory ? "Stop Keeping History" : "Keep History", skin: skin) {
                store.settings.keepSearchHistory.toggle()
                if !store.settings.keepSearchHistory { store.clearSearchHistory() }
            }
            .padding(.leading, 6).padding(.top, 4)
            heading("starred").padding(.top, 14).padding(.bottom, 4)
            if store.settings.starredUsers.isEmpty {
                Text("Star users from a result's menu").font(TypeScale.caption).foregroundStyle(skin.textTertiary)
                    .padding(.leading, 6).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.settings.starredUsers.prefix(8), id: \.self) { user in
                PanelListRow(title: user, selected: false, glyph: "star.fill", skin: skin) { onInsert("@" + user) }
                    .help("Add @\(user) to search only their files")
            }
            if !store.settings.hiddenUsers.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    heading("hidden")
                    Spacer()
                    TextAction(title: "Show All", skin: skin) { store.settings.hiddenUsers = [] }
                }
                .padding(.top, 14).padding(.bottom, 4)
                ForEach(store.settings.hiddenUsers.prefix(6), id: \.self) { user in
                    PanelListRow(title: user, selected: false, skin: skin) {
                        store.settings.hiddenUsers.removeAll { $0 == user }
                    }
                    .help("Show results from \(user) again")
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "search")
            hint("tab", "complete")
            hint("click a row", "add it")
            if canClose { hint("esc", "results") }
            hint("⌘F", "search field")
            Spacer(minLength: 8)
            if canClose {
                Button("Show Results", action: onClose)
                    .buttonStyle(PillButtonStyle(skin: skin, compact: true))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(skin.textPrimary.opacity(0.03))
    }

    private func hint(_ key: String, _ text: String) -> some View {
        (Text(key).foregroundColor(skin.textSecondary) + Text(" " + text).foregroundColor(skin.textTertiary))
            .font(TypeScale.caption)
            .lineLimit(1)
            .fixedSize()
    }
}

/// One form in the key: the form as typed, what it does. Click to add it.
private struct KeyRow: View {
    var entry: SearchKey.Entry
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Group {
                if entry.literal {
                    Text(entry.form).font(AppFont.ui(12)).foregroundStyle(skin.textSecondary)
                } else {
                    SyntaxLine(tokens: SearchCommand(entry.form).tokens, skin: skin)
                }
            }
            .lineLimit(1)
            .frame(width: 118, alignment: .leading)
            Text(entry.meaning).font(TypeScale.body)
                .foregroundStyle(hovering && !entry.insert.isEmpty ? skin.textPrimary : skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Rectangle().fill(hovering && !entry.insert.isEmpty ? skin.textPrimary.opacity(0.05) : .clear))
        .padding(.leading, -8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(entry.insert.isEmpty ? "" : "Add \(entry.insert) to the search")
    }
}

private struct ExampleRow: View {
    var text: String
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SyntaxLine(tokens: SearchCommand(text).tokens, skin: skin).lineLimit(1)
                Spacer(minLength: 8)
                Text("use").font(TypeScale.caption).foregroundStyle(skin.textTertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Rectangle().fill(hovering ? skin.textPrimary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.leading, -8)
    }
}

/// A choice written as plain text; the selected one is highlighted.
struct TextOption: View {
    var title: String
    var on: Bool
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.12)) { action() } } label: {
            Text(title)
                .font(on ? TypeScale.strong : TypeScale.body)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on || hovering ? skin.textPrimary : skin.textTertiary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Rectangle().fill(on ? skin.textPrimary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PanelListRow: View {
    var title: String
    var selected: Bool
    var glyph: String? = nil
    var detail: String? = nil
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let glyph { Glyph(glyph, size: 9).foregroundStyle(skin.textTertiary) }
                Text(title).font(selected ? TypeScale.strong : TypeScale.body).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(selected || hovering ? skin.textPrimary : skin.textSecondary)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(TypeScale.caption).foregroundStyle(skin.textTertiary) }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(Rectangle().fill(selected ? skin.textPrimary.opacity(0.12) : hovering ? skin.textPrimary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A plain text button for inline actions ("Clear", "Expand All").
struct TextAction: View {
    var title: String
    var skin: Skin
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(TypeScale.caption).lineLimit(1).fixedSize()
                .foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
// MARK: - Result rows

/// Fixed column widths, so folders and their files line up like a table.
enum ResultColumns {
    static let lead: CGFloat = 10
    static let spacing: CGFloat = 10
    static let format: CGFloat = 44
    static let quality: CGFloat = 50
    static let files: CGFloat = 40
    static let size: CGFloat = 64
    static let speed: CGFloat = 70
    static let action: CGFloat = 20
}

private struct ResultColumnsHeader: View {
    var sort: SearchFilters.Sort
    var skin: Skin
    var onSort: (SearchFilters.Sort) -> Void

    var body: some View {
        HStack(spacing: ResultColumns.spacing) {
            Color.clear.frame(width: ResultColumns.lead)
            column("Folder", .user, width: nil)
            column("Format", nil, width: ResultColumns.format)
            column("Quality", .quality, width: ResultColumns.quality)
            column("Files", .files, width: ResultColumns.files)
            column("Size", .size, width: ResultColumns.size)
            column("Speed", .speed, width: ResultColumns.speed)
            Color.clear.frame(width: ResultColumns.action)
        }
        .padding(.horizontal, 12)
        .frame(height: 20)
    }

    @ViewBuilder
    private func column(_ title: String, _ key: SearchFilters.Sort?, width: CGFloat?) -> some View {
        let on = key != nil && key == sort
        let label = HStack(spacing: 4) {
            if width != nil { Spacer(minLength: 0) }
            Text(title)
            if on { Glyph("chevron.down", size: 6) }
            if width == nil { Spacer(minLength: 0) }
        }
        .font(on ? TypeScale.strong : TypeScale.caption)
        .foregroundStyle(on ? skin.textPrimary : skin.textTertiary)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        if let key {
            Button { onSort(on ? .best : key) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(on ? "Sorted by \(key.title.lowercased()). Click for best match." : "Sort by \(key.title.lowercased())")
        } else {
            label
        }
    }
}

struct ResultGroupRow: View {
    var group: SoulseekStore.SearchGroup
    var expanded: Bool
    var skin: Skin
    /// Keys from `SoulseekStore.transferKeys`.
    var queued: Set<String> = []
    var starred = false
    /// Off when browsing one user: their speed is not known.
    var showsPeer = true
    var onToggle: () -> Void
    var onDownload: ([SlskFile]) -> Void
    var onBrowse: () -> Void
    var onStar: (() -> Void)? = nil
    var onHideUser: (() -> Void)? = nil
    @State private var hovering = false

    private func isQueued(_ f: SlskFile) -> Bool { queued.contains(group.user + "\u{0}" + f.path) }
    private var allQueued: Bool { !queued.isEmpty && group.files.allSatisfy(isQueued) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.files, id: \.path) { f in
                        FileRow(file: f, queued: isQueued(f), skin: skin) { onDownload([f]) }
                            .appContextMenu {
                                MenuContent(title: f.name, subtitle: group.user, entries: [
                                    .action("Download", glyph: "downloads") { onDownload([f]) },
                                    .action("Copy Name", glyph: "doc.on.doc") { copyText(f.name) },
                                ])
                            }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(Rectangle().fill(skin.textPrimary.opacity(expanded ? 0.045 : hovering ? 0.035 : 0.02)))
        .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(expanded ? 0.14 : 0.07), lineWidth: 1))
        .onHover { hovering = $0 }
    }

    private var userEntries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .action("Browse Their Files", glyph: "folder.badge.plus", onBrowse),
            .action("Copy Username", glyph: "doc.on.doc") { copyText(group.user) },
        ]
        if let onStar { entries.append(.action(starred ? "Unstar User" : "Star User", glyph: starred ? "star" : "star.fill", onStar)) }
        if let onHideUser, !starred { entries.append(.action("Hide Results from User", glyph: "minus.circle", onHideUser)) }
        return entries
    }

    private var header: some View {
        HStack(spacing: ResultColumns.spacing) {
            Glyph(expanded ? "chevron.down" : "chevron.right", size: 8).foregroundStyle(skin.textTertiary)
                .frame(width: ResultColumns.lead)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.folderName)
                    .font(TypeScale.strong).foregroundStyle(skin.textPrimary).lineLimit(1)
                HStack(spacing: 5) {
                    if starred { Glyph("star.fill", size: 8).foregroundStyle(skin.textSecondary) }
                    (Text(group.user).foregroundColor(skin.textSecondary)
                     + Text(group.parentPath.isEmpty ? "" : "  " + group.parentPath).foregroundColor(skin.textTertiary))
                        .font(TypeScale.caption).lineLimit(1).truncationMode(.tail)
                    if group.hasCover {
                        Glyph("photo", size: 9).foregroundStyle(skin.textTertiary)
                            .padding(.leading, 2)
                            .help("Includes a cover image")
                    }
                    if group.hasLyrics {
                        Glyph("quote", size: 8).foregroundStyle(skin.textTertiary)
                            .help("Includes lyrics")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(formats, width: ResultColumns.format, strong: true)
                .help(group.kinds.count > 1 ? group.kinds.map { $0.uppercased() }.joined(separator: ", ") : "")
            cell(group.qualityLabel, width: ResultColumns.quality, strong: true)
            cell("\(group.audioCount)", width: ResultColumns.files)
            cell(Format.bytes(group.size), width: ResultColumns.size)
            cell(showsPeer ? Format.speed(Double(group.speed)) : "", width: ResultColumns.speed)
            Group {
                if allQueued {
                    Glyph("checkmark.circle.fill", size: 10).foregroundStyle(skin.textSecondary)
                        .help("In Transfers")
                } else {
                    Button { onDownload(group.files) } label: {
                        Glyph("downloads", size: 11).frame(width: ResultColumns.action, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(hovering ? skin.textPrimary : skin.textTertiary)
                    .help("Download all \(group.files.count) files")
                }
            }
            .frame(width: ResultColumns.action)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .appContextMenu {
            MenuContent(title: group.folderName, subtitle: "\(group.user) · \(group.files.count) files", [
                MenuGroup(nil, [
                    .action("Download Folder", glyph: "downloads", detail: Format.bytes(group.size)) { onDownload(group.files) },
                    .action(expanded ? "Collapse" : "Show Files", glyph: "list.bullet", onToggle),
                ]),
                MenuGroup(group.user, userEntries),
                MenuGroup(nil, [.action("Copy Folder Path", glyph: "doc.on.doc") { copyText(group.folder) }]),
            ])
        }
    }

    /// The folder's music format; "FLAC+" when it mixes formats (all are in the tooltip).
    private var formats: String {
        let kinds = group.kinds.map { $0.uppercased() }
        guard let first = kinds.first else { return "" }
        return kinds.count > 1 ? "\(first)+" : first
    }

    private func cell(_ text: String, width: CGFloat, strong: Bool = false) -> some View {
        Text(text.isEmpty ? "–" : text)
            .font(TypeScale.caption)
            .foregroundStyle(strong ? skin.textSecondary : skin.textTertiary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

private struct FileRow: View {
    var file: SlskFile
    var queued: Bool
    var skin: Skin
    var onDownload: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: ResultColumns.spacing) {
            Color.clear.frame(width: ResultColumns.lead)
            Text(file.name).font(TypeScale.body).foregroundStyle(hovering ? skin.textPrimary : skin.textSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(file.kind.uppercased(), width: ResultColumns.format)
            cell(file.qualityLabel, width: ResultColumns.quality)
            cell(file.durationLabel, width: ResultColumns.files)
            cell(Format.bytes(file.size), width: ResultColumns.size)
            Color.clear.frame(width: ResultColumns.speed)
            Group {
                if queued {
                    Glyph("checkmark.circle.fill", size: 9).foregroundStyle(skin.textSecondary).help("In Transfers")
                } else {
                    Button(action: onDownload) {
                        Glyph("downloads", size: 10).frame(width: ResultColumns.action, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(hovering ? skin.textPrimary : skin.textTertiary)
                    .help("Download this file")
                }
            }
            .frame(width: ResultColumns.action)
        }
        .padding(.horizontal, 12)
        .frame(height: 25)
        .background(hovering ? skin.textPrimary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onDownload)
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).font(TypeScale.caption).foregroundStyle(skin.textTertiary).lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
