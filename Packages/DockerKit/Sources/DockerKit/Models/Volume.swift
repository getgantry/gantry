import Foundation

/// One entry of the `Volumes` array in `GET /volumes`.
public struct Volume: Identifiable, Hashable, Codable, Sendable {
    public var name: String
    public var driver: String
    public var mountpoint: String
    public var createdAt: String
    public var labels: [String: String]
    public var scope: String
    public var options: [String: String]
    public var usageData: UsageData?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case createdAt = "CreatedAt"
        case labels = "Labels"
        case scope = "Scope"
        case options = "Options"
        case usageData = "UsageData"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        mountpoint = try c.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "local"
        options = try c.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        usageData = try c.decodeIfPresent(UsageData.self, forKey: .usageData)
    }

    public struct UsageData: Hashable, Codable, Sendable {
        public var size: Int64
        public var refCount: Int

        enum CodingKeys: String, CodingKey {
            case size = "Size"
            case refCount = "RefCount"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? -1
            refCount = try c.decodeIfPresent(Int.self, forKey: .refCount) ?? -1
        }
    }
}

/// `GET /volumes` response envelope.
public struct VolumeListResponse: Hashable, Codable, Sendable {
    public var volumes: [Volume]
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case volumes = "Volumes"
        case warnings = "Warnings"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}
