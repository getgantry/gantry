import Foundation
import MCP
import DockerKit
import AppCore

/// The tool catalog and dispatch for the Gantry MCP server. Owns the
/// `HeadlessDocker` connection cache for the process lifetime.
actor GantryTools {
    private let docker = HeadlessDocker()

    // MARK: - Tool catalog

    func toolDefinitions() -> [Tool] {
        let hostIDProp = Schema.string("Gantry host id (UUID, from list_hosts). Omit to target all hosts.")
        let hostIDRequired = Schema.string("Gantry host id (UUID, from list_hosts).")
        let containerProp = Schema.string("Container id or name.")

        return [
            Tool(
                name: "list_hosts",
                description: "List the Docker hosts Gantry knows about (local daemon and trusted SSH remotes), with a connectivity hint per host.",
                inputSchema: Schema.object(properties: [:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_containers",
                description: "List containers across one or all hosts. Defaults to all hosts and all containers (running and stopped).",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDProp,
                    "all": Schema.boolean("Include stopped containers (default true).")
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_action",
                description: "Perform a lifecycle action on a container: start, stop, restart, kill, pause, unpause, or remove.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "container_id": containerProp,
                    "action": Schema.string(
                        "Action to perform.",
                        enumValues: ["start", "stop", "restart", "kill", "pause", "unpause", "remove"]
                    )
                ], required: ["host_id", "container_id", "action"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_logs",
                description: "Fetch recent container logs (non-following). Returns up to 100KB of text.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "container_id": containerProp,
                    "tail": Schema.integer("Number of trailing lines to return (default 100).")
                ], required: ["host_id", "container_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_stats",
                description: "Read a single resource-usage sample for a container: CPU %, memory used/limit, network IO, pids.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "container_id": containerProp
                ], required: ["host_id", "container_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_exec",
                description: "Run a shell command inside a container via /bin/sh -c. Returns stdout, stderr, and the exit code. Capped at 30 seconds and 200KB of output.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "container_id": containerProp,
                    "command": Schema.string("Shell command to run (passed to /bin/sh -c).")
                ], required: ["host_id", "container_id", "command"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_images",
                description: "List images on one or all hosts.",
                inputSchema: Schema.object(properties: ["host_id": hostIDProp]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_volumes",
                description: "List volumes on one or all hosts.",
                inputSchema: Schema.object(properties: ["host_id": hostIDProp]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_networks",
                description: "List networks on one or all hosts.",
                inputSchema: Schema.object(properties: ["host_id": hostIDProp]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "system_df",
                description: "Report Docker disk usage (images, containers, volumes, build cache) for a host.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired
                ], required: ["host_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            )
        ]
    }

    // MARK: - Dispatch

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = Arguments(arguments)
        do {
            switch name {
            case "list_hosts":      return try await listHosts()
            case "list_containers": return try await listContainers(args)
            case "container_action": return try await containerAction(args)
            case "container_logs":  return try await containerLogs(args)
            case "container_stats": return try await containerStats(args)
            case "container_exec":  return try await containerExec(args)
            case "list_images":     return try await listImages(args)
            case "list_volumes":    return try await listVolumes(args)
            case "list_networks":   return try await listNetworks(args)
            case "system_df":       return try await systemDF(args)
            default:
                return .failure("Unknown tool '\(name)'.")
            }
        } catch let error as LocalizedError {
            return .failure(error.errorDescription ?? "\(error)")
        } catch {
            return .failure("\(error)")
        }
    }

    func shutdown() async {
        await docker.shutdown()
    }

    // MARK: - Host resolution

    /// Resolves the target hosts: a single host if `host_id` was given, else all.
    private func targetHosts(_ args: Arguments) throws -> [DockerHost] {
        let all = docker.loadHosts()
        if let id = try args.uuid("host_id") {
            guard let host = all.first(where: { $0.id == id }) else {
                throw ToolError("No host with id \(id.uuidString). Call list_hosts first.")
            }
            return [host]
        }
        return all
    }

    private func requiredHost(_ args: Arguments) throws -> DockerHost {
        let id = try args.uuid("host_id")
        let all = docker.loadHosts()
        guard let id else {
            throw ToolError("Missing required 'host_id'. Call list_hosts first.")
        }
        guard let host = all.first(where: { $0.id == id }) else {
            throw ToolError("No host with id \(id.uuidString). Call list_hosts first.")
        }
        return host
    }

    // MARK: - Tools

    private func listHosts() async throws -> CallTool.Result {
        let hosts = docker.loadHosts().map(HostDTO.init)
        return .text(try jsonText(hosts))
    }

    private func listContainers(_ args: Arguments) async throws -> CallTool.Result {
        let all = args.bool("all", default: true)
        let hosts = try targetHosts(args)
        var results: [ContainerListDTO] = []
        for host in hosts {
            do {
                let client = try await docker.connect(to: host)
                let containers = try await client.listContainers(all: all)
                results.append(ContainerListDTO(
                    hostID: host.id.uuidString,
                    hostName: host.name,
                    containers: containers.map(ContainerDTO.init),
                    error: nil
                ))
            } catch {
                results.append(ContainerListDTO(
                    hostID: host.id.uuidString,
                    hostName: host.name,
                    containers: [],
                    error: readable(error)
                ))
            }
        }
        return .text(try jsonText(results))
    }

    private func containerAction(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let containerID = try args.requiredString("container_id")
        let actionName = try args.requiredString("action")
        let client = try await docker.connect(to: host)

        switch actionName.lowercased() {
        case "start":   try await client.startContainer(id: containerID)
        case "stop":    try await client.stopContainer(id: containerID, timeout: nil)
        case "restart": try await client.restartContainer(id: containerID, timeout: nil)
        case "kill":    try await client.killContainer(id: containerID, signal: nil)
        case "pause":   try await client.pauseContainer(id: containerID)
        case "unpause": try await client.unpauseContainer(id: containerID)
        case "remove":  try await client.removeContainer(id: containerID, force: false, removeVolumes: false)
        default:
            throw ToolError("Unknown action '\(actionName)'. Use one of: start, stop, restart, kill, pause, unpause, remove.")
        }
        return .text("OK: \(actionName) on \(containerID) (host \(host.name)).")
    }

    private func containerLogs(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let containerID = try args.requiredString("container_id")
        let tail = args.int("tail", default: 100)
        let client = try await docker.connect(to: host)

        // Inspect to learn TTY framing, then pull a bounded, non-following tail.
        let details = try await client.inspectContainer(id: containerID)
        let stream = try await client.containerLogs(
            id: containerID,
            tty: details.config.tty,
            follow: false,
            tail: tail,
            timestamps: false,
            since: nil
        )

        var lines: [String] = []
        for try await entry in stream {
            let prefix = entry.stream == .stderr ? "[stderr] " : ""
            lines.append(prefix + entry.text)
        }
        let text = lines.isEmpty ? "(no log output)" : lines.joined(separator: "\n")
        return .text(cap(text, bytes: 100 * 1024))
    }

    private func containerStats(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let containerID = try args.requiredString("container_id")
        let client = try await docker.connect(to: host)

        let stream = try await client.containerStats(id: containerID)
        var sample: ContainerStatsSample?
        for try await s in stream {
            sample = s
            break
        }
        guard let sample else {
            throw ToolError("No stats sample available for \(containerID) (is it running?).")
        }
        return .text(try jsonText(StatsDTO(containerID: containerID, sample)))
    }

    private func containerExec(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let containerID = try args.requiredString("container_id")
        let command = try args.requiredString("command")
        let client = try await docker.connect(to: host)

        let result = try await ExecRunner.run(
            client: client,
            containerID: containerID,
            command: command
        )
        return .text(try jsonText(result))
    }

    private func listImages(_ args: Arguments) async throws -> CallTool.Result {
        let hosts = try targetHosts(args)
        var results: [ImageListDTO] = []
        for host in hosts {
            do {
                let client = try await docker.connect(to: host)
                let images = try await client.listImages()
                results.append(ImageListDTO(
                    hostID: host.id.uuidString, hostName: host.name,
                    images: images.map(ImageDTO.init), error: nil
                ))
            } catch {
                results.append(ImageListDTO(
                    hostID: host.id.uuidString, hostName: host.name,
                    images: [], error: readable(error)
                ))
            }
        }
        return .text(try jsonText(results))
    }

    private func listVolumes(_ args: Arguments) async throws -> CallTool.Result {
        let hosts = try targetHosts(args)
        var results: [VolumeListDTO] = []
        for host in hosts {
            do {
                let client = try await docker.connect(to: host)
                let volumes = try await client.listVolumes()
                results.append(VolumeListDTO(
                    hostID: host.id.uuidString, hostName: host.name,
                    volumes: volumes.map(VolumeDTO.init), error: nil
                ))
            } catch {
                results.append(VolumeListDTO(
                    hostID: host.id.uuidString, hostName: host.name,
                    volumes: [], error: readable(error)
                ))
            }
        }
        return .text(try jsonText(results))
    }

    private func listNetworks(_ args: Arguments) async throws -> CallTool.Result {
        let hosts = try targetHosts(args)
        var results: [NetworkListDTO] = []
        for host in hosts {
            do {
                let client = try await docker.connect(to: host)
                let networks = try await client.listNetworks()
                results.append(NetworkListDTO(
                    hostID: host.id.uuidString, hostName: host.name,
                    networks: networks.map(NetworkDTO.init), error: nil
                ))
            } catch {
                results.append(NetworkListDTO(
                    hostID: host.id.uuidString, hostName: host.name,
                    networks: [], error: readable(error)
                ))
            }
        }
        return .text(try jsonText(results))
    }

    private func systemDF(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let client = try await docker.connect(to: host)
        let df = try await client.systemDiskUsage()
        return .text(try jsonText(DiskUsageDTO(hostID: host.id.uuidString, hostName: host.name, df)))
    }

    // MARK: - Helpers

    private func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
