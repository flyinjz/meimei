import Foundation

struct Playlist: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    /// Manual playlists: the tracks, in play order. Unused for smart playlists.
    var trackIDs: [UUID]
    /// The built-in "whole library" entry. Kept for compatibility with older
    /// library files; it never appears as a user playlist.
    var isLibraryView: Bool = false
    var isSmart: Bool = false
    var matchAll: Bool = true
    var rules: [SmartRule] = []
    var isBuiltIn: Bool = false
    /// Smart playlists only: how matches are ordered, and how many to keep.
    var smartOrder: SmartOrder = .library
    var smartLimit: Int? = nil

    init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [UUID] = [],
        isLibraryView: Bool = false,
        isSmart: Bool = false,
        matchAll: Bool = true,
        rules: [SmartRule] = [],
        isBuiltIn: Bool = false,
        smartOrder: SmartOrder = .library,
        smartLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.isLibraryView = isLibraryView
        self.isSmart = isSmart
        self.matchAll = matchAll
        self.rules = rules
        self.isBuiltIn = isBuiltIn
        self.smartOrder = smartOrder
        self.smartLimit = smartLimit
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, trackIDs, isLibraryView, isSmart, matchAll, rules, isBuiltIn, smartOrder, smartLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        trackIDs = try c.decodeIfPresent([UUID].self, forKey: .trackIDs) ?? []
        isLibraryView = try c.decodeIfPresent(Bool.self, forKey: .isLibraryView) ?? false
        isSmart = try c.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
        matchAll = try c.decodeIfPresent(Bool.self, forKey: .matchAll) ?? true
        rules = try c.decodeIfPresent([SmartRule].self, forKey: .rules) ?? []
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        smartOrder = (try? c.decodeIfPresent(SmartOrder.self, forKey: .smartOrder)) ?? .library
        smartLimit = try c.decodeIfPresent(Int.self, forKey: .smartLimit)
    }

    func matches(_ track: Track, now: Date = Date()) -> Bool {
        guard isSmart, !rules.isEmpty else { return false }
        return matchAll
            ? rules.allSatisfy { $0.matches(track, now: now) }
            : rules.contains { $0.matches(track, now: now) }
    }

    /// Smart playlist contents: matching tracks, ordered and capped.
    func resolveSmart(from tracks: [Track]) -> [Track] {
        let now = Date()
        var result = tracks.filter { matches($0, now: now) }
        smartOrder.sort(&result)
        if let smartLimit, smartLimit > 0, result.count > smartLimit {
            result = Array(result.prefix(smartLimit))
        }
        return result
    }
}

/// A node in the genre browse list.
struct GenreNode: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
}
