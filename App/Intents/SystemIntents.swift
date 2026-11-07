import AppIntents
import AppKit
import AppCore
import DockerKit

/// An error with a message for Shortcuts and Siri.
struct GantryIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
    init(_ message: LocalizedStringResource) { localizedStringResource = message }
}

// MARK: - Open

struct OpenContainerIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Container"
    static let description = IntentDescription("Shows a container in Gantry.")

    @Parameter(title: "Container")
    var target: ContainerEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let parts = ContainerEntity.split(target.id) else {
            throw GantryIntentError("The container is not known.")
        }
        NotificationActions.handle(.openContainer(hostID: parts.hostID, containerID: parts.containerID))
        return .result()
    }
}

struct OpenComposeProjectIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Compose Project"
    static let description = IntentDescription("Shows the containers of a Compose project's host in Gantry.")

    @Parameter(title: "Project")
    var target: ComposeProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let hostID = target.hostID else { throw GantryIntentError("The project is not known.") }
        HostNavigation.showContainers(hostID)
        return .result()
    }
}

struct OpenHostIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Host"
    static let description = IntentDescription("Shows a Docker host in Gantry.")

    @Parameter(title: "Host")
    var target: HostEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        HostNavigation.showContainers(target.id)
        return .result()
    }
}

/// Brings the window forward on a host's Containers section.
@MainActor
enum HostNavigation {
    static func showContainers(_ hostID: UUID) {
        MainWindowActivation.activate()
        NotificationCenter.default.post(name: .gantrySelectHostContainers, object: hostID)
        // A window that is still opening misses the first post.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: .gantrySelectHostContainers, object: hostID)
        }
    }
}

// MARK: - Open in Browser

struct OpenInBrowserIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Container in Browser"
    static let description = IntentDescription(
        "Opens the first published port of a container in the browser. An apple/container container opens at its DNS name or address."
    )

    @Parameter(title: "Container")
    var container: ContainerEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$container) in the browser")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<URL> & ProvidesDialog {
        let resolved = try IntentSupport.resolve(container)
        let host = resolved.host
        let details = try await LiveFleet.withClient(host) { try await $0.inspectContainer(id: resolved.containerID) }
        let containers = try await LiveFleet.containers(on: host)
        let summary = containers.first { $0.id == details.id || $0.id.hasPrefix(resolved.containerID) }
        let domain = summary?.labels[HostSession.dnsDomainLabelKey] ?? details.config.domainname
        let ports = summary?.ports ?? []
        switch BrowserTarget.url(
            host: host, ports: ports, ipAddress: details.networkSettings.ipAddress,
            domain: domain, containerName: container.name
        ) {
        case .success(let url):
            NSWorkspace.shared.open(url)
            return .result(value: url, dialog: "Opened \(url.absoluteString).")
        case .failure(.noPort):
            throw GantryIntentError("\(container.name) publishes no port.")
        case .failure(.needsForward(let port)):
            throw GantryIntentError("Port \(port) of \(container.name) listens only on the server. Use a port forward in Gantry.")
        }
    }
}

// MARK: - Compose Down

struct ComposeDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Compose Down"
    static let description = IntentDescription(
        "Stops and removes the containers and networks of a Compose project. Volumes stay."
    )

    @Parameter(title: "Project")
    var project: ComposeProjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Compose down \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let hostID = project.hostID else { throw GantryIntentError("The project is not known.") }
        let host = try LiveFleet.host(hostID)
        try await requestConfirmation(
            actionName: .turnOff,
            dialog: "Stop and remove the \(project.total) containers of \(project.name) on \(host.name)?"
        )
        let name = project.name
        let outcome = try await LiveFleet.withClient(host) { try await ComposeDown.run(client: $0, project: name) }
        await LiveFleet.refresh(hostID)
        if !outcome.failures.isEmpty {
            throw GantryIntentError("Could not remove: \(outcome.failures.joined(separator: ", ")).")
        }
        return .result(dialog: "Removed \(outcome.removedContainers) containers of \(name).")
    }
}

// MARK: - Prune

enum PruneTarget: String, AppEnum {
    case stoppedContainers
    case danglingImages
    case unusedImages
    case unusedVolumes
    case unusedNetworks
    case buildCache

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Prune Target" }

    static let caseDisplayRepresentations: [PruneTarget: DisplayRepresentation] = [
        .stoppedContainers: "Stopped containers",
        .danglingImages: "Dangling images",
        .unusedImages: "Unused images",
        .unusedVolumes: "Unused volumes",
        .unusedNetworks: "Unused networks",
        .buildCache: "Build cache"
    ]

