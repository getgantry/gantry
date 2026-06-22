import Foundation

/// One entry of `GET /containers/json`.
public struct ContainerSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var names: [String]
    public var image: String
    public var imageID: String
    public var command: String
    public var created: Int64
    public var ports: [PortBinding]
    public var labels: [String: String]
    public var state: ContainerState
    public var status: String
    public var mounts: [MountPoint]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case imageID = "ImageID"
        case command = "Command"
        case created = "Created"
        case ports = "Ports"
        case labels = "Labels"
        case state = "State"
        case status = "Status"
        case mounts = "Mounts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        ports = try c.decodeIfPresent([PortBinding].self, forKey: .ports) ?? []
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        state = try c.decodeIfPresent(ContainerState.self, forKey: .state) ?? .unknown
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        mounts = try c.decodeIfPresent([MountPoint].self, forKey: .mounts) ?? []
    }

    /// Display name without the leading slash.
    public var displayName: String {
        names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(id.prefix(12))
    }

    public var shortID: String { String(id.prefix(12)) }

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }

    /// Compose project name when the container was started by docker compose.
    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var composeService: String? { labels["com.docker.compose.service"] }
}

public enum ContainerState: String, Codable, Sendable, CaseIterable {
    case created
    case running
    case paused
    case restarting
    case removing
    case exited
    case dead
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ContainerState(rawValue: raw) ?? .unknown
    }

    public var isRunning: Bool { self == .running }
}

public struct PortBinding: Hashable, Codable, Sendable {
    public var ip: String?
    public var privatePort: Int
    public var publicPort: Int?
    public var type: String

    public init(ip: String? = nil, privatePort: Int, publicPort: Int? = nil, type: String = "tcp") {
        self.ip = ip
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case ip = "IP"
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
    }

    public var display: String {
        if let publicPort {
            "\(ip ?? "0.0.0.0"):\(publicPort) → \(privatePort)/\(type)"
        } else {
            "\(privatePort)/\(type)"
        }
    }
}

public struct MountPoint: Hashable, Codable, Sendable {
    public var type: String?
    public var name: String?
    public var source: String
    public var destination: String
    public var mode: String?
    public var rw: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case name = "Name"
        case source = "Source"
        case destination = "Destination"
        case mode = "Mode"
        case rw = "RW"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        rw = try c.decodeIfPresent(Bool.self, forKey: .rw)
    }
}
