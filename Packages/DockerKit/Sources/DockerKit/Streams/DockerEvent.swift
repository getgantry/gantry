import Foundation

/// One entry of `GET /events`.
public struct DockerEvent: Sendable, Hashable {
    public var type: String
    public var action: String
    public var actorID: String
    public var actorAttributes: [String: String]
    public var time: Int64
    public var timeNano: Int64

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case action = "Action"
        case actor = "Actor"
        case time = "time"
        case timeNano = "timeNano"
    }

    private struct Actor: Decodable {
        var id: String
        var attributes: [String: String]
        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case attributes = "Attributes"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            attributes = try c.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        let actor = try c.decodeIfPresent(Actor.self, forKey: .actor)
        actorID = actor?.id ?? ""
        actorAttributes = actor?.attributes ?? [:]
        time = try c.decodeIfPresent(Int64.self, forKey: .time) ?? 0
        timeNano = try c.decodeIfPresent(Int64.self, forKey: .timeNano) ?? 0
    }

    public init(
        type: String,
        action: String,
        actorID: String,
        actorAttributes: [String: String] = [:],
        time: Int64 = 0,
        timeNano: Int64 = 0
    ) {
        self.type = type
        self.action = action
        self.actorID = actorID
        self.actorAttributes = actorAttributes
        self.time = time
        self.timeNano = timeNano
    }

    public var isContainerEvent: Bool { type == "container" }

    /// The container name from the actor attributes, when present.
    public var containerName: String? { actorAttributes["name"] }
}

extension DockerEvent: Decodable {}
