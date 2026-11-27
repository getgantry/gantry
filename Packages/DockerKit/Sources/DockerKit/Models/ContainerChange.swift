import Foundation

/// One entry of `GET /containers/{id}/changes`: a path that the container
/// added, changed or deleted compared to its image (`docker diff`).
public struct ContainerChange: Hashable, Codable, Sendable {
    /// The kind of a change. Docker sends 0, 1 or 2.
    public enum Kind: Int, Hashable, Codable, Sendable, CaseIterable {
        case changed = 0
        case added = 1
        case deleted = 2
    }

    public var path: String
    public var kind: Kind

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case kind = "Kind"
    }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        // An unknown kind from a newer engine shows as a change.
        let raw = try c.decodeIfPresent(Int.self, forKey: .kind) ?? 0
        kind = Kind(rawValue: raw) ?? .changed
    }
}
