import Foundation
import MCP
import DockerKit
import AppCore

/// System maintenance plus apple/container-specific tools: machines, the
/// `container` background services, and local DNS domains. The apple tools are
/// driven through `AppleContainerControl` (the `container` CLI), so they require
/// a host of kind apple-container.
extension GantryTools {
    func systemAppleTools() -> [Tool] {
        let hostIDRequired = Schema.string("Gantry host id (UUID, from list_hosts).")
        let appleHostID = Schema.string("Gantry host id of an apple/container host (from list_hosts).")
        let machineName = Schema.string("Machine name.")
        return [
            Tool(
                name: "prune_build_cache",
                description: "Clear the build cache on a host.",
                inputSchema: Schema.object(properties: ["host_id": hostIDRequired], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            // Machines
            Tool(
                name: "list_machines",
                description: "List apple/container Linux VMs (machines) on an apple/container host.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_machine",
                description: "Create and boot an apple/container machine.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "name": machineName,
                    "image": Schema.string("Machine image reference (optional; CLI default if omitted)."),
                    "cpus": Schema.integer("Number of CPUs (optional)."),
                    "memory": Schema.string("Memory, e.g. 4g (optional)."),
                    "nested_virtualization": Schema.boolean(
                        "Enable nested virtualization (optional; apple/container 1.1+, Apple silicon M3+ on macOS 15+, needs a kernel with CONFIG_KVM=y)."
                    ),
                    "kernel": Schema.string("Path to a custom kernel binary (optional; apple/container 1.1+).")
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "start_machine",
                description: "Start a stopped apple/container machine.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID, "name": machineName], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "stop_machine",
                description: "Stop a running apple/container machine.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID, "name": machineName], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "delete_machine",
                description: "Delete an apple/container machine.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID, "name": machineName], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "set_default_machine",
                description: "Set the default apple/container machine.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID, "name": machineName], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "set_machine_resources",
                description: "Set boot settings for a machine — CPU, memory, home mount, nested virtualization, custom kernel (restarts a running machine to take effect).",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID, "name": machineName,
                    "cpus": Schema.integer("Number of CPUs (optional)."),
                    "memory": Schema.string("Memory, e.g. 8g (optional)."),
                    "home_mount": Schema.string("Home directory mount mode: ro, rw or none (optional)."),
                    "nested_virtualization": Schema.boolean(
                        "Enable nested virtualization (optional; apple/container 1.1+, Apple silicon M3+ on macOS 15+, needs a kernel with CONFIG_KVM=y)."
                    ),
                    "kernel": Schema.string("Path to a custom kernel binary, or an empty string to reset to the system default (optional; apple/container 1.1+).")
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "inspect_machine",
                description: "Return the raw JSON inspect of an apple/container machine.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID, "name": machineName], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            // Services
            Tool(
                name: "apple_service_status",
                description: "Report whether the apple/container background services are running.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_service_start",
                description: "Start the apple/container background services.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "apple_service_stop",
                description: "Stop the apple/container background services.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apple_service_restart",
                description: "Restart the apple/container background services.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            // DNS domains
            Tool(
                name: "list_dns_domains",
                description: "List the local apple/container DNS domains.",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_dns_domain",
                description: "Create a local apple/container DNS domain (may require admin).",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID, "domain": Schema.string("Domain name, e.g. test.")
                ], required: ["host_id", "domain"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "delete_dns_domain",
                description: "Delete a local apple/container DNS domain (may require admin).",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID, "domain": Schema.string("Domain name.")
                ], required: ["host_id", "domain"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "set_default_dns_domain",
                description: "Set the default apple/container DNS domain for new containers.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID, "domain": Schema.string("Domain name.")
                ], required: ["host_id", "domain"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            )
        ]
    }

    func handleSystemApple(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        switch name {
        case "prune_build_cache":     return try await pruneBuildCache(args)
        case "list_machines":         return try await listMachines(args)
        case "create_machine":        return try await createMachine(args)
        case "start_machine":         return try await machineSimple(args, op: "start")
        case "stop_machine":          return try await machineSimple(args, op: "stop")
        case "delete_machine":        return try await machineSimple(args, op: "delete")
        case "set_default_machine":   return try await machineSimple(args, op: "default")
        case "set_machine_resources": return try await setMachineResources(args)
        case "inspect_machine":       return try await inspectMachine(args)
        case "apple_service_status":  return try await appleService(args, op: "status")
        case "apple_service_start":   return try await appleService(args, op: "start")
        case "apple_service_stop":    return try await appleService(args, op: "stop")
        case "apple_service_restart": return try await appleService(args, op: "restart")
        case "list_dns_domains":      return try await listDNSDomains(args)
        case "create_dns_domain":     return try await dnsDomain(args, op: "create")
        case "delete_dns_domain":     return try await dnsDomain(args, op: "delete")
        case "set_default_dns_domain":return try await setDefaultDNSDomain(args)
        default:                      return nil
        }
    }

    // MARK: - System

    private func pruneBuildCache(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let client = try await docker.connect(to: host)
        let result = try await client.pruneBuildCache()
        return .text(pruneText(result, noun: "build cache entries"))
    }

    // MARK: - Apple host resolution

    /// The CLI override for an apple/container host, throwing if the host isn't apple.
    private func appleCLIOverride(_ args: Arguments) throws -> String? {
        let host = try requiredHost(args)
        guard host.isAppleContainer else {
            throw ToolError("\(host.name) is not an apple/container host.")
        }
        return host.socketPathOverride
    }

    // MARK: - Machines

    private func listMachines(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let machines = try await AppleContainerControl.listMachines(cliOverride: cli)
        return .text(try jsonText(machines.map(MachineDTO.init)))
    }

    private func createMachine(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let name = try args.requiredString("name")
        try await AppleContainerControl.createMachine(
            image: args.string("image") ?? "",
            name: name,
            cpus: args.intOrNil("cpus"),
            memory: args.string("memory"),
            nestedVirtualization: args.bool("nested_virtualization", default: false),
            kernelPath: args.string("kernel"),
            cliOverride: cli
        )
        return .text("OK: created machine \(name).")
    }

    private func machineSimple(_ args: Arguments, op: String) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let name = try args.requiredString("name")
        switch op {
        case "start":   try await AppleContainerControl.startMachine(name, cliOverride: cli)
        case "stop":    try await AppleContainerControl.stopMachine(name, cliOverride: cli)
        case "delete":  try await AppleContainerControl.deleteMachine(name, cliOverride: cli)
        case "default": try await AppleContainerControl.setDefaultMachine(name, cliOverride: cli)
        default: throw ToolError("Unknown machine op.")
        }
        return .text("OK: \(op) machine \(name).")
    }

    private func setMachineResources(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let name = try args.requiredString("name")
        // `container machine set` only understands `key=value` arguments — a
        // flag form like `--cpus 4` is rejected as an invalid setting.
        let settings = AppleContainerControl.MachineSettings(
            cpus: args.intOrNil("cpus"),
            memory: args.string("memory"),
            homeMount: args.string("home_mount"),
            nestedVirtualization: args.boolOrNil("nested_virtualization"),
            kernelPath: args.string("kernel")
        )
        guard !settings.isEmpty else {
            throw ToolError("Provide at least one of cpus, memory, home_mount, nested_virtualization or kernel.")
        }
        try await AppleContainerControl.setMachine(name, settings: settings, cliOverride: cli)
        return .text("OK: updated machine \(name) with \(settings.arguments.joined(separator: " ")). Restart it for the change to take effect.")
    }

    private func inspectMachine(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let name = try args.requiredString("name")
        let json = try await AppleContainerControl.rawInspectMachine(name, cliOverride: cli)
        return .text(json)
    }

    // MARK: - Services

    private func appleService(_ args: Arguments, op: String) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        switch op {
        case "status":
            let status = await AppleContainerControl.serviceStatus(cliOverride: cli)
            return .text("apple/container services: \(status)")
        case "start":   try await AppleContainerControl.startServices(cliOverride: cli); return .text("OK: services started.")
        case "stop":    try await AppleContainerControl.stopServices(cliOverride: cli); return .text("OK: services stopped.")
        case "restart": try await AppleContainerControl.restartServices(cliOverride: cli); return .text("OK: services restarted.")
        default: throw ToolError("Unknown service op.")
        }
    }

    // MARK: - DNS domains

    private func listDNSDomains(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let domains = try await AppleContainerControl.listDomains(cliOverride: cli)
        return .text(try jsonText(domains))
    }

    private func dnsDomain(_ args: Arguments, op: String) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let domain = try args.requiredString("domain")
        if op == "create" {
            try await AppleContainerControl.createDomain(domain, cliOverride: cli)
            return .text("OK: created domain \(domain).")
        } else {
            try await AppleContainerControl.deleteDomain(domain, cliOverride: cli)
            return .text("OK: deleted domain \(domain).")
        }
    }

    private func setDefaultDNSDomain(_ args: Arguments) async throws -> CallTool.Result {
        _ = try appleCLIOverride(args)
        let domain = try args.requiredString("domain")
        try AppleContainerControl.setDefaultDNSDomain(domain)
        return .text("OK: default DNS domain set to \(domain).")
    }
}
