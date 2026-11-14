import Foundation
import AppKit

// The search syntax: reading a typed search, completing what's being typed,
// and correcting misspelled syntax. Only the syntax is ever corrected:
// words, phrases and usernames are left exactly as typed.

// MARK: - Numbers

/// A numeric condition: "320" (at least), ">320", ">=320", "<192", "<=192",
/// "=320" (exactly) or "256..320" (between, inclusive).
struct NumRange: Equatable {
    var min: Double?
    var max: Double?
    var minOpen = false
    var maxOpen = false

    var isAny: Bool { min == nil && max == nil }

    func contains(_ v: Double) -> Bool {
        if let min, minOpen ? v <= min : v < min { return false }
        if let max, maxOpen ? v >= max : v > max { return false }
        return true
    }

    /// `value` turns "50m", "3:30" or "96" into a number; nil when it can't.
    static func parse(_ text: String, exactByDefault: Bool = false, value: (String) -> Double?) -> NumRange? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        for sep in ["..", "–"] where s.contains(sep) {
            let parts = s.components(separatedBy: sep)
            guard parts.count == 2, let a = value(parts[0]), let b = value(parts[1]) else { return nil }
            return NumRange(min: Swift.min(a, b), max: Swift.max(a, b))
        }
        // "1990-1999", but not a leading minus.
        if let dash = s.dropFirst().firstIndex(of: "-"), !s.contains(":") {
            let a = String(s[..<dash]), b = String(s[s.index(after: dash)...])
            if let x = value(a), let y = value(b) { return NumRange(min: Swift.min(x, y), max: Swift.max(x, y)) }
        }
        var r = NumRange()
        if s.hasPrefix(">=") { s.removeFirst(2); guard let v = value(s) else { return nil }; r.min = v; return r }
        if s.hasPrefix("<=") { s.removeFirst(2); guard let v = value(s) else { return nil }; r.max = v; return r }
        if s.hasPrefix(">") { s.removeFirst(); guard let v = value(s) else { return nil }; r.min = v; r.minOpen = true; return r }
        if s.hasPrefix("<") { s.removeFirst(); guard let v = value(s) else { return nil }; r.max = v; r.maxOpen = true; return r }
        if s.hasPrefix("=") { s.removeFirst(); guard let v = value(s) else { return nil }; return NumRange(min: v, max: v) }
        guard let v = value(s) else { return nil }
        return exactByDefault ? NumRange(min: v, max: v) : NumRange(min: v)
    }

    /// "320 or more", "under 192", "256 to 320", "2002".
    func describe(_ f: (Double) -> String) -> String {
        switch (min, max) {
        case let (a?, b?) where a == b: return f(a)
        case let (a?, b?): return "\(f(a)) to \(f(b))"
        case let (a?, nil): return minOpen ? "over \(f(a))" : "\(f(a)) or more"
        case let (nil, b?): return maxOpen ? "under \(f(b))" : "\(f(b)) or less"
        default: return "any"
        }
    }

    // Units

    static func plain(_ s: String) -> Double? {
        let v = Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "+ ")))
        return v.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Bytes: "500k", "50m", "1.5g"; a bare number is megabytes.
    static func bytes(_ s: String) -> Double? {
        var t = s.lowercased().replacingOccurrences(of: " ", with: "")
        if t.hasSuffix("b") { t.removeLast() }
        var unit = 1_000_000.0
        if t.hasSuffix("k") { unit = 1000; t.removeLast() } else if t.hasSuffix("m") { t.removeLast() } else if t.hasSuffix("g") { unit = 1_000_000_000; t.removeLast() }
        return plain(t).map { $0 * unit }
    }

    /// Bytes a second: "500k", "2m"; a bare number is kB/s.
    static func speed(_ s: String) -> Double? {
        var t = s.lowercased().replacingOccurrences(of: "/s", with: "").replacingOccurrences(of: "ps", with: "")
        if t.hasSuffix("b") { t.removeLast() }
        var unit = 1000.0
        if t.hasSuffix("m") { unit = 1_000_000; t.removeLast() } else if t.hasSuffix("k") { t.removeLast() } else if t.hasSuffix("g") { unit = 1_000_000_000; t.removeLast() }
        return plain(t).map { $0 * unit }
    }

    /// Seconds: "3:30", "1:02:00", "4m", "90s", "1h"; a bare number is minutes.
    static func seconds(_ s: String) -> Double? {
        let t = s.lowercased()
        if t.contains(":") {
            let parts = t.split(separator: ":").map { Double($0) }
            guard !parts.contains(where: { $0 == nil }), (2...3).contains(parts.count) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        if t.hasSuffix("h") { return plain(String(t.dropLast())).map { $0 * 3600 } }
        if t.hasSuffix("m") { return plain(String(t.dropLast())).map { $0 * 60 } }
        if t.hasSuffix("s") { return plain(String(t.dropLast())) }
        return plain(t).map { $0 * 60 }
    }

    /// Hertz: "96" or "44.1" (kHz), "44100" (Hz).
    static func hertz(_ s: String) -> Double? {
        var t = s.lowercased()
        if t.hasSuffix("khz") { t.removeLast(3) } else if t.hasSuffix("k") { t.removeLast() }
        guard let v = plain(t) else { return nil }
        return v >= 1000 ? v : v * 1000
    }

    static func year(_ s: String) -> Double? {
        guard let v = Int(s), (1000...2999).contains(v) else { return nil }
        return Double(v)
    }
}

