import Foundation
import DockerKit

extension AppleBuilderStatus {
    /// True for the apple/container BuildKit builder (`buildkit`). It is system
    /// plumbing that `container builder` owns, so the container list hides it;
    /// the System ▸ Builder pane manages it instead.
    public static func isBuilderContainer(_ container: ContainerSummary) -> Bool {
        if container.labels["com.apple.container.resource.role"] == "builder" { return true }
        if container.labels["com.apple.container.plugin"] == "builder" { return true }
        return container.displayName == "buildkit" && container.image.contains("container-builder-shim")
    }
}

/// The BuildKit builder container (`buildkit`) that `container build` runs in,
/// as `container builder status --format json` reports it.
public struct AppleBuilderStatus: Sendable, Equatable, Codable {
    public var id: String
    public var image: String
    /// `running`, `stopped`, … as the CLI reports it.
    public var state: String
    public var ipAddress: String?
    public var cpus: Int?
    public var memoryBytes: Int64?
    public var rosetta: Bool?
    public var startedDate: String?

    public var isRunning: Bool { state == "running" }

    public init(
        id: String,
        image: String,
        state: String,
        ipAddress: String? = nil,
        cpus: Int? = nil,
        memoryBytes: Int64? = nil,
        rosetta: Bool? = nil,
        startedDate: String? = nil
    ) {
        self.id = id
        self.image = image
        self.state = state
        self.ipAddress = ipAddress
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.rosetta = rosetta
        self.startedDate = startedDate
    }
}

/// Options for `container builder start`. Empty values are left to the CLI
/// (which takes them from the `[build]` system properties).
public struct AppleBuilderStartOptions: Sendable, Equatable {
    public var cpus: Int?
    /// Memory with an optional K, M, G, T or P suffix, e.g. `4g`.
    public var memory: String?
    public var dnsServers: [String]
    public var dnsDomain: String?
    public var dnsSearchDomains: [String]
    public var dnsOptions: [String]

    public init(
        cpus: Int? = nil,
        memory: String? = nil,
        dnsServers: [String] = [],
        dnsDomain: String? = nil,
        dnsSearchDomains: [String] = [],
        dnsOptions: [String] = []
    ) {
        self.cpus = cpus
        self.memory = memory
        self.dnsServers = dnsServers
        self.dnsDomain = dnsDomain
        self.dnsSearchDomains = dnsSearchDomains
        self.dnsOptions = dnsOptions
    }

    /// The `container` arguments, validated. Throws `invalidInput` for a value
    /// the CLI would reject.
    public func arguments() throws -> [String] {
        var arguments = ["builder", "start"]
        if let cpus {
            guard cpus > 0 else { throw AppleSystemError.invalidInput("CPUs must be a positive number.") }
            arguments += ["--cpus", String(cpus)]
        }
        if let memory = AppleContainerControl.nonEmpty(memory?.trimmingCharacters(in: .whitespaces)) {
            guard AppleContainerControl.isValidMemorySize(memory) else {
                throw AppleSystemError.invalidInput("“\(memory)” is not a valid memory size. Use a number with an optional K, M, G, T or P suffix, for example 4g.")
            }
            arguments += ["--memory", memory]
        }
        for server in dnsServers.map(trimmed).filter({ !$0.isEmpty }) {
            guard AppleContainerControl.isValidIPAddress(server) else {
                throw AppleSystemError.invalidInput("“\(server)” is not a valid IP address.")
            }
            arguments += ["--dns", server]
        }
        if let domain = AppleContainerControl.nonEmpty(dnsDomain.map(trimmed)) {
            guard AppleContainerControl.isValidDomainName(domain) else {
                throw AppleSystemError.invalidInput("“\(domain)” is not a valid domain name.")
            }
            arguments += ["--dns-domain", domain]
        }
        for domain in dnsSearchDomains.map(trimmed).filter({ !$0.isEmpty }) {
            guard AppleContainerControl.isValidDomainName(domain) else {
                throw AppleSystemError.invalidInput("“\(domain)” is not a valid domain name.")
            }
            arguments += ["--dns-search", domain]
        }
        for option in dnsOptions.map(trimmed).filter({ !$0.isEmpty }) {
            guard !option.contains(where: \.isWhitespace) else {
                throw AppleSystemError.invalidInput("A DNS option cannot contain spaces: “\(option)”.")
            }
            arguments += ["--dns-option", option]
        }
        return arguments
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
    }
}

