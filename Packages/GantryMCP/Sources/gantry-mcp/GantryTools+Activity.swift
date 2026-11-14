import Foundation
import MCP
import DockerKit
import AppCore

/// `fleet_activity`: the app's Resource Usage table for agents. The server
/// has no load history, so it takes two one-shot samples per container.
extension GantryTools {
    static let activitySampleInterval: TimeInterval = 1

    func activityTools() -> [Tool] {
        [
            Tool(
                name: "fleet_activity",
                description: """
                    Running containers of all hosts (or one host) with CPU (100 = one core), memory, \
                    network and disk rates in bytes per second, and uptime, sorted. Takes about one \
                    second: it samples each container twice. Hosts that fail are listed in `errors`.
                    """,
                inputSchema: Schema.object(properties: [
                    "host_id": Schema.string("Gantry host id (UUID, from list_hosts). Omit to target all hosts."),
                    "sort": Schema.string(
                        "Sort column (default cpu).",
                        enumValues: FleetActivity.Column.allCases.map(\.rawValue)
                    ),
                    "ascending": Schema.boolean("Sort order. Default: false for metrics, true for host, name and image."),
                    "limit": Schema.integer("Maximum rows, 1-500 (default 50)."),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
        ]
    }

    func handleActivity(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        guard name == "fleet_activity" else { return nil }
        let request = try FleetActivityRequest(args)
        let hosts = try targetHosts(args)

        var connected: [(host: DockerHost, client: DockerClient, containers: [ContainerSummary])] = []
        var errors: [FleetActivityReport.HostError] = []
        for host in hosts {
            do {
                let client = try await docker.connect(to: host)
                let containers = try await client.listContainers(all: false)
                connected.append((host, client, containers))
            } catch {
                errors.append(.init(hostID: host.id.uuidString, hostName: host.name, error: readable(error)))
            }
        }

        var first: [[String: ContainerCounters]] = []
        for entry in connected {
            first.append(await Self.counters(entry.client, entry.containers))
        }
        if !connected.isEmpty {
            try await Task.sleep(for: .seconds(Self.activitySampleInterval))
        }
        var inputs: [FleetActivity.HostInput] = []
        for (index, entry) in connected.enumerated() {
            let second = await Self.counters(entry.client, entry.containers)
            var load: [String: ContainerLoadPoint] = [:]
            for (id, current) in second {
                guard let previous = first[index][id] else { continue }
                load[id] = LoadMath.point(previous: previous, current: current)
            }
            inputs.append(FleetActivity.HostInput(
                id: entry.host.id, name: entry.host.name, isAppleContainer: entry.host.isAppleContainer,
                state: .connected, containers: entry.containers, load: load
            ))
        }

        let report = FleetActivityReport.make(
            hosts: inputs, errors: errors, request: request, sampledSeconds: Self.activitySampleInterval
        )
        return .text(try jsonText(report))
    }

    /// Counters of the running, visible containers; a failed sample is left out.
    private static func counters(_ client: DockerClient, _ containers: [ContainerSummary]) async -> [String: ContainerCounters] {
        var result: [String: ContainerCounters] = [:]
        for container in containers where container.state.isRunning && ContainerCounts.isUserVisible(container) {
            guard let sample = try? await client.containerStatsOnce(id: container.id) else { continue }
            result[container.id] = ContainerCounters(sample, date: .now)
        }
        return result
    }
}

struct FleetActivityRequest: Equatable {
    var comparator: FleetActivity.Comparator
    var limit: Int

    static let defaultLimit = 50
    static let maxLimit = 500

    init(_ args: Arguments) throws {
        let column: FleetActivity.Column
        if let raw = args.string("sort"), !raw.isEmpty {
            guard let parsed = FleetActivity.Column(rawValue: raw.lowercased()) else {
                let names = FleetActivity.Column.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("Unknown sort column '\(raw)'. Use one of: \(names).")
            }
            column = parsed
        } else {
            column = .cpu
        }
        let order = args.boolOrNil("ascending").map { $0 ? SortOrder.forward : .reverse }
        comparator = FleetActivity.Comparator(column, order: order)
        limit = min(max(args.int("limit", default: Self.defaultLimit), 1), Self.maxLimit)
    }
}

struct FleetActivityReport: Encodable {
    struct Row: Encodable {
        var hostID: String
        var hostName: String
        var containerID: String
        var name: String
        var image: String
        var cpuPercent: Double?
        var memoryBytes: Int64?
        var networkInBytesPerSecond: Double?
        var networkOutBytesPerSecond: Double?
        var diskReadBytesPerSecond: Double?
        var diskWriteBytesPerSecond: Double?
        var uptimeSeconds: Int?

        init(_ row: FleetActivity.Row) {
            hostID = row.hostID.uuidString
            hostName = row.hostName
            containerID = row.containerID
            name = row.name
            image = row.image
            if let load = row.load {
                cpuPercent = (load.cpuPercent * 100).rounded() / 100
                memoryBytes = load.memoryBytes
                networkInBytesPerSecond = load.networkInRate.rounded()
                networkOutBytesPerSecond = load.networkOutRate.rounded()
                diskReadBytesPerSecond = load.diskReadRate.rounded()
                diskWriteBytesPerSecond = load.diskWriteRate.rounded()
            }
            uptimeSeconds = row.uptime.map { Int($0) }
        }
    }

    struct HostError: Encodable, Equatable {
        var hostID: String
        var hostName: String
        var error: String
    }

    var sampledSeconds: Double
    var containers: [Row]
    var errors: [HostError]

    static func make(
        hosts: [FleetActivity.HostInput], errors: [HostError],
        request: FleetActivityRequest, sampledSeconds: Double
    ) -> FleetActivityReport {
        let rows = FleetActivity.sorted(FleetActivity.snapshot(hosts: hosts).rows, using: [request.comparator])
        return FleetActivityReport(
            sampledSeconds: sampledSeconds,
            containers: rows.prefix(request.limit).map(Row.init),
            errors: errors
        )
    }
}
