import Foundation
import DockerKit

extension HostSession {
    /// How many items a bulk run works on at the same time.
    static let bulkConcurrency = 4

    /// The selected items of `resource`, in list order, split into the ones
    /// `action` applies to and the ones it skips.
    public func bulkPlan(_ action: BulkAction, on resource: BulkResource, ids: Set<String>) -> BulkPlan {
        switch resource {
        case .containers: .containers(containers.filter { ids.contains($0.id) }, action: action)
        case .images: .images(images.filter { ids.contains($0.id) }, action: action)
        case .volumes: .volumes(volumes.filter { ids.contains($0.name) }, action: action)
        case .networks: .networks(networks.filter { ids.contains($0.id) }, action: action)
        }
    }

    /// The shared remove confirmation for the selected items.
    public func bulkRemoveAction(on resource: BulkResource, ids: Set<String>) -> DestructiveAction? {
        let engine = DestructiveAction.Engine(host)
        switch resource {
        case .containers:
            let selected = containers.filter { ids.contains($0.id) }
            return selected.isEmpty ? nil : .removeContainers(selected, engine: engine)
        case .images:
            let selected = images.filter { ids.contains($0.id) }
            return selected.isEmpty ? nil : .removeImages(selected, containers: containers, engine: engine)
        case .volumes:
            let names = volumes.map(\.name).filter { ids.contains($0) }
            return names.isEmpty ? nil : .removeVolumes(names: names, containers: containers, engine: engine)
        case .networks:
            let plan = BulkPlan.networks(networks.filter { ids.contains($0.id) }, action: .remove(force: false))
            let selected = networks.filter { network in plan.eligible.contains { $0.id == network.id } }
            return selected.isEmpty ? nil : .removeNetworks(selected)
        }
    }

    /// Runs `action` on the selected items as one long operation with
    /// per-item progress. A failed item does not stop the others; the
    /// failures go to the banner and to the operation. Nil when no selected
    /// item applies.
    @discardableResult
    public func runBulk(_ action: BulkAction, on resource: BulkResource, ids: Set<String>) -> LongOperation? {
        let plan = bulkPlan(action, on: resource, ids: ids)
        guard !plan.eligible.isEmpty else { return nil }
        let center = operations ?? OperationCenter()
        let title = String(
            localized: "\(action.displayName): \(resource.countText(plan.eligible.count))", bundle: .module
        )
        return center.run(.bulk, title: title, host: host.name) { [weak self] operation in
            guard let self else { return nil }
            let outcome = await self.performBulk(action, on: resource, plan: plan, operation: operation)
            if let report = outcome.failureReport {
                self.report(report)
                throw OperationFailure(report)
            }
            return outcome.summary
        }
    }

    /// The work of ``runBulk(_:on:ids:)``: at most ``bulkConcurrency`` items
    /// at a time, then one refresh of the list.
    func performBulk(
        _ action: BulkAction, on resource: BulkResource, plan: BulkPlan, operation: LongOperation?
    ) async -> BulkOutcome {
        let items = plan.eligible
        var results = [BulkStepResult?](repeating: nil, count: items.count)
        var finished = 0
        operation?.update(progress: progressText(0, items.count), fraction: 0)
        await withTaskGroup(of: (Int, BulkStepResult).self) { group in
            var next = 0
            while next < items.count || !group.isEmpty {
                // Fill the free slots, then wait for one item to finish.
                while next < items.count, next - finished < Self.bulkConcurrency, !Task.isCancelled {
                    let index = next
                    let item = items[index]
                    group.addTask { [self] in (index, await self.bulkStep(action, resource, item)) }
                    next += 1
                }
                guard let (index, result) = await group.next() else { break }
                results[index] = result
                finished += 1
                log(result, for: items[index], to: operation)
                operation?.update(
                    progress: progressText(finished, items.count),
                    fraction: Double(finished) / Double(items.count)
                )
            }
        }
        var outcome = BulkOutcome(action: action, resource: resource, skipped: plan.skipped)
        for (item, result) in zip(items, results) {
            switch result {
            case .done: outcome.succeeded.append(item)
            case .failed(let message): outcome.failed.append(BulkFailure(item: item, message: message))
            case .cancelled, nil: outcome.notRun.append(item)
            }
        }
        if outcome.failed.isEmpty, !outcome.succeeded.isEmpty { clearStaleError() }
        await refresh(resource)
        return outcome
    }

    private func progressText(_ done: Int, _ total: Int) -> String {
        String(localized: "\(done) of \(total)", bundle: .module)
    }

    private func log(_ result: BulkStepResult, for item: BulkItem, to operation: LongOperation?) {
        switch result {
        case .done: operation?.append(log: String(localized: "\(item.name): done", bundle: .module))
        case .failed(let message): operation?.append(log: "\(item.name): \(message)")
        case .cancelled: break
        }
    }

    private func refresh(_ resource: BulkResource) async {
        switch resource {
        case .containers: await refreshContainers()
        case .images: await refreshImages()
        case .volumes: await refreshVolumes()
        case .networks: await refreshNetworks()
        }
    }

    /// Runs the action on one item and returns the outcome; never throws.
    private func bulkStep(_ action: BulkAction, _ resource: BulkResource, _ item: BulkItem) async -> BulkStepResult {
        guard let client else { return .failed(String(localized: "Not connected", bundle: .module)) }
        if Task.isCancelled { return .cancelled }
        if resource == .containers, [.stop, .restart].contains(action) || action.isRemove {
            markExpectedExit(item.id)
        }
        do {
            try await execute(action, resource, item.id, client: client)
            return .done
        } catch {
            if OperationCenter.isCancellation(error) || Task.isCancelled { return .cancelled }
            return .failed(Self.message(for: error))
        }
    }

    private func execute(_ action: BulkAction, _ resource: BulkResource, _ id: String, client: DockerClient) async throws {
        switch (resource, action) {
        case (.containers, .start): try await client.startContainer(id: id)
        case (.containers, .stop): try await client.stopContainer(id: id, timeout: nil)
        case (.containers, .restart): try await client.restartContainer(id: id, timeout: nil)
        case (.containers, .pause): try await client.pauseContainer(id: id)
        case (.containers, .unpause): try await client.unpauseContainer(id: id)
        case (.containers, .remove(let force)): try await client.removeContainer(id: id, force: force, removeVolumes: false)
        case (.images, .remove(let force)): try await client.removeImage(id: id, force: force)
        case (.images, .pull):
            // `id` is the tag here (see BulkPlan.images); drain the progress.
            for try await _ in try await pullImage(reference: id) {}
        case (.volumes, .remove(let force)): try await client.removeVolume(name: id, force: force)
        case (.networks, .remove): try await client.removeNetwork(id: id)
        default: throw OperationFailure(String(localized: "This action is not available here.", bundle: .module))
        }
    }
}

/// The result of one item in a bulk run.
enum BulkStepResult: Equatable, Sendable {
    case done
    case failed(String)
    case cancelled
}
