import Foundation
import MCP
import AppCore

/// apple/container system management: versions and status, the image
/// builder, registry logins (list and log out only; no tool takes a
/// password), the default kernel, service logs and system properties.
extension GantryTools {
    func appleSystemTools() -> [Tool] {
        let appleHostID = Schema.string("Gantry host id of an apple/container host (from list_hosts).")
        let hostOnly = Schema.object(properties: ["host_id": appleHostID], required: ["host_id"])
        return [
            Tool(
                name: "apple_system_info",
                description: "Report apple/container client and API server versions, service status, host facts, paths, resource counts and whether a default kernel is installed.",
                inputSchema: hostOnly,
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_builder_status",
                description: "Report the apple/container image builder container (state, image, CPUs, memory). Returns null when no builder exists.",
                inputSchema: hostOnly,
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_builder_start",
                description: "Start the apple/container image builder (creating it if needed). CPUs and memory apply when the builder is created or restarted.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "cpus": Schema.integer("Number of CPUs (optional; default from build.cpus)."),
                    "memory": Schema.string("Memory with a K, M, G, T or P suffix, e.g. 4g (optional; default from build.memory).")
                ], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)
            ),
            Tool(
                name: "apple_builder_stop",
                description: "Stop the apple/container image builder. Running builds fail.",
                inputSchema: hostOnly,
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_builder_delete",
                description: "Delete the apple/container image builder container and its build cache (force-deletes a running builder).",
                inputSchema: hostOnly,
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_list_registries",
                description: "List the registries apple/container holds logins for (host name and user name; never the password).",
                inputSchema: hostOnly,
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_registry_logout",
                description: "Log apple/container out of a registry (removes its saved credentials). Logging in is only possible in the Gantry app, so that no password passes through an agent.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "registry": Schema.string("Registry host name, e.g. ghcr.io or localhost:5000.")
                ], required: ["host_id", "registry"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_get_properties",
                description: "List apple/container system properties: the value the services use now, the value set in ~/.config/container/config.toml, and whether a restart is pending.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "key": Schema.string("Only this property (e.g. build.cpus) or table (e.g. build) (optional).")
                ], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_set_property",
                description: "Set an apple/container system property in ~/.config/container/config.toml after type validation. Takes effect after apple_service_restart.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "key": Schema.string("Property key, e.g. container.memory or build.rosetta."),
                    "value": Schema.string("New value, e.g. 4g, 8, true. A list (container.dns.nameservers) takes comma-separated items, e.g. 1.1.1.1, 8.8.8.8.")
                ], required: ["host_id", "key", "value"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "apple_clear_property",
                description: "Remove an apple/container system property from ~/.config/container/config.toml so the package default applies after apple_service_restart.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "key": Schema.string("Property key, e.g. container.memory.")
                ], required: ["host_id", "key"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "apple_system_logs",
                description: "Return recent apple/container service logs (API server, runtime, network helpers).",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "last": Schema.string("Period: a number with an optional m, h or d suffix, e.g. 30m (optional; default 5m)."),
                    "filter": Schema.string("Only lines containing this text, case-insensitive (optional)."),
                    "errors_only": Schema.boolean("Only Error and Fault lines (optional)."),
                    "tail": Schema.integer("Maximum number of most recent lines (optional; default 200).")
                ], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_install_recommended_kernel",
                description: "Download and install the recommended Linux kernel as the apple/container default. Needed when containers fail with 'default kernel not found'.",
                inputSchema: hostOnly,
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)
            )
        ]
    }

    func handleAppleSystem(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        switch name {
        case "apple_system_info":                return try await appleSystemInfo(args)
        case "apple_builder_status":             return try await appleBuilderStatus(args)
        case "apple_builder_start":              return try await appleBuilderStart(args)
        case "apple_builder_stop":               return try await appleBuilderSimple(args, delete: false)
        case "apple_builder_delete":             return try await appleBuilderSimple(args, delete: true)
        case "apple_list_registries":            return try await appleListRegistries(args)
        case "apple_registry_logout":            return try await appleRegistryLogout(args)
        case "apple_get_properties":             return try await appleGetProperties(args)
        case "apple_set_property":               return try await appleSetProperty(args)
        case "apple_clear_property":             return try await appleClearProperty(args)
        case "apple_system_logs":                return try await appleSystemLogs(args)
        case "apple_install_recommended_kernel": return try await appleInstallKernel(args)
        default:                                 return nil
        }
    }

    // MARK: - Info

    private func appleSystemInfo(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let status = try await AppleContainerControl.systemStatus(cliOverride: cli)
        let versions = (try? await AppleContainerControl.systemVersions(cliOverride: cli)) ?? []
        let root = status.appRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let kernel = AppleContainerControl.defaultKernel(appRoot: root)
        return .text(try jsonText(AppleSystemInfoDTO(
            status: status,
            versions: versions,
            defaultKernelInstalled: kernel.isInstalled,
            defaultKernelFile: kernel.kernelFile
        )))
    }

    // MARK: - Builder

    private func appleBuilderStatus(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let status = try await AppleContainerControl.builderStatus(cliOverride: cli)
        return .text(try jsonText(status))
    }

    private func appleBuilderStart(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let options = AppleBuilderStartOptions(cpus: args.intOrNil("cpus"), memory: args.string("memory"))
        var lines: [String] = []
        for try await line in try AppleContainerControl.startBuilder(options, cliOverride: cli) {
            lines.append(line)
        }
        let status = try await AppleContainerControl.builderStatus(cliOverride: cli)
        return .text("OK: builder \(status?.state ?? "started").\n" + cap(lines.suffix(20).joined(separator: "\n"), bytes: 4_000))
    }

    private func appleBuilderSimple(_ args: Arguments, delete: Bool) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        if delete {
            try await AppleContainerControl.deleteBuilder(force: true, cliOverride: cli)
            return .text("OK: builder deleted.")
        }
        try await AppleContainerControl.stopBuilder(cliOverride: cli)
        return .text("OK: builder stopped.")
    }

    // MARK: - Registries

    private func appleListRegistries(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let logins = try await AppleContainerControl.listRegistryLogins(cliOverride: cli)
        return .text(try jsonText(logins))
    }

    private func appleRegistryLogout(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let registry = try args.requiredString("registry")
        try await AppleContainerControl.logoutRegistry(registry, cliOverride: cli)
        return .text("OK: logged out of \(registry).")
    }

    // MARK: - Properties

    private func appleGetProperties(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        var properties = try await AppleContainerControl.listProperties(cliOverride: cli)
        if let key = args.string("key"), !key.isEmpty {
            properties = properties.filter { $0.key == key || $0.section == key }
            guard !properties.isEmpty else { throw ToolError("No system property or table named '\(key)'.") }
        }
        return .text(try jsonText(properties.map(AppleSystemPropertyDTO.init)))
    }

    private func appleSetProperty(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let key = try args.requiredString("key")
        let raw = try args.requiredString("value")
        let properties = try await AppleContainerControl.listProperties(cliOverride: cli)
        let kind = try Self.editablePropertyKind(key, in: properties, clearing: false)
        let value = try AppleContainerControl.setUserProperty(key, to: raw, kind: kind)
        return .text("OK: \(key) = \(value.tomlLiteral) in config.toml. Run apple_service_restart to apply it.")
    }

    private func appleClearProperty(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let key = try args.requiredString("key")
        let properties = try await AppleContainerControl.listProperties(cliOverride: cli)
        _ = try Self.editablePropertyKind(key, in: properties, clearing: true)
        try AppleContainerControl.clearUserProperty(key)
        return .text("OK: removed \(key) from config.toml. Run apple_service_restart to apply the default.")
    }

    /// The type to validate a new value with. Only keys from the schema or
    /// the effective list are accepted, and array or table values are not
    /// overwritten (the System pane does not edit them either).
    static func editablePropertyKind(
        _ key: String,
        in properties: [AppleSystemProperty],
        clearing: Bool
    ) throws -> AppleSystemPropertyKind {
        guard AppleContainerControl.isValidPropertyKey(key) else {
            throw ToolError("'\(key)' is not a valid property key. Use a dotted name such as build.cpus.")
        }
        guard let property = properties.first(where: { $0.key == key }) else {
            throw ToolError("Unknown system property '\(key)'. Call apple_get_properties for the keys.")
        }
        if clearing { return property.kind }
        for value in [property.effective, property.user].compactMap({ $0 }) {
            if case .other = value {
                throw ToolError("\(key) holds an array or a table. Edit ~/.config/container/config.toml by hand.")
            }
        }
        guard property.kind == .unknown else { return property.kind }
        // A key without a schema keeps the type the services report.
        switch property.effective ?? property.user {
        case .strings?: return .stringList
        case .bool?: return .bool
        case .integer?: return .integerValue
        case .number?: return .numberValue
        default: return .string
        }
    }

    // MARK: - Logs and kernel

    private func appleSystemLogs(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let raw = try await AppleContainerControl.systemLogs(last: args.string("last"), cliOverride: cli)
        let lines = Self.filterSystemLogs(
            raw,
            filter: args.string("filter"),
            errorsOnly: args.bool("errors_only", default: false),
            tail: args.intOrNil("tail") ?? 200
        )
        return .text(lines.isEmpty ? "No log lines." : cap(lines.joined(separator: "\n"), bytes: 60_000))
    }

    static func filterSystemLogs(_ raw: [String], filter: String?, errorsOnly: Bool, tail: Int) -> [String] {
        let needle = filter?.trimmingCharacters(in: .whitespaces) ?? ""
        let kept = raw.filter { text in
            let line = AppleSystemLogLine(raw: text)
            if line.isHeader { return false }
            if errorsOnly, line.level != .error { return false }
            if !needle.isEmpty, text.range(of: needle, options: .caseInsensitive) == nil { return false }
            return true
        }
        return Array(kept.suffix(max(1, tail)))
    }

    private func appleInstallKernel(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        var lines: [String] = []
        for try await line in try AppleContainerControl.installKernel(.recommended, cliOverride: cli) {
            lines.append(line)
        }
        return .text("OK: recommended kernel installed.\n" + cap(lines.suffix(10).joined(separator: "\n"), bytes: 2_000))
    }
}

struct AppleSystemInfoDTO: Encodable {
    let status: AppleSystemStatus
    let versions: [AppleComponentVersion]
    let defaultKernelInstalled: Bool
    let defaultKernelFile: String?
}

struct AppleSystemPropertyDTO: Encodable, Equatable {
    let key: String
    let kind: String
    let value: String?
    let userValue: String?
    let pendingRestart: Bool

    init(_ property: AppleSystemProperty) {
        key = property.key
        kind = property.kind.rawValue
        value = property.effective?.display
        userValue = property.user?.display
        pendingRestart = property.isPendingRestart
    }
}