// MARK: - The syntax

enum SearchSyntax {
    /// Canonical keys, and the other names each answers to.
    static let keys: [String] = ["is", "ext", "kbps", "bits", "rate", "size", "length", "files", "year", "folder", "file", "speed", "sort"]
    static let aliases: [String: String] = [
        "format": "ext", "bitrate": "kbps", "depth": "bits", "khz": "rate", "len": "length", "duration": "length",
        "tracks": "files", "dir": "folder", "name": "file", "order": "sort",
    ]
    static let isValues = ["lossless", "hires", "lossy", "cbr", "vbr", "album", "single"]
    static let sortValues = ["best", "speed", "quality", "size", "files", "length", "year", "user", "name"]
    /// Audio file extensions `.ext` accepts, and the kinds each stands for.
    static let formats: [String: [String]] = [
        "flac": ["flac"], "alac": ["alac"], "wav": ["wav"], "aiff": ["aiff"], "aif": ["aiff"], "ape": ["ape"], "wv": ["wv"],
        "mp3": ["mp3"], "aac": ["aac"], "m4a": ["aac", "alac"], "mp4": ["aac", "alac"], "m4b": ["m4b"], "ogg": ["ogg"],
        "oga": ["ogg"], "opus": ["opus"], "wma": ["wma"], "dsf": ["dsf"], "dff": ["dff"], "mpc": ["mpc"], "tta": ["tta"],
        "shn": ["shn"], "ac3": ["ac3"], "dts": ["dts"], "mka": ["mka"],
    ]
    static let formatOrder = ["flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff", "mp3", "aac", "m4a", "ogg", "opus",
                              "wma", "mpc", "tta", "shn", "ac3", "dts", "mka", "m4b", "mp4", "aif", "oga"]

    static func canonical(_ key: String) -> String? {
        let k = key.lowercased()
        return keys.contains(k) ? k : aliases[k]
    }

    /// Optimal string alignment distance: insertions, deletions,
    /// substitutions and swaps of neighbours each count one.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = Swift.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = Swift.min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    /// The closest of `options` to a misspelled `word`, when close enough to
    /// be a typo: one edit for short words, two from five letters.
    static func nearest(_ word: String, in options: [String]) -> String? {
        let w = word.lowercased()
        guard w.count >= 3, !options.contains(w) else { return nil }
        let limit = w.count >= 5 ? 2 : 1
        let scored = options.map { ($0, distance(w, $0)) }.filter { $0.1 <= limit }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        // Two equally close options: don't guess.
        return scored.filter { $0.1 == best.1 }.count == 1 ? best.0 : nil
    }
}

// MARK: - Reading a search

/// A typed search. Words, "phrases" and -words go to Soulseek; @names pick
/// who is asked; everything else is applied here to what comes back.
struct SearchCommand: Equatable {
    enum Kind: Equatable { case word, phrase, exclude, user, filter, invalid }

    struct Token: Equatable {
        var text: String
        var kind: Kind
    }

    var words: [String] = []
    var phrases: [String] = []
    var exclude: [String] = []
    var users: [String] = []
    var starred = false
    var filters = SearchFilters()
    var problems: [String] = []
    /// Not errors: tokens read as plain words that look like misspelled syntax.
    var hints: [String] = []
    var tokens: [Token] = []

