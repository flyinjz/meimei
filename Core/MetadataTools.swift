import Foundation

// MARK: - Capitalization

enum CaseStyle: String, Codable, CaseIterable, Identifiable {
    case title, sentence
    var id: String { rawValue }
    var label: String { self == .title ? "Title Case" : "Sentence case" }
}

/// Music-aware capitalization. Leaves alone what was written on purpose:
/// acronyms and Roman numerals (DJ, NYC, II), mixed-case names (iPhone,
/// McCartney, deadmau5), and anything with digits. Small words stay lower
/// inside a title, but not first, last, or after a colon, dash, or bracket.
enum TitleCaser {
    /// MusicBrainz's English capitalization standard's lowercase words.
    static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "en", "for", "if", "in", "nor", "n", "o",
        "of", "on", "or", "per", "the", "to", "v", "vs", "via",
    ]
    /// Always lowercase, even first in a bracket: "(feat. X)".
    static let featWords: Set<String> = ["feat", "ft", "featuring"]
    static let acronyms: Set<String> = [
        "dj", "mc", "ep", "lp", "uk", "us", "usa", "nyc", "la", "tv", "ok", "ufo", "rip", "mtv", "bbc", "edm", "r&b", "a&r",
        "ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii", "xiv", "xv", "xx", "id", "vip", "aka",
    ]

    static func apply(_ text: String, style: CaseStyle) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // An all-caps title says nothing about which words are acronyms.
        let letters = text.filter(\.isLetter)
        let shouting = letters.count > 3 && letters == letters.uppercased() && words.count > 1
        var out: [String] = []
        var startsPhrase = true
        // Featured names are names: kept as written up to the bracket's end.
        var inFeat = false
        for (i, word) in words.enumerated() {
            guard !word.isEmpty else { out.append(word); continue }
            if inFeat {
                out.append(word)
                if word.last.map({ ")]".contains($0) }) == true { inFeat = false }
                continue
            }
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if i > 0, featWords.contains(bare) {
                out.append(word.lowercased())
                inFeat = true
                continue
            }
            let isLast = i == words.count - 1
            out.append(caseWord(word, style: style, startsPhrase: startsPhrase, isLast: isLast, shouting: shouting))
            startsPhrase = word.last.map { ":-–—([{/".contains($0) } ?? false || word == "-" || word == "–" || word == "—"
            if word.first.map({ "([{".contains($0) }) == true, word.count == 1 { startsPhrase = true }
        }
        return out.joined(separator: " ")
    }

    private static func caseWord(_ word: String, style: CaseStyle, startsPhrase: Bool, isLast: Bool, shouting: Bool) -> String {
        // Opening punctuation starts a phrase of its own: "(remix)" → "(Remix)".
        let lead = word.prefix { "([{\"'“‘".contains($0) }
        let core = String(word.dropFirst(lead.count))
        let opensPhrase = startsPhrase || lead.contains { "([{".contains($0) }
        guard !core.isEmpty else { return word }
        // Hyphenated words case each part.
        if core.contains("-"), core.count > 2 {
            let parts = core.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { j, part in
                caseWord(String(part), style: style, startsPhrase: opensPhrase && j == 0, isLast: isLast, shouting: shouting)
            }
            return lead + parts.joined(separator: "-")
        }
        let bare = core.trimmingCharacters(in: .punctuationCharacters).lowercased()
        if keepsAsWritten(core, bare: bare, shouting: shouting) { return word }
        let lower = core.lowercased()
        let capital: Bool
        switch style {
        case .title: capital = opensPhrase || isLast || !smallWords.contains(bare)
        case .sentence: capital = opensPhrase || bare == "i" || bare.hasPrefix("i'")
        }
        if acronyms.contains(bare) { return lead + core.uppercased() }
        if featWords.contains(bare) { return lead + lower }
        return lead + (capital ? capitalizeFirstLetter(lower) : lower)
    }

    private static func keepsAsWritten(_ core: String, bare: String, shouting: Bool) -> Bool {
        if core.contains(where: \.isNumber) { return true }
        let letters = core.filter(\.isLetter)
        guard !letters.isEmpty else { return true }
        // Capitals after the first letter: iPhone, McCartney, DJ, NYC.
        let rest = letters.dropFirst()
        if !shouting, rest.contains(where: \.isUppercase), rest.contains(where: \.isLowercase) || letters.first?.isLowercase == true { return true }
        if !shouting, letters.count >= 2, letters == letters.uppercased() { return true }
        if core.contains("."), core.filter({ $0 == "." }).count >= 2 { return true } // A.D., U.S.A.
        return false
    }

    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return s[..<i] + s[i].uppercased() + s[s.index(after: i)...]
    }
}

