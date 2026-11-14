import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

/// Reading lyrics: synced `.lrc` or plain text, and which line is being sung.
/// Each platform's lyrics store loads files and tags; the rules live here.
enum Lyrics {
    /// Synced lines when the text has LRC stamps, else the plain lines
    /// (trimmed, trailing blanks dropped) with no timing.
    static func read(_ raw: String) -> (lines: [LyricLine], synced: Bool) {
        let synced = parse(raw)
        if !synced.isEmpty { return (synced, true) }
        var lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: 0, text: $0.element) }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return (lines, false)
    }

    /// Index of the line being sung at `time` (offset already applied), or nil before the first.
    static func currentIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordStamp = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    /// LRC: `[mm:ss.xx]text`, several stamps on one line, and `[mm:ss:xx]`.
    /// Enhanced-LRC word stamps (`<mm:ss.xx>`) are stripped from the text.
    static func parse(_ raw: String) -> [LyricLine] {
        var timed: [(TimeInterval, String)] = []
        for line in raw.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var text = stamp.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            text = wordStamp.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            text = text.trimmingCharacters(in: .whitespaces)
            for match in matches {
                func group(_ i: Int) -> String {
                    let r = match.range(at: i)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
                let minutes = Double(group(1)) ?? 0
                let seconds = Double(group(2)) ?? 0
                let fraction = group(3)
                let frac = fraction.isEmpty ? 0 : (Double(fraction) ?? 0) / pow(10, Double(fraction.count))
                timed.append((minutes * 60 + seconds + frac, text))
            }
        }
        return timed
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
