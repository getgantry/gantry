import Foundation
import DockerKit

/// A progress event emitted while bringing a Compose project up.
public enum ComposeUpEvent: Sendable, Equatable {
    case info(String)
    case warning(String)
    case buildingImage(service: String)
    case pullingImage(service: String, reference: String)
    case creatingNetwork(String)
    case creatingVolume(String)
    case startingService(String)
    case startedService(service: String, containerID: String)
    case finished(project: String, started: Int)
}

/// Options controlling a Compose `up`.
public struct ComposeUpOptions: Sendable {
    /// Remove any existing containers of this project before starting.
    public var recreate: Bool
    /// Build with `--no-cache`.
    public var noCache: Bool

    public init(recreate: Bool = true, noCache: Bool = false) {
        self.recreate = recreate
        self.noCache = noCache
    }
}

/// Orchestrates a Compose project onto a connected host by building images,
/// creating the project's networks and volumes, and starting each service in
/// dependency order — labeling containers with `com.docker.compose.*` so the
/// existing project grouping picks them up.
///
/// The feature targets apple/container hosts (the only kind that serves the
/// `/build` route); the UI gates host selection accordingly.
@MainActor
public struct ComposeRunner {
    /// Docker Compose labels (mirrors the upstream convention).
    public enum Label {
        public static let project = "com.docker.compose.project"
        public static let service = "com.docker.compose.service"
        public static let containerNumber = "com.docker.compose.container-number"
        public static let oneoff = "com.docker.compose.oneoff"
        public static let workingDir = "com.docker.compose.project.working_dir"
        public static let configFiles = "com.docker.compose.project.config_files"
        public static let managedBy = "com.docker.compose.version"
    }

    let session: HostSession
    let project: ComposeProject
    let options: ComposeUpOptions

    public init(session: HostSession, project: ComposeProject, options: ComposeUpOptions = .init()) {
        self.session = session
        self.project = project
        self.options = options
    }

    /// Brings the whole project up, reporting progress via `emit`. Throws on the
    /// first hard failure (build/create error), having emitted context first.
    @discardableResult
    public func up(emit: @MainActor (ComposeUpEvent) -> Void) async throws -> Int {
        let order = orderedServices()

        if options.recreate {
            await removeExistingProjectContainers(emit: emit)
        }

        try await ensureNetworks(for: order, emit: emit)
        try await ensureVolumes(for: order, emit: emit)

        var started = 0
        for service in order {
            let image = try await resolveImage(for: service, emit: emit)
            let request = try buildCreateRequest(for: service, image: image, emit: emit)
            emit(.startingService(service.name))
            let id = try await session.createAndRun(request)
            emit(.startedService(service: service.name, containerID: id))
            started += 1
        }

        emit(.finished(project: project.name, started: started))
        return started
    }

    // MARK: - Ordering

    /// Topologically sorts services by `depends_on`. Falls back to declared
    /// order on a dependency cycle (emitting nothing — the caller can't fix it).
    func orderedServices() -> [ComposeService] {
        let byName = Dictionary(uniqueKeysWithValues: project.services.map { ($0.name, $0) })
        var visited: Set<String> = []
        var inStack: Set<String> = []
        var result: [ComposeService] = []
        var cycle = false

        func visit(_ service: ComposeService) {
            if visited.contains(service.name) { return }
            if inStack.contains(service.name) { cycle = true; return }
            inStack.insert(service.name)
            for dep in service.dependsOn {
                if let depService = byName[dep] { visit(depService) }
            }
            inStack.remove(service.name)
            visited.insert(service.name)
            result.append(service)
        }

        for service in project.services { visit(service) }
        return cycle ? project.services : result
    }

    // MARK: - Networks & volumes

    /// The full (project-scoped) name for a declared network key.
    func networkFullName(_ key: String) -> String {
        if let def = project.networks[key], def.external {
            return def.name ?? key
        }
        return "\(project.name)_\(key)"
    }

    /// The networks a service joins: its declared list, or the implicit default.
    func serviceNetworks(_ service: ComposeService) -> [String] {
        service.networks.isEmpty ? ["default"] : service.networks
    }

    private func ensureNetworks(for services: [ComposeService], emit: @MainActor (ComposeUpEvent) -> Void) async throws {
        var wanted: [String] = []
        for service in services {
            for key in serviceNetworks(service) where !wanted.contains(key) { wanted.append(key) }
        }
        let existing = Set(session.networks.map(\.name))
        for key in wanted {
            if let def = project.networks[key], def.external { continue }
            let full = networkFullName(key)
            if existing.contains(full) { continue }
            emit(.creatingNetwork(full))
            let labels = [Label.project: project.name, "com.docker.compose.network": key]
            if await session.createNetwork(name: full, labels: labels) == nil {
                emit(.warning("Could not create network \(full); it may already exist."))
            }
        }
    }

    /// The full (project-scoped) name for a named volume key.
    func volumeFullName(_ key: String) -> String {
        if let def = project.volumes[key], def.external {
            return def.name ?? key
        }
        return "\(project.name)_\(key)"
    }

    private func ensureVolumes(for services: [ComposeService], emit: @MainActor (ComposeUpEvent) -> Void) async throws {
        var wanted: [String] = []
        for service in services {
            for mount in service.volumes {
                if case .named(let key) = mount.kind, !wanted.contains(key) { wanted.append(key) }
            }
        }
        let existing = Set(session.volumes.map(\.name))
        for key in wanted {
            if let def = project.volumes[key], def.external { continue }
            let full = volumeFullName(key)
            if existing.contains(full) { continue }
            emit(.creatingVolume(full))
            let labels = [Label.project: project.name, "com.docker.compose.volume": key]
            if await session.createVolume(name: full, labels: labels) == nil {
                emit(.warning("Could not create volume \(full); it may already exist."))
            }
        }
    }

