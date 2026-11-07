import Foundation

/// Orders palette results for a query.
public enum PaletteRanker {
    /// Ranks `items` for `query`. Every word of the query must match the
    /// title, a keyword, the host name or the kind. Titles weigh more than
    /// the other fields, and recent items get a bonus. An empty query lists
    /// the recent items first, then commands, hosts and sections.
    public static func rank(
        _ items: [PaletteItem],
        query: String,
        recents: [String] = [],
        limit: Int = 60
    ) -> [PaletteItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let recentIndex = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        if words.isEmpty {
            return Array(emptyQueryOrder(items, recentIndex: recentIndex).prefix(limit))
        }

        var scored: [(item: PaletteItem, score: Int)] = []
        for item in items {
            guard var total = score(item, words: words) else { continue }
            if let index = recentIndex[item.id] { total += max(0, 20 - index * 2) }
            scored.append((item, total))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return tieBreak(lhs.item, rhs.item)
        }
        return Array(scored.prefix(limit).map(\.item))
    }

    /// The score of one item, or nil when a query word matches nothing.
    static func score(_ item: PaletteItem, words: [String]) -> Int? {
        var total = 0
        for word in words {
            let title = FuzzyMatch.score(word, in: item.title).map { $0 * 2 }
            var others = item.keywords
            if let hostName = item.hostName { others.append(hostName) }
            others.append(item.kind.title)
            let other = FuzzyMatch.bestScore(word, in: others)
            guard let best = [title, other].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }

    static func emptyQueryOrder(_ items: [PaletteItem], recentIndex: [String: Int]) -> [PaletteItem] {
        let recent = items
            .filter { recentIndex[$0.id] != nil }
            .sorted { (recentIndex[$0.id] ?? 0) < (recentIndex[$1.id] ?? 0) }
        let rest = [PaletteKind.command, .host, .section].flatMap { kind in
            items.filter { $0.kind == kind && recentIndex[$0.id] == nil }
        }
        return recent + rest
    }

    static func tieBreak(_ lhs: PaletteItem, _ rhs: PaletteItem) -> Bool {
        if lhs.kind.rankOrder != rhs.kind.rankOrder { return lhs.kind.rankOrder < rhs.kind.rankOrder }
        if lhs.title.count != rhs.title.count { return lhs.title.count < rhs.title.count }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// The items the user ran from the palette, newest first.
public struct PaletteRecents: Sendable, Equatable {
    public static let defaultsKey = "commandPaletteRecents"
    public static let limit = 12

    public private(set) var ids: [String]

    public init(ids: [String] = []) {
        self.ids = Array(ids.prefix(Self.limit))
    }

    /// Moves `id` to the front and drops the oldest past the limit.
    public mutating func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }

    public static func load(from defaults: UserDefaults = .standard) -> PaletteRecents {
        PaletteRecents(ids: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(ids, forKey: Self.defaultsKey)
    }
}
