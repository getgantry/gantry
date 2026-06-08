import Foundation

/// `GET /containers/{id}/json` — the fields the app actually uses.
/// The full raw JSON is available separately for the Inspect tab.
public struct ContainerDetails: Hashable, Codable, Sendable {
    public var id: String
    public var created: String
    public var path: String
    public var args: [String]
    public var state: DetailedState
    public var image: String
    public var name: String
    public var restartCount: Int
    public var platform: String?
    public var hostConfig: HostConfig
    public var config: ContainerConfig
    public var networkSettings: NetworkSettings
    public var mounts: [MountPoint]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case created = "Created"
        case path = "Path"
        case args = "Args"
        case state = "State"
        case image = "Image"
        case name = "Name"
        case restartCount = "RestartCount"
        case platform = "Platform"
        case hostConfig = "HostConfig"
        case config = "Config"
        case networkSettings = "NetworkSettings"
        case mounts = "Mounts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        state = try c.decode(DetailedState.self, forKey: .state)
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        restartCount = try c.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        hostConfig = try c.decodeIfPresent(HostConfig.self, forKey: .hostConfig) ?? HostConfig()
        config = try c.decode(ContainerConfig.self, forKey: .config)
        networkSettings = try c.decodeIfPresent(NetworkSettings.self, forKey: .networkSettings) ?? NetworkSettings()
        mounts = try c.decodeIfPresent([MountPoint].self, forKey: .mounts) ?? []
    }

    public var displayName: String { name.hasPrefix("/") ? String(name.dropFirst()) : name }

    public struct DetailedState: Hashable, Codable, Sendable {
        public var status: ContainerState
        public var running: Bool
        public var paused: Bool
        public var restarting: Bool
        public var oomKilled: Bool
        public var pid: Int
        public var exitCode: Int
        public var error: String
        public var startedAt: String
        public var finishedAt: String
        public var health: Health?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case running = "Running"
            case paused = "Paused"
            case restarting = "Restarting"
            case oomKilled = "OOMKilled"
            case pid = "Pid"
            case exitCode = "ExitCode"
            case error = "Error"
            case startedAt = "StartedAt"
            case finishedAt = "FinishedAt"
            case health = "Health"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(ContainerState.self, forKey: .status) ?? .unknown
            running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
            paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            restarting = try c.decodeIfPresent(Bool.self, forKey: .restarting) ?? false
            oomKilled = try c.decodeIfPresent(Bool.self, forKey: .oomKilled) ?? false
            pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
            exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
            finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt) ?? ""
            health = try c.decodeIfPresent(Health.self, forKey: .health)
        }
    }

    public struct Health: Hashable, Codable, Sendable {
        public var status: String
        public var failingStreak: Int

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case failingStreak = "FailingStreak"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            failingStreak = try c.decodeIfPresent(Int.self, forKey: .failingStreak) ?? 0
        }
    }

    public struct HostConfig: Hashable, Codable, Sendable {
        public var binds: [String]?
        public var networkMode: String?
        public var restartPolicy: RestartPolicy?
        public var memory: Int64?
        public var nanoCpus: Int64?
        public var privileged: Bool?
        public var autoRemove: Bool?

        enum CodingKeys: String, CodingKey {
            case binds = "Binds"
            case networkMode = "NetworkMode"
            case restartPolicy = "RestartPolicy"
            case memory = "Memory"
            case nanoCpus = "NanoCpus"
            case privileged = "Privileged"
            case autoRemove = "AutoRemove"
        }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            binds = try c.decodeIfPresent([String].self, forKey: .binds)
            networkMode = try c.decodeIfPresent(String.self, forKey: .networkMode)
            restartPolicy = try c.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy)
            memory = try c.decodeIfPresent(Int64.self, forKey: .memory)
            nanoCpus = try c.decodeIfPresent(Int64.self, forKey: .nanoCpus)
            privileged = try c.decodeIfPresent(Bool.self, forKey: .privileged)
            autoRemove = try c.decodeIfPresent(Bool.self, forKey: .autoRemove)
        }
    }

    public struct RestartPolicy: Hashable, Codable, Sendable {
        public var name: String?
        public var maximumRetryCount: Int?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case maximumRetryCount = "MaximumRetryCount"
        }
    }

    public struct ContainerConfig: Hashable, Codable, Sendable {
        public var hostname: String?
        public var domainname: String?
        public var env: [String]?
        public var cmd: [String]?
        public var entrypoint: [String]?
        public var image: String?
        public var labels: [String: String]?
        public var tty: Bool
        public var workingDir: String?
        public var user: String?

        enum CodingKeys: String, CodingKey {
            case hostname = "Hostname"
            case domainname = "Domainname"
            case env = "Env"
            case cmd = "Cmd"
            case entrypoint = "Entrypoint"
            case image = "Image"
            case labels = "Labels"
            case tty = "Tty"
            case workingDir = "WorkingDir"
            case user = "User"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
            domainname = try c.decodeIfPresent(String.self, forKey: .domainname)
            env = try c.decodeIfPresent([String].self, forKey: .env)
            cmd = try c.decodeIfPresent([String].self, forKey: .cmd)
            entrypoint = try c.decodeIfPresent([String].self, forKey: .entrypoint)
            image = try c.decodeIfPresent(String.self, forKey: .image)
            labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
            tty = try c.decodeIfPresent(Bool.self, forKey: .tty) ?? false
            workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir)
            user = try c.decodeIfPresent(String.self, forKey: .user)
        }
    }

    public struct NetworkSettings: Hashable, Codable, Sendable {
        public var ipAddress: String?
        public var ports: [String: [HostPort]?]?
        public var networks: [String: EndpointSettings]?

        enum CodingKeys: String, CodingKey {
            case ipAddress = "IPAddress"
            case ports = "Ports"
            case networks = "Networks"
        }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ipAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress)
            ports = try c.decodeIfPresent([String: [HostPort]?].self, forKey: .ports)
            networks = try c.decodeIfPresent([String: EndpointSettings].self, forKey: .networks)
        }
    }

    public struct HostPort: Hashable, Codable, Sendable {
        public var hostIP: String?
        public var hostPort: String?

        enum CodingKeys: String, CodingKey {
            case hostIP = "HostIp"
            case hostPort = "HostPort"
        }
    }

    public struct EndpointSettings: Hashable, Codable, Sendable {
        public var ipAddress: String?
        public var gateway: String?
        public var macAddress: String?

        enum CodingKeys: String, CodingKey {
            case ipAddress = "IPAddress"
            case gateway = "Gateway"
            case macAddress = "MacAddress"
        }
    }
}
