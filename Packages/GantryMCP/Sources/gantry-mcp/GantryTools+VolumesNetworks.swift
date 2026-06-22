import Foundation
import MCP
import DockerKit

/// Volume and network management: create, remove, inspect, prune, and
/// connect/disconnect containers to networks.
extension GantryTools {
    func volumeNetworkTools() -> [Tool] {
        let hostIDRequired = Schema.string("Gantry host id (UUID, from list_hosts).")
        return [
            Tool(
                name: "create_volume",
                description: "Create a volume.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "name": Schema.string("Volume name."),
                    "driver": Schema.string("Volume driver (default local)."),
                    "labels": .object(["type": .string("object"), "description": .string("Labels as a string→string map.")])
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "remove_volume",
                description: "Delete a volume.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "name": Schema.string("Volume name."),
                    "force": Schema.boolean("Force removal (default false).")
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "inspect_volume",
                description: "Return the full raw JSON inspect of a volume.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "name": Schema.string("Volume name.")
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "prune_volumes",
                description: "Remove all unused volumes on a host.",
                inputSchema: Schema.object(properties: ["host_id": hostIDRequired], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_network",
                description: "Create a network.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "name": Schema.string("Network name."),
                    "driver": Schema.string("Network driver (default bridge)."),
                    "labels": .object(["type": .string("object"), "description": .string("Labels as a string→string map.")])
                ], required: ["host_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "remove_network",
                description: "Delete a network.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "network_id": Schema.string("Network id or name.")
                ], required: ["host_id", "network_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "inspect_network",
                description: "Return the full raw JSON inspect of a network.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "network_id": Schema.string("Network id or name.")
                ], required: ["host_id", "network_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "connect_container",
                description: "Attach a container to a network.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "network_id": Schema.string("Network id or name."),
                    "container_id": Schema.string("Container id or name.")
                ], required: ["host_id", "network_id", "container_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "disconnect_container",
                description: "Detach a container from a network.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "network_id": Schema.string("Network id or name."),
                    "container_id": Schema.string("Container id or name."),
                    "force": Schema.boolean("Force disconnect (default false).")
                ], required: ["host_id", "network_id", "container_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "prune_networks",
                description: "Remove all unused networks on a host.",
                inputSchema: Schema.object(properties: ["host_id": hostIDRequired], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            )
        ]
    }

    func handleVolumesNetworks(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        switch name {
        case "create_volume":        return try await createVolume(args)
        case "remove_volume":        return try await removeVolume(args)
        case "inspect_volume":       return try await inspectVolume(args)
        case "prune_volumes":        return try await pruneVolumes(args)
        case "create_network":       return try await createNetwork(args)
        case "remove_network":       return try await removeNetwork(args)
        case "inspect_network":      return try await inspectNetwork(args)
        case "connect_container":    return try await connectContainer(args)
        case "disconnect_container": return try await disconnectContainer(args)
        case "prune_networks":       return try await pruneNetworks(args)
        default:                     return nil
        }
    }

    // MARK: - Volumes

    private func createVolume(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let name = try args.requiredString("name")
        let client = try await docker.connect(to: host)
        let volume = try await client.createVolume(name: name, driver: args.string("driver") ?? "local", labels: args.stringDict("labels"))
        return .text("OK: created volume \(volume.name) on \(host.name).")
    }

    private func removeVolume(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let name = try args.requiredString("name")
        let client = try await docker.connect(to: host)
        try await client.removeVolume(name: name, force: args.bool("force", default: false))
        return .text("OK: removed volume \(name).")
    }

    private func inspectVolume(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let name = try args.requiredString("name")
        let client = try await docker.connect(to: host)
        let data = try await client.rawInspectVolume(name: name)
        return .text(String(decoding: data, as: UTF8.self))
    }

    private func pruneVolumes(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let client = try await docker.connect(to: host)
        let result = try await client.pruneVolumes()
        return .text(pruneText(result, noun: "volumes"))
    }

    // MARK: - Networks

    private func createNetwork(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let name = try args.requiredString("name")
        let client = try await docker.connect(to: host)
        let id = try await client.createNetwork(name: name, driver: args.string("driver") ?? "bridge", labels: args.stringDict("labels"))
        return .text("OK: created network \(name) (\(id)) on \(host.name).")
    }

    private func removeNetwork(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("network_id")
        let client = try await docker.connect(to: host)
        try await client.removeNetwork(id: id)
        return .text("OK: removed network \(id).")
    }

    private func inspectNetwork(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("network_id")
        let client = try await docker.connect(to: host)
        let data = try await client.rawInspectNetwork(id: id)
        return .text(String(decoding: data, as: UTF8.self))
    }

    private func connectContainer(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let networkID = try args.requiredString("network_id")
        let containerID = try args.requiredString("container_id")
        let client = try await docker.connect(to: host)
        try await client.connectContainer(networkID: networkID, containerID: containerID)
        return .text("OK: connected \(containerID) to \(networkID).")
    }

    private func disconnectContainer(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let networkID = try args.requiredString("network_id")
        let containerID = try args.requiredString("container_id")
        let client = try await docker.connect(to: host)
        try await client.disconnectContainer(networkID: networkID, containerID: containerID, force: args.bool("force", default: false))
        return .text("OK: disconnected \(containerID) from \(networkID).")
    }

    private func pruneNetworks(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let client = try await docker.connect(to: host)
        let result = try await client.pruneNetworks()
        return .text(pruneText(result, noun: "networks"))
    }
}
