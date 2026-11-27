import Foundation
import DockerKit

extension HostSession {
    /// How often the loop looks at the cache. The cache decides what is due.
    static let imageUpdateLoopInterval: Duration = .seconds(30 * 60)

    /// The containers that the check looks at: not Gantry's own helpers.
    var imageUpdateCandidates: [ContainerSummary] {
        containers.filter { !DebugShell.isSidecar($0) && !AppleBuilderStatus.isBuilderContainer($0) }
    }

    /// The check target of `container`, or nil when Gantry does not check it.
    public func imageUpdateTarget(for container: ContainerSummary) -> ImageUpdatePlan.Target? {
        ImageUpdatePlan.target(for: container, images: images, isApple: host.isAppleContainer)
    }

    /// Nil when unknown: not checked yet, the check failed, or skipped.
    public func imageUpdateStatus(for container: ContainerSummary) -> ImageUpdateStatus? {
        let target = imageUpdateTarget(for: container)
        return ImageUpdatePlan.status(of: target, remoteDigest: target.flatMap { imageUpdateMonitor.remoteDigest(for: $0.key) })
    }

    /// Asks the registry for the references that are due (all with `force`).
    /// Failures are silent: the containers then show no mark.
    public func checkImageUpdates(force: Bool = false) async {
        guard status.isConnected else { return }
        if !host.isAppleContainer { await refreshImages() }
        let targets = imageUpdateCandidates.compactMap(imageUpdateTarget(for:))
        guard !targets.isEmpty else { return }
        await imageUpdateMonitor.check(targets, force: force, lookup: registryDigestLookup())
    }

    /// Docker hosts ask the daemon (`/distribution`); Apple hosts ask the
    /// registry over HTTP. Both use the credentials of `~/.docker/config.json`.
    func registryDigestLookup() -> @Sendable (ImageReference) async throws -> String {
        let credentials = registryCredentials
        if host.isAppleContainer {
            let registry = RegistryManifestClient()
            return { reference in
                let auth = await credentials.auth(forImageReference: reference.canonical)
                return try await registry.digest(for: reference, credentials: auth)
            }
        }
        guard let client else { return { _ in throw DockerError.connectionFailed("Not connected") } }
        return { reference in
            let auth = await credentials.auth(forImageReference: reference.canonical)
            return try await client.distributionDigest(reference: reference.canonical, auth: auth)
        }
    }

    func startImageUpdateLoop() {
        imageUpdateTask?.cancel()
        imageUpdateTask = Task { [weak self] in
            // Let the first lists and the event stream come up first.
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.checkImageUpdates()
                try? await Task.sleep(for: Self.imageUpdateLoopInterval)
            }
        }
    }

    // MARK: - Update Container

    /// Pulls the image of `container` again (progress in the activity list
    /// and the menu bar), then makes the container again with the same
    /// settings. The old container stays when the pull fails or is cancelled.
    /// Nil for a Compose container or a container that Gantry does not check.
    @discardableResult
    public func updateContainer(_ container: ContainerSummary) -> LongOperation? {
        guard container.composeProject == nil, let target = imageUpdateTarget(for: container) else { return nil }
        let center = operations ?? OperationCenter()
        let title = String(localized: "Update \(container.displayName)", bundle: .module)
        return center.run(.pull, title: title, host: host.name) { [weak self] operation in
            guard let self else { return nil }
            try await self.performUpdate(container, reference: target.reference.canonical, operation: operation)
            return String(localized: "Updated to the new image.", bundle: .module)
        }
    }

    func performUpdate(_ container: ContainerSummary, reference: String, operation: LongOperation?) async throws {
        guard let details = await details(for: container.id) else {
            throw OperationFailure(String(localized: "Could not read the container settings.", bundle: .module))
        }
        // Read the defaults of the old image before the pull moves the tag.
        let defaults = await oldImageDefaults(for: container)
        var tracker = PullProgressTracker()
        for try await update in try await pullImage(reference: container.image) {
            tracker.apply(update)
            operation?.report(tracker.progress, status: update.status, fraction: tracker.fraction)
        }
        try Task.checkCancellation()
        await refreshImages()
        operation?.report(tracker.progress, status: String(localized: "Recreating the container", bundle: .module))
        let request = updateRequest(container: container, details: details, imageDefaults: defaults)
        try await recreate(container) { _, next in next = request }
    }

    /// `recreationRequest` with the user environment and command only, and
    /// the network mode of a Docker container.
    func updateRequest(
        container: ContainerSummary, details: ContainerDetails, imageDefaults: (env: [String], cmd: [String]?)
    ) -> ContainerCreateRequest {
        var request = recreationRequest(container: container, details: details)
        request.env = ImageUpdatePlan.userEnvironment(container: request.env, image: imageDefaults.env)
        request.cmd = ImageUpdatePlan.userCommand(container: request.cmd, image: imageDefaults.cmd)
        if !host.isAppleContainer, let mode = details.hostConfig.networkMode, !mode.isEmpty {
            request.hostConfig?.networkMode = mode
        }
        return request
    }

    /// `Config.Env` and `Config.Cmd` of the image that the container runs.
    /// Apple inspects by reference (the tag is not pulled yet at this time).
    func oldImageDefaults(for container: ContainerSummary) async -> (env: [String], cmd: [String]?) {
        guard let client else { return ([], nil) }
        let id = host.isAppleContainer ? container.image : container.imageID
        guard let data = try? await client.rawInspectImage(id: id) else { return ([], nil) }
        return ImageUpdatePlan.imageDefaults(fromInspect: data)
    }
}
