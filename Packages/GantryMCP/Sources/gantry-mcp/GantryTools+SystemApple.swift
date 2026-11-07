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
            // Kubernetes clusters
            Tool(
                name: "list_clusters",
                description: "List local Kubernetes clusters and their nodes on an apple/container host (container cluster, CLI 1.5+).",
                inputSchema: Schema.object(properties: ["host_id": appleHostID], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_cluster",
                description: "Create and start a local Kubernetes cluster on an apple/container host. Pulls the kindest/node image and can take several minutes. The CLI merges the cluster context into the kubeconfig.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "name": Schema.string("Cluster name. It is also the kubectl context name."),
                    "workers": Schema.integer("Number of worker nodes (optional; default 0; CLI 1.6+)."),
                    "cpus": Schema.integer("CPUs per node (optional). On CLI 1.7+ with workers, CPUs of the control plane."),
                    "memory": Schema.string("Memory per node, e.g. 4G (optional). On CLI 1.7+ with workers, memory of the control plane."),
                    "worker_cpus": Schema.integer("CPUs per worker node (optional; CLI 1.7+)."),
                    "worker_memory": Schema.string("Memory per worker node, e.g. 4G (optional; CLI 1.7+)."),
                    "shared_image_store": Schema.boolean(
                        "Let the nodes pull images from the local image store, so locally built images run without a registry (optional; CLI 1.7+)."
                    ),
                    "node_image": Schema.string("Node image reference (optional; CLI default kindest/node)."),
                    "cni": Schema.string(
                        "CNI to install: 'default' (kindnet), 'none' (CLI 1.6+), or the path of a CNI manifest file (optional)."
                    ),
                    "remove_on_stop": Schema.boolean("Remove the node containers when they stop (optional)."),
                    "kubeconfig": Schema.string("Kubeconfig file to merge the context into (optional; default ~/.kube/config).")
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)
            ),
            Tool(
                name: "delete_cluster",
                description: "Delete a local Kubernetes cluster and its nodes, and remove its context from the kubeconfig.",
                inputSchema: Schema.object(properties: [
                    "host_id": appleHostID,
                    "name": Schema.string("Cluster name."),
                    "kubeconfig": Schema.string("Kubeconfig file to remove the context from (optional; default: the file the cluster was created with, else ~/.kube/config).")
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
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
        ] + appleSystemTools()
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
        case "list_clusters":         return try await listClusters(args)
        case "create_cluster":        return try await createCluster(args)
        case "delete_cluster":        return try await deleteCluster(args)
        case "apple_service_status":  return try await appleService(args, op: "status")
        case "apple_service_start":   return try await appleService(args, op: "start")
        case "apple_service_stop":    return try await appleService(args, op: "stop")
        case "apple_service_restart": return try await appleService(args, op: "restart")
        case "list_dns_domains":      return try await listDNSDomains(args)
        case "create_dns_domain":     return try await dnsDomain(args, op: "create")
        case "delete_dns_domain":     return try await dnsDomain(args, op: "delete")
        case "set_default_dns_domain":return try await setDefaultDNSDomain(args)
        default:                      return try await handleAppleSystem(name, args)
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
    func appleCLIOverride(_ args: Arguments) throws -> String? {
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

    // MARK: - Kubernetes clusters

    /// The cluster subcommand of the installed CLI and its feature gates.
    private func clusterFeatures(cliOverride: String?) async throws -> (command: String, features: ContainerTooling.Features) {
        let features = await ContainerTooling.currentFeatures(cliOverride: cliOverride)
        guard let command = features.clusterCommand else {
            throw ToolError("Kubernetes clusters need apple/container CLI \(ContainerTooling.clustersVersion) or later.")
        }
        return (command, features)
    }

    private func listClusters(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let (command, _) = try await clusterFeatures(cliOverride: cli)
        let clusters = try await AppleContainerControl.listClusters(command: command, cliOverride: cli)
        return .text(try jsonText(clusters.map(ClusterDTO.init)))
    }

    private func createCluster(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let (command, features) = try await clusterFeatures(cliOverride: cli)
        let options = try clusterCreateOptions(args, features: features)
        let hostID = try requiredHost(args).id.uuidString
        let existing = try await AppleContainerControl.listClusters(command: command, cliOverride: cli)
        guard !existing.contains(where: { $0.name == options.name }) else {
            throw ToolError("A cluster named '\(options.name)' already exists.")
        }
        ClusterKubeconfigStore.record(options.kubeconfigPath, host: hostID, cluster: options.name)
        try await AppleContainerControl.createCluster(options, command: command, cliOverride: cli)
        let config = options.kubeconfigPath ?? "~/.kube/config"
        return .text("OK: created cluster \(options.name). kubectl context \(options.name) is in \(config).")
    }

    private func deleteCluster(_ args: Arguments) async throws -> CallTool.Result {
        let cli = try appleCLIOverride(args)
        let (command, _) = try await clusterFeatures(cliOverride: cli)
        let name = try args.requiredString("name")
        let hostID = try requiredHost(args).id.uuidString
        // Without an explicit kubeconfig, use the one the cluster was created with.
        let kubeconfig = args.string("kubeconfig") ?? ClusterKubeconfigStore.path(host: hostID, cluster: name)
        try await AppleContainerControl.deleteCluster(
            name, kubeconfigPath: kubeconfig, command: command, cliOverride: cli
        )
        ClusterKubeconfigStore.record(nil, host: hostID, cluster: name)
        return .text("OK: deleted cluster \(name).")
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

/// Maps `create_cluster` arguments to CLI options and rejects options that
/// the installed CLI does not have.
func clusterCreateOptions(
    _ args: Arguments,
    features: ContainerTooling.Features
) throws -> AppleContainerControl.ClusterCreateOptions {
    let name = try args.requiredString("name")
    let workers = args.intOrNil("workers")
    if let workers, workers < 0 { throw ToolError("'workers' must be 0 or more.") }
    let cni: AppleContainerControl.ClusterCNI
    switch args.string("cni")?.trimmingCharacters(in: .whitespaces) {
    case nil, "", "default": cni = .standard
    case let value? where value.lowercased() == "none": cni = .none
    case let path?: cni = .manifest(path)
    }
    if !features.clusterWorkers {
        if (workers ?? 0) > 0 {
            throw ToolError("Worker nodes need apple/container CLI \(ContainerTooling.clusterWorkersVersion) or later.")
        }
        if cni == .none {
            throw ToolError("cni 'none' needs apple/container CLI \(ContainerTooling.clusterWorkersVersion) or later.")
        }
    }
    let workerCPUs = args.intOrNil("worker_cpus")
    let workerMemory = args.string("worker_memory")
    let sharedImageStore = args.bool("shared_image_store", default: false)
    if !features.clusterService {
        if workerCPUs != nil || workerMemory != nil {
            throw ToolError("worker_cpus and worker_memory need apple/container CLI \(ContainerTooling.clusterServiceVersion) or later.")
        }
        if sharedImageStore {
            throw ToolError("shared_image_store needs apple/container CLI \(ContainerTooling.clusterServiceVersion) or later.")
        }
    }
    if workerCPUs != nil || workerMemory != nil, (workers ?? 0) == 0 {
        throw ToolError("worker_cpus and worker_memory need 'workers' of 1 or more.")
    }
    if let workerCPUs, workerCPUs < 1 { throw ToolError("'worker_cpus' must be 1 or more.") }
    return AppleContainerControl.ClusterCreateOptions(
        name: name,
        workers: workers,
        cpus: args.intOrNil("cpus"),
        memory: args.string("memory"),
        workerCPUs: workerCPUs,
        workerMemory: workerMemory,
        sharedImageStore: sharedImageStore,
        nodeImage: args.string("node_image"),
        cni: cni,
        removeOnStop: args.bool("remove_on_stop", default: false),
        kubeconfigPath: args.string("kubeconfig")
    )
}
