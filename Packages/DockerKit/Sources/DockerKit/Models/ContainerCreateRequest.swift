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
    /// apple/container knobs that have no Docker equivalent. Only
    /// `AppleContainerTransport` reads this; a real Docker daemon ignores body
    /// keys it doesn't know, so carrying it costs nothing on Docker hosts.
    public var appleOptions: AppleOptions?

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
        case appleOptions = "GantryAppleOptions"
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
        appleOptions: AppleOptions? = nil,
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
        // An options object with nothing set would encode as an empty `{}` the
        // transport then has to special-case; drop it here instead.
        self.appleOptions = (appleOptions?.isEmpty ?? true) ? nil : appleOptions
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
        appleOptions: AppleOptions? = nil,
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
            appleOptions: appleOptions,
            name: name
        )
    }

    /// apple/container-specific create options with no Docker counterpart.
    ///
    /// Kept out of `HostConfig` deliberately: that struct mirrors Docker's own
    /// schema, and these keys are Gantry's own extension, read only by the
    /// apple/container transport.
    public struct AppleOptions: Encodable, Hashable, Sendable {
        /// A custom kernel binary the container boots (`--kernel`). Supported
        /// by every CLI Gantry targets (1.0+).
        public var kernel: String?
        /// Raw boot arguments appended to the kernel command line, in order
        /// (`--kernel-arg`, repeatable). Needs CLI 1.2 or newer — see
        /// `ContainerTooling.kernelArgumentsVersion`.
        public var kernelArgs: [String]

        enum CodingKeys: String, CodingKey {
            case kernel = "Kernel"
            case kernelArgs = "KernelArgs"
        }

        /// Whether nothing is actually set, so the key can be omitted.
        public var isEmpty: Bool {
            (kernel?.isEmpty ?? true) && kernelArgs.isEmpty
        }

        public init(kernel: String? = nil, kernelArgs: [String] = []) {
            self.kernel = kernel
            self.kernelArgs = kernelArgs
        }

        // MARK: - Label round-trip

        /// Label recording the custom kernel a container was created with.
        public static let kernelLabelKey = "com.gantry.kernel"
        /// Label recording its boot arguments, one per line.
        public static let kernelArgsLabelKey = "com.gantry.kernel-args"

        /// Marker labels to stamp at create time, empty when nothing is set.
        ///
        /// `container inspect` reports neither the kernel path nor its boot
        /// arguments (checked against CLI 1.2), so without these a recreate
        /// would silently boot the container off the stock kernel. Mirrors the
        /// DNS-domain marker Gantry already stamps.
        ///
        /// Arguments are joined with newlines rather than spaces because a
        /// single boot argument may legitimately contain a quoted space.
        public var labels: [String: String] {
            var labels: [String: String] = [:]
            if let kernel, !kernel.isEmpty { labels[Self.kernelLabelKey] = Self.escape(kernel) }
            if !kernelArgs.isEmpty {
                labels[Self.kernelArgsLabelKey] = Self.escape(kernelArgs.joined(separator: "\n"))
            }
            return labels
        }

        /// Rebuilds the options a previous create stamped into `labels`.
        /// Yields empty options when the labels carry no kernel markers.
        public init(labels: [String: String]) {
            let kernel = labels[Self.kernelLabelKey].map(Self.unescape)
            self.kernel = (kernel?.isEmpty ?? true) ? nil : kernel
            self.kernelArgs = Self.unescape(labels[Self.kernelArgsLabelKey] ?? "")
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        }

        /// Boot arguments are `key=value` and apple/container parses a label as
        /// `key=value` too, rejecting outright any label whose value contains a
        /// second `=` (`Parser.parseLabels`, checked against CLI 1.2). So the
        /// `=` is percent-escaped on the way into a label — `%` first, or
        /// unescaping would be ambiguous.
        private static func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "=", with: "%3D")
        }

        private static func unescape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "%3D", with: "=")
                .replacingOccurrences(of: "%25", with: "%")
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let kernel, !kernel.isEmpty { try c.encode(kernel, forKey: .kernel) }
            if !kernelArgs.isEmpty { try c.encode(kernelArgs, forKey: .kernelArgs) }
        }
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
