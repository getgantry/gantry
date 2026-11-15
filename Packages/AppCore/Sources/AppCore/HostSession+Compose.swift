import Foundation
import DockerKit

/// The items that Compose down and Compose pull work on, found from the
/// `com.docker.compose.project` label of the containers and networks.
public enum ComposeProjectPlan {
    /// The containers of `project`.
    public static func members(_ project: String, in containers: [ContainerSummary]) -> [ContainerSummary] {
        containers.filter { $0.composeProject == project }
    }

    /// Down stops and removes every container of the project.
    public static func downContainers(_ project: String, in containers: [ContainerSummary]) -> BulkPlan {
        BulkPlan.containers(members(project, in: containers), action: .down)
    }

    /// The networks that the project made: the ones with its label. External
    /// networks have no project label, so they stay.
    public static func downNetworks(_ project: String, in networks: [NetworkResource]) -> [NetworkResource] {
        networks.filter {
            $0.labels[ComposeRunner.Label.project] == project && !BulkPlan.builtInNetworks.contains($0.name)
        }
    }

    /// One pull for each image reference that the project containers use. A
    /// container that shows an image id (its tag moved or it was never
    /// tagged) has nothing to pull, so it is skipped.
    public static func pull(_ project: String, in containers: [ContainerSummary]) -> BulkPlan {
        var plan = BulkPlan(eligible: [], skipped: [])
        var seen: Set<String> = []
        for container in members(project, in: containers) {
            let reference = container.image
            guard seen.insert(reference).inserted else { continue }
            let item = BulkItem(id: reference, name: reference)
            if isPullable(reference) { plan.eligible.append(item) } else { plan.skipped.append(item) }
        }
        return plan
    }

    static func isPullable(_ reference: String) -> Bool {
        guard !reference.isEmpty, !reference.hasPrefix("sha256:") else { return false }
        // A bare 64-hex id (some engines drop the prefix).
        return !(reference.count == 64 && reference.allSatisfy(\.isHexDigit))
    }
}

extension HostSession {
    /// Stops and removes the containers of a Compose project, then the
    /// networks it made. Volumes and images stay (the default of `docker
    /// compose down`). ``ComposeDown`` does the same without a session, for
    /// Shortcuts; this one reports progress and can be cancelled.
    /// Nil when the project has no containers.
    @discardableResult
    public func composeDown(project: String) -> LongOperation? {
        let plan = ComposeProjectPlan.downContainers(project, in: containers)
        guard !plan.eligible.isEmpty else { return nil }
        let title = String(localized: "Compose down \(project)", bundle: .module)
        return runPlan(.down, on: .containers, plan: plan, kind: .composeDown, title: title) { session, operation in
            await session.removeProjectNetworks(project, operation: operation)
        }
    }

    /// Pulls the image of each service of a Compose project again. The
    /// containers keep running on the old image until the next Compose up.
    @discardableResult
    public func composePull(project: String) -> LongOperation? {
        let plan = ComposeProjectPlan.pull(project, in: containers)
        guard !plan.eligible.isEmpty else { return nil }
        let title = String(localized: "Compose pull \(project)", bundle: .module)
        return runPlan(.pull, on: .images, plan: plan, kind: .composePull, title: title)
    }

    /// Removes the project networks; returns one line for each failure.
    private func removeProjectNetworks(_ project: String, operation: LongOperation) async -> [String] {
        await refreshNetworks()
        let targets = ComposeProjectPlan.downNetworks(project, in: networks)
        guard !targets.isEmpty, let client else { return [] }
        var failures: [String] = []
        for network in targets {
            if Task.isCancelled { break }
            do {
                try await client.removeNetwork(id: network.id)
                operation.append(log: String(localized: "\(network.name): done", bundle: .module))
            } catch {
                let line = "\(network.name): \(Self.message(for: error))"
                operation.append(log: line)
                failures.append(line)
            }
        }
        await refreshNetworks()
        return failures
    }
}