// MARK: - Cleanup rules

enum FeatStyle: String, Codable, CaseIterable, Identifiable {
    case parentheses, inline, asIs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .parentheses: return "(feat. X)"
        case .inline: return "feat. X"
        case .asIs: return "As written"
        }
    }
}

/// How titles and names get tidied. Each rule is optional.
struct CleanupRules: Codable, Equatable {
    var caseStyle: CaseStyle? = .title
    var feat: FeatStyle = .parentheses
    var tidySpaces = true
    var straightQuotes = false
    var removeEditionTags = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanupRules()
        caseStyle = try c.decodeIfPresent(CaseStyle?.self, forKey: .caseStyle) ?? d.caseStyle
        feat = try c.decodeIfPresent(FeatStyle.self, forKey: .feat) ?? d.feat
        tidySpaces = try c.decodeIfPresent(Bool.self, forKey: .tidySpaces) ?? d.tidySpaces
        straightQuotes = try c.decodeIfPresent(Bool.self, forKey: .straightQuotes) ?? d.straightQuotes
        removeEditionTags = try c.decodeIfPresent(Bool.self, forKey: .removeEditionTags) ?? d.removeEditionTags
    }
}

enum MetadataCleanup {
    /// A title (track or album) with the rules applied.
    static func title(_ s: String, _ rules: CleanupRules) -> String {
        var t = s
        if rules.tidySpaces { t = tidy(t) }
        if rules.straightQuotes { t = straighten(t) }
        if rules.removeEditionTags { t = removingEditionTags(t) }
        if rules.feat != .asIs { t = featuring(t, rules.feat) }
        if let style = rules.caseStyle { t = TitleCaser.apply(t, style: style) }
        return t
    }

