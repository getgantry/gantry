import Foundation
import DockerKit

extension HostSession {
    /// The engine of the Edit Resources sheet for this host.
    public var resourceEngine: ContainerResourceForm.Engine {
        host.isAppleContainer ? .apple : .docker
    }

    /// The CPU count of the host for the CPU check; 0 when it is not known.
    public var hostCPUCount: Int {
        if let count = info?.ncpu, count > 0 { return count }
        return host.isAppleContainer ? ProcessInfo.processInfo.activeProcessorCount : 0
    }

    /// The form with the current values of `container`, from a fresh inspect.
    public func resourceForm(for container: ContainerSummary) async -> ContainerResourceForm? {
        guard let details = await details(for: container.id) else { return nil }
        return ContainerResourceForm(
            original: ContainerResources(details: details), engine: resourceEngine, hostCPUs: hostCPUCount
        )
    }

    /// Applies the form. Docker updates the container in place; an Apple host
    /// recreates it. Throws the daemon or CLI error. Returns the warnings.
    @discardableResult
    public func applyResources(_ form: ContainerResourceForm, to container: ContainerSummary) async throws -> [String] {
        var warnings: [String] = []
        switch form.engine {
        case .docker:
            guard let update = form.dockerUpdate() else { throw Self.invalidResources }
            guard let client else { throw DockerError.connectionFailed(String(localized: "Not connected", bundle: .module)) }
            if !update.isEmpty { warnings = try await client.updateContainer(id: container.id, update: update) }
        case .apple:
            guard form.appleLimits() != nil else { throw Self.invalidResources }
            try await recreate(container) { _, request in form.applyAppleLimits(to: &request) }
        }
        await refreshAfterResourceChange(container.id)
        return warnings
    }

    private static var invalidResources: OperationFailure {
        OperationFailure(String(localized: "Some values are not valid.", bundle: .module))
    }

    /// Loads the inspect and the list again, and tells the views to reload.
    func refreshAfterResourceChange(_ containerID: String) async {
        _ = await details(for: containerID)
        await refreshContainers()
        resourceRevisions[containerID, default: 0] += 1
    }

    /// The text of an apply error for the sheet: the daemon message as it is.
    public static func resourceErrorText(_ error: Error) -> String {
        if case DockerError.apiError(_, let message) = error, !message.isEmpty { return message }
        return error.localizedDescription
    }

    /// The revision of `containerID` for `.task(id:)`.
    public func resourceRevision(_ containerID: String) -> Int {
        resourceRevisions[containerID] ?? 0
    }
}