extension AppleContainerControl {
    // MARK: - Builder

    /// The builder container, or nil when none exists. Throws
    /// `AppleSystemError.pluginMissing` when the builder plugin is absent.
    public static func builderStatus(cliOverride: String? = nil) async throws -> AppleBuilderStatus? {
        let output = try await runContainer(["builder", "status", "--format", "json"], cliOverride: cliOverride)
        return parseBuilderStatus(output)
    }

    /// Starts (creating if needed) the builder container, yielding progress
    /// lines while the CLI pulls the builder image and boots it.
    public static func startBuilder(
        _ options: AppleBuilderStartOptions = AppleBuilderStartOptions(),
        cliOverride: String? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        streamContainer(try options.arguments(), cliOverride: cliOverride)
    }

    public static func stopBuilder(cliOverride: String? = nil) async throws {
        _ = try await runContainer(["builder", "stop"], cliOverride: cliOverride)
    }

    /// Deletes the builder container. `force` also deletes a running builder.
    public static func deleteBuilder(force: Bool = false, cliOverride: String? = nil) async throws {
        _ = try await runContainer(builderDeleteArguments(force: force), cliOverride: cliOverride)
    }

    static func builderDeleteArguments(force: Bool) -> [String] {
        force ? ["builder", "delete", "--force"] : ["builder", "delete"]
    }

    /// Parses `builder status --format json`: an array with zero or one
    /// container snapshot (`[]` when no builder exists).
    static func parseBuilderStatus(_ json: String) -> AppleBuilderStatus? {
        guard let any = jsonObject(json) else { return nil }
        let object: [String: Any]?
        if let array = any as? [[String: Any]] {
            object = array.first
        } else {
            object = any as? [String: Any]
        }
        guard let object else { return nil }
        let configuration = object["configuration"] as? [String: Any] ?? [:]
        let statusObject = object["status"] as? [String: Any]
        let id = (object["id"] as? String) ?? (configuration["id"] as? String) ?? "buildkit"
        let imageObject = configuration["image"] as? [String: Any]
        let image = (imageObject?["reference"] as? String) ?? (configuration["image"] as? String) ?? ""
        let state = (statusObject?["state"] as? String)
            ?? (object["status"] as? String)
            ?? (object["state"] as? String)
            ?? "unknown"
        let resources = configuration["resources"] as? [String: Any]
        let networks = (statusObject?["networks"] as? [[String: Any]]) ?? (object["networks"] as? [[String: Any]]) ?? []
        let address = networks.lazy.compactMap { $0["ipv4Address"] as? String }.first
        return AppleBuilderStatus(
            id: id,
            image: image,
            state: state,
            ipAddress: address.map { String($0.split(separator: "/").first ?? Substring($0)) },
            cpus: intValue(resources?["cpus"]),
            memoryBytes: intValue(resources?["memoryInBytes"]).map(Int64.init),
            rosetta: configuration["rosetta"] as? Bool,
            startedDate: statusObject?["startedDate"] as? String
        )
    }

    // MARK: - Value validation

    /// A memory size as apple/container parses it: a number with an optional
    /// binary unit (`b`, `k`/`kb`/`kib` … `p`/`pb`/`pib`), case-insensitive.
    public static func isValidMemorySize(_ value: String) -> Bool {
        value.wholeMatch(of: /(?i)\d+(b|[kmgtp](i?b)?)?/) != nil
    }

    /// An IPv4 or IPv6 address.
    public static func isValidIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }

    /// A DNS name: labels of letters, digits and inner hyphens, split by dots.
    public static func isValidDomainName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        return value.wholeMatch(of: /[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*/) != nil
    }
}