    /// A name (artist, album artist, composer): spaces and quotes only;
    /// names keep their own capitalization.
    static func name(_ s: String, _ rules: CleanupRules) -> String {
        var t = s
        if rules.tidySpaces { t = tidy(t) }
        if rules.straightQuotes { t = straighten(t) }
        return t
    }

    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        for (a, b) in [("( ", "("), (" )", ")"), ("[ ", "["), (" ]", "]")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    static func straighten(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
    }

    private static let editionPattern = try! NSRegularExpression(
        pattern: #"\s*[\(\[](?:\d{4}\s+)?(?:digital(?:ly)?\s+)?(?:remaster(?:ed)?|explicit|clean|bonus track|deluxe(?: edition| version)?|expanded edition|album version)(?:\s+\d{4})?(?:\s+version)?[\)\]]"#,
        options: [.caseInsensitive])

    static func removingEditionTags(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return editionPattern.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let featPattern = try! NSRegularExpression(
        pattern: #"\s*[\(\[]?\s*\b(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+?)\s*[\)\]]?\s*$"#, options: [.caseInsensitive])

    /// "Song ft Someone", "Song [Featuring Someone]" → "Song (feat. Someone)".
    static func featuring(_ s: String, _ style: FeatStyle) -> String {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = featPattern.firstMatch(in: s, range: range), let whole = Range(m.range, in: s),
              let who = Range(m.range(at: 1), in: s) else { return s }
        let head = String(s[..<whole.lowerBound])
        guard !head.trimmingCharacters(in: .whitespaces).isEmpty else { return s }
        let name = String(s[who]).trimmingCharacters(in: .whitespaces)
        return style == .parentheses ? "\(head) (feat. \(name))" : "\(head) feat. \(name)"
    }
}

// MARK: - Artist spellings

/// One artist written several ways ("Beyoncé", "Beyonce", "BEYONCÉ").
struct ArtistSpellings: Identifiable, Equatable {
    var key: String
    /// Every spelling with how many tracks use it (as artist or album artist).
    var variants: [(name: String, count: Int)]
    var id: String { key }
    /// The spelling most tracks use.
    var suggested: String { variants.first?.name ?? "" }

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.variants.map(\.name) == b.variants.map(\.name) && a.variants.map(\.count) == b.variants.map(\.count)
    }

    /// The comparison key: case, accents, punctuation, "&"/"and", and a
    /// leading "The" don't matter.
    static func key(_ name: String) -> String {
        var k = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        k = k.replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "+", with: " and ")
        if k.hasPrefix("the ") { k = String(k.dropFirst(4)) }
        return String(k.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// Artists with more than one spelling across the library.
    static func find(in tracks: [Track]) -> [ArtistSpellings] {
        var counts: [String: [String: Int]] = [:]
        for t in tracks {
            for name in Set([t.artist, t.albumArtist]) where !name.isEmpty {
                let k = key(name)
                guard !k.isEmpty else { continue }
                counts[k, default: [:]][name, default: 0] += 1
            }
        }
        return counts.compactMap { key, names in
            guard names.count > 1 else { return nil }
            let variants = names.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            return ArtistSpellings(key: key, variants: variants)
        }
        .sorted { $0.suggested.localizedStandardCompare($1.suggested) == .orderedAscending }
    }
}

// MARK: - Album health

/// What looks off about an album, for the "needs attention" list.
struct AlbumIssues: OptionSet, Hashable {
    let rawValue: Int
    static let noCover = AlbumIssues(rawValue: 1 << 0)
    static let mixedAlbumArtist = AlbumIssues(rawValue: 1 << 1)
    static let noYear = AlbumIssues(rawValue: 1 << 2)
    static let trackNumbers = AlbumIssues(rawValue: 1 << 3)
    static let formatting = AlbumIssues(rawValue: 1 << 4)
    static let artistSpelling = AlbumIssues(rawValue: 1 << 5)
    static let noGenre = AlbumIssues(rawValue: 1 << 6)
    static let noLyrics = AlbumIssues(rawValue: 1 << 7)

    var labels: [String] {
        var out: [String] = []
        if contains(.noCover) { out.append("no cover") }
        if contains(.artistSpelling) { out.append("artist spelling") }
        if contains(.mixedAlbumArtist) { out.append("mixed album artist") }
        if contains(.formatting) { out.append("formatting") }
        if contains(.trackNumbers) { out.append("track numbers") }
        if contains(.noYear) { out.append("no year") }
        if contains(.noGenre) { out.append("no genre") }
        if contains(.noLyrics) { out.append("no lyrics") }
        return out
    }

    static func of(_ tracks: [Track], rules: CleanupRules, spellingKeys: Set<String>, lyricsMissing: Bool = false) -> AlbumIssues {
        guard let first = tracks.first else { return [] }
        var issues: AlbumIssues = []
        if tracks.allSatisfy({ $0.artworkFilePath == nil }) { issues.insert(.noCover) }
        if lyricsMissing { issues.insert(.noLyrics) }
        if Set(tracks.map(\.albumArtist)).count > 1 { issues.insert(.mixedAlbumArtist) }
        if tracks.allSatisfy({ $0.year == nil }) { issues.insert(.noYear) }
        if tracks.allSatisfy({ $0.genre.isEmpty || $0.genre == "Unknown" }) { issues.insert(.noGenre) }
        let numbers = tracks.map { "\($0.discNumber ?? 1)-\($0.trackNumber ?? 0)" }
        if tracks.contains(where: { $0.trackNumber == nil }) || Set(numbers).count != numbers.count { issues.insert(.trackNumbers) }
        if MetadataCleanup.title(first.album, rules) != first.album || tracks.contains(where: { MetadataCleanup.title($0.title, rules) != $0.title }) {
            issues.insert(.formatting)
        }
        if tracks.contains(where: { spellingKeys.contains(ArtistSpellings.key($0.artist)) || spellingKeys.contains(ArtistSpellings.key($0.albumArtist)) }) {
            issues.insert(.artistSpelling)
        }
        return issues
    }
}
