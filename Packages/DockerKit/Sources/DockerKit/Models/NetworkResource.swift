import Foundation

/// One entry of `GET /networks`.
public struct NetworkResource: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var created: String
    public var scope: String
    public var driver: String
    public var enableIPv6: Bool
    public var isInternal: Bool
    public var attachable: Bool
    public var ingress: Bool
    public var ipam: IPAM?
    public var labels: [String: String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case created = "Created"
        case scope = "Scope"
        case driver = "Driver"
        case enableIPv6 = "EnableIPv6"
        case isInternal = "Internal"
        case attachable = "Attachable"
        case ingress = "Ingress"
        case ipam = "IPAM"
        case labels = "Labels"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        created = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "local"
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        enableIPv6 = try c.decodeIfPresent(Bool.self, forKey: .enableIPv6) ?? false
        isInternal = try c.decodeIfPresent(Bool.self, forKey: .isInternal) ?? false
        attachable = try c.decodeIfPresent(Bool.self, forKey: .attachable) ?? false
        ingress = try c.decodeIfPresent(Bool.self, forKey: .ingress) ?? false
        ipam = try c.decodeIfPresent(IPAM.self, forKey: .ipam)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }

    /// Network id truncated to 12 chars.
    public var shortID: String { String(id.prefix(12)) }

    public struct IPAM: Hashable, Codable, Sendable {
        public var driver: String?
        public var config: [IPAMConfig]

        enum CodingKeys: String, CodingKey {
            case driver = "Driver"
            case config = "Config"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            driver = try c.decodeIfPresent(String.self, forKey: .driver)
            config = try c.decodeIfPresent([IPAMConfig].self, forKey: .config) ?? []
        }
    }

    public struct IPAMConfig: Hashable, Codable, Sendable {
        public var subnet: String?
        public var gateway: String?

        enum CodingKeys: String, CodingKey {
            case subnet = "Subnet"
            case gateway = "Gateway"
        }
    }
}