    init(_ text: String) {
        for piece in Self.split(text) {
            if piece.quoted {
                let phrase = piece.text.trimmingCharacters(in: .whitespaces)
                guard !phrase.isEmpty else { continue }
                if piece.negated {
                    filters.notPhrases.append(phrase.lowercased())
                    tokens.append(Token(text: "-\u{201C}\(phrase)\u{201D}", kind: .exclude))
                } else {
                    phrases.append(phrase)
                    tokens.append(Token(text: "\u{201C}\(phrase)\u{201D}", kind: .phrase))
                }
            } else {
                read(piece.text)
            }
        }
        filters.exclude = exclude.map { $0.lowercased() }
        filters.phrases = phrases.map { $0.lowercased() }
    }

    private mutating func read(_ t: String) {
        let negated = t.hasPrefix("-") && t.count > 1
        let body = negated ? String(t.dropFirst()) : t
        let lower = body.lowercased()

        if body.hasPrefix("@") {
            let name = String(body.dropFirst())
            if name.isEmpty { problem("Add a username after @, like @username.", t); return }
            if negated {
                if name == "*" { problem("-@* isn't supported. Hide users one at a time with -@username.", t); return }
                if !filters.hiddenUsers.contains(name) { filters.hiddenUsers.append(name) }
                tokens.append(Token(text: t, kind: .filter))
            } else if name == "*" {
                starred = true
                tokens.append(Token(text: t, kind: .user))
            } else {
                if !users.contains(name) { users.append(name) }
                tokens.append(Token(text: t, kind: .user))
            }
            return
        }
        if lower.hasPrefix("."), let kinds = SearchSyntax.formats[String(lower.dropFirst())] {
            for k in kinds {
                if negated { if !filters.notFormats.contains(k) { filters.notFormats.append(k) } }
                else if !filters.formats.contains(k) { filters.formats.append(k) }
            }
            tokens.append(Token(text: t, kind: .filter))
            return
        }
        if let colon = lower.firstIndex(of: ":"), colon != lower.startIndex {
            let rawKey = String(lower[..<colon]), value = String(lower[lower.index(after: colon)...])
            if let key = SearchSyntax.canonical(rawKey), !value.isEmpty {
                let isAlias = key != rawKey
                if let problem = apply(key, value, negated: negated) {
                    if isAlias { plain(t, negated: negated, body: body) } else { self.problem(problem, t) }
                } else {
                    tokens.append(Token(text: t, kind: .filter))
                }
                return
            }
        }
        plain(t, negated: negated, body: body)
    }

    private mutating func plain(_ t: String, negated: Bool, body: String) {
        if let fix = SearchAssist.correction(for: t) {
            hints.append("\(t) is read as a word. Did you mean \(fix)?")
        }
        if negated { exclude.append(body); tokens.append(Token(text: t, kind: .exclude)) }
        else { words.append(t); tokens.append(Token(text: t, kind: .word)) }
    }

    private mutating func problem(_ text: String, _ token: String) {
        problems.append(text)
        tokens.append(Token(text: token, kind: .invalid))
    }

