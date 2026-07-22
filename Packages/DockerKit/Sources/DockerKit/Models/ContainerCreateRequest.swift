import Foundation

/// Body for `POST /containers/create`. Maps to Docker's container config object.
///
/// Built as a clean Encodable struct with optional fields so unset values are
/// omitted from the JSON. The container name is supplied separately as a query
/// parameter (see `createContainer`), not part of this body.
public struct ContainerCreateRequest: Encodable, Sendable {
    public var image: String
    public var cmd: [String]?
    public var entrypoint: [String]?
    /// The container's DNS domain. On apple/container this maps to
    /// `--dns-domain`, so a container named `web` on domain `test` resolves as
    /// `web.test` once that local domain exists.
    public var domainname: String?
    public var env: [String]
    /// Exposed ports as Docker's `{"80/tcp": {}}` set.
    public var exposedPorts: [String: EmptyObject]?
    public var labels: [String: String]
    public var tty: Bool
    public var workingDir: String?
    public var hostConfig: HostConfig?
    public var networkingConfig: NetworkingConfig?

    /// Desired container name. Not part of the request body — Docker takes the
    /// name as a query parameter on `POST /containers/create`, so this is
    /// excluded from `CodingKeys` and read separately by the client/session.
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case cmd = "Cmd"
        case entrypoint = "Entrypoint"
        case domainname = "Domainname"
        case env = "Env"
        case exposedPorts = "ExposedPorts"
        case labels = "Labels"
        case tty = "Tty"
        case workingDir = "WorkingDir"
        case hostConfig = "HostConfig"
        case networkingConfig = "NetworkingConfig"
    }

    public init(
        image: String,
        cmd: [String]? = nil,
        entrypoint: [String]? = nil,
        domainname: String? = nil,
        env: [String] = [],
        exposedPorts: [String]? = nil,
        labels: [String: String] = [:],
        tty: Bool = false,
        workingDir: String? = nil,
        hostConfig: HostConfig? = nil,
        networkingConfig: NetworkingConfig? = nil,
        name: String? = nil
    ) {
        self.image = image
        self.cmd = cmd
        self.entrypoint = entrypoint
        self.domainname = domainname
        self.env = env
        if let exposedPorts {
            self.exposedPorts = Dictionary(uniqueKeysWithValues: exposedPorts.map { ($0, EmptyObject()) })
        } else {
            self.exposedPorts = nil
        }
        self.labels = labels
        self.tty = tty
        self.workingDir = workingDir
        self.hostConfig = hostConfig
        self.networkingConfig = networkingConfig
        self.name = name
    }

    /// Convenience initializer mirroring the common `docker run` knobs used by
    /// the create-container UI. Port mappings are given as
    /// `["80/tcp": "8080"]` (container port/proto → host port) and binds as
    /// `["host:container[:ro]"]`. Builds the `HostConfig` and exposed-ports set.
    public init(
        image: String,
        cmd: [String]? = nil,
        env: [String] = [],
        ports: [String: String] = [:],
        binds: [String] = [],
        restartPolicy: String = "no",
        tty: Bool = false,
        labels: [String: String] = [:],
        autoRemove: Bool = false,
        domainname: String? = nil,
        name: String? = nil
    ) {
        let exposed: [String]? = ports.isEmpty ? nil : Array(ports.keys)
        var portBindings: [String: [PortBinding]]? = nil
        if !ports.isEmpty {
            portBindings = Dictionary(uniqueKeysWithValues: ports.map { key, host in
                (key, [PortBinding(hostPort: host)])
            })
        }
        let policy: RestartPolicy? = restartPolicy == "no" ? nil : RestartPolicy(name: restartPolicy)
        let hostConfig = HostConfig(
            binds: binds.isEmpty ? nil : binds,
            portBindings: portBindings,
            restartPolicy: policy,
            autoRemove: autoRemove ? true : nil
        )
        self.init(
            image: image,
            cmd: cmd,
            domainname: domainname,
            env: env,
            exposedPorts: exposed,
            labels: labels,
            tty: tty,
            hostConfig: hostConfig,
            name: name
        )
    }

    /// An empty JSON object `{}`, used for the exposed-ports set values.
    public struct EmptyObject: Encodable, Hashable, Sendable {
        public init() {}
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode([String: String]())
        }
    }

    /// A single host port binding for one container port.
    public struct PortBinding: Encodable, Hashable, Sendable {
        public var hostIP: String?
        public var hostPort: String

        enum CodingKeys: String, CodingKey {
            case hostIP = "HostIp"
            case hostPort = "HostPort"
        }

        public init(hostIP: String? = nil, hostPort: String) {
            self.hostIP = hostIP
            self.hostPort = hostPort
        }
    }

    /// Container restart policy.
    public struct RestartPolicy: Encodable, Hashable, Sendable {
        public var name: String
        public var maximumRetryCount: Int

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case maximumRetryCount = "MaximumRetryCount"
        }

        public init(name: String, maximumRetryCount: Int = 0) {
            self.name = name
            self.maximumRetryCount = maximumRetryCount
        }
    }

    /// Host-level container configuration.
    public struct HostConfig: Encodable, Sendable {
        /// Bind mounts in `host:container[:mode]` form.
        public var binds: [String]?
        /// Port bindings keyed by `"80/tcp"`.
        public var portBindings: [String: [PortBinding]]?
        public var restartPolicy: RestartPolicy?
        public var memory: Int64?
        public var nanoCPUs: Int64?
        public var autoRemove: Bool?
        public var privileged: Bool?
        /// PID namespace to join, e.g. `"container:<id>"`. Sharing the target's
        /// PID namespace is what lets a debug sidecar see its processes — and
        /// reach its filesystem through `/proc/1/root`.
        public var pidMode: String?
        /// Network mode; `"container:<id>"` joins another container's network
        /// namespace, so `curl localhost:<port>` hits the target's listener.
        public var networkMode: String?
        /// IPC namespace to join, e.g. `"container:<id>"`.
        public var ipcMode: String?
        /// Extra Linux capabilities, e.g. `["SYS_PTRACE"]`.
        public var capAdd: [String]?
        /// Security options, e.g. `["apparmor=unconfined"]`.
        public var securityOpt: [String]?

        enum CodingKeys: String, CodingKey {
            case binds = "Binds"
            case portBindings = "PortBindings"
            case restartPolicy = "RestartPolicy"
            case memory = "Memory"
            case nanoCPUs = "NanoCpus"
            case autoRemove = "AutoRemove"
            case privileged = "Privileged"
            case pidMode = "PidMode"
            case networkMode = "NetworkMode"
            case ipcMode = "IpcMode"
            case capAdd = "CapAdd"
            case securityOpt = "SecurityOpt"
        }

        public init(
            binds: [String]? = nil,
            portBindings: [String: [PortBinding]]? = nil,
            restartPolicy: RestartPolicy? = nil,
            memory: Int64? = nil,
            nanoCPUs: Int64? = nil,
            autoRemove: Bool? = nil,
            privileged: Bool? = nil,
            pidMode: String? = nil,
            networkMode: String? = nil,
            ipcMode: String? = nil,
            capAdd: [String]? = nil,
            securityOpt: [String]? = nil
        ) {
            self.binds = binds
            self.portBindings = portBindings
            self.restartPolicy = restartPolicy
            self.memory = memory
            self.nanoCPUs = nanoCPUs
            self.autoRemove = autoRemove
            self.privileged = privileged
            self.pidMode = pidMode
            self.networkMode = networkMode
            self.ipcMode = ipcMode
            self.capAdd = capAdd
            self.securityOpt = securityOpt
        }
    }

    /// Networking configuration attaching the container to named endpoints.
    public struct NetworkingConfig: Encodable, Sendable {
        public var endpointsConfig: [String: EndpointConfig]

        enum CodingKeys: String, CodingKey {
            case endpointsConfig = "EndpointsConfig"
        }

        public init(endpointsConfig: [String: EndpointConfig]) {
            self.endpointsConfig = endpointsConfig
        }
    }

    /// Per-network endpoint settings.
    public struct EndpointConfig: Encodable, Sendable {
        public var aliases: [String]?

        enum CodingKeys: String, CodingKey {
            case aliases = "Aliases"
        }

        public init(aliases: [String]? = nil) {
            self.aliases = aliases
        }
    }
}

/// Response from `POST /containers/create`.
public struct ContainerCreateResponse: Codable, Sendable {
    public var id: String
    public var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case warnings = "Warnings"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}
