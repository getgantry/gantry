import Foundation
import DockerKit
import GantryShared

/// Builds the widget snapshot from plain host values, so tests need no
/// `HostSession`.
public enum FleetSnapshotBuilder {
    public struct HostInput: Sendable {
        public var id: UUID
        public var name: String
        public var status: ConnectionStatus
        public var isAppleContainer: Bool
        public var containers: [ContainerSummary]

        public init(id: UUID, name: String, status: ConnectionStatus, isAppleContainer: Bool, containers: [ContainerSummary]) {
            self.id = id
            self.name = name
            self.status = status
            self.isAppleContainer = isAppleContainer
            self.containers = containers
        }
    }

    public static func build(
        hosts: [HostInput],
        appleServicesRunning: Bool?,
        controlToken: String,
        now: Date
    ) -> FleetSnapshot {
        var problems: [FleetSnapshot.Problem] = []
        var refs: [FleetSnapshot.ContainerRef] = []
        let summaries = hosts.map { host -> FleetSnapshot.Host in
            let counts = ContainerCounts(host.containers)
            let state = hostState(host.status)
            problems += self.problems(for: host, state: state)
            if host.status.isConnected {
                refs += host.containers.filter(ContainerCounts.isUserVisible).map {
                    .init(hostID: host.id, hostName: host.name, name: $0.displayName, isRunning: $0.state.isRunning)
                }
            }
            return FleetSnapshot.Host(
                id: host.id,
                name: host.name,
                state: state,
                running: host.status.isConnected ? counts.running : 0,
                stopped: host.status.isConnected ? counts.stopped : 0,
                unhealthy: host.status.isConnected ? counts.unhealthy : 0,
                attention: host.status.isConnected ? counts.attention : 0
            )
        }
        // Stable sort: the first host in sidebar order wins a tie.
        let top = problems.enumerated().min { ($0.element.kind.rank, $0.offset) < ($1.element.kind.rank, $1.offset) }
        let sortedRefs = refs.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
        let hasApple = hosts.contains(where: \.isAppleContainer)
        return FleetSnapshot(
            generatedAt: now,
            hosts: summaries,
            topProblem: top?.element,
            appleServices: hasApple ? appleServicesRunning.map(FleetSnapshot.AppleServices.init) : nil,
            containers: sortedRefs,
            controlToken: controlToken
        )
    }

    static func hostState(_ status: ConnectionStatus) -> FleetSnapshot.HostState {
        switch status {
        case .connected: .connected
        case .connecting: .connecting
        case .disconnected: .disconnected
        case .failed: .failed
        }
    }

    private static func problems(for host: HostInput, state: FleetSnapshot.HostState) -> [FleetSnapshot.Problem] {
        if state == .failed {
            return [.init(kind: .hostFailed, hostID: host.id, hostName: host.name, containerName: nil)]
        }
        guard host.status.isConnected else { return [] }
        return host.containers.filter(ContainerCounts.isUserVisible).compactMap { container in
            let kind: FleetSnapshot.ProblemKind
            if container.state.isRunning, container.status.lowercased().contains("(unhealthy)") {
                kind = .unhealthy
            } else if container.state == .dead {
                kind = .dead
            } else if container.state == .restarting {
                kind = .restarting
            } else {
                return nil
            }
            return .init(kind: kind, hostID: host.id, hostName: host.name, containerName: container.displayName)
        }
    }
}

/// The health of one host, for the Host Health shortcut.
public struct HostHealthSummary: Equatable, Sendable {
    public enum Level: String, Sendable {
        case ok
        case warning
        case down
    }

    public var level: Level
    public var connected: Bool
    public var counts: ContainerCounts

    public init(status: ConnectionStatus, containers: [ContainerSummary]) {
        connected = status.isConnected
        counts = ContainerCounts(containers)
        if !connected {
            level = .down
        } else if counts.attention > 0 {
            level = .warning
        } else {
            level = .ok
        }
    }
}

/// Stops and removes the containers of a Compose project, then removes the
/// networks that Compose made for it. Volumes stay, as with `compose down`.
public enum ComposeDown {
    public struct Outcome: Equatable, Sendable {
        public var removedContainers: Int
        public var removedNetworks: Int
        public var failures: [String]
    }

    public static func run(client: DockerClient, project: String) async throws -> Outcome {
        let label = ComposeRunner.Label.project
        let members = try await client.listContainers(all: true).filter { $0.labels[label] == project }
        var outcome = Outcome(removedContainers: 0, removedNetworks: 0, failures: [])
        for container in members {
            do {
                if container.state.isRunning || container.state == .restarting || container.state == .paused {
                    try await client.stopContainer(id: container.id, timeout: nil)
                }
                try await client.removeContainer(id: container.id, force: false, removeVolumes: false)
                outcome.removedContainers += 1
            } catch {
                outcome.failures.append(container.displayName)
            }
        }
        let networks = (try? await client.listNetworks()) ?? []
        for network in networks where network.labels[label] == project {
            if (try? await client.removeNetwork(id: network.id)) != nil {
                outcome.removedNetworks += 1
            }
        }
        return outcome
    }
}