    /// Applies one key:value filter; returns the problem, or nil.
    private mutating func apply(_ key: String, _ value: String, negated: Bool) -> String? {
        func range(_ unit: (String) -> Double?, exact: Bool = false) -> NumRange? {
            NumRange.parse(value, exactByDefault: exact, value: unit)
        }
        let numeric = ["kbps", "bits", "rate", "size", "length", "files", "year", "speed"]
        if negated && numeric.contains(key) { return "Use < or > with \(key): instead of a leading -." }
        switch key {
        case "is":
            switch value {
            case "lossless": negated ? filters.notQuality.append(.lossless) : (filters.quality = .lossless)
            case "hires", "hi-res": negated ? filters.notQuality.append(.hiRes) : (filters.quality = .hiRes)
            case "lossy": negated ? filters.notQuality.append(.lossy) : (filters.quality = .lossy)
            case "cbr": filters.encoding = negated ? .vbr : .cbr
            case "vbr": filters.encoding = negated ? .cbr : .vbr
            case "album", "albums":
                if negated { filters.files.max = Double(SearchFilters.albumFiles - 1) } else { filters.files.min = Double(SearchFilters.albumFiles) }
            case "single", "singles":
                if negated { filters.files.min = Double(SearchFilters.albumFiles) } else { filters.files.max = Double(SearchFilters.albumFiles - 1) }
            default:
                return "is: takes lossless, hires, lossy, cbr, vbr, album or single."
                    + (SearchSyntax.nearest(value, in: SearchSyntax.isValues).map { " Did you mean is:\($0)?" } ?? "")
            }
        case "ext":
            for piece in value.split(separator: ",").map(String.init) {
                let name = piece.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                guard let kinds = SearchSyntax.formats[name] else { return "ext: doesn't know \(name). Try flac, mp3, aac, ogg." }
                for k in kinds {
                    if negated { if !filters.notFormats.contains(k) { filters.notFormats.append(k) } }
                    else if !filters.formats.contains(k) { filters.formats.append(k) }
                }
            }
        case "kbps":
            guard let r = range(NumRange.plain) else { return "kbps: takes a bitrate, like kbps:320 or kbps:256..320." }
            filters.kbps = r
        case "bits":
            guard let r = range(NumRange.plain) else { return "bits: takes a bit depth, like bits:24." }
            filters.bits = r
        case "rate":
            guard let r = range(NumRange.hertz) else { return "rate: takes a sample rate in kHz, like rate:96 or rate:44.1." }
            filters.rate = r
        case "size":
            guard let r = range(NumRange.bytes) else { return "size: takes a file size, like size:<50m or size:>1g." }
            filters.size = r
        case "length":
            guard let r = range(NumRange.seconds) else { return "length: takes a duration, like length:<6m or length:2:00..5:00." }
            filters.length = r
        case "files":
            guard let r = range(NumRange.plain) else { return "files: takes a count, like files:>=10." }
            filters.files = r
        case "year":
            guard let r = range(NumRange.year, exact: true) else { return "year: takes a year or a range, like year:2002 or year:1990..1999." }
            filters.year = r
        case "speed":
            guard let r = range(NumRange.speed) else { return "speed: takes a speed, like speed:>500k or speed:>2m." }
            filters.speed = r
        case "folder":
            negated ? filters.notFolderWords.append(value) : filters.folderWords.append(value)
        case "file":
            negated ? filters.notFileWords.append(value) : filters.fileWords.append(value)
        case "sort":
            if negated { return "Reverse an order with sort:-key, like sort:-size." }
            let reversed = value.hasPrefix("-")
            let name = reversed ? String(value.dropFirst()) : value
            let map: [String: SearchFilters.Sort] = ["best": .best, "speed": .speed, "fast": .speed, "fastest": .speed,
                                                    "quality": .quality, "size": .size, "files": .files, "length": .length,
                                                    "year": .year, "user": .user, "name": .name]
            guard let s = map[name] else {
                return "sort: takes best, speed, quality, size, files, length, year, user or name."
                    + (SearchSyntax.nearest(name, in: SearchSyntax.sortValues).map { " Did you mean sort:\(reversed ? "-" : "")\($0)?" } ?? "")
            }
            filters.sort = s
            filters.reversed = reversed
        default:
            return "Unknown filter."
        }
        return nil
    }

