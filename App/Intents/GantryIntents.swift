import AppIntents
import AppCore
import DockerKit

// MARK: - List containers

struct ListContainersIntent: AppIntent {
    static let title: LocalizedStringResource = "List Containers"
    static let description = IntentDescription(
        "Lists the containers on a Docker host, with a summary of how many are running and stopped."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Host")
    var host: HostEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("List containers on \(\.$host)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<[ContainerEntity]> & ProvidesDialog {
        let dockerHost = try resolvedHost()
        let client = try await HeadlessDocker.connect(to: dockerHost)
        defer { Task { await client.shutdown() } }

        let summaries = try await client.listContainers(all: true)
        let entities = summaries.map { ContainerEntity(hostID: dockerHost.id, summary: $0) }

        let running = summaries.filter { $0.state == .running }.count
        let stopped = summaries.count - running
        let dialog = IntentDialog(
            "\(running) running, \(stopped) stopped on \(dockerHost.name)"
        )

        return .result(value: entities, dialog: dialog)
    }

    /// Uses the chosen host, or the first persisted host (typically Local) when
    /// the parameter was left blank.
    private func resolvedHost() throws -> DockerHost {
        if let host {
            return try IntentSupport.host(for: host)
        }
        guard let first = HeadlessDocker.loadHosts().first else {
            throw HeadlessDockerError.hostNotFound("no hosts are configured")
        }
        return first
    }
}

// MARK: - Container lifecycle actions

struct StartContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Container"
    static let description = IntentDescription("Starts a container on a Docker host.")
    static let openAppWhenRun = false

    @Parameter(title: "Host")
    var host: HostEntity

    @Parameter(title: "Container", optionsProvider: StartContainerOptions())
    var container: ContainerEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$container) on \(\.$host)")
    }

    struct StartContainerOptions: DynamicOptionsProvider {
        @IntentParameterDependency<StartContainerIntent>(\.$host) var dependency
        func results() async throws -> [ContainerEntity] {
            try await containerOptions(for: dependency?.host)
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ContainerActionRunner.run(container: container) { client, id in
            try await client.startContainer(id: id)
        }
        return .result(dialog: "Started \(container.name).")
    }
}

struct StopContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Container"
    static let description = IntentDescription("Stops a running container on a Docker host.")
    static let openAppWhenRun = false

    @Parameter(title: "Host")
    var host: HostEntity

    @Parameter(title: "Container", optionsProvider: StopContainerOptions())
    var container: ContainerEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$container) on \(\.$host)")
    }

    struct StopContainerOptions: DynamicOptionsProvider {
        @IntentParameterDependency<StopContainerIntent>(\.$host) var dependency
        func results() async throws -> [ContainerEntity] {
            try await containerOptions(for: dependency?.host)
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ContainerActionRunner.run(container: container) { client, id in
            try await client.stopContainer(id: id, timeout: nil)
        }
        return .result(dialog: "Stopped \(container.name).")
    }
}

struct RestartContainerIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart Container"
    static let description = IntentDescription("Restarts a container on a Docker host.")
    static let openAppWhenRun = false

    @Parameter(title: "Host")
    var host: HostEntity

    @Parameter(title: "Container", optionsProvider: RestartContainerOptions())
    var container: ContainerEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Restart \(\.$container) on \(\.$host)")
    }

    struct RestartContainerOptions: DynamicOptionsProvider {
        @IntentParameterDependency<RestartContainerIntent>(\.$host) var dependency
        func results() async throws -> [ContainerEntity] {
            try await containerOptions(for: dependency?.host)
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ContainerActionRunner.run(container: container) { client, id in
            try await client.restartContainer(id: id, timeout: nil)
        }
        return .result(dialog: "Restarted \(container.name).")
    }
}

// MARK: - Logs

struct GetContainerLogsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Container Logs"
    static let description = IntentDescription(
        "Returns the last lines of a container's logs as text (does not follow)."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Host")
    var host: HostEntity

    @Parameter(title: "Container", optionsProvider: LogsContainerOptions())
    var container: ContainerEntity

    @Parameter(title: "Lines", default: 50)
    var lines: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get the last \(\.$lines) log lines of \(\.$container) on \(\.$host)")
    }

    struct LogsContainerOptions: DynamicOptionsProvider {
        @IntentParameterDependency<GetContainerLogsIntent>(\.$host) var dependency
        func results() async throws -> [ContainerEntity] {
            try await containerOptions(for: dependency?.host)
        }
    }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let resolved = try IntentSupport.resolve(container)
        let client = try await HeadlessDocker.connect(to: resolved.host)
        // Manual shutdown so it survives the stream consumption below.
        do {
            let details = try await client.inspectContainer(id: resolved.containerID)
            let tail = max(1, lines)
            let stream = try await client.containerLogs(
                id: resolved.containerID,
                tty: details.config.tty,
                follow: false,
                tail: tail,
                timestamps: false,
                since: nil
            )

            var collected: [String] = []
            for try await entry in stream {
                collected.append(entry.text)
            }
            await client.shutdown()

            let text = collected.joined(separator: "\n")
            let dialog = IntentDialog("\(collected.count) log lines from \(container.name)")
            return .result(value: text, dialog: dialog)
        } catch {
            await client.shutdown()
            throw error
        }
    }
}

// MARK: - Shared action runner

/// Connects to the container's host, runs a single client action, and shuts the
/// connection down. Used by the start/stop/restart intents.
enum ContainerActionRunner {
    static func run(
        container: ContainerEntity,
        _ action: (DockerClient, String) async throws -> Void
    ) async throws {
        let resolved = try IntentSupport.resolve(container)
        let client = try await HeadlessDocker.connect(to: resolved.host)
        defer { Task { await client.shutdown() } }
        try await action(client, resolved.containerID)
    }
}