    var label: LocalizedStringResource {
        switch self {
        case .stoppedContainers: "Stopped containers"
        case .danglingImages: "Dangling images"
        case .unusedImages: "Unused images"
        case .unusedVolumes: "Unused volumes"
        case .unusedNetworks: "Unused networks"
        case .buildCache: "Build cache"
        }
    }
}

struct PruneIntent: AppIntent {
    static let title: LocalizedStringResource = "Prune"
    static let description = IntentDescription(
        "Deletes unused containers, images, volumes, networks or build cache on a host, after you confirm."
    )

    @Parameter(title: "Host")
    var host: HostEntity

    @Parameter(title: "What", default: .stoppedContainers)
    var target: PruneTarget

    static var parameterSummary: some ParameterSummary {
        Summary("Prune \(\.$target) on \(\.$host)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<Int> & ProvidesDialog {
        let dockerHost = try IntentSupport.host(for: host)
        if target == .buildCache, !dockerHost.capabilities.buildCachePrune {
            throw GantryIntentError("\(dockerHost.name) cannot prune the build cache.")
        }
        let what = String(localized: target.label)
        try await requestConfirmation(actionName: .continue, dialog: "Delete \(what) on \(dockerHost.name)? You cannot undo this.")
        let choice = target
        let result = try await LiveFleet.withClient(dockerHost) { client -> PruneResult in
            switch choice {
            case .stoppedContainers: try await client.pruneContainers()
            case .danglingImages: try await client.pruneImages(dangling: true)
            case .unusedImages: try await client.pruneImages(dangling: false)
            case .unusedVolumes: try await client.pruneVolumes()
            case .unusedNetworks: try await client.pruneNetworks()
            case .buildCache: try await client.pruneBuildCache()
            }
        }
        if let session = LiveFleet.connectedSession(dockerHost.id) { await session.refreshAll() }
        let freed = ByteCountFormatter.string(fromByteCount: result.spaceReclaimed, countStyle: .file)
        return .result(value: result.deletedCount, dialog: "Deleted \(result.deletedCount) items, freed \(freed).")
    }
}

// MARK: - Exec

struct ExecCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command in Container"
    static let description = IntentDescription(
        "Runs a shell command in a running container and returns its output. The command stops after 30 seconds."
    )

    @Parameter(title: "Container")
    var container: ContainerEntity

    @Parameter(title: "Command", inputOptions: String.IntentInputOptions(keyboardType: .default, capitalizationType: .none, autocorrect: false))
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in \(\.$container)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let resolved = try IntentSupport.resolve(container)
        let line = command
        let result = try await LiveFleet.withClient(resolved.host) {
            try await ContainerExec.run(client: $0, containerID: resolved.containerID, command: line)
        }
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let code = result.exitCode.map(String.init) ?? "?"
        return .result(value: output, dialog: "Exit code \(code) in \(container.name).")
    }
}

// MARK: - Host Health

struct HostHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Host Health"
    static let description = IntentDescription(
        "Reports whether hosts answer and how many containers run or need attention."
    )

    @Parameter(title: "Host", description: "Leave empty for every host.")
    var host: HostEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Health of \(\.$host)")
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let hosts = try host.map { [try IntentSupport.host(for: $0)] } ?? LiveFleet.hosts()
        guard !hosts.isEmpty else { throw GantryIntentError("No hosts are configured.") }
        var lines: [String] = []
        for dockerHost in hosts {
            lines.append(await Self.line(for: dockerHost))
        }
        let text = lines.joined(separator: "\n")
        return .result(value: text, dialog: "\(text)")
    }

    @MainActor
    private static func line(for host: DockerHost) async -> String {
        let health: HostHealthSummary
        if let session = LiveFleet.connectedSession(host.id) {
            health = HostHealthSummary(status: session.status, containers: session.containers)
        } else if let list = try? await LiveFleet.withClient(host, { try await $0.listContainers(all: true) }) {
            let counts = ContainerCounts(list)
            return Self.describe(host.name, counts: counts)
        } else {
            health = HostHealthSummary(status: .failed(""), containers: [])
        }
        if !health.connected { return String(localized: "\(host.name): not reachable") }
        return Self.describe(host.name, counts: health.counts)
    }

    private static func describe(_ name: String, counts: ContainerCounts) -> String {
        if counts.attention > 0 {
            return String(localized: "\(name): \(counts.running) running, \(counts.attention) need attention")
        }
        return String(localized: "\(name): \(counts.running) running, all healthy")
    }
}