    /// Words and "quoted phrases", in order; a - right before a quote negates it.
    private static func split(_ text: String) -> [(text: String, quoted: Bool, negated: Bool)] {
        var out: [(String, Bool, Bool)] = []
        var current = "", inQuote = false, negated = false
        for c in text {
            if c == "\"" || c == "\u{201C}" || c == "\u{201D}" {
                if inQuote {
                    out.append((current, true, negated)); current = ""; negated = false
                } else {
                    if current == "-" { negated = true; current = "" }
                    else if !current.isEmpty { out.append((current, false, false)); current = "" }
                }
                inQuote.toggle()
            } else if c.isWhitespace && !inQuote {
                if !current.isEmpty { out.append((current, false, false)); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { out.append((current, inQuote, inQuote && negated)) }
        return out
    }

    var scope: SoulseekStore.SearchScope { starred ? .starred : users.isEmpty ? .everyone : .users(users) }

    /// What Soulseek receives: the words, the phrases' words, and -words.
    var wire: String {
        (words + phrases.flatMap { $0.split(separator: " ").map(String.init) } + exclude.map { "-" + $0 }).joined(separator: " ")
    }

    var problem: String? {
        if let first = problems.first { return first }
        if words.isEmpty && phrases.isEmpty { return "Add at least one word to search for." }
        return nil
    }
}

// MARK: - Completion and correction

enum SearchAssist {
    struct Suggestion: Equatable, Identifiable {
        var id: String { text }
        /// The whole token it replaces the typed one with.
        var text: String
        var detail: String
    }

    static let keyDetails: [String: String] = [
        "is": "quality, encoding or folder kind", "ext": "formats, as a list", "kbps": "bitrate of lossy files",
        "bits": "bit depth", "rate": "sample rate in kHz", "size": "file size", "length": "track length",
        "files": "matching files per folder", "year": "year in the folder path", "folder": "word in the folder path",
        "file": "word in the file name", "speed": "upload speed", "sort": "order of results",
    ]

    static let valueDetails: [String: [(String, String)]] = [
        "is": [("lossless", "FLAC, ALAC, WAV, AIFF, APE, WavPack"), ("hires", "lossless above 16-bit or 48 kHz"),
               ("lossy", "MP3, AAC, Ogg, Opus and others"), ("cbr", "constant bitrate"), ("vbr", "variable bitrate"),
               ("album", "\(SearchFilters.albumFiles) or more matching files"), ("single", "fewer than \(SearchFilters.albumFiles) matching files")],
        "sort": [("best", "free slots, short queues, speed"), ("speed", "fastest first"), ("quality", "highest first"),
                 ("size", "largest first"), ("files", "most files first"), ("length", "longest first"),
                 ("year", "newest first"), ("user", "A to Z"), ("name", "folder name, A to Z"),
                 ("-size", "smallest first"), ("-year", "oldest first")],
        "kbps": [("320", "320 or more"), ("256..320", "256 to 320"), ("<192", "under 192")],
        "bits": [("24", "24-bit or more"), ("16", "16-bit or more")],
        "rate": [("96", "96 kHz or more"), ("44.1..48", "44.1 to 48 kHz"), (">48", "above 48 kHz")],
        "size": [("<50m", "under 50 MB"), (">500m", "over 500 MB"), (">1g", "over 1 GB")],
        "length": [("<6m", "under 6 minutes"), (">10m", "over 10 minutes"), ("2:00..5:00", "2 to 5 minutes")],
        "files": [(">=10", "10 or more"), ("1", "1 or more"), ("<=3", "3 or fewer")],
        "year": [("1990..1999", "a decade"), ("2002", "one year"), (">=2010", "2010 or later")],
        "speed": [(">500k", "over 500 kB/s"), (">1m", "over 1 MB/s"), (">5m", "over 5 MB/s")],
        "folder": [], "file": [],
    ]

    /// What the token being typed could become. `bare` when the token is an
    /// ordinary word that happens to start like a filter key: those are
    /// offered only as a quiet inline completion.
    static func suggestions(for token: String, users: [String]) -> (items: [Suggestion], bare: Bool) {
        guard !token.isEmpty else { return ([], false) }
        let negated = token.hasPrefix("-")
        let sign = negated ? "-" : ""
        let body = negated ? String(token.dropFirst()) : token
        let lower = body.lowercased()
        var out: [Suggestion] = []

        if body.hasPrefix("@") {
            let typed = String(body.dropFirst()).lowercased()
            if !negated, "*".hasPrefix(typed) || typed.isEmpty { out.append(Suggestion(text: "@*", detail: "your starred users")) }
            for u in users where typed.isEmpty || u.lowercased().hasPrefix(typed) {
                out.append(Suggestion(text: sign + "@" + u, detail: negated ? "hide this user's results" : "ask only this user"))
            }
            return (Array(out.filter { $0.text != token }.prefix(8)), false)
        }
        if lower.hasPrefix(".") {
            let typed = String(lower.dropFirst())
            for f in SearchSyntax.formatOrder where f.hasPrefix(typed) {
                out.append(Suggestion(text: sign + "." + f, detail: negated ? "leave out \(f.uppercased())" : "only \(f.uppercased())"))
            }
            return (Array(out.filter { $0.text.lowercased() != token.lowercased() }.prefix(8)), false)
        }
        if let colon = lower.firstIndex(of: ":") {
            let rawKey = String(lower[..<colon])
            guard let key = SearchSyntax.canonical(rawKey) else { return ([], false) }
            let value = String(lower[lower.index(after: colon)...])
            let written = String(body[..<body.index(body.startIndex, offsetBy: rawKey.count)])
            if key == "ext" {
                var pieces = value.components(separatedBy: ",")
                let last = pieces.removeLast()
                let head = pieces.isEmpty ? "" : pieces.joined(separator: ",") + ","
                for f in SearchSyntax.formatOrder where f.hasPrefix(last) && !pieces.contains(f) {
                    out.append(Suggestion(text: sign + written + ":" + head + f, detail: f.uppercased()))
                }
            } else {
                for (v, detail) in valueDetails[key] ?? [] where v.hasPrefix(value) {
                    out.append(Suggestion(text: sign + written + ":" + v, detail: detail))
                }
            }
            return (Array(out.filter { $0.text.lowercased() != token.lowercased() }.prefix(8)), false)
        }
        // An ordinary word that starts like a key: complete quietly.
        guard lower.count >= 2 else { return ([], true) }
        for k in SearchSyntax.keys where k.hasPrefix(lower) && k != lower {
            out.append(Suggestion(text: sign + k + ":", detail: keyDetails[k] ?? ""))
        }
        return (Array(out.prefix(4)), true)
    }

    /// The fix for misspelled syntax ("is:losless" → "is:lossless",
    /// "kpbs:320" → "kbps:320", ".flca" → ".flac"), or nil. Words, phrases
    /// and @names are never corrected.
    static func correction(for token: String) -> String? {
        let negated = token.hasPrefix("-")
        let sign = negated ? "-" : ""
        let body = negated ? String(token.dropFirst()) : token
        let lower = body.lowercased()
        if body.hasPrefix("@") || body.hasPrefix("\"") { return nil }

        if lower.hasPrefix(".") {
            let ext = String(lower.dropFirst())
            guard ext.count >= 3, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }),
                  SearchSyntax.formats[ext] == nil,
                  let fix = SearchSyntax.nearest(ext, in: Array(SearchSyntax.formats.keys)) else { return nil }
            return sign + "." + fix
        }
        guard let colon = lower.firstIndex(of: ":"), colon != lower.startIndex else { return nil }
        var key = String(lower[..<colon])
        let value = String(lower[lower.index(after: colon)...])
        var keyChanged = false
        if SearchSyntax.canonical(key) == nil {
            // Only real keys are candidates; an unknown word before a colon
            // ("re:member") is left alone unless it's one slip from a key.
            guard key.allSatisfy(\.isLetter), let fix = SearchSyntax.nearest(key, in: SearchSyntax.keys + Array(SearchSyntax.aliases.keys)) else { return nil }
            key = fix
            keyChanged = true
        }
        let canonical = SearchSyntax.canonical(key) ?? key
        var newValue = value
        switch canonical {
        case "is":
            if !SearchSyntax.isValues.contains(value), value != "hi-res", value != "albums", value != "singles",
               let fix = SearchSyntax.nearest(value, in: SearchSyntax.isValues) { newValue = fix }
        case "sort":
            let rev = value.hasPrefix("-")
            let name = rev ? String(value.dropFirst()) : value
            if !SearchSyntax.sortValues.contains(name), !["fast", "fastest"].contains(name),
               let fix = SearchSyntax.nearest(name, in: SearchSyntax.sortValues) { newValue = (rev ? "-" : "") + fix }
        case "ext":
            newValue = value.split(separator: ",", omittingEmptySubsequences: false).map { piece -> String in
                let p = String(piece)
                if SearchSyntax.formats[p] != nil || p.isEmpty { return p }
                return SearchSyntax.nearest(p, in: Array(SearchSyntax.formats.keys)) ?? p
            }.joined(separator: ",")
        default: break
        }
        guard keyChanged || newValue != value else { return nil }
        // Keep what wasn't misspelled exactly as typed.
        let keyText = keyChanged ? key : String(body[..<body.index(body.startIndex, offsetBy: key.count)])
        let valueText = newValue == value ? String(body[body.index(after: body.firstIndex(of: ":")!)...]) : newValue
        return sign + keyText + ":" + valueText
    }

    /// The token being typed at the end of `text`, if the text doesn't end
    /// in a space or inside a quoted phrase.
    static func lastToken(_ text: String) -> String? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        if text.filter({ $0 == "\"" }).count % 2 == 1 { return nil }
        let token = text.split(separator: " ", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return token.contains("\"") ? nil : token
    }
}

extension String {
    /// Whether `needle` occurs in this string, byte for byte (both sides
    /// already lowercased by the caller). A plain byte search, many times
    /// faster than `contains` for the filters' thousands of checks.
    func has(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var a = self, b = needle
        return a.withUTF8 { hay in
            b.withUTF8 { pin in
                guard pin.count <= hay.count, let h = hay.baseAddress, let p = pin.baseAddress else { return false }
                return memmem(h, hay.count, p, pin.count) != nil
            }
        }
    }
}
