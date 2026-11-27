import Foundation
import DockerKit

/// The logic of the Changes tab: counts, filter, tree and the row limit for
/// `GET /containers/{id}/changes`. All of it is pure, so the view can run it
/// off the main actor for a diff with many thousands of entries.
public enum ContainerChanges {
    /// The most rows that the view draws at one time: in the flat list, and
    /// per directory in the tree.
    public static let rowLimit = 2_000

    /// The number of entries of each kind.
    public struct Counts: Hashable, Sendable {
        public var added = 0
        public var changed = 0
        public var deleted = 0

        public init(added: Int = 0, changed: Int = 0, deleted: Int = 0) {
            self.added = added
            self.changed = changed
            self.deleted = deleted
        }

        public init(_ changes: [ContainerChange]) {
            for change in changes {
                switch change.kind {
                case .added: added += 1
                case .changed: changed += 1
                case .deleted: deleted += 1
                }
            }
        }

        public var total: Int { added + changed + deleted }

        public func count(of kind: ContainerChange.Kind) -> Int {
            switch kind {
            case .added: added
            case .changed: changed
            case .deleted: deleted
            }
        }
    }

    /// The entries of the given kinds whose path contains `search` (any
    /// letter case), sorted by path. An empty search matches all paths.
    public static func filtered(
        _ changes: [ContainerChange],
        kinds: Set<ContainerChange.Kind>,
        search: String
    ) -> [ContainerChange] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return changes
            .filter { change in
                guard kinds.contains(change.kind) else { return false }
                return needle.isEmpty || change.path.range(of: needle, options: .caseInsensitive) != nil
            }
            .sorted { $0.path < $1.path }
    }

    /// The first `limit` rows and the number of rows that are not shown.
    public static func page<T>(_ rows: [T], limit: Int = rowLimit) -> (rows: [T], hidden: Int) {
        guard rows.count > limit else { return (rows, 0) }
        return (Array(rows.prefix(limit)), rows.count - limit)
    }

    /// One row of the tree: a path of the diff, a parent directory that is
    /// not in the (filtered) diff (`kind` nil), or a "more" row that stands
    /// for `hiddenCount` children over the limit.
    public struct Node: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var kind: ContainerChange.Kind?
        /// nil for a leaf, so that `List(children:)` shows no disclosure.
        public var children: [Node]?
        public var hiddenCount: Int

        public var isMoreRow: Bool { hiddenCount > 0 }
    }

    /// Builds the tree of the given entries. Each level is sorted by name and
    /// holds at most `limit` nodes; a last "more" node counts the rest.
    public static func tree(_ changes: [ContainerChange], limit: Int = rowLimit) -> [Node] {
        let root = Builder()
        for change in changes {
            var node = root
            var path = ""
            for component in change.path.split(separator: "/", omittingEmptySubsequences: true) {
                let name = String(component)
                path += "/" + name
                if let next = node.children[name] {
                    node = next
                } else {
                    let next = Builder()
                    next.path = path
                    node.children[name] = next
                    node = next
                }
            }
            if node !== root { node.kind = change.kind }
        }
        return root.nodes(limit: limit)
    }

    /// Filters and builds the rows for the view off the main actor: a
    /// nonisolated async function runs on the global executor.
    public static func prepare(
        _ changes: [ContainerChange],
        kinds: Set<ContainerChange.Kind>,
        search: String,
        asTree: Bool
    ) async -> Prepared {
        let rows = filtered(changes, kinds: kinds, search: search)
        if asTree { return Prepared(matchCount: rows.count, flat: [], hidden: 0, tree: tree(rows)) }
        let page = page(rows)
        return Prepared(matchCount: rows.count, flat: page.rows, hidden: page.hidden, tree: [])
    }

    /// The rows for the view, made by `prepare`.
    public struct Prepared: Hashable, Sendable {
        public var matchCount: Int
        public var flat: [ContainerChange]
        /// Flat rows over the limit that the view does not draw.
        public var hidden: Int
        public var tree: [Node]

        public static let empty = Prepared(matchCount: 0, flat: [], hidden: 0, tree: [])
    }

    /// A map from path to kind, for badges in the file browser.
    public static func kindsByPath(_ changes: [ContainerChange]) -> [String: ContainerChange.Kind] {
        Dictionary(changes.map { ($0.path, $0.kind) }, uniquingKeysWith: { _, last in last })
    }

    private final class Builder {
        var path = ""
        var kind: ContainerChange.Kind?
        var children: [String: Builder] = [:]

        func nodes(limit: Int) -> [Node] {
            let names = children.keys.sorted()
            var result: [Node] = []
            result.reserveCapacity(min(names.count, limit) + 1)
            for name in names.prefix(limit) {
                guard let child = children[name] else { continue }
                let grandchildren = child.children.isEmpty ? nil : child.nodes(limit: limit)
                result.append(Node(id: child.path, name: name, kind: child.kind, children: grandchildren, hiddenCount: 0))
            }
            if names.count > limit {
                result.append(Node(id: path + "/\u{0}more", name: "", kind: nil, children: nil, hiddenCount: names.count - limit))
            }
            return result
        }
    }
}
