import Foundation
import MCP
import DockerKit
import AppCore

/// Session-bound tools backed by a live `HostSession` held for the server's
/// lifetime: Compose up, Cloudflare tunnels and SSH port forwards. Tunnels and
/// forwards stay up only as long as this MCP server process runs.
extension GantryTools {
    func sessionTools() -> [Tool] {
        let hostIDRequired = Schema.string("Gantry host id (UUID, from list_hosts).")
        return [
            Tool(
                name: "compose_up",
                description: "Bring a Docker Compose project up on a host from a local compose file. Runs to completion and returns the progress log.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "compose_file": Schema.string("Absolute path to a docker-compose.yml on this Mac."),
                    "recreate": Schema.boolean("Remove existing project containers first (default true)."),
                    "no_cache": Schema.boolean("Build with --no-cache (default false).")
                ], required: ["host_id", "compose_file"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "cloudflare_tunnel_start",
                description: "Expose a published container port to the internet over a Cloudflare Tunnel. Quick mode needs no account (ephemeral *.trycloudflare.com); named mode needs a prior `cloudflared tunnel login`. The tunnel lives until stopped or the MCP server exits.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "container_id": Schema.string("Container id or name."),
                    "port": Schema.integer("Published container port to expose."),
                    "mode": Schema.string("Tunnel mode.", enumValues: ["quick", "named"]),
                    "hostname": Schema.string("Hostname for named mode (required when mode=named).")
                ], required: ["host_id", "container_id", "port"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)
            ),
            Tool(
                name: "cloudflare_tunnel_list",
                description: "List active Cloudflare tunnels with their public URLs.",
                inputSchema: Schema.object(properties: [:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "cloudflare_tunnel_stop",
                description: "Stop an active Cloudflare tunnel by its id (from cloudflare_tunnel_list).",
                inputSchema: Schema.object(properties: [
                    "tunnel_id": Schema.string("Tunnel id (UUID).")
                ], required: ["tunnel_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "port_forward_start",
                description: "Forward a remote container port on an SSH host to a local port on this Mac (ssh -L style). Lives until stopped or the MCP server exits.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "container_id": Schema.string("Container id or name (label only)."),
                    "remote_port": Schema.integer("Published port on the remote Docker host."),
                    "local_port": Schema.integer("Preferred local port (optional; a free one is chosen otherwise).")
                ], required: ["host_id", "remote_port"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "port_forward_list",
                description: "List active SSH port forwards.",
                inputSchema: Schema.object(properties: [:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "port_forward_stop",
                description: "Stop an active SSH port forward by its id (from port_forward_list).",
                inputSchema: Schema.object(properties: [
                    "forward_id": Schema.string("Forward id (UUID).")
                ], required: ["forward_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            )
        ]
    }

    func handleSessions(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        switch name {
        case "compose_up":              return try await composeUp(args)
        case "cloudflare_tunnel_start": return try await cloudflareTunnelStart(args)
        case "cloudflare_tunnel_list":  return try await cloudflareTunnelList()
        case "cloudflare_tunnel_stop":  return try await cloudflareTunnelStop(args)
        case "port_forward_start":      return try await portForwardStart(args)
        case "port_forward_list":       return try await portForwardList()
        case "port_forward_stop":       return try await portForwardStop(args)
        default:                        return nil
        }
    }

    // MARK: - Compose

    private func composeUp(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let path = try args.requiredString("compose_file")
        let options = ComposeUpOptions(
            recreate: args.bool("recreate", default: true),
            noCache: args.bool("no_cache", default: false)
        )
        let project = try ComposeParser().parse(fileURL: URL(fileURLWithPath: path))
        let result = try await HostSessionManager.shared.composeUp(host: host, project: project, options: options)
        let tail = result.log.suffix(40).joined(separator: "\n")
        return .text("OK: \(result.started) service(s) up on \(host.name).\n\(cap(tail, bytes: 50 * 1024))")
    }

    // MARK: - Cloudflare tunnels

    private func cloudflareTunnelStart(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let containerID = try args.requiredString("container_id")
        guard let port = args.intOrNil("port") else { throw ToolError("Missing required integer 'port'.") }
        let modeName = args.string("mode") ?? "quick"
        let mode: CloudflareTunnel.Mode
        if modeName == "named" {
            let hostname = try args.requiredString("hostname")
            mode = .named(hostname: hostname)
        } else {
            mode = .quick
        }
        let tunnel = try await HostSessionManager.shared.startTunnel(host: host, containerID: containerID, port: port, mode: mode)
        // The tunnel comes up asynchronously; poll briefly for its public URL.
        if let url = await awaitTunnelURL(id: tunnel.id) {
            return .text("OK: tunnel \(tunnel.id.uuidString) live at \(url)")
        }
        return .text("OK: tunnel \(tunnel.id.uuidString) starting (call cloudflare_tunnel_list for its URL).")
    }

    /// Polls the manager for the tunnel's public URL for up to ~15s.
    private func awaitTunnelURL(id: UUID) async -> String? {
        for _ in 0..<30 {
            let tunnels = await HostSessionManager.shared.listTunnels()
            if let match = tunnels.first(where: { $0.tunnel.id == id }) {
                if let url = match.tunnel.publicURL { return url.absoluteString }
                if case .failed = match.tunnel.status { return nil }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func cloudflareTunnelList() async throws -> CallTool.Result {
        let tunnels = await HostSessionManager.shared.listTunnels()
        return .text(try jsonText(tunnels.map { TunnelDTO($0.tunnel, hostID: $0.hostID.uuidString) }))
    }

    private func cloudflareTunnelStop(_ args: Arguments) async throws -> CallTool.Result {
        let id = try args.uuid("tunnel_id")
        guard let id else { throw ToolError("Missing required 'tunnel_id'.") }
        let stopped = await HostSessionManager.shared.stopTunnel(id: id)
        return stopped ? .text("OK: stopped tunnel \(id.uuidString).") : .failure("No active tunnel with id \(id.uuidString).")
    }

    // MARK: - Port forwards

    private func portForwardStart(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        guard let remotePort = args.intOrNil("remote_port") else { throw ToolError("Missing required integer 'remote_port'.") }
        let containerID = args.string("container_id") ?? "port-forward"
        let forward = try await HostSessionManager.shared.startForward(
            host: host, containerID: containerID, remotePort: remotePort, localPort: args.intOrNil("local_port")
        )
        return .text(try jsonText(ForwardDTO(forward, hostID: host.id.uuidString)))
    }

    private func portForwardList() async throws -> CallTool.Result {
        let forwards = await HostSessionManager.shared.listForwards()
        return .text(try jsonText(forwards.map { ForwardDTO($0.forward, hostID: $0.hostID.uuidString) }))
    }

    private func portForwardStop(_ args: Arguments) async throws -> CallTool.Result {
        let id = try args.uuid("forward_id")
        guard let id else { throw ToolError("Missing required 'forward_id'.") }
        let stopped = await HostSessionManager.shared.stopForward(id: id)
        return stopped ? .text("OK: stopped forward \(id.uuidString).") : .failure("No active forward with id \(id.uuidString).")
    }
}
