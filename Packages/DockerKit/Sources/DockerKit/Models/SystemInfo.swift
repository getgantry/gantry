import Foundation

/// `GET /version`.
public struct SystemVersion: Hashable, Codable, Sendable {
    public var version: String
    public var apiVersion: String
    public var minAPIVersion: String?
    public var os: String
    public var arch: String
    public var kernelVersion: String?
    public var platformName: String?

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case minAPIVersion = "MinAPIVersion"
        case os = "Os"
        case arch = "Arch"
        case kernelVersion = "KernelVersion"
        case platform = "Platform"
    }

    private struct Platform: Codable, Sendable {
        var name: String?
        enum CodingKeys: String, CodingKey { case name = "Name" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? ""
        minAPIVersion = try c.decodeIfPresent(String.self, forKey: .minAPIVersion)
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        kernelVersion = try c.decodeIfPresent(String.self, forKey: .kernelVersion)
        platformName = try c.decodeIfPresent(Platform.self, forKey: .platform)?.name
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(apiVersion, forKey: .apiVersion)
        try c.encodeIfPresent(minAPIVersion, forKey: .minAPIVersion)
        try c.encode(os, forKey: .os)
        try c.encode(arch, forKey: .arch)
        try c.encodeIfPresent(kernelVersion, forKey: .kernelVersion)
        if let platformName {
            try c.encode(Platform(name: platformName), forKey: .platform)
        }
    }
}

/// `GET /info` — the subset of fields the app surfaces.
public struct SystemInfo: Hashable, Codable, Sendable {
    public var containers: Int
    public var containersRunning: Int
    public var containersPaused: Int
    public var containersStopped: Int
    public var images: Int
    public var serverVersion: String
    public var name: String
    public var operatingSystem: String
    public var osType: String
    public var architecture: String
    public var memTotal: Int64
    public var ncpu: Int

    enum CodingKeys: String, CodingKey {
        case containers = "Containers"
        case containersRunning = "ContainersRunning"
        case containersPaused = "ContainersPaused"
        case containersStopped = "ContainersStopped"
        case images = "Images"
        case serverVersion = "ServerVersion"
        case name = "Name"
        case operatingSystem = "OperatingSystem"
        case osType = "OSType"
        case architecture = "Architecture"
        case memTotal = "MemTotal"
        case ncpu = "NCPU"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        containers = try c.decodeIfPresent(Int.self, forKey: .containers) ?? 0
        containersRunning = try c.decodeIfPresent(Int.self, forKey: .containersRunning) ?? 0
        containersPaused = try c.decodeIfPresent(Int.self, forKey: .containersPaused) ?? 0
        containersStopped = try c.decodeIfPresent(Int.self, forKey: .containersStopped) ?? 0
        images = try c.decodeIfPresent(Int.self, forKey: .images) ?? 0
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        operatingSystem = try c.decodeIfPresent(String.self, forKey: .operatingSystem) ?? ""
        osType = try c.decodeIfPresent(String.self, forKey: .osType) ?? ""
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? ""
        memTotal = try c.decodeIfPresent(Int64.self, forKey: .memTotal) ?? 0
        ncpu = try c.decodeIfPresent(Int.self, forKey: .ncpu) ?? 0
    }
}
