import Foundation
import DockerKit

/// Everything the New Container sheet can hold, as plain values. A pasted
/// `docker run` fills one, a saved recipe stores one as JSON, and
/// "Copy as docker run" prints one.
public struct ContainerRecipe: Codable, Equatable, Sendable {
    public struct Port: Codable, Equatable, Sendable {
        public var hostIP: String
        public var host: String
        public var container: String
        public var proto: String

        public init(hostIP: String = "", host: String, container: String, proto: String = "tcp") {
            self.hostIP = hostIP
            self.host = host
            self.container = container
            self.proto = proto
        }
    }

    public struct EnvVar: Codable, Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// A bind (`/host:/path`) or a named volume (`data:/path`).
    public struct Volume: Codable, Equatable, Sendable {
        public var source: String
        public var target: String
        public var readOnly: Bool

        public init(source: String, target: String, readOnly: Bool = false) {
            self.source = source
            self.target = target
            self.readOnly = readOnly
        }

        /// The `source:target[:ro]` bind string of the create request.
        public var bind: String {
            readOnly ? "\(source):\(target):ro" : "\(source):\(target)"
        }
    }

    public struct Label: Codable, Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var image = ""
    public var name = ""
    public var command: [String] = []
    /// One executable, as `--entrypoint` takes it.
    public var entrypoint = ""
    public var ports: [Port] = []
    public var env: [EnvVar] = []
    /// `--env-file` paths. Gantry does not read them; they are kept so that
    /// the user sees them and a copied command keeps them.
    public var envFiles: [String] = []
    public var volumes: [Volume] = []
    public var labels: [Label] = []
    public var network = ""
    public var restartPolicy = "no"
    /// CPU count as typed, for example `1.5`.
    public var cpus = ""
    /// Memory limit as typed, for example `512m`.
    public var memory = ""
    public var workdir = ""
    public var user = ""
    public var tty = false
    public var interactive = false
    public var autoRemove = false
    public var detach = true
    /// apple/container only.
    public var dnsDomain = ""
    public var kernel = ""
    public var kernelArgs: [String] = []

    public init() {}

    public init(image: String) {
        self.image = image
    }

    // Older or newer recipe files may lack keys; every key has a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        image = try value(.image, "")
        name = try value(.name, "")
        command = try value(.command, [])
        entrypoint = try value(.entrypoint, "")
        ports = try value(.ports, [])
        env = try value(.env, [])
        envFiles = try value(.envFiles, [])
        volumes = try value(.volumes, [])
        labels = try value(.labels, [])
        network = try value(.network, "")
        restartPolicy = try value(.restartPolicy, "no")
        cpus = try value(.cpus, "")
        memory = try value(.memory, "")
        workdir = try value(.workdir, "")
        user = try value(.user, "")
        tty = try value(.tty, false)
        interactive = try value(.interactive, false)
        autoRemove = try value(.autoRemove, false)
        detach = try value(.detach, true)
        dnsDomain = try value(.dnsDomain, "")
        kernel = try value(.kernel, "")
        kernelArgs = try value(.kernelArgs, [])
    }

    enum CodingKeys: String, CodingKey {
        case image, name, command, entrypoint, ports, env, envFiles, volumes, labels
        case network, restartPolicy, cpus, memory, workdir, user
        case tty, interactive, autoRemove, detach, dnsDomain, kernel, kernelArgs
    }

    /// Restart policy names Docker accepts.
    public static let restartPolicies = ["no", "on-failure", "always", "unless-stopped"]

    // MARK: - Limits

    /// Bytes for a Docker memory value: a number with an optional `b`, `k`,
    /// `m`, `g` or `t` unit (an extra `b`, as in `mb`, is allowed). Nil when
    /// the text is not such a value or is zero.
    public static func memoryBytes(_ text: String) -> Int64? {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        if value.count > 1, value.hasSuffix("b"),
           let unit = value.dropLast().last, "kmgt".contains(unit) {
            value.removeLast()
        }
        var multiplier: Double = 1
        if let unit = value.last, unit.isLetter {
            switch unit {
            case "b": multiplier = 1
            case "k": multiplier = 1024
            case "m": multiplier = 1024 * 1024
            case "g": multiplier = 1024 * 1024 * 1024
            case "t": multiplier = 1024 * 1024 * 1024 * 1024
            default: return nil
            }
            value.removeLast()
        }
        guard let number = Double(value), number > 0, number.isFinite else { return nil }
        let bytes = number * multiplier
        guard bytes >= 1, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    /// Docker's `NanoCpus` for a CPU count such as `1.5`. Nil when invalid.
    public static func nanoCPUs(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard let number = Double(value), number > 0, number.isFinite, number < 1_000_000 else { return nil }
        return Int64((number * 1_000_000_000).rounded())
    }

    /// The short text for a byte count: `512m`, `2g`, or plain bytes.
    public static func memoryText(bytes: Int64) -> String {
        let mib: Int64 = 1024 * 1024
        let gib = mib * 1024
        if bytes % gib == 0 { return "\(bytes / gib)g" }
        if bytes % mib == 0 { return "\(bytes / mib)m" }
        if bytes % 1024 == 0 { return "\(bytes / 1024)k" }
        return "\(bytes)"
    }

    /// The CPU count text for a `NanoCpus` value: `2`, `1.5`.
    public static func cpusText(nanoCPUs: Int64) -> String {
        let value = Double(nanoCPUs) / 1_000_000_000
        if value == value.rounded() { return String(Int64(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// The inline problem with the memory field, or nil.
    public var memoryIssue: String? {
        guard !memory.trimmingCharacters(in: .whitespaces).isEmpty, Self.memoryBytes(memory) == nil else { return nil }
        return String(localized: "Enter a memory size, for example 512m or 2g.", bundle: .module)
    }

    /// The inline problem with the CPUs field, or nil.
    public var cpusIssue: String? {
        guard !cpus.trimmingCharacters(in: .whitespaces).isEmpty, Self.nanoCPUs(cpus) == nil else { return nil }
        return String(localized: "Enter a number of CPUs, for example 2 or 1.5.", bundle: .module)
    }

    // MARK: - Network

    /// Docker network modes that are not a named network.
    static let dockerNetworkModes: Set<String> = ["host", "none"]

    /// Network names that mean "the default network".
    static func isDefaultNetwork(_ name: String) -> Bool {
        ["", "default", "bridge"].contains(name)
    }
}
