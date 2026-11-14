import SwiftUI

// MARK: - Account name

/// The name the profile and the rail show: the one set in the profile, else
/// the Mac user's full name.
enum AccountName {
    @MainActor static func display(_ settings: AppSettings) -> String {
        let custom = settings.data.localAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let full = NSFullUserName()
        return full.isEmpty ? "Listener" : full
    }
}

/// The profile's stats, worked out again only when the listens, the library
/// or the range change.
@MainActor
final class ProfileModel {
    static let shared = ProfileModel()
    private var key: (count: Int, last: UUID?, tracks: Int, range: ProfileRange)?
    private var cached: ProfileStats?

    func stats(_ history: ListenHistory, _ library: LibraryStore, range: ProfileRange) -> ProfileStats {
        let k = (history.listens.count, history.listens.last?.id, library.tracks.count, range)
        if let cached, let key, key.count == k.0, key.last == k.1, key.tracks == k.2, key.range == k.3 { return cached }
        let s = ProfileStats(listens: history.listens, library: library.tracks, albums: library.albumGroups, range: range)
        key = k
        cached = s
        return s
    }
}

// MARK: - Page

/// The listener's profile: who, since when, and everything the listening
/// history says about them, for a chosen period. Sections are transparent,
/// separated by lines only.
struct ProfilePage: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var history: ListenHistory
    @ObservedObject var settings: AppSettings
    var skin: Skin
    @State var range: ProfileRange = .month
    @State private var renaming = false
    @State private var nameDraft = ""

    var body: some View {
        let stats = ProfileModel.shared.stats(history, library, range: range)
        GeometryReader { geo in
            let width = max(0, geo.size.width - 44)
            let columns = width >= 980 ? 3 : width >= 620 ? 2 : 1
            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    header(stats, wide: width >= 620)
                    if stats.totalListens == 0 {
                        emptyState
                    } else {
                        totals(stats, columns: width >= 820 ? 6 : width >= 420 ? 3 : 2)
                        timeline(stats)
                        // Six list sections pair up in two columns and fill rows of three.
                        rows(columns, [
                            AnyView(rankList("Top artists", stats.topArtists, kind: .artist)),
                            AnyView(rankList("Top albums", stats.topAlbums, kind: .album)),
                            AnyView(rankList("Top tracks", stats.topTracks, kind: .track)),
                            AnyView(recent(stats)),
                            AnyView(discoveries(stats)),
                            AnyView(records(stats)),
                        ])
                        rows(columns >= 2 ? (width >= 980 ? 4 : 2) : 1, [
                            AnyView(clock(stats)),
                            AnyView(weekdays(stats)),
                            AnyView(shares("Genres", stats.genres, empty: "No genre tags on these tracks.")),
                            AnyView(shares("Decades", stats.decades, empty: "No release years on these tracks.")),
                        ])
                    }
                }
                .padding(22)
            }
        }
        .background(skin.surface(skin.bgRow))
    }

    // MARK: Header

    private func header(_ s: ProfileStats, wide: Bool) -> some View {
        let name = AccountName.display(settings)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                Text(String(name.prefix(1)).uppercased())
                    .font(AppFont.ui(30, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                    .frame(width: 76, height: 76)
                    .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.18), lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    if renaming {
                        HStack(spacing: 8) {
                            TextField("Your name", text: $nameDraft)
                                .textFieldStyle(.plain)
                                .font(AppFont.ui(24, weight: .semibold))
                                .foregroundStyle(skin.textPrimary)
                                .frame(maxWidth: 320)
                                .onSubmit(saveName)
                            Button("Save", action: saveName).buttonStyle(PillButtonStyle(skin: skin, prominent: true, compact: true))
                            Button("Cancel") { renaming = false }.buttonStyle(PillButtonStyle(skin: skin, compact: true))
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(name).font(AppFont.ui(26, weight: .semibold)).foregroundStyle(skin.textPrimary).lineLimit(1)
                            Button {
                                nameDraft = settings.data.localAccountName
                                renaming = true
                            } label: {
                                Glyph("pencil", size: 11).foregroundStyle(skin.textTertiary).frame(width: 22, height: 22).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Change your name")
                        }
                    }
                    Text(summary(s)).font(AppFont.ui(12)).foregroundStyle(skin.textSecondary).lineLimit(1)
                    integrity.padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 12) {
                ChoiceChips(options: ProfileRange.allCases.map { ($0.title, nil) }, selected: range.rawValue, skin: skin) { i in
                    range = ProfileRange(rawValue: i) ?? .month
                }
                Spacer(minLength: 0)
                if wide, let d = range.days {
                    Text("Compared with the \(d == 365 ? "12 months" : "\(d) days") before")
                        .font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageGlass(skin)
    }

    private func summary(_ s: ProfileStats) -> String {
        guard let since = s.since else { return "No listens yet" }
        return "Listening since \(ProfileStats.shortDate.string(from: since)) · \(Fmt.count(s.totalListens)) listen\(s.totalListens == 1 ? "" : "s") · \(Fmt.duration(s.totalSeconds))"
    }

    private var integrity: some View {
        let r = history.report
        let unverified = r.rejected + r.implausible
        let ok = unverified == 0 && r.gaps == 0
        return HStack(spacing: 6) {
            Glyph(ok ? "shield.check" : "shield.alert", size: 10)
            Text(ok ? "History verified on this Mac"
                 : unverified > 0 ? "\(unverified) listen\(unverified == 1 ? "" : "s") couldn't be verified and aren't counted"
                 : "Some history is missing")
        }
        .font(AppFont.ui(10.5))
        .foregroundStyle(skin.textTertiary)
        .help("Listens are sealed and signed on this Mac as they happen. Anything changed outside i2s fails the check and is left out.")
    }

    private func saveName() {
        settings.data.localAccountName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your stats start with your first listen").font(AppFont.ui(15, weight: .semibold)).foregroundStyle(skin.textPrimary)
            Text("A track counts once you've heard half of it, or four minutes of it. Muted playback doesn't count.")
                .font(AppFont.ui(12)).foregroundStyle(skin.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageGlass(skin)
    }

    // MARK: Totals

    private func totals(_ s: ProfileStats, columns: Int) -> some View {
        let p = s.previous
        let cells: [(String, String, String?)] = [
            ("Listens", Fmt.count(s.listens), p.map { Fmt.change(Double(s.listens), Double($0.listens)) }),
            ("Listening time", Fmt.duration(s.seconds), p.map { Fmt.change(s.seconds, $0.seconds) }),
            ("Artists", Fmt.count(s.artists), p.map { Fmt.change(Double(s.artists), Double($0.artists)) }),
            ("Albums", Fmt.count(s.albums), p.map { Fmt.change(Double(s.albums), Double($0.albums)) }),
            ("Tracks", Fmt.count(s.tracks), p.map { Fmt.change(Double(s.tracks), Double($0.tracks)) }),
            ("Per day", String(format: s.dailyAverage < 10 ? "%.1f" : "%.0f", s.dailyAverage), nil),
        ]
        let rowsOfCells = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        return VStack(spacing: 0) {
            ForEach(Array(rowsOfCells.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cell.0).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1)
                            Text(cell.1).font(AppFont.ui(22, weight: .semibold)).foregroundStyle(skin.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                            Text(cell.2 ?? (cell.0 == "Per day" ? "listens on average" : " "))
                                .font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).lineLimit(1)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) { if i > 0 { line.frame(width: 1) } }
                    }
                }
                .overlay(alignment: .top) { if r > 0 { line.frame(height: 1) } }
            }
        }
        .pageGlass(skin)
    }

    private var line: some View { Rectangle().fill(skin.isGlass ? Color.white.opacity(0.13) : skin.hairline) }

    // MARK: Timeline

    private func timeline(_ s: ProfileStats) -> some View {
        let peak = max(1, s.timeline.map(\.count).max() ?? 1)
        let labelEvery = max(1, Int((Double(s.timeline.count) / 10).rounded(.up)))
        return section("Listening over time", detail: s.timelineUnit) {
            VStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: s.timeline.count > 60 ? 1 : 3) {
                    ForEach(s.timeline) { b in
                        Rectangle()
                            .fill(b.isCurrent ? skin.accent : skin.textPrimary.opacity(b.count == 0 ? 0.06 : 0.24))
                            .frame(height: max(2, 120 * CGFloat(b.count) / CGFloat(peak)))
                            .frame(maxWidth: .infinity)
                            .help(b.help)
                    }
                }
                .frame(height: 120, alignment: .bottom)
                .overlay(alignment: .top) {
                    HStack {
                        Spacer()
                        Text("\(peak)").font(AppFont.ui(10)).foregroundStyle(skin.textTertiary)
                    }
                    .offset(y: -14)
                }
                HStack(spacing: s.timeline.count > 60 ? 1 : 3) {
                    ForEach(s.timeline) { b in
                        Text(b.id % labelEvery == 0 ? b.label : "")
                            .font(AppFont.ui(9.5)).foregroundStyle(skin.textTertiary)
                            .lineLimit(1).fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: 12)
                .clipped()
            }
            .padding(.top, 10)
        }
    }

    // MARK: Top lists

    private enum RankKind { case artist, album, track }

    private func rankList(_ title: String, _ ranks: [ProfileStats.Rank], kind: RankKind) -> some View {
        let peak = max(1, ranks.first?.count ?? 1)
        return section(title, detail: nil) {
            if ranks.isEmpty {
                quiet("Nothing in this period.")
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(ranks.enumerated()), id: \.element.id) { i, r in
                        RankRow(rank: r, number: i + 1, share: Double(r.count) / Double(peak), skin: skin) {
                            switch kind {
                            case .artist: library.source = .artist(r.target)
                            case .album, .track:
                                if library.albumGroup(for: r.target) != nil { library.albumKey = r.target }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Patterns

    private func clock(_ s: ProfileStats) -> some View {
        let peak = max(1, s.hours.max() ?? 1)
        let top = s.hours.indices.max { s.hours[$0] < s.hours[$1] } ?? 0
        return section("Time of day", detail: s.listens > 0 ? "most at \(Fmt.hour(top))" : nil) {
            VStack(spacing: 5) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24, id: \.self) { h in
                        Rectangle()
                            .fill(h == top && s.hours[h] > 0 ? skin.accent : skin.textPrimary.opacity(s.hours[h] == 0 ? 0.06 : 0.24))
                            .frame(height: max(2, 90 * CGFloat(s.hours[h]) / CGFloat(peak)))
                            .frame(maxWidth: .infinity)
                            .help("\(Fmt.hour(h)): \(s.hours[h]) listens")
                    }
                }
                .frame(height: 90, alignment: .bottom)
                HStack(spacing: 0) {
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text(Fmt.hour(h)).font(AppFont.ui(9.5)).foregroundStyle(skin.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func weekdays(_ s: ProfileStats) -> some View {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let peak = max(1, s.weekdays.max() ?? 1)
        let total = max(1, s.weekdays.reduce(0, +))
        return section("Days of the week", detail: nil) {
            VStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { i in
                    ShareRow(name: names[i], value: "\(Int((Double(s.weekdays[i]) / Double(total) * 100).rounded()))%",
                             share: Double(s.weekdays[i]) / Double(peak), skin: skin)
                }
            }
        }
    }

    private func shares(_ title: String, _ items: [ProfileStats.Share], empty: String) -> some View {
        let peak = max(1, items.map(\.count).max() ?? 1)
        let total = max(1, items.reduce(0) { $0 + $1.count })
        return section(title, detail: nil) {
            if items.isEmpty {
                quiet(empty)
            } else {
                VStack(spacing: 5) {
                    ForEach(items) { item in
                        ShareRow(name: item.name, value: "\(Int((Double(item.count) / Double(total) * 100).rounded()))%",
                                 share: Double(item.count) / Double(peak), skin: skin)
                    }
                }
            }
        }
    }

    // MARK: Recent, discoveries, records

    private func recent(_ s: ProfileStats) -> some View {
        let covers = Dictionary(library.albumGroups.map { ($0.key, $0.artworkFilePath) }, uniquingKeysWith: { a, _ in a })
        return section("Recent listens", detail: nil) {
            VStack(spacing: 0) {
                ForEach(s.recent) { l in
                    HStack(spacing: 10) {
                        ArtworkView(path: covers[ProfileStats.albumKey(l)] ?? nil, size: 32, skin: skin, placeholder: "opticaldisc")
                            .frame(width: 32, height: 32)
                            .clipShape(Rectangle())
                            .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.1), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l.title).font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).lineLimit(1)
                            Text(l.artist).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.ago(l.endedAt)).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).lineLimit(1).fixedSize()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func discoveries(_ s: ProfileStats) -> some View {
        section("New artists", detail: range == .all ? nil : "first heard in this period") {
            if range == .all {
                quiet("Every artist you've heard is new to all time. Pick a period to see who you found in it.")
            } else if s.discoveries.isEmpty {
                quiet("No artists heard for the first time in this period.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.discoveries.count == 10 ? "10+" : "\(s.discoveries.count)") new")
                        .font(AppFont.ui(22, weight: .semibold)).foregroundStyle(skin.textPrimary)
                        .padding(.bottom, 6)
                    ForEach(Array(s.discoveries.prefix(6).enumerated()), id: \.element.id) { i, r in
                        RankRow(rank: r, number: i + 1, share: nil, skin: skin) { library.source = .artist(r.target) }
                    }
                }
            }
        }
    }

    private func records(_ s: ProfileStats) -> some View {
        let coverage = s.libraryTracks == 0 ? 0 : Double(s.heardTracks) / Double(s.libraryTracks)
        return section("Records", detail: nil) {
            VStack(alignment: .leading, spacing: 0) {
                fact("Current streak", Fmt.days(s.currentStreak))
                fact("Longest streak", Fmt.days(s.longestStreak))
                if let b = s.busiestDay {
                    fact("Busiest day", "\(ProfileStats.shortDate.string(from: b.date)) · \(b.count) listens")
                }
                fact("Library heard", "\(Int((coverage * 100).rounded()))% of \(Fmt.count(s.libraryTracks)) tracks")
                ForEach(s.milestones) { m in
                    fact(m.number == 1 ? "First listen" : Fmt.ordinal(m.number) + " listen", "\(m.listen.title) · \(ProfileStats.shortDate.string(from: m.listen.endedAt))")
                }
                if let next = s.nextMilestone {
                    fact("Next milestone", "\(Fmt.count(next - s.totalListens)) to go to \(Fmt.count(next))")
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Text(value).font(AppFont.ui(12)).foregroundStyle(skin.textPrimary).lineLimit(1).truncationMode(.middle)
        }
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(skin.textPrimary.opacity(0.07)).frame(height: 1) }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(AppFont.ui(15, weight: .semibold)).foregroundStyle(skin.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pageGlass(skin)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(AppFont.ui(12)).foregroundStyle(skin.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    /// Sections side by side, `columns` to a row, each row as tall as its tallest.
    private func rows(_ columns: Int, _ views: [AnyView]) -> some View {
        let groups = stride(from: 0, to: views.count, by: columns).map { Array(views[$0..<min($0 + columns, views.count)]) }
        return VStack(spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, v in v }
                    if group.count < columns {
                        ForEach(0..<(columns - group.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A ranked line: number, cover, what it is, how many listens, and a thin
/// line for its share of the top entry.
private struct RankRow: View {
    var rank: ProfileStats.Rank
    var number: Int
    var share: Double?
    var skin: Skin
    var onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)").font(AppFont.ui(11)).foregroundStyle(skin.textTertiary).frame(width: 16, alignment: .trailing)
            ArtworkView(path: rank.cover, size: 32, skin: skin, placeholder: "opticaldisc")
                .frame(width: 32, height: 32)
                .clipShape(Rectangle())
                .overlay(Rectangle().strokeBorder(skin.textPrimary.opacity(0.1), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(rank.title).font(AppFont.ui(12, weight: .medium)).foregroundStyle(skin.textPrimary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.count(rank.count)).font(AppFont.ui(11)).foregroundStyle(skin.textSecondary)
                }
                Text(rank.subtitle).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary).lineLimit(1)
                if let share {
                    GeometryReader { g in
                        Rectangle().fill(skin.textPrimary.opacity(0.32)).frame(width: max(2, g.size.width * share), height: 2)
                    }
                    .frame(height: 2)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(Rectangle().fill(skin.textPrimary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("\(rank.count) listen\(rank.count == 1 ? "" : "s"), \(Fmt.duration(rank.seconds))")
    }
}

/// A name, its share of the whole, and a line for its share of the largest.
private struct ShareRow: View {
    var name: String
    var value: String
    var share: Double
    var skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(name).font(AppFont.ui(11.5)).foregroundStyle(skin.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                Text(value).font(AppFont.ui(10.5)).foregroundStyle(skin.textTertiary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(skin.textPrimary.opacity(0.07))
                    Rectangle().fill(skin.textPrimary.opacity(0.32)).frame(width: max(2, g.size.width * share))
                }
            }
            .frame(height: 2)
        }
    }
}