    // MARK: - Images

    /// Resolves the image to run for a service: builds it (and returns the tag)
    /// when `build:` is present, otherwise pulls `image:` if it is missing.
    private func resolveImage(for service: ComposeService, emit: @MainActor (ComposeUpEvent) -> Void) async throws -> String {
        if let build = service.build {
            let tag = service.image ?? "\(project.name)-\(service.name):latest"
            emit(.buildingImage(service: service.name))
            let spec = ImageBuildSpec(
                contextPath: resolvePath(build.context),
                dockerfile: build.dockerfile,
                tag: tag,
                buildArgs: build.args,
                target: build.target,
                labels: [Label.project: project.name, Label.service: service.name],
                noCache: options.noCache
            )
            _ = try await session.buildImage(spec)
            return tag
        }

        let image = service.image ?? ""
        if !imageIsPresent(image) {
            emit(.pullingImage(service: service.name, reference: image))
            let stream = try await session.pullImage(reference: image)
            for try await _ in stream {}
            await session.refreshImages()
        }
        return image
    }

    /// Whether `reference` (with an implicit `:latest`) is already pulled.
    private func imageIsPresent(_ reference: String) -> Bool {
        let normalized = reference.contains(":") ? reference : reference + ":latest"
        return session.images.contains { $0.repoTags.contains(normalized) }
    }

    // MARK: - Container request

    private func buildCreateRequest(
        for service: ComposeService,
        image: String,
        emit: @MainActor (ComposeUpEvent) -> Void
    ) throws -> ContainerCreateRequest {
        let containerName = service.containerName ?? "\(project.name)-\(service.name)-1"

        // Environment: env_file values first, overridden by inline environment.
        var env: [String] = []
        for file in service.envFiles {
            let fileEnv = ComposeParser.parseDotEnv(at: URL(fileURLWithPath: resolvePath(file)))
            for (k, v) in fileEnv.sorted(by: { $0.key < $1.key }) { env.append("\(k)=\(v)") }
        }
        for pair in service.environment { env.append("\(pair.key)=\(pair.value)") }

        // Labels: service labels plus the compose identity labels that drive
        // grouping in the rest of the app.
        var labels = service.labels
        labels[Label.project] = project.name
        labels[Label.service] = service.name
        labels[Label.containerNumber] = "1"
        labels[Label.oneoff] = "False"
        labels[Label.workingDir] = project.directory.path
        labels[Label.configFiles] = project.filePath.path
        labels[Label.managedBy] = "gantry"

        // Ports → exposed set + host bindings (preserving host IP).
        var exposed: [String] = []
        var portBindings: [String: [ContainerCreateRequest.PortBinding]] = [:]
        for port in service.ports {
            let key = "\(port.containerPort)/\(port.proto)"
            exposed.append(key)
            let hostPort = port.hostPort ?? port.containerPort
            portBindings[key, default: []].append(
                .init(hostIP: port.hostIP, hostPort: hostPort)
            )
        }

        // Volumes → binds. Relative bind paths resolve against the project dir;
        // named volumes use their project-scoped name.
        var binds: [String] = []
        for mount in service.volumes {
            let source: String
            switch mount.kind {
            case .bind(let hostPath): source = resolvePath(hostPath)
            case .named(let key): source = volumeFullName(key)
            }
            binds.append(mount.readOnly ? "\(source):\(mount.containerPath):ro" : "\(source):\(mount.containerPath)")
        }

        if let restart = service.restart, restart != "no" {
            emit(.warning("\(service.name): restart policy `\(restart)` is not supported on apple/container and was ignored."))
        }
        if service.user != nil {
            emit(.warning("\(service.name): `user:` is not yet applied on apple/container."))
        }

        let networks = serviceNetworks(service)
        if networks.count > 1 {
            emit(.warning("\(service.name): joins multiple networks; apple/container attaches only `\(networks[0])`."))
        }
        let endpoints = networks.first.map { key in
            [networkFullName(key): ContainerCreateRequest.EndpointConfig(aliases: [service.name])]
        }

        let hostConfig = ContainerCreateRequest.HostConfig(
            binds: binds.isEmpty ? nil : binds,
            portBindings: portBindings.isEmpty ? nil : portBindings,
            memory: service.memoryBytes,
            nanoCPUs: service.cpus.map { Int64($0 * 1_000_000_000) },
            privileged: service.privileged ? true : nil
        )

        return ContainerCreateRequest(
            image: image,
            cmd: service.command,
            entrypoint: service.entrypoint,
            env: env,
            exposedPorts: exposed.isEmpty ? nil : exposed,
            labels: labels,
            tty: service.tty,
            workingDir: service.workingDir,
            hostConfig: hostConfig,
            networkingConfig: endpoints.map { .init(endpointsConfig: $0) },
            name: containerName
        )
    }

    // MARK: - Recreate

    private func removeExistingProjectContainers(emit: @MainActor (ComposeUpEvent) -> Void) async {
        let mine = session.containers.filter { $0.labels[Label.project] == project.name }
        if mine.isEmpty { return }
        emit(.info("Removing \(mine.count) existing container(s) for project \(project.name)."))
        for container in mine {
            _ = await session.perform(.remove(force: true), on: container.id)
        }
    }

    // MARK: - Paths

    /// Resolves a possibly-relative compose path against the project directory,
    /// expanding a leading `~`.
    func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return project.directory.appendingPathComponent(path).standardizedFileURL.path
    }
}
