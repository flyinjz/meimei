import Foundation

// MARK: - Ranges

enum ProfileRange: Int, CaseIterable {
    case week, month, quarter, year, all

    var title: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .year: return "12 months"
        case .all: return "All time"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all: return nil
        }
    }
}

// MARK: - Stats

/// Everything the profile shows, worked out from the verified listens only.
struct ProfileStats {
    struct Rank: Identifiable, Equatable {
        var id: String
        var title: String
        var subtitle: String
        var count: Int
        var seconds: Double
        var cover: String?
        /// Albums: the library's album key; artists: the artist's name.
        var target: String
    }

    struct Bucket: Identifiable, Equatable {
        var id: Int
        var label: String
        var help: String
        var count: Int
        var isCurrent: Bool
    }

    struct Share: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var count: Int
    }

    struct Milestone: Identifiable, Equatable {
        var id: Int { number }
        var number: Int
        var listen: Listen
    }

    var range: ProfileRange
    var start: Date
    var days: Int

    // In range
    var listens = 0
    var seconds = 0.0
    var artists = 0
    var albums = 0
    var tracks = 0
    var dailyAverage = 0.0
    /// The same numbers for the period before (nil for all time).
    var previous: (listens: Int, seconds: Double, artists: Int, albums: Int, tracks: Int)?
    var timeline: [Bucket] = []
    var timelineUnit = ""
    var topArtists: [Rank] = []
    var topAlbums: [Rank] = []
    var topTracks: [Rank] = []
    var hours = [Int](repeating: 0, count: 24)
    /// Monday first.
    var weekdays = [Int](repeating: 0, count: 7)
    var genres: [Share] = []
    var decades: [Share] = []
    var discoveries: [Rank] = []
    var busiestDay: (date: Date, count: Int)?

    // All time
    var totalListens = 0
    var totalSeconds = 0.0
    var since: Date?
    var milestones: [Milestone] = []
    var nextMilestone: Int?
    var currentStreak = 0
    var longestStreak = 0
    var heardTracks = 0
    var libraryTracks = 0
    var recent: [Listen] = []

    static let milestoneSteps = [1, 100, 1_000, 10_000, 100_000]

    static func heard(_ l: Listen) -> Double { min(l.heardSeconds, l.trackDuration) }
    static func artistKey(_ l: Listen) -> String { l.artist.lowercased() }
    static func albumKey(_ l: Listen) -> String { "\(l.albumArtist.lowercased())::\(l.album.lowercased())" }

    init(listens all: [Listen], library tracks: [Track], albums albumGroups: [AlbumGroup], range: ProfileRange, now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = .current
        cal.timeZone = .current
        let today = cal.startOfDay(for: now)
        let sorted = all.sorted { $0.endedAt < $1.endedAt }
        self.range = range
        let first = sorted.first.map { cal.startOfDay(for: $0.startedAt) } ?? today
        if let d = range.days {
            start = cal.date(byAdding: .day, value: -(d - 1), to: today) ?? today
            days = d
        } else {
            start = first
            days = max(1, (cal.dateComponents([.day], from: first, to: today).day ?? 0) + 1)
        }

        let inRange = sorted.filter { $0.endedAt >= start }
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let coverByAlbum = Dictionary(albumGroups.map { ($0.key, $0.artworkFilePath) }, uniquingKeysWith: { a, _ in a })

        // Totals
        listens = inRange.count
        seconds = inRange.reduce(0) { $0 + Self.heard($1) }
        artists = Set(inRange.map(Self.artistKey)).count
        self.albums = Set(inRange.map(Self.albumKey)).count
        self.tracks = Set(inRange.map(\.trackKey)).count
        dailyAverage = Double(listens) / Double(days)
        if let d = range.days, let prevStart = cal.date(byAdding: .day, value: -d, to: start) {
            let prev = sorted.filter { $0.endedAt >= prevStart && $0.endedAt < start }
            previous = (prev.count, prev.reduce(0) { $0 + Self.heard($1) }, Set(prev.map(Self.artistKey)).count,
                        Set(prev.map(Self.albumKey)).count, Set(prev.map(\.trackKey)).count)
        }

        timeline = Self.timeline(inRange, range: range, start: start, today: today, cal: cal)
        timelineUnit = Self.unit(range: range, start: start, today: today, cal: cal)

        // Top lists
        var artistCount: [String: (name: String, count: Int, seconds: Double, albums: [String: Int])] = [:]
        var albumCount: [String: (title: String, artist: String, count: Int, seconds: Double)] = [:]
        var trackCount: [String: (title: String, artist: String, album: String, count: Int, seconds: Double)] = [:]
        for l in inRange {
            let a = Self.artistKey(l), al = Self.albumKey(l), h = Self.heard(l)
            var ae = artistCount[a] ?? (l.artist, 0, 0, [:])
            ae.count += 1; ae.seconds += h; ae.albums[al, default: 0] += 1
            artistCount[a] = ae
            var be = albumCount[al] ?? (l.album, l.albumArtist.isEmpty ? l.artist : l.albumArtist, 0, 0)
            be.count += 1; be.seconds += h
            albumCount[al] = be
            var te = trackCount[l.trackKey] ?? (l.title, l.artist, al, 0, 0)
            te.count += 1; te.seconds += h
            trackCount[l.trackKey] = te
            let hour = cal.component(.hour, from: l.startedAt)
            hours[hour] += 1
            let weekday = cal.component(.weekday, from: l.startedAt) // 1 = Sunday
            weekdays[(weekday + 5) % 7] += 1
        }
        func ranked<T>(_ d: [String: T], _ count: (T) -> Int, _ seconds: (T) -> Double, _ make: (String, T) -> Rank) -> [Rank] {
            d.sorted { count($0.value) != count($1.value) ? count($0.value) > count($1.value) : seconds($0.value) > seconds($1.value) }
                .prefix(10).map { make($0.key, $0.value) }
        }
        topArtists = ranked(artistCount, { $0.count }, { $0.seconds }) { key, v in
            let album = v.albums.max { $0.value < $1.value }?.key
            return Rank(id: key, title: v.name, subtitle: "\(v.albums.count) album\(v.albums.count == 1 ? "" : "s")", count: v.count,
                        seconds: v.seconds, cover: album.flatMap { coverByAlbum[$0] ?? nil }, target: v.name)
        }
        topAlbums = ranked(albumCount, { $0.count }, { $0.seconds }) { key, v in
            Rank(id: key, title: v.title, subtitle: v.artist, count: v.count, seconds: v.seconds, cover: coverByAlbum[key] ?? nil, target: key)
        }
        topTracks = ranked(trackCount, { $0.count }, { $0.seconds }) { key, v in
            Rank(id: key, title: v.title, subtitle: v.artist, count: v.count, seconds: v.seconds, cover: coverByAlbum[v.album] ?? nil, target: v.album)
        }

        // Genres and decades, from the library's tags
        var genre: [String: Int] = [:], decade: [Int: Int] = [:]
        for l in inRange {
            guard let t = byID[l.trackID] else { continue }
            let g = t.genre.trimmingCharacters(in: .whitespaces)
            if !g.isEmpty { genre[g, default: 0] += 1 }
            if let y = t.year, y > 1000 { decade[y / 10 * 10, default: 0] += 1 }
        }
        genres = genre.map { Share(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }.prefix(8).map { $0 }
        decades = decade.sorted { $0.key < $1.key }.map { Share(name: "\($0.key)s", count: $0.value) }

        // Artists heard for the first time in this range
        if range != .all {
            var firstHeard: [String: Date] = [:]
            for l in sorted where firstHeard[Self.artistKey(l)] == nil { firstHeard[Self.artistKey(l)] = l.startedAt }
            discoveries = ranked(artistCount.filter { (firstHeard[$0.key] ?? .distantPast) >= start }, { $0.count }, { $0.seconds }) { key, v in
                let album = v.albums.max { $0.value < $1.value }?.key
                return Rank(id: key, title: v.name, subtitle: firstHeard[key].map { Self.shortDate.string(from: $0) } ?? "",
                            count: v.count, seconds: v.seconds, cover: album.flatMap { coverByAlbum[$0] ?? nil }, target: v.name)
            }
        }

        var perDay: [Date: Int] = [:]
        for l in inRange { perDay[cal.startOfDay(for: l.startedAt), default: 0] += 1 }
        busiestDay = perDay.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }

        // All time
        totalListens = sorted.count
        totalSeconds = sorted.reduce(0) { $0 + Self.heard($1) }
        since = sorted.first?.startedAt
        milestones = Self.milestoneSteps.filter { $0 <= sorted.count }.map { Milestone(number: $0, listen: sorted[$0 - 1]) }
        nextMilestone = Self.milestoneSteps.first { $0 > sorted.count }
        let listenedDays = Set(sorted.map { cal.startOfDay(for: $0.startedAt) })
        var longest = 0, run = 0
        var previousDay: Date?
        for day in listenedDays.sorted() {
            if let p = previousDay, cal.date(byAdding: .day, value: 1, to: p) == day { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previousDay = day
        }
        longestStreak = longest
        var day = listenedDays.contains(today) ? today : (cal.date(byAdding: .day, value: -1, to: today) ?? today)
        var current = 0
        while listenedDays.contains(day) {
            current += 1
            guard let p = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = p
        }
        currentStreak = current
        let heardIDs = Set(sorted.map(\.trackID))
        heardTracks = tracks.reduce(0) { $0 + (heardIDs.contains($1.id) ? 1 : 0) }
        libraryTracks = tracks.count
        recent = Array(sorted.suffix(12).reversed())
    }

    private static func timeline(_ listens: [Listen], range: ProfileRange, start: Date, today: Date, cal: Calendar) -> [Bucket] {
        enum Step { case day, week, month, year }
        let span = cal.dateComponents([.month], from: start, to: today).month ?? 0
        let step: Step
        switch range {
        case .week, .month: step = .day
        case .quarter: step = .week
        case .year: step = .month
        case .all: step = span <= 1 ? .day : span <= 36 ? .month : .year
        }
        func floor(_ d: Date) -> Date {
            switch step {
            case .day: return cal.startOfDay(for: d)
            case .week: return cal.date(byAdding: .day, value: (cal.dateComponents([.day], from: start, to: cal.startOfDay(for: d)).day ?? 0) / 7 * 7, to: start) ?? d
            case .month: return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
            case .year: return cal.date(from: cal.dateComponents([.year], from: d)) ?? d
            }
        }
        func next(_ d: Date) -> Date {
            switch step {
            case .day: return cal.date(byAdding: .day, value: 1, to: d) ?? d
            case .week: return cal.date(byAdding: .day, value: 7, to: d) ?? d
            case .month: return cal.date(byAdding: .month, value: 1, to: d) ?? d
            case .year: return cal.date(byAdding: .year, value: 1, to: d) ?? d
            }
        }
        var counts: [Date: Int] = [:]
        for l in listens { counts[floor(l.startedAt), default: 0] += 1 }
        let label = DateFormatter()
        let help = DateFormatter()
        switch step {
        case .day:
            label.setLocalizedDateFormatFromTemplate(range == .week ? "EEE" : "d")
            help.setLocalizedDateFormatFromTemplate("EEE d MMM")
        case .week:
            label.setLocalizedDateFormatFromTemplate("d MMM")
            help.setLocalizedDateFormatFromTemplate("d MMM")
        case .month:
            label.setLocalizedDateFormatFromTemplate("MMM")
            help.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        case .year:
            label.setLocalizedDateFormatFromTemplate("yyyy")
            help.setLocalizedDateFormatFromTemplate("yyyy")
        }
        var buckets: [Bucket] = []
        var d = floor(start)
        let end = floor(today)
        while d <= end, buckets.count < 400 {
            let n = counts[d] ?? 0
            buckets.append(Bucket(id: buckets.count, label: label.string(from: d),
                                  help: "\(step == .week ? "Week of " : "")\(help.string(from: d)): \(n) listen\(n == 1 ? "" : "s")",
                                  count: n, isCurrent: d == end))
            d = next(d)
        }
        return buckets
    }

    private static func unit(range: ProfileRange, start: Date, today: Date, cal: Calendar) -> String {
        switch range {
        case .week, .month: return "per day"
        case .quarter: return "per week"
        case .year: return "per month"
        case .all:
            let span = cal.dateComponents([.month], from: start, to: today).month ?? 0
            return span <= 1 ? "per day" : span <= 36 ? "per month" : "per year"
        }
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()
}

/// Number and time formats for the profile.
enum Fmt {
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func count(_ n: Int) -> String { grouping.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m >= 6000 { return "\(count(m / 60)) h" }
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return "\(m) min"
    }

    /// "+12% vs before", "same as before", "new".
    static func change(_ now: Double, _ before: Double) -> String {
        if before == 0 { return now == 0 ? "same as before" : "none before" }
        let p = Int(((now - before) / before * 100).rounded())
        return p == 0 ? "same as before" : "\(p > 0 ? "+" : "−")\(abs(p))% vs before"
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    static func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return Calendar.current.date(from: c).map { f.string(from: $0) } ?? "\(h)"
    }

    /// English, to match the copy around it: 100th, 1,000th.
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return count(n) + suffix
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3_600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3_600)) h ago" }
        if Calendar.current.isDateInYesterday(d) { return "yesterday" }
        return ProfileStats.shortDate.string(from: d)
    }
}
