import Foundation

/// One entry of `GET /images/json`.
public struct ImageSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var parentID: String
    public var repoTags: [String]
    public var repoDigests: [String]
    public var created: Int64
    public var size: Int64
    public var sharedSize: Int64
    public var containers: Int
    public var labels: [String: String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case parentID = "ParentId"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case created = "Created"
        case size = "Size"
        case sharedSize = "SharedSize"
        case containers = "Containers"
        case labels = "Labels"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        repoDigests = try c.decodeIfPresent([String].self, forKey: .repoDigests) ?? []
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sharedSize = try c.decodeIfPresent(Int64.self, forKey: .sharedSize) ?? -1
        containers = try c.decodeIfPresent(Int.self, forKey: .containers) ?? -1
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }

    /// First repo tag, or the short id with a `<none>` style fallback when untagged.
    public var displayName: String {
        if let tag = repoTags.first, tag != "<none>:<none>" {
            return tag
        }
        return "\(shortID) <none>"
    }

    /// Image id with the `sha256:` prefix stripped, truncated to 12 chars.
    public var shortID: String {
        let stripped = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id
        return String(stripped.prefix(12))
    }

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }

    public var sizeDisplay: String { size.formatted(.byteCount(style: .file)) }
}
