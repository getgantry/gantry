import Foundation

/// One entry of `GET /images/{id}/history`.
public struct ImageHistoryEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var created: Int64
    public var createdBy: String
    public var size: Int64
    public var comment: String
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case created = "Created"
        case createdBy = "CreatedBy"
        case size = "Size"
        case comment = "Comment"
        case tags = "Tags"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        // Docker may emit a JSON null for Tags on empty layers.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
}
