import Foundation
import DockerKit

extension ContainerRecipe {
    /// The image's own config. Inspect merges it into the container config,
    /// so it is removed again to keep a copied command short.
    public struct ImageDefaults: Sendable, Equatable {
        public var env: [String] = []
        public var cmd: [String] = []
        public var entrypoint: [String] = []
        public var workingDir = ""
        public var user = ""
        public var labels: [String: String] = [:]

        public init() {}

        /// Reads `Config` of a `GET /images/{id}/json` body. Nil when the
        /// body has no config object.
        public init?(inspectJSON data: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = root["Config"] as? [String: Any] else { return nil }
            env = config["Env"] as? [String] ?? []
            cmd = config["Cmd"] as? [String] ?? []
            entrypoint = config["Entrypoint"] as? [String] ?? []
            workingDir = config["WorkingDir"] as? String ?? ""
            user = config["User"] as? String ?? ""
            labels = config["Labels"] as? [String: String] ?? [:]
        }
    }

    /// Labels Gantry stamps itself; they map back to recipe fields.
    static var internalLabelKeys: Set<String> {
        [dnsDomainLabelKey, ContainerCreateRequest.AppleOptions.kernelLabelKey,
         ContainerCreateRequest.AppleOptions.kernelArgsLabelKey]
    }

    /// A recipe that creates the same container again, from inspect data.
    public init(details: ContainerDetails, summary: ContainerSummary? = nil, image defaults: ImageDefaults? = nil) {
        self.init()
        let config = details.config
        image = [config.image, summary?.image, details.image].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        name = details.displayName
        setProcess(config: config, defaults: defaults)
        env = (config.env ?? [])
            .filter { !(defaults?.env.contains($0) ?? false) }
            .map { entry in
                guard let eq = entry.firstIndex(of: "=") else { return EnvVar(key: entry, value: "") }
                return EnvVar(key: String(entry[..<eq]), value: String(entry[entry.index(after: eq)...]))
            }
        setLabels(config.labels ?? [:], defaults: defaults)
        ports = Self.ports(details: details, summary: summary)
        volumes = Self.volumes(details: details)
        let mode = details.hostConfig.networkMode ?? ""
        network = Self.isDefaultNetwork(mode) ? "" : mode
        let policy = details.hostConfig.restartPolicy?.name ?? ""
        restartPolicy = policy.isEmpty ? "no" : policy
        if let nano = details.hostConfig.nanoCpus, nano > 0 { cpus = Self.cpusText(nanoCPUs: nano) }
        if let bytes = details.hostConfig.memory, bytes > 0 { memory = Self.memoryText(bytes: bytes) }
        tty = config.tty
        interactive = config.openStdin
        autoRemove = details.hostConfig.autoRemove ?? false
        detach = true
    }

    private mutating func setProcess(config: ContainerDetails.ContainerConfig, defaults: ImageDefaults?) {
        var entry = config.entrypoint ?? []
        var cmd = config.cmd ?? []
        if let defaults, entry == defaults.entrypoint {
            entry = []
            if cmd == defaults.cmd { cmd = [] }
        }
        entrypoint = entry.first ?? ""
        command = Array(entry.dropFirst()) + cmd
        let dir = config.workingDir ?? ""
        workdir = dir == defaults?.workingDir ? "" : dir
        let who = config.user ?? ""
        user = who == defaults?.user ? "" : who
    }

    private mutating func setLabels(_ all: [String: String], defaults: ImageDefaults?) {
        labels = all.keys.sorted()
            .filter { !Self.internalLabelKeys.contains($0) && defaults?.labels[$0] != all[$0] }
            .map { Label(key: $0, value: all[$0] ?? "") }
        dnsDomain = all[Self.dnsDomainLabelKey] ?? ""
        let apple = ContainerCreateRequest.AppleOptions(labels: all)
        kernel = apple.kernel ?? ""
        kernelArgs = apple.kernelArgs
    }

    /// Requested bindings first (they survive a stop), then live ones, then
    /// the list summary. An IPv4 and IPv6 "any" pair becomes one row.
    static func ports(details: ContainerDetails, summary: ContainerSummary?) -> [Port] {
        let source = [details.hostConfig.portBindings, details.networkSettings.ports]
            .compactMap { $0 }
            .first { map in map.values.contains { !($0 ?? []).isEmpty } }
        var result: [Port] = []
        if let source {
            for key in source.keys.sorted(by: portOrder) {
                let parts = key.split(separator: "/").map(String.init)
                let container = parts.first ?? key
                let proto = parts.count > 1 ? parts[1] : "tcp"
                for binding in source[key].flatMap({ $0 }) ?? [] {
                    let ip = binding.hostIP ?? ""
                    let port = Port(hostIP: ["0.0.0.0", "::", ""].contains(ip) ? "" : ip,
                                    host: binding.hostPort ?? "", container: container, proto: proto)
                    if !result.contains(port) { result.append(port) }
                }
            }
            return result
        }
        for port in summary?.ports ?? [] {
            guard let published = port.publicPort, published > 0 else { continue }
            let item = Port(host: String(published), container: String(port.privatePort), proto: port.type)
            if !result.contains(item) { result.append(item) }
        }
        return result
    }

    private static func portOrder(_ a: String, _ b: String) -> Bool {
        let left = Int(a.split(separator: "/").first ?? "") ?? 0
        let right = Int(b.split(separator: "/").first ?? "") ?? 0
        return left == right ? a < b : left < right
    }

    /// Binds as written, then named volumes and binds that only show up in
    /// `Mounts` (from `--mount`, or on apple/container).
    static func volumes(details: ContainerDetails) -> [Volume] {
        var result: [Volume] = []
        for bind in details.hostConfig.binds ?? [] {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let readOnly = parts.count > 2 && parts[2].split(separator: ",").contains("ro")
            result.append(Volume(source: parts[0], target: parts[1], readOnly: readOnly))
        }
        for mount in details.mounts where !result.contains(where: { $0.target == mount.destination }) {
            let type = mount.type ?? ""
            // apple/container reports binds as `virtiofs`; tmpfs has no source.
            guard !["tmpfs", "npipe", "image", "cluster"].contains(type) else { continue }
            let source = type == "volume" ? (mount.name ?? mount.source) : mount.source
            guard !source.isEmpty, !mount.destination.isEmpty else { continue }
            result.append(Volume(source: source, target: mount.destination, readOnly: mount.rw == false))
        }
        return result
    }
}
